import AppKit
import ApplicationServices
import Foundation

/// Watches for macOS notification banners from LINE and extracts sender + message text.
/// Notification banners are drawn by `com.apple.notificationcenterui` (not LINE's Qt),
/// so standard AX APIs can read the text reliably — no OCR needed.
///
/// Strategy:
///   1. AXObserver on notificationcenterui for AXWindowCreated (event-driven)
///   2. Fallback polling every 2s to catch banners missed by observer
///   3. Extract text from banner AX tree, emit to EventBus
///   4. Deduplicate via fingerprint (sender + text prefix)
final class NotificationBannerWatcher {
    private let eventBus: EventBus
    private let logger: AppLogger
    private let recentSendTracker: RecentSendTracker
    private var observer: AXObserver?
    private var fallbackTimer: Timer?
    private let bundleID = "com.apple.notificationcenterui"

    /// Fingerprints of recently processed banners to prevent duplicate events.
    /// Entries are pruned after `dedupWindowSeconds`.
    private var processedBanners: [(fingerprint: String, timestamp: Date)] = []
    private let dedupWindowSeconds: TimeInterval = 10.0

    init(eventBus: EventBus, logger: AppLogger, recentSendTracker: RecentSendTracker) {
        self.eventBus = eventBus
        self.logger = logger
        self.recentSendTracker = recentSendTracker
    }

    func start() {
        setupObserver()
        startFallbackPolling()
        logger.log(.info, "NotificationBannerWatcher started")
    }

    func stop() {
        if let obs = observer, let ncPid = findNCPid() {
            let appElement = AXQuery.applicationElement(pid: ncPid)
            AXObserverRemoveNotification(obs, appElement, kAXWindowCreatedNotification as CFString)
        }
        observer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        logger.log(.info, "NotificationBannerWatcher stopped")
    }

    // MARK: - AXObserver (event-driven)

    private func setupObserver() {
        guard let ncPid = findNCPid() else {
            logger.log(.warning, "NotificationBannerWatcher: notificationcenterui not found, will retry via polling")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var obs: AXObserver?
        let status = AXObserverCreate(ncPid, notificationCallback, &obs)
        guard status == .success, let axObserver = obs else {
            logger.log(.warning, "NotificationBannerWatcher: AXObserverCreate failed (\(status.rawValue))")
            return
        }

        let appElement = AXQuery.applicationElement(pid: ncPid)
        let addStatus = AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)
        if addStatus == .success {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
            self.observer = axObserver
            logger.log(.debug, "NotificationBannerWatcher: AXObserver registered for window creation")
        } else {
            logger.log(.warning, "NotificationBannerWatcher: AXObserverAddNotification failed (\(addStatus.rawValue))")
        }
    }

    private func startFallbackPolling() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanBanners()
        }
    }

    /// Called by AXObserver when a new window is created in notificationcenterui.
    func handleWindowCreated() {
        // Small delay to let the banner populate its AX children
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scanBanners()
        }
    }

    // MARK: - Banner scanning

    private func scanBanners() {
        guard let ncPid = findNCPid() else { return }

        let appElement = AXQuery.applicationElement(pid: ncPid)
        let windows = AXQuery.windows(appElement: appElement)
        guard !windows.isEmpty else { return }

        for window in windows {
            processNotificationWindow(window)
        }
    }

    private func processNotificationWindow(_ window: AXUIElement) {
        // Walk the AX tree of the notification window to find text nodes
        let nodes = AXQuery.descendants(of: window, maxDepth: 8, maxNodes: 50)

        // Find all AXStaticText nodes with non-empty values
        let textNodes: [(text: String, frame: CGRect?)] = nodes.compactMap { node in
            guard node.role == "AXStaticText" else { return nil }
            let text = node.value ?? node.title ?? node.description
            guard let t = text, !t.isEmpty else { return nil }
            return (text: t, frame: node.frame)
        }

        guard !textNodes.isEmpty else { return }

        // Check if this is a LINE notification
        // Look for "LINE" in the text nodes (app name label)
        let isLINE = textNodes.contains { node in
            node.text == "LINE" || node.text.hasPrefix("LINE")
        }
        guard isLINE else { return }

        // Extract sender and message from the remaining text nodes
        // Typical structure: [app_name, sender_name, message_preview]
        // or: [app_name, "sender_name: message_preview"]
        let nonAppTexts = textNodes.filter { $0.text != "LINE" }

        var sender = ""
        var messageText = ""

        if nonAppTexts.count >= 2 {
            // Two or more text nodes after "LINE" -> first is sender, rest is message
            sender = nonAppTexts[0].text
            messageText = nonAppTexts[1...].map(\.text).joined(separator: "\n")
        } else if nonAppTexts.count == 1 {
            // Single text node — may be "sender: message" format
            let combined = nonAppTexts[0].text
            if let colonRange = combined.range(of: ": ") {
                sender = String(combined[..<colonRange.lowerBound])
                messageText = String(combined[colonRange.upperBound...])
            } else {
                messageText = combined
            }
        }

        // Skip if no meaningful content
        guard !messageText.isEmpty || !sender.isEmpty else { return }

        // Deduplicate
        let fingerprint = "notif:\(sender):\(messageText.prefix(30))"
        pruneStaleBanners()
        if processedBanners.contains(where: { $0.fingerprint == fingerprint }) {
            return
        }
        processedBanners.append((fingerprint: fingerprint, timestamp: Date()))

        // Echo suppression
        let isEcho = recentSendTracker.isLikelyEcho()
        let eventType = isEcho ? "echo_message" : "inbound_message"

        _ = eventBus.append(
            type: eventType,
            adapter: "line",
            payload: [
                "text": messageText,
                "sender": sender,
                "source": "notification_banner",
                "confidence": "high",
                "score": "95",
                "signals": "notification_banner",
                "pipeline_version": "line-banner-v1",
            ]
        )
        logger.log(.info, "NotificationBannerWatcher: \(eventType) from \(sender.isEmpty ? "unknown" : sender) via banner (text: \(messageText.prefix(50)))")
    }

    // MARK: - Helpers

    private func findNCPid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    private func pruneStaleBanners() {
        let cutoff = Date().addingTimeInterval(-dedupWindowSeconds)
        processedBanners.removeAll { $0.timestamp < cutoff }
    }
}

// MARK: - AXObserver C callback

private func notificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<NotificationBannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleWindowCreated()
}
