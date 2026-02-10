import AppKit
import ApplicationServices
import Foundation

final class LINEInboundWatcher {
    private let eventBus: EventBus
    private let logger: AppLogger
    private let pollInterval: TimeInterval
    private let recentSendTracker: RecentSendTracker
    private let bundleIdentifier = "jp.naver.line.mac"
    private let detectionMode: String
    private let enablePixelSignal: Bool
    private let enableProcessSignal: Bool
    private let enableNotificationStoreSignal: Bool
    private let fusionEngine: LineDetectionFusionEngine

    private var timer: Timer?

    /// Snapshot of chat row frames from last poll (sorted by Y coordinate)
    private var lastRowSnapshot: [CGRect] = []
    private var lastRowCount: Int = 0

    /// Pixel-change detection state
    private var lastImageHash: UInt64 = 0
    private var lastOCRText: String = ""
    private var baselineCaptured: Bool = false

    /// Exposed for debug snapshot endpoint/logging
    private var lastSignalNames: [String] = []
    private var lastScore: Int = 0
    private var lastConfidence: String = "low"

    init(
        eventBus: EventBus,
        logger: AppLogger,
        pollIntervalSeconds: Int,
        recentSendTracker: RecentSendTracker,
        detectionMode: String,
        fusionThreshold: Int,
        enablePixelSignal: Bool,
        enableProcessSignal: Bool,
        enableNotificationStoreSignal: Bool
    ) {
        self.eventBus = eventBus
        self.logger = logger
        self.pollInterval = TimeInterval(pollIntervalSeconds)
        self.recentSendTracker = recentSendTracker
        self.detectionMode = detectionMode
        self.enablePixelSignal = enablePixelSignal
        self.enableProcessSignal = enableProcessSignal
        self.enableNotificationStoreSignal = enableNotificationStoreSignal
        self.fusionEngine = LineDetectionFusionEngine(threshold: fusionThreshold)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        logger.log(.info, "LINEInboundWatcher started (interval: \(pollInterval)s, mode: \(detectionMode))")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.log(.info, "LINEInboundWatcher stopped")
    }

    func snapshotState() -> LineDetectionStateSnapshot {
        LineDetectionStateSnapshot(
            mode: detectionMode,
            threshold: fusionEngine.threshold,
            baselineCaptured: baselineCaptured,
            lastRowCount: lastRowCount,
            lastImageHash: lastImageHash,
            lastOCRText: lastOCRText,
            lastSignals: lastSignalNames,
            lastScore: lastScore,
            lastConfidence: lastConfidence,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    func resetBaseline() {
        lastRowSnapshot = []
        lastRowCount = 0
        lastImageHash = 0
        lastOCRText = ""
        baselineCaptured = false
        lastSignalNames = []
        lastScore = 0
        lastConfidence = "low"
    }

    private func poll() {
        BlockingWork.queue.async { [weak self] in
            self?.doPoll()
        }
    }

    private func doPoll() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        let lineWindowID = AXActions.findWindowID(pid: app.processIdentifier) ?? kCGNullWindowID

        guard let window = AXQuery.focusedWindow(appElement: appElement)
            ?? AXQuery.windows(appElement: appElement).first else {
            return
        }

        let windowTitle = AXQuery.copyStringAttribute(window, attribute: kAXTitleAttribute as String) ?? ""
        let nodes = AXQuery.descendants(of: window, maxDepth: 4, maxNodes: 220)
        guard let chatList = findChatList(in: nodes) else {
            return
        }

        var signals: [LineDetectionSignal] = []

        if let structuralSignal = collectStructuralSignal(chatList: chatList, lineWindowID: lineWindowID, conversation: windowTitle) {
            signals.append(structuralSignal)
        }

        if enablePixelSignal, let pixelSignal = collectPixelSignal(chatList: chatList, lineWindowID: lineWindowID, conversation: windowTitle) {
            signals.append(pixelSignal)
        }

        if enableProcessSignal, let processSignal = collectProcessSignal(app: app, conversation: windowTitle) {
            signals.append(processSignal)
        }

        // Placeholder for future notification-store layer. We keep this config gate now
        // so rollout can be controlled without touching fusion logic again.
        if enableNotificationStoreSignal {
            logger.log(.debug, "LINEInboundWatcher: notification store signal is enabled but not implemented yet")
        }

        if detectionMode == "legacy" {
            // In legacy mode, keep historical behavior: emit from first available signal.
            if let first = signals.first {
                emitFromSignal(first)
            }
            return
        }

        let isEcho = recentSendTracker.isLikelyEcho()
        let decision = fusionEngine.decide(
            signals: signals,
            fallbackText: "",
            fallbackConversation: windowTitle,
            isEcho: isEcho
        )

        lastSignalNames = decision.signals
        lastScore = decision.score
        lastConfidence = decision.confidence

        guard decision.shouldEmit else {
            if !decision.signals.isEmpty {
                logger.log(
                    .debug,
                    "LINEInboundWatcher: detection below threshold (score=\(decision.score), threshold=\(fusionEngine.threshold), signals=\(decision.signals.joined(separator: ",")))"
                )
            }
            return
        }

        var payload: [String: String] = [
            "text": decision.text,
            "conversation": decision.conversation,
            "source": "hybrid_fusion",
            "confidence": decision.confidence,
            "score": String(decision.score),
            "signals": decision.signals.joined(separator: ","),
            "pipeline_version": "line-hybrid-v1",
        ]
        for (k, v) in decision.details {
            payload[k] = v
        }

        _ = eventBus.append(type: decision.eventType, adapter: "line", payload: payload)
        logger.log(.debug, "LINEInboundWatcher: \(decision.eventType) via fusion score=\(decision.score), conf=\(decision.confidence), signals=\(decision.signals.joined(separator: ","))")
    }

    private func emitFromSignal(_ signal: LineDetectionSignal) {
        let isEcho = recentSendTracker.isLikelyEcho()
        let eventType = isEcho ? "echo_message" : "inbound_message"

        var payload: [String: String] = [
            "text": signal.text,
            "conversation": signal.conversation,
            "source": signal.name,
            "confidence": signal.score >= 80 ? "high" : (signal.score >= 50 ? "medium" : "low"),
            "score": String(signal.score),
            "signals": signal.name,
            "pipeline_version": "line-legacy-v2",
        ]
        for (k, v) in signal.details {
            payload[k] = v
        }

        _ = eventBus.append(type: eventType, adapter: "line", payload: payload)
        lastSignalNames = [signal.name]
        lastScore = signal.score
        lastConfidence = payload["confidence"] ?? "low"
    }

    private func collectStructuralSignal(chatList: AXUIElement, lineWindowID: CGWindowID, conversation: String) -> LineDetectionSignal? {
        let rowChildren = AXQuery.children(of: chatList)
        let rowFrames: [CGRect] = rowChildren.compactMap { child in
            let role = AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute)
            guard role == "AXRow" else { return nil }
            return AXQuery.copyFrameAttribute(child)
        }.sorted { $0.origin.y < $1.origin.y }

        let currentCount = rowFrames.count
        guard currentCount > 0 else { return nil }

        let previousCount = lastRowCount
        let previousFrames = lastRowSnapshot
        let lastFrame = rowFrames.last!

        lastRowSnapshot = rowFrames
        lastRowCount = currentCount

        guard previousCount > 0 else {
            logger.log(.debug, "LINEInboundWatcher: baseline captured (\(currentCount) rows)")
            return nil
        }

        let countChanged = currentCount != previousCount
        let bottomChanged: Bool
        if let prevLast = previousFrames.last {
            bottomChanged = Int(lastFrame.origin.y) != Int(prevLast.origin.y)
                || Int(lastFrame.size.height) != Int(prevLast.size.height)
        } else {
            bottomChanged = false
        }

        guard countChanged || bottomChanged else { return nil }

        let newRowCount = max(0, currentCount - previousCount)
        let newRowFrames: [CGRect]
        if currentCount > previousCount {
            newRowFrames = Array(rowFrames.suffix(currentCount - previousCount))
        } else {
            newRowFrames = [lastFrame]
        }

        let ocrText = VisionOCR.extractText(from: newRowFrames, padding: 4, windowID: lineWindowID) ?? ""

        return LineDetectionSignal(
            name: "ax_structure",
            score: countChanged ? 70 : 58,
            text: ocrText,
            conversation: conversation,
            details: [
                "row_count_delta": String(newRowCount),
                "total_rows": String(currentCount),
                "ax_bottom_changed": bottomChanged ? "1" : "0",
            ]
        )
    }

    private func collectPixelSignal(chatList: AXUIElement, lineWindowID: CGWindowID, conversation: String) -> LineDetectionSignal? {
        guard let chatListFrame = AXQuery.copyFrameAttribute(chatList) else { return nil }

        let bottomHalf = CGRect(
            x: chatListFrame.origin.x,
            y: chatListFrame.origin.y + chatListFrame.height / 2,
            width: chatListFrame.width,
            height: chatListFrame.height / 2
        )
        let captureOptions: CGWindowListOption = lineWindowID != kCGNullWindowID
            ? .optionIncludingWindow : .optionOnScreenOnly

        guard let image = CGWindowListCreateImage(bottomHalf, captureOptions, lineWindowID, [.bestResolution]) else {
            return nil
        }

        let hash = computeImageHash(image)

        if !baselineCaptured {
            lastImageHash = hash
            lastOCRText = VisionOCR.extractText(from: chatListFrame, windowID: lineWindowID) ?? ""
            baselineCaptured = true
            logger.log(.debug, "LINEInboundWatcher: pixel baseline captured (hash: \(hash))")
            return nil
        }

        guard hash != lastImageHash else { return nil }
        let previousHash = lastImageHash
        lastImageHash = hash

        let pixelOCRText = VisionOCR.extractText(from: chatListFrame, windowID: lineWindowID) ?? ""
        let textChanged = pixelOCRText != lastOCRText
        if textChanged {
            lastOCRText = pixelOCRText
        }

        return LineDetectionSignal(
            name: "pixel_diff",
            score: textChanged ? 48 : 35,
            text: textChanged ? pixelOCRText : "",
            conversation: conversation,
            details: [
                "pixel_hash_prev": String(previousHash),
                "pixel_hash_now": String(hash),
                "pixel_text_changed": textChanged ? "1" : "0",
            ]
        )
    }

    private func collectProcessSignal(app: NSRunningApplication, conversation: String) -> LineDetectionSignal? {
        // Lightweight placeholder signal. Full proc/network metadata collection requires
        // additional low-level APIs and entitlement validation in a dedicated phase.
        guard !app.isTerminated else { return nil }
        return nil
    }

    /// Downsample image to 32x32 and compute FNV-1a hash for fast change detection.
    private func computeImageHash(_ image: CGImage) -> UInt64 {
        let size = 32
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return 0 }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 14695981039346656037  // FNV offset basis
        for i in 0..<(size * size * 4) {
            hash ^= UInt64(bytes[i])
            hash &*= 1099511628211  // FNV prime
        }
        return hash
    }

    /// Find the chat message list element.
    /// Strategy: look for AXList nodes and pick the one with the most AXRow children.
    private func findChatList(in nodes: [AXNode]) -> AXUIElement? {
        var bestList: AXUIElement?
        var bestRowCount = 0

        for node in nodes {
            guard node.role == "AXList" else { continue }

            let children = AXQuery.children(of: node.element)
            let rowCount = children.filter { child in
                AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute) == "AXRow"
            }.count

            if rowCount > bestRowCount {
                bestRowCount = rowCount
                bestList = node.element
            }
        }

        return bestList
    }
}
