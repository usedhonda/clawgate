import AppKit
import ApplicationServices
import Foundation

final class LINEInboundWatcher {
    private let eventBus: EventBus
    private let logger: AppLogger
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastSnapshot: String?
    private var seenHashes: [Int] = []
    private let maxSeenHashes = 20
    private let bundleIdentifier = "jp.naver.line.mac"

    init(eventBus: EventBus, logger: AppLogger, pollIntervalSeconds: Int) {
        self.eventBus = eventBus
        self.logger = logger
        self.pollInterval = TimeInterval(pollIntervalSeconds)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        logger.log(.info, "LINEInboundWatcher started (interval: \(pollInterval)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.log(.info, "LINEInboundWatcher stopped")
    }

    private func poll() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            return
        }

        let nodes = AXQuery.descendants(of: window, maxDepth: 6, maxNodes: 500)
        let textNodes = nodes
            .filter { $0.role == "AXStaticText" }
            .compactMap { $0.title ?? $0.description }

        let windowTitle = AXQuery.copyStringAttribute(window, attribute: kAXTitleAttribute as String)

        guard let lastText = textNodes.last else { return }

        if lastText != lastSnapshot {
            let hash = lastText.hashValue

            if !seenHashes.contains(hash) {
                seenHashes.append(hash)
                if seenHashes.count > maxSeenHashes {
                    seenHashes.removeFirst(seenHashes.count - maxSeenHashes)
                }

                _ = eventBus.append(
                    type: "inbound_message",
                    adapter: "line",
                    payload: ["text": lastText, "conversation": windowTitle ?? ""]
                )
                logger.log(.debug, "LINEInboundWatcher: new message detected")
            }

            lastSnapshot = lastText
        }
    }
}
