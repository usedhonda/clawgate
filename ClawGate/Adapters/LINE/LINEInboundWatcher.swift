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
    private let pollTimeoutSeconds: TimeInterval = 30.0
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
    private struct RecentInboundLineObservation {
        let conversation: String
        let normalizedLine: String
        let at: Date
    }
    private var recentInboundLineObservations: [RecentInboundLineObservation] = []
    private let maxRecentInboundLineObservations = 240
    private let inboundLineMemoryWindowSeconds: TimeInterval = 75
    private let inboundDedupWindowSeconds: TimeInterval = 20
    private let inboundDedupWindowSecondsV2: TimeInterval
    private let ingressDedupTuneV2Enabled: Bool
    private var lastSeparatorAnchorY: Int?
    private var lastSeparatorAnchorConfidence: Int = 0
    private var lastSeparatorAnchorMethod: String = "none"
    private var shouldSkipPollNoLine: Bool = false
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

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
        self.ingressDedupTuneV2Enabled = Self.envBool("CLAWGATE_INGRESS_DEDUP_TUNE_V2", defaultValue: true)
        self.inboundDedupWindowSecondsV2 = TimeInterval(
            max(
                1,
                Self.envInt("CLAWGATE_LINE_INBOUND_DEDUP_WINDOW_SEC", defaultValue: 8)
            )
        )
    }

    private static func envBool(_ key: String, defaultValue: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    private static func envInt(_ key: String, defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int(raw) else { return defaultValue }
        return parsed
    }

    private func isoString(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private func elapsedMs(from start: Date, to end: Date) -> String {
        let value = Int(max(0, end.timeIntervalSince(start) * 1000.0))
        return String(value)
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
        stateLock.lock()
        defer { stateLock.unlock() }
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
        lastSeparatorAnchorY = nil
        lastSeparatorAnchorConfidence = 0
        lastSeparatorAnchorMethod = "none"
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
        let pollStartedAt = Date()
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
        let captureDoneAt = Date()

        shouldSkipPollNoLine = false
        var signals: [LineDetectionSignal] = []
        let signalCollectStartedAt = Date()

        if let structuralSignal = collectStructuralSignal(chatList: chatList, lineWindowID: lineWindowID, conversation: windowTitle) {
            signals.append(structuralSignal)
        }

        guard shouldContinue(pollID: pollID) else { return }
        if enablePixelSignal, let pixelSignal = collectPixelSignal(chatList: chatList, nodes: nodes, windowFrame: AXQuery.copyFrameAttribute(window) ?? .zero, lineWindowID: lineWindowID, conversation: windowTitle) {
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
        let signalCollectDoneAt = Date()

        if detectionMode == "legacy" {
            // In legacy mode, keep historical behavior: emit from first available signal.
            if let first = signals.first {
                emitFromSignal(first)
            }
            return
        }

        let fusionStartedAt = Date()
        let decisionText = signals.first(where: { !$0.text.isEmpty })?.text ?? ""
        let isEcho = recentSendTracker.isLikelyEcho(text: decisionText)
        let decision = fusionEngine.decide(
            signals: signals,
            fallbackText: "",
            fallbackConversation: windowTitle,
            isEcho: isEcho
        )
        let fusionDoneAt = Date()

        func buildTimingFields(now: Date, dropStage: String, dropReason: String) -> [String: String] {
            [
                "poll_started_at": isoString(pollStartedAt),
                "capture_done_at": isoString(captureDoneAt),
                "signal_collect_done_at": isoString(signalCollectDoneAt),
                "fusion_done_at": isoString(fusionDoneAt),
                "capture_ms": elapsedMs(from: pollStartedAt, to: captureDoneAt),
                "signal_collect_ms": elapsedMs(from: signalCollectStartedAt, to: signalCollectDoneAt),
                "fusion_ms": elapsedMs(from: fusionStartedAt, to: fusionDoneAt),
                "total_detect_ms": elapsedMs(from: pollStartedAt, to: now),
                "drop_stage": dropStage,
                "drop_reason_detail": dropReason,
            ]
        }

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
            savePipelineResult(
                decision: decision,
                sanitizedText: nil,
                dedupResult: "n/a",
                emitted: false,
                extra: buildTimingFields(now: Date(), dropStage: "fusion", dropReason: "below_threshold")
            )
            return
        }

        let filteredDecisionText = LineTextSanitizer.sanitize(decision.text)
        guard !filteredDecisionText.isEmpty else {
            logger.log(.debug, "LINEInboundWatcher: dropped empty/standalone-ui text after sanitize")
            savePipelineResult(
                decision: decision,
                sanitizedText: "",
                dedupResult: "n/a",
                emitted: false,
                extra: buildTimingFields(now: Date(), dropStage: "sanitize", dropReason: "empty_after_sanitize")
            )
            return
        }
        if shouldSuppressDuplicateInbound(text: filteredDecisionText, conversation: decision.conversation) {
            logger.log(.debug, "LINEInboundWatcher: suppressed duplicate inbound within dedup window")
            savePipelineResult(
                decision: decision,
                sanitizedText: filteredDecisionText,
                dedupResult: "suppressed",
                emitted: false,
                extra: buildTimingFields(now: Date(), dropStage: "dedup", dropReason: "line_memory_or_window")
            )
            return
        }

        let eventAppendAt = Date()
        let timingFields = buildTimingFields(now: eventAppendAt, dropStage: "none", dropReason: "accepted")
        var payload: [String: String] = [
            "text": filteredDecisionText,
            "conversation": decision.conversation,
            "source": "hybrid_fusion",
            "confidence": decision.confidence,
            "score": String(decision.score),
            "signals": decision.signals.joined(separator: ","),
            "pipeline_version": "line-hybrid-v1",
            "line_watch_poll_started_at": timingFields["poll_started_at"] ?? "",
            "line_watch_capture_done_at": timingFields["capture_done_at"] ?? "",
            "line_watch_signal_collect_done_at": timingFields["signal_collect_done_at"] ?? "",
            "line_watch_fusion_done_at": timingFields["fusion_done_at"] ?? "",
            "line_watch_eventbus_appended_at": isoString(eventAppendAt),
            "line_watch_capture_ms": timingFields["capture_ms"] ?? "",
            "line_watch_signal_collect_ms": timingFields["signal_collect_ms"] ?? "",
            "line_watch_fusion_ms": timingFields["fusion_ms"] ?? "",
            "line_watch_total_detect_ms": timingFields["total_detect_ms"] ?? "",
            "line_watch_drop_stage": "none",
            "line_watch_drop_reason": "accepted",
        ]
        for (k, v) in decision.details {
            payload[k] = v
        }

        _ = eventBus.append(type: decision.eventType, adapter: "line", payload: payload)
        logger.log(.debug, "LINEInboundWatcher: \(decision.eventType) via fusion score=\(decision.score), conf=\(decision.confidence), signals=\(decision.signals.joined(separator: ","))")
        savePipelineResult(
            decision: decision,
            sanitizedText: filteredDecisionText,
            dedupResult: "passed",
            emitted: true,
            extra: timingFields
        )
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
        let normalized = normalizeForDuplicateFingerprint(text)
        guard !normalized.isEmpty else { return false }
        if ingressDedupTuneV2Enabled, normalized.count < 6 { return false }

        let normalizedConversation = conversation.lowercased()
        let fingerprint = "\(normalizedConversation)|\(normalized)"
        let now = Date()
        let windowSeconds = ingressDedupTuneV2Enabled ? inboundDedupWindowSecondsV2 : inboundDedupWindowSeconds
        let lineMemoryWindowSeconds = max(windowSeconds, inboundLineMemoryWindowSeconds)

        let normalizedLines = normalizedInboundLinesForDedup(text)
        pruneRecentInboundLineObservations(now: now, windowSeconds: lineMemoryWindowSeconds)
        if !normalizedLines.isEmpty {
            let hasNovelLine = normalizedLines.contains { normalizedLine in
                !lineSeenRecently(
                    normalizedLine: normalizedLine,
                    conversation: normalizedConversation,
                    now: now,
                    windowSeconds: lineMemoryWindowSeconds
                )
            }
            if !hasNovelLine {
                logger.log(.debug, "LINEInboundWatcher: suppressed duplicate inbound by line memory")
                return true
            }
        }

        if fingerprint == lastInboundFingerprint && now.timeIntervalSince(lastInboundAt) < windowSeconds {
            return true
        }

        lastInboundFingerprint = fingerprint
        lastInboundAt = now
        recordInboundLines(
            normalizedLines,
            conversation: normalizedConversation,
            at: now,
            windowSeconds: lineMemoryWindowSeconds
        )
        return false
    }

    private func normalizeForDuplicateFingerprint(_ text: String) -> String {
        if !ingressDedupTuneV2Enabled {
            return LineTextSanitizer.normalizeForEcho(text)
        }
        return text
            .lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedInboundLinesForDedup(_ text: String) -> [String] {
        let sanitized = LineTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { return [] }
        let lines = sanitized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var segments: [String] = []
        for line in lines {
            segments.append(line)
            let punctuated = line
                .replacingOccurrences(of: "•", with: "\n")
                .replacingOccurrences(of: "・", with: "\n")
                .replacingOccurrences(of: "。", with: "\n")
                .replacingOccurrences(of: "！", with: "\n")
                .replacingOccurrences(of: "？", with: "\n")
                .replacingOccurrences(of: "!", with: "\n")
                .replacingOccurrences(of: "?", with: "\n")
            let parts = punctuated
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            segments.append(contentsOf: parts)
        }
        return segments
            .map { normalizeForDuplicateFingerprint($0) }
            .filter { $0.count >= 4 }
    }

    private func pruneRecentInboundLineObservations(now: Date, windowSeconds: TimeInterval) {
        recentInboundLineObservations.removeAll { now.timeIntervalSince($0.at) > windowSeconds }
        if recentInboundLineObservations.count > maxRecentInboundLineObservations {
            recentInboundLineObservations.removeFirst(recentInboundLineObservations.count - maxRecentInboundLineObservations)
        }
    }

    private func lineSeenRecently(
        normalizedLine: String,
        conversation: String,
        now: Date,
        windowSeconds: TimeInterval
    ) -> Bool {
        for entry in recentInboundLineObservations.reversed() {
            if now.timeIntervalSince(entry.at) > windowSeconds { break }
            if entry.conversation != conversation { continue }
            if linesLikelyEquivalent(normalizedLine, entry.normalizedLine) {
                let matchedHead = String(entry.normalizedLine.prefix(40)).replacingOccurrences(of: "\n", with: "↵")
                let queryHead = String(normalizedLine.prefix(40)).replacingOccurrences(of: "\n", with: "↵")
                logger.log(.debug, "LINEInboundWatcher: fuzzy_dedup_hit query=[\(queryHead)] matched=[\(matchedHead)]")
                return true
            }
        }
        return false
    }

    private func recordInboundLines(
        _ normalizedLines: [String],
        conversation: String,
        at now: Date,
        windowSeconds: TimeInterval
    ) {
        guard !normalizedLines.isEmpty else { return }
        var seenInBatch = Set<String>()
        for normalizedLine in normalizedLines where seenInBatch.insert(normalizedLine).inserted {
            recentInboundLineObservations.append(
                RecentInboundLineObservation(
                    conversation: conversation,
                    normalizedLine: normalizedLine,
                    at: now
                )
            )
        }
        pruneRecentInboundLineObservations(now: now, windowSeconds: windowSeconds)
    }

    private func linesLikelyEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let short = lhs.count <= rhs.count ? lhs : rhs
        let long = lhs.count <= rhs.count ? rhs : lhs
        if short.count >= 8, long.contains(short) {
            let coverage = Double(short.count) / Double(max(long.count, 1))
            if coverage >= 0.84 { return true }
        }
        if min(lhs.count, rhs.count) < 8 { return false }
        return trigramSimilarity(lhs, rhs) >= 0.88
    }

    private func trigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count >= 3, right.count >= 3 else { return 0.0 }

        var leftGrams = Set<String>()
        var rightGrams = Set<String>()
        for i in 0...(left.count - 3) {
            leftGrams.insert(String(left[i...(i + 2)]))
        }
        for i in 0...(right.count - 3) {
            rightGrams.insert(String(right[i...(i + 2)]))
        }
        guard !leftGrams.isEmpty, !rightGrams.isEmpty else { return 0.0 }
        let common = leftGrams.intersection(rightGrams).count
        return (2.0 * Double(common)) / Double(leftGrams.count + rightGrams.count)
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
        let anchorAreaText = collectAnchorAreaOCR(chatList: chatList, lineWindowID: lineWindowID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let axFallbackText = extractTextFromRows(incomingRows)
        let structuralFallbackOCR = collectStructuralFallbackOCR(
            lastFrame: lastFrame,
            lineWindowID: lineWindowID
        )
        let mergedText: String
        let mergedCandidates = mergeCandidatesPreservingLines(
            [ocrText, anchorAreaText, axFallbackText, structuralFallbackOCR]
        )
        mergedText = mergedCandidates

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
                "anchor_area_text_len": String(anchorAreaText.count),
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

    private func collectAnchorAreaOCR(chatList: AXUIElement, lineWindowID: CGWindowID) -> String {
        guard let chatListFrame = AXQuery.copyFrameAttribute(chatList) else { return "" }
        let bottomHalf = CGRect(
            x: chatListFrame.origin.x,
            y: chatListFrame.origin.y + chatListFrame.height / 2,
            width: chatListFrame.width,
            height: chatListFrame.height / 2
        )
        let captureOptions: CGWindowListOption = lineWindowID != kCGNullWindowID
            ? .optionIncludingWindow : .optionOnScreenOnly
        guard let image = CGWindowListCreateImage(bottomHalf, captureOptions, lineWindowID, [.bestResolution]) else {
            return ""
        }
        let anchored = computeInboundAnchorCrop(in: image, baseRect: bottomHalf)
        let text = VisionOCR.extractTextLineInbound(from: anchored, windowID: lineWindowID) ?? ""
        return LineTextSanitizer.sanitize(text)
    }

    private func mergeCandidatesPreservingLines(_ candidates: [String]) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            let clean = LineTextSanitizer.sanitize(candidate)
            guard !clean.isEmpty else { continue }
            let parts = clean
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts {
                if seen.insert(part).inserted {
                    lines.append(part)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Deduplicate OCR rows while preserving richer text.
    /// If one candidate contains another, keep the longer one.
    private func mergeOCRRowPreferLonger(_ candidate: String, into rows: inout [String]) {
        if !rows.contains(candidate) {
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

    private func collectPixelSignal(chatList: AXUIElement, nodes: [AXNode], windowFrame: CGRect, lineWindowID: CGWindowID, conversation: String) -> LineDetectionSignal? {
        guard !recentSendTracker.isSending else {
            logger.log(.debug, "LINEInboundWatcher: pixel signal skipped (sending)")
            return nil
        }
        guard let chatListFrame = AXQuery.copyFrameAttribute(chatList) else { return nil }
        guard windowFrame.width > 10, windowFrame.height > 10 else { return nil }

        let captureOptions: CGWindowListOption = lineWindowID != kCGNullWindowID
            ? .optionIncludingWindow : .optionOnScreenOnly

        guard let image = CGWindowListCreateImage(windowFrame, captureOptions, lineWindowID, [.bestResolution]) else {
            return nil
        }

        let inputFieldY = nodes.first(where: { $0.role == "AXTextArea" })
            .flatMap { AXQuery.copyFrameAttribute($0.element) }
            .map(\.origin.y)
        let fixedAnchor = computeInboundAnchorCropFixed(windowFrame: windowFrame, messageAreaFrame: chatListFrame, inputFieldY: inputFieldY)
        stateLock.lock()
        lastSeparatorAnchorY = Int(fixedAnchor.origin.y)
        lastSeparatorAnchorConfidence = 99
        lastSeparatorAnchorMethod = "fixed-ratio"
        stateLock.unlock()

        maybeSaveOCRDebugArtifacts(
            rawImage: image,
            anchorRect: fixedAnchor,
            lineWindowID: lineWindowID,
            conversation: conversation,
            frameAction: "processed",
            separatorConfidence: 99,
            separatorMethod: "fixed-ratio"
        )

        let hash = computeImageHash(image)

        if !baselineCaptured {
            lastImageHash = hash
            let baseline = burstInboundOCR(from: fixedAnchor, windowID: lineWindowID)
            if baseline.frameSkippedNoCutDescription == "1" {
                logger.log(.debug, "LINEInboundWatcher: baseline fallback without y-cut (continuing)")
            }
            let baselineHead = String(baseline.text.prefix(60)).replacingOccurrences(of: "\n", with: "↵")
            lastOCRText = ""  // force textChanged=true on first poll after baseline
            baselineCaptured = true
            logger.log(.debug, "LINEInboundWatcher: pixel baseline captured (hash: \(hash), lane=\(baseline.laneXDescription), y_cut=\(baseline.cutYDescription), text_head=[\(baselineHead)])")
            return nil
        }

        guard hash != lastImageHash else { return nil }
        let previousHash = lastImageHash
        lastImageHash = hash

        let burst = burstInboundOCR(from: fixedAnchor, windowID: lineWindowID)
        if burst.frameSkippedNoCutDescription == "1" {
            logger.log(.debug, "LINEInboundWatcher: frame fallback without y-cut (continuing)")
        }
        let pixelOCRText = burst.text
        let previousOCRText = lastOCRText
        let textChanged = pixelOCRText != previousOCRText
        if !textChanged {
            let prevHead = String(previousOCRText.prefix(60)).replacingOccurrences(of: "\n", with: "↵")
            let currHead = String(pixelOCRText.prefix(60)).replacingOccurrences(of: "\n", with: "↵")
            logger.log(.debug, "LINEInboundWatcher: text_unchanged prev=[\(prevHead)] curr=[\(currHead)]")
        }
        if textChanged {
            lastOCRText = pixelOCRText
        }
        let deltaText = textChanged ? extractDeltaText(previous: previousOCRText, current: pixelOCRText) : ""

        return LineDetectionSignal(
            name: "pixel_diff",
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
                "pixel_lane_x": burst.laneXDescription,
                "pixel_y_cut": burst.cutYDescription,
                "pixel_green_rows": burst.greenRowsDescription,
                "pixel_green_rows_expanded": burst.expandedGreenRowsDescription,
                "pixel_frame_skipped_no_cut": burst.frameSkippedNoCutDescription,
                "frame_action": "processed",
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

    private func burstInboundOCR(from rect: CGRect, windowID: CGWindowID) -> (
        text: String,
        delaysDescription: String,
        lengthsDescription: String,
        anchorYDescription: String,
        laneXDescription: String,
        cutYDescription: String,
        greenRowsDescription: String,
        expandedGreenRowsDescription: String,
        frameSkippedNoCutDescription: String
    ) {
        let delays = [0]
        var best = ""
        var lengths: [Int] = []
        var selectedDebug = VisionOCR.InboundPreprocessDebug(
            laneX: -1,
            yCut: nil,
            greenRows: 0,
            expandedGreenRows: 0,
            cutApplied: false,
            frameSkippedNoCut: false
        )
        for delay in delays {
            if delay > 0 { usleep(useconds_t(delay * 1000)) }
            var debug = VisionOCR.InboundPreprocessDebug(
                laneX: -1,
                yCut: nil,
                greenRows: 0,
                expandedGreenRows: 0,
                cutApplied: false,
                frameSkippedNoCut: false
            )
            let raw = VisionOCR.extractTextLineInbound(from: rect, windowID: windowID, debug: &debug) ?? ""
            let sanitized = LineTextSanitizer.sanitize(raw)
            lengths.append(sanitized.count)
            if sanitized.count > best.count {
                best = sanitized
                selectedDebug = debug
            } else if delays.count == 1 {
                selectedDebug = debug
            }
        }
        return (
            text: best,
            delaysDescription: delays.map(String.init).joined(separator: ","),
            lengthsDescription: lengths.map(String.init).joined(separator: ","),
            anchorYDescription: String(Int(rect.origin.y)),
            laneXDescription: String(selectedDebug.laneX),
            cutYDescription: selectedDebug.yCut.map(String.init) ?? "",
            greenRowsDescription: String(selectedDebug.greenRows),
            expandedGreenRowsDescription: String(selectedDebug.expandedGreenRows),
            frameSkippedNoCutDescription: selectedDebug.frameSkippedNoCut ? "1" : "0"
        )
    }

    private func computeInboundAnchorCrop(in image: CGImage, baseRect: CGRect, fallbackCutoffY: CGFloat? = nil) -> CGRect {
        // Legacy structural path keeps previous crop behavior.
        baseRect
    }

    /// Avatar icon width (measured 38px @1x + 2px margin).
    private static let avatarLeftInset: CGFloat = 40

    private func computeInboundAnchorCropFixed(windowFrame: CGRect, messageAreaFrame: CGRect, inputFieldY: CGFloat? = nil) -> CGRect {
        let cropBottom: CGFloat
        if let inputY = inputFieldY, inputY > messageAreaFrame.origin.y {
            cropBottom = inputY  // Crop up to, but not including, the input field
        } else {
            cropBottom = messageAreaFrame.origin.y + messageAreaFrame.height
        }
        let cropX = messageAreaFrame.origin.x + Self.avatarLeftInset
        let cropWidth = messageAreaFrame.width - Self.avatarLeftInset
        let cropHeight = cropBottom - messageAreaFrame.origin.y
        guard cropHeight >= 120, cropWidth >= 100 else { return messageAreaFrame }
        return CGRect(
            x: cropX,
            y: messageAreaFrame.origin.y,
            width: cropWidth,
            height: cropHeight
        )
    }

    private func savePipelineResult(
        decision: LineDetectionDecision,
        sanitizedText: String?,
        dedupResult: String,
        emitted: Bool,
        extra: [String: String] = [:]
    ) {
        guard logger.isDebugEnabled else { return }
        var result: [String: String] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "fusion_score": String(decision.score),
            "fusion_threshold": String(fusionEngine.threshold),
            "fusion_signals": decision.signals.joined(separator: ","),
            "fusion_should_emit": String(decision.shouldEmit),
            "sanitized_text": sanitizedText ?? "",
            "dedup_result": dedupResult,
            "dedup_mode": ingressDedupTuneV2Enabled ? "v2" : "legacy",
            "dedup_window_sec": String(Int(ingressDedupTuneV2Enabled ? inboundDedupWindowSecondsV2 : inboundDedupWindowSeconds)),
            "emitted": String(emitted),
            "conversation": decision.conversation,
        ]
        for (k, v) in extra {
            result[k] = v
        }
        let url = URL(fileURLWithPath: "/tmp/clawgate-ocr-debug/latest-pipeline.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func maybeSaveOCRDebugArtifacts(
        rawImage: CGImage,
        anchorRect: CGRect?,
        lineWindowID: CGWindowID,
        conversation: String,
        frameAction: String,
        separatorConfidence: Int = -1,
        separatorMethod: String = "unset"
    ) {
        guard logger.isDebugEnabled else { return }

        let debug: (raw: CGImage, preprocessed: CGImage?)?
        if let anchorRect {
            debug = VisionOCR.captureInboundDebugImages(from: anchorRect, windowID: lineWindowID)
        } else {
            debug = nil
        }

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let eventID = "\(ts)_\(UUID().uuidString.prefix(8))"
        let meta: [String: String] = [
            "conversation": conversation,
            "anchor_x": anchorRect.map { String(format: "%.0f", $0.origin.x) } ?? "",
            "anchor_y": anchorRect.map { String(format: "%.0f", $0.origin.y) } ?? "",
            "anchor_w": anchorRect.map { String(format: "%.0f", $0.width) } ?? "",
            "anchor_h": anchorRect.map { String(format: "%.0f", $0.height) } ?? "",
            "separator_y": lastSeparatorAnchorY.map(String.init) ?? "",
            "separator_confidence": String(separatorConfidence),
            "separator_method": separatorMethod,
            "window_id": String(lineWindowID),
            "frame_action": frameAction,
            "line_found": anchorRect == nil ? "0" : "1",
        ]
        OCRDebugArtifactStore.saveEvent(
            eventID: eventID,
            raw: rawImage,
            anchor: debug?.raw,
            preprocessed: debug?.preprocessed,
            metadata: meta,
            retention: 50
        )
    }

    /// Detect fixed bottom separator line in LINE window coordinates.
    private func detectFixedSeparatorLineY(in image: CGImage) -> (y: Int, confidence: Int, method: String)? {
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

        // Hard-coded search band for the input separator line.
        let minY = max(0, Int(Double(height) * 0.86))
        let maxY = min(height - 1, max(minY + 1, Int(Double(height) * 0.95)))
        let minX = max(0, width - 100)
        let maxX = width - 1
        let spanWidth = max(1, maxX - minX + 1)

        var bestY: Int?
        var bestRun = 0
        var bestDensity = 0

        for y in minY...maxY {
            let rowOffset = y * bytesPerRow
            var grayCount = 0
            var longestRun = 0
            var currentRun = 0
            for x in minX...maxX {
                let i = rowOffset + x * 4
                let r = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])
                if isInputSeparatorGrayPixel(r: r, g: g, b: b) {
                    grayCount += 1
                    currentRun += 1
                    if currentRun > longestRun { longestRun = currentRun }
                } else {
                    currentRun = 0
                }
            }

            if longestRun > bestRun || (longestRun == bestRun && grayCount > bestDensity) {
                bestRun = longestRun
                bestDensity = grayCount
                bestY = y
            }
        }

        guard let y = bestY else { return nil }
        let runRatio = Double(bestRun) / Double(spanWidth)
        let densityRatio = Double(bestDensity) / Double(spanWidth)

        // 1px separator: prioritize contiguous run in right-edge 100px lane.
        guard bestRun >= 72, runRatio >= 0.72, densityRatio >= 0.30 else {
            return nil
        }

        let confidence = max(1, min(99, Int((0.85 * runRatio + 0.15 * densityRatio) * 100.0)))
        return (y, confidence, "fixed-band-right100")
    }

    /// Pixel classifier for LINE input separator gray.
    /// Tuned to prefer the fixed thin separator color over generic light-gray text.
    private func isInputSeparatorGrayPixel(r: Int, g: Int, b: Int) -> Bool {
        // Sampled separator is near neutral light gray. Keep chroma very low.
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let sat = maxC - minC
        guard sat <= 9 else { return false }

        // Fixed-color anchor around LINE separator gray.
        // Use distance in RGB space so this stays robust across slight rendering differences.
        if maxC < 178 || maxC > 245 { return false }
        let dr = r - 222
        let dg = g - 222
        let db = b - 222
        let dist2 = dr * dr + dg * dg + db * db
        return dist2 <= 34 * 34
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
