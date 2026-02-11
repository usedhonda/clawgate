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
    private let watchQueue = DispatchQueue(label: "com.clawgate.line.inbound-watch", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isPolling = false
    private var activePollID: UUID?
    private var consecutiveTimeouts = 0
    private var skippedPollCount = 0
    private let pollTimeoutSeconds: TimeInterval = 3.0
    private let resetAfterTimeoutStreak = 2

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
    private var lastInboundFingerprint: String = ""
    private var lastInboundAt: Date = .distantPast
    private let inboundDedupWindowSeconds: TimeInterval = 20

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
        stateLock.lock()
        isPolling = false
        activePollID = nil
        skippedPollCount = 0
        consecutiveTimeouts = 0
        stateLock.unlock()
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
        lastInboundFingerprint = ""
        lastInboundAt = .distantPast
    }

    private func poll() {
        let pollID = UUID()
        stateLock.lock()
        if isPolling {
            skippedPollCount += 1
            let shouldLog = skippedPollCount == 1 || skippedPollCount % 10 == 0
            stateLock.unlock()
            if shouldLog {
                logger.log(.warning, "LINEInboundWatcher: skipped poll (previous cycle still running, skipped=\(skippedPollCount))")
            }
            return
        }
        isPolling = true
        activePollID = pollID
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pollTimeoutSeconds) { [weak self] in
            self?.handlePollTimeout(pollID: pollID)
        }

        watchQueue.async { [weak self] in
            guard let self else { return }
            self.doPoll(pollID: pollID)
            self.finishPoll(pollID: pollID)
        }
    }

    private func handlePollTimeout(pollID: UUID) {
        stateLock.lock()
        guard isPolling, activePollID == pollID else {
            stateLock.unlock()
            return
        }

        consecutiveTimeouts += 1
        isPolling = false
        activePollID = nil
        let timeoutStreak = consecutiveTimeouts
        stateLock.unlock()

        logger.log(.warning, "LINEInboundWatcher: poll timeout (\(Int(pollTimeoutSeconds))s). Soft-releasing cycle to keep watcher alive (streak=\(timeoutStreak))")

        if timeoutStreak >= resetAfterTimeoutStreak {
            resetBaseline()
            logger.log(.warning, "LINEInboundWatcher: baseline reset after repeated timeouts (streak=\(timeoutStreak))")
        }
    }

    private func finishPoll(pollID: UUID) {
        stateLock.lock()
        guard activePollID == pollID else {
            // Timed-out poll finished later; keep current state untouched.
            stateLock.unlock()
            return
        }
        isPolling = false
        activePollID = nil
        consecutiveTimeouts = 0
        skippedPollCount = 0
        stateLock.unlock()
    }

    private func shouldContinue(pollID: UUID) -> Bool {
        stateLock.lock()
        let keep = activePollID == pollID
        stateLock.unlock()
        return keep
    }

    private func doPoll(pollID: UUID) {
        guard shouldContinue(pollID: pollID) else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        let lineWindowID = AXActions.findWindowID(pid: app.processIdentifier) ?? kCGNullWindowID

        guard shouldContinue(pollID: pollID) else { return }
        guard let window = AXQuery.focusedWindow(appElement: appElement)
            ?? AXQuery.windows(appElement: appElement).first else {
            return
        }

        guard shouldContinue(pollID: pollID) else { return }
        let windowTitle = AXQuery.copyStringAttribute(window, attribute: kAXTitleAttribute as String) ?? ""
        let nodes = AXQuery.descendants(of: window, maxDepth: 4, maxNodes: 220)
        guard let chatList = findChatList(in: nodes) else {
            return
        }

        var signals: [LineDetectionSignal] = []

        if let structuralSignal = collectStructuralSignal(chatList: chatList, lineWindowID: lineWindowID, conversation: windowTitle) {
            signals.append(structuralSignal)
        }

        guard shouldContinue(pollID: pollID) else { return }
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

        let decisionText = signals.first(where: { !$0.text.isEmpty })?.text ?? ""
        let isEcho = recentSendTracker.isLikelyEcho(text: decisionText)
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

        let filteredDecisionText = LineTextSanitizer.sanitize(decision.text)
        guard !filteredDecisionText.isEmpty else {
            logger.log(.debug, "LINEInboundWatcher: dropped empty/standalone-ui text after sanitize")
            return
        }
        if shouldSuppressDuplicateInbound(text: filteredDecisionText, conversation: decision.conversation) {
            logger.log(.debug, "LINEInboundWatcher: suppressed duplicate inbound within dedup window")
            return
        }

        var payload: [String: String] = [
            "text": filteredDecisionText,
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
        let filtered = LineTextSanitizer.sanitize(signal.text)
        guard !filtered.isEmpty else { return }
        if shouldSuppressDuplicateInbound(text: filtered, conversation: signal.conversation) {
            logger.log(.debug, "LINEInboundWatcher: suppressed duplicate inbound within dedup window (legacy)")
            return
        }
        let isEcho = recentSendTracker.isLikelyEcho(text: filtered)
        let eventType = isEcho ? "echo_message" : "inbound_message"

        var payload: [String: String] = [
            "text": filtered,
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

    private func shouldSuppressDuplicateInbound(text: String, conversation: String) -> Bool {
        let normalized = LineTextSanitizer.normalizeForEcho(text)
        guard !normalized.isEmpty else { return false }
        let fingerprint = "\(conversation.lowercased())|\(normalized)"
        let now = Date()
        if fingerprint == lastInboundFingerprint && now.timeIntervalSince(lastInboundAt) < inboundDedupWindowSeconds {
            return true
        }
        lastInboundFingerprint = fingerprint
        lastInboundAt = now
        return false
    }

    private func collectStructuralSignal(chatList: AXUIElement, lineWindowID: CGWindowID, conversation: String) -> LineDetectionSignal? {
        let rowChildren = AXQuery.children(of: chatList)
        let rowEntries: [(element: AXUIElement, frame: CGRect)] = rowChildren.compactMap { child in
            let role = AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute)
            guard role == "AXRow", let frame = AXQuery.copyFrameAttribute(child) else { return nil }
            return (child, frame)
        }.sorted { $0.frame.origin.y < $1.frame.origin.y }

        let rowFrames = rowEntries.map(\.frame)

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
        let newRowElements: [AXUIElement]
        let newRowFrames: [CGRect]
        if currentCount > previousCount {
            newRowElements = Array(rowEntries.suffix(currentCount - previousCount)).map(\.element)
            newRowFrames = Array(rowFrames.suffix(currentCount - previousCount))
        } else {
            newRowElements = [rowEntries.last!.element]
            newRowFrames = [lastFrame]
        }

        let incomingCandidates = zip(newRowElements, newRowFrames).filter { element, frame in
            rowLikelyInbound(rowElement: element, rowFrame: frame, chatList: chatList, lineWindowID: lineWindowID)
        }
        let incomingRows = incomingCandidates.map(\.0)
        let incomingFrames = incomingCandidates.map(\.1)
        let hasOnlyOutgoingRows = !newRowFrames.isEmpty && incomingFrames.isEmpty
        if hasOnlyOutgoingRows {
            return nil
        }

        let ocrFrames = selectOCRFrames(
            incomingFrames: incomingFrames,
            lastFrame: lastFrame,
            countChanged: countChanged,
            newRowCount: newRowCount
        )
        let ocrText = extractInboundOCRText(from: ocrFrames, lineWindowID: lineWindowID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let axFallbackText = extractTextFromRows(incomingRows)
        let structuralFallbackOCR = collectStructuralFallbackOCR(
            lastFrame: lastFrame,
            lineWindowID: lineWindowID
        )
        let mergedText: String
        if !ocrText.isEmpty {
            mergedText = ocrText
        } else if !axFallbackText.isEmpty {
            mergedText = axFallbackText
        } else {
            mergedText = structuralFallbackOCR
        }

        return LineDetectionSignal(
            name: "ax_structure",
            score: countChanged ? 70 : 58,
            text: mergedText,
            conversation: conversation,
            details: [
                "row_count_delta": String(newRowCount),
                "total_rows": String(currentCount),
                "ax_bottom_changed": bottomChanged ? "1" : "0",
                "incoming_rows": String(incomingFrames.count),
                "ocr_empty_fallback_ax": ocrText.isEmpty ? "1" : "0",
                "ocr_text_len": String(ocrText.count),
                "merged_text_len": String(mergedText.count),
                "merged_text_head": textHeadForLog(mergedText),
                "ax_fallback_text_len": String(axFallbackText.count),
                "ocr_fallback_text_len": String(structuralFallbackOCR.count),
            ]
        )
    }

    private func collectStructuralFallbackOCR(lastFrame: CGRect, lineWindowID: CGWindowID) -> String {
        // Fallback 1: OCR from latest row with wider padding.
        let rowText = (VisionOCR.extractTextLineInbound(from: inboundCropRect(for: lastFrame, horizontalRatio: 0.82), windowID: lineWindowID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rowText
    }

    private func extractInboundOCRText(from incomingFrames: [CGRect], lineWindowID: CGWindowID) -> String {
        guard !incomingFrames.isEmpty else { return "" }

        // OCR each row independently to avoid a wide union-crop pulling in older/adjacent bubbles.
        let ordered = incomingFrames.sorted { $0.origin.y < $1.origin.y }
        var rows: [String] = []
        for frame in ordered {
            let crop = inboundCropRect(for: frame, horizontalRatio: 0.90)
            let text = (VisionOCR.extractTextLineInbound(from: crop, windowID: lineWindowID) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let normalized = LineTextSanitizer.sanitize(text)
                if !normalized.isEmpty {
                    mergeOCRRowPreferLonger(normalized, into: &rows)
                }
            }
        }
        return rows.joined(separator: "\n")
    }

    /// Deduplicate OCR rows while preserving richer text.
    /// If one candidate contains another, keep the longer one.
    private func mergeOCRRowPreferLonger(_ candidate: String, into rows: inout [String]) {
        var replaced = false
        rows.removeAll { existing in
            if existing == candidate { return true }
            if existing.contains(candidate) {
                replaced = true
                return false
            }
            if candidate.contains(existing) {
                return true
            }
            return false
        }
        if !replaced {
            rows.append(candidate)
        }
    }

    private func textHeadForLog(_ text: String, maxChars: Int = 48) -> String {
        guard !text.isEmpty else { return "" }
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= maxChars { return compact }
        let end = compact.index(compact.startIndex, offsetBy: maxChars)
        return String(compact[..<end]) + "..."
    }

    private func selectOCRFrames(
        incomingFrames: [CGRect],
        lastFrame: CGRect,
        countChanged: Bool,
        newRowCount: Int
    ) -> [CGRect] {
        guard !incomingFrames.isEmpty else { return [newestSliceRect(for: lastFrame)] }
        // Qt/LINE frequently keeps row count unchanged while appending text to the tail.
        // In that case, prioritize the bottom slice to avoid re-reading older bubbles above.
        if !countChanged || newRowCount == 0 {
            // Keep both tail slice and full row to avoid dropping long wrapped messages.
            return [newestSliceRect(for: lastFrame), lastFrame]
        }
        return incomingFrames
    }

    private func newestSliceRect(for frame: CGRect) -> CGRect {
        let h = frame.height
        let sliceHeight = min(max(h * 0.72, 120), 420)
        return CGRect(
            x: frame.origin.x,
            y: frame.maxY - sliceHeight,
            width: frame.width,
            height: sliceHeight
        )
    }

    private func inboundCropRect(for frame: CGRect, horizontalRatio: CGFloat) -> CGRect {
        let ratio = max(0.45, min(horizontalRatio, 1.0))
        let width = max(40, frame.width * ratio)
        let rect = CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: width,
            height: frame.height
        )
        return rect.insetBy(dx: -4, dy: -2)
    }

    private func extractTextFromRows(_ rows: [AXUIElement]) -> String {
        var collected: [String] = []
        var seen = Set<String>()

        for row in rows {
            collectTextRecursive(
                row,
                depth: 0,
                maxDepth: 6,
                maxNodes: 220,
                visited: 0,
                out: &collected,
                seen: &seen
            )
            if collected.count >= 8 {
                break
            }
        }

        return collected.joined(separator: "\n")
    }

    private func collectTextRecursive(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        visited: Int,
        out: inout [String],
        seen: inout Set<String>
    ) {
        guard depth <= maxDepth, visited < maxNodes else { return }

        let attrs = [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String]
        for attr in attrs {
            guard let raw = AXQuery.copyStringAttribute(element, attribute: attr) else { continue }
            let normalized = LineTextSanitizer.sanitize(raw)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                out.append(normalized)
                if out.count >= 8 {
                    return
                }
            }
        }

        let children = AXQuery.children(of: element)
        if children.isEmpty { return }

        var localVisited = visited + 1
        for child in children {
            collectTextRecursive(
                child,
                depth: depth + 1,
                maxDepth: maxDepth,
                maxNodes: maxNodes,
                visited: localVisited,
                out: &out,
                seen: &seen
            )
            localVisited += 1
            if out.count >= 8 || localVisited >= maxNodes {
                return
            }
        }
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
        let inboundHalf = computeInboundAnchorCrop(in: image, baseRect: bottomHalf)

        let hash = computeImageHash(image)

        if !baselineCaptured {
            lastImageHash = hash
            let baseline = burstInboundOCR(from: inboundHalf, windowID: lineWindowID)
            lastOCRText = baseline.text
            baselineCaptured = true
            logger.log(.debug, "LINEInboundWatcher: pixel baseline captured (hash: \(hash))")
            return nil
        }

        guard hash != lastImageHash else { return nil }
        let previousHash = lastImageHash
        lastImageHash = hash

        let burst = burstInboundOCR(from: inboundHalf, windowID: lineWindowID)
        let pixelOCRText = burst.text
        let previousOCRText = lastOCRText
        let textChanged = pixelOCRText != previousOCRText
        if textChanged {
            lastOCRText = pixelOCRText
        }
        let deltaText = textChanged ? extractDeltaText(previous: previousOCRText, current: pixelOCRText) : ""

        return LineDetectionSignal(
            name: "pixel_diff",
            // Allow pixel-only path to emit when structural AX signal is unstable.
            score: textChanged ? 62 : 35,
            text: textChanged ? LineTextSanitizer.sanitize(deltaText) : "",
            conversation: conversation,
            details: [
                "pixel_hash_prev": String(previousHash),
                "pixel_hash_now": String(hash),
                "pixel_text_changed": textChanged ? "1" : "0",
                "pixel_burst_delays_ms": burst.delaysDescription,
                "pixel_burst_chars": burst.lengthsDescription,
                "pixel_anchor_y": burst.anchorYDescription,
            ]
        )
    }

    private func extractDeltaText(previous: String, current: String) -> String {
        let normalizedPrevious = LineTextSanitizer.sanitize(previous)
        let normalizedCurrent = LineTextSanitizer.sanitize(current)
        guard !normalizedCurrent.isEmpty else { return "" }
        guard !normalizedPrevious.isEmpty else { return normalizedCurrent }

        let previousLines = Set(
            normalizedPrevious
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let currentLines = normalizedCurrent
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let delta = currentLines.filter { !previousLines.contains($0) }
        if delta.isEmpty {
            // Keep current text to avoid false drops caused by OCR line segmentation drift.
            return normalizedCurrent
        }
        return delta.joined(separator: "\n")
    }

    private func collectProcessSignal(app: NSRunningApplication, conversation: String) -> LineDetectionSignal? {
        // Lightweight placeholder signal. Full proc/network metadata collection requires
        // additional low-level APIs and entitlement validation in a dedicated phase.
        guard !app.isTerminated else { return nil }
        return nil
    }

    private func rowLikelyInbound(
        rowElement: AXUIElement,
        rowFrame: CGRect,
        chatList: AXUIElement,
        lineWindowID: CGWindowID
    ) -> Bool {
        guard let chatFrame = AXQuery.copyFrameAttribute(chatList) else {
            return true
        }
        let centerX = chatFrame.midX
        let rowMidX = rowFrame.midX

        // Geometry is the cheapest first filter.
        if rowMidX < centerX - 28 {
            return true
        }
        if rowMidX > centerX + 28 {
            return false
        }

        // Color pre-filter before OCR for ambiguous center-aligned rows.
        guard let avg = averageRowColor(rowFrame: rowFrame, lineWindowID: lineWindowID) else {
            return true
        }
        if looksOutgoingBubbleColor(avg) {
            return false
        }
        if looksIncomingBubbleColor(avg) {
            return true
        }

        // AX metadata fallback: sender name often appears on inbound rows.
        let marker = extractTextFromRows([rowElement]).lowercased()
        if marker.contains("既読") {
            return false
        }
        return true
    }

    private func averageRowColor(rowFrame: CGRect, lineWindowID: CGWindowID) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let options: CGWindowListOption = lineWindowID != kCGNullWindowID ? .optionIncludingWindow : .optionOnScreenOnly
        guard let image = CGWindowListCreateImage(rowFrame, options, lineWindowID, [.bestResolution]) else {
            return nil
        }
        guard let ctx = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (
            r: CGFloat(bytes[0]),
            g: CGFloat(bytes[1]),
            b: CGFloat(bytes[2])
        )
    }

    private func looksOutgoingBubbleColor(_ avg: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        avg.g > 118 && avg.g > avg.r + 10 && avg.g > avg.b + 16
    }

    private func looksIncomingBubbleColor(_ avg: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        abs(avg.r - avg.g) < 18 && abs(avg.g - avg.b) < 18 && avg.r > 108 && avg.r < 240
    }

    private func burstInboundOCR(from rect: CGRect, windowID: CGWindowID) -> (text: String, delaysDescription: String, lengthsDescription: String, anchorYDescription: String) {
        let delays = [0, 180, 420]
        var best = ""
        var lengths: [Int] = []
        for delay in delays {
            if delay > 0 { usleep(useconds_t(delay * 1000)) }
            let raw = VisionOCR.extractTextLineInbound(from: rect, windowID: windowID) ?? ""
            let sanitized = LineTextSanitizer.sanitize(raw)
            lengths.append(sanitized.count)
            if sanitized.count > best.count {
                best = sanitized
            }
        }
        return (
            text: best,
            delaysDescription: delays.map(String.init).joined(separator: ","),
            lengthsDescription: lengths.map(String.init).joined(separator: ","),
            anchorYDescription: String(Int(rect.origin.y))
        )
    }

    private func computeInboundAnchorCrop(in image: CGImage, baseRect: CGRect) -> CGRect {
        guard let lineY = detectLightGraySeparatorY(in: image) else {
            return CGRect(
                x: baseRect.origin.x,
                y: baseRect.origin.y,
                width: baseRect.width * 0.90,
                height: baseRect.height
            )
        }

        // The separator we want is the thin gray line above the input area.
        // OCR should target the message area ABOVE that line, not below.
        // Keep only a tiny safety gap from the separator (just above input area).
        let maxY = baseRect.origin.y + CGFloat(lineY) - 2
        let h = max(80, maxY - baseRect.origin.y)
        return CGRect(
            x: baseRect.origin.x,
            y: baseRect.origin.y,
            width: baseRect.width * 0.90,
            height: h
        )
    }

    /// Detect a long thin light-gray separator row (e.g. unread separator) in the captured region.
    private func detectLightGraySeparatorY(in image: CGImage) -> Int? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let minY = max(0, Int(Double(height) * 0.05))
        let maxY = max(minY, Int(Double(height) * 0.92))
        var bestY: Int?
        var bestScore = 0.0
        for y in minY..<maxY {
            let rowOffset = y * bytesPerRow
            var grayCount = 0
            var longestRun = 0
            var currentRun = 0
            for x in 0..<width {
                let i = rowOffset + x * 4
                let r = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let sat = maxC - minC
                let yv = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                if sat <= 10 && yv >= 188 && yv <= 232 {
                    grayCount += 1
                    currentRun += 1
                    if currentRun > longestRun { longestRun = currentRun }
                } else {
                    currentRun = 0
                }
            }
            let score = Double(grayCount) / Double(max(width, 1))
            let runScore = Double(longestRun) / Double(max(width, 1))
            let yRatio = Double(y) / Double(max(height - 1, 1))
            // Prefer lower separators (input boundary) over mid-list separators.
            let weighted = (0.45 * score + 0.55 * runScore) * (1.0 + 0.45 * yRatio)
            if weighted > bestScore {
                bestScore = weighted
                bestY = y
            }
        }
        guard let y = bestY, bestScore >= 0.32 else { return nil }
        return y
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
