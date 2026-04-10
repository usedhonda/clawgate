import AppKit
import Foundation

final class LineHealthCaretaker {
    private enum Constants {
        static let tickInterval: TimeInterval = 60
        static let watcherStaleThreshold: TimeInterval = 60
        static let forcedRepairInterval: TimeInterval = 600
        static let repairCooldown: TimeInterval = 180
        static let recentSendQuietPeriod: TimeInterval = 60
    }

    private let lineAdapter: LINEAdapter
    private let inboundWatcher: LINEInboundWatcher
    private let recentSendTracker: RecentSendTracker
    private let configStore: ConfigStore
    private let logger: AppLogger
    private let nowProvider: () -> Date

    private let timerQueue = DispatchQueue(label: "com.clawgate.line.health-caretaker", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var tickInFlight = false

    private var lastProbeAt: Date = .distantPast
    private var lastAssessmentReason = "never_started"
    private var lastRepairAt: Date = .distantPast
    private var lastRepairReason = "none"
    private var lastRepairSucceeded: Bool?
    private var nextForcedRepairDueAt: Date
    private var cooldownUntil: Date = .distantPast
    private var lastSurface: LineSurfaceHealthSnapshot?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    init(
        lineAdapter: LINEAdapter,
        inboundWatcher: LINEInboundWatcher,
        recentSendTracker: RecentSendTracker,
        configStore: ConfigStore,
        logger: AppLogger,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.lineAdapter = lineAdapter
        self.inboundWatcher = inboundWatcher
        self.recentSendTracker = recentSendTracker
        self.configStore = configStore
        self.logger = logger
        self.nowProvider = nowProvider
        self.nextForcedRepairDueAt = nowProvider().addingTimeInterval(Constants.forcedRepairInterval)
    }

    func start() {
        stateLock.lock()
        guard timer == nil else {
            stateLock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(
            deadline: .now() + Constants.tickInterval,
            repeating: Constants.tickInterval,
            leeway: .seconds(5)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleTick(trigger: "interval")
        }
        timer = source
        stateLock.unlock()

        source.resume()
        scheduleTick(trigger: "startup")
        logger.log(
            .info,
            "LineHealthCaretaker started (tick=\(Int(Constants.tickInterval))s cooldown=\(Int(Constants.repairCooldown))s forced=\(Int(Constants.forcedRepairInterval))s)"
        )
    }

    func stop() {
        stateLock.lock()
        let currentTimer = timer
        timer = nil
        tickInFlight = false
        stateLock.unlock()

        currentTimer?.setEventHandler {}
        currentTimer?.cancel()
        logger.log(.info, "LineHealthCaretaker stopped")
    }

    func snapshot() -> LineCaretakerSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return LineCaretakerSnapshot(
            lastProbeAt: isoString(lastProbeAt),
            lastAssessmentReason: lastAssessmentReason,
            lastRepairAt: isoString(lastRepairAt),
            lastRepairReason: lastRepairReason,
            lastRepairSucceeded: lastRepairSucceeded,
            nextForcedRepairDueAt: isoString(nextForcedRepairDueAt),
            cooldownUntil: isoString(cooldownUntil),
            lastSurface: lastSurface,
            timestamp: isoString(nowProvider())
        )
    }

    private func scheduleTick(trigger: String) {
        stateLock.lock()
        guard !tickInFlight else {
            stateLock.unlock()
            return
        }
        tickInFlight = true
        stateLock.unlock()

        BlockingWork.queue.async { [weak self] in
            guard let self else { return }
            self.runTick(trigger: trigger)
            self.stateLock.lock()
            self.tickInFlight = false
            self.stateLock.unlock()
        }
    }

    private func runTick(trigger: String) {
        let now = nowProvider()
        updateState(lastProbeAt: now, lastAssessmentReason: "tick_\(trigger)")

        let config = configStore.load()
        let defaultConversation = config.lineDefaultConversation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.lineEnabled else {
            updateState(lastAssessmentReason: "inactive_line_disabled")
            return
        }
        guard !defaultConversation.isEmpty else {
            updateState(lastAssessmentReason: "inactive_default_conversation_missing")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            updateState(lastAssessmentReason: "screen_recording_missing")
            logger.log(.warning, "LineHealthCaretaker: screen recording unavailable, skipping repair")
            return
        }

        let watcherSnapshot = inboundWatcher.snapshotState()
        let surfaceSnapshot: LineSurfaceHealthSnapshot?
        do {
            surfaceSnapshot = try lineAdapter.probeDefaultConversationSurface()
            updateState(lastSurface: surfaceSnapshot)
        } catch let error as BridgeRuntimeError {
            if error.code == "line_not_running" {
                updateState(lastAssessmentReason: "line_not_running")
                logger.log(.warning, "LineHealthCaretaker: LINE not running, skipping repair")
                return
            }
            surfaceSnapshot = nil
            logger.log(
                .warning,
                "LineHealthCaretaker: probe failed code=\(error.code) step=\(error.failedStep ?? "-")"
            )
        } catch {
            surfaceSnapshot = nil
            logger.log(.warning, "LineHealthCaretaker: probe failed error=\(error)")
        }

        let decision = LineCaretakerDecisionEngine.decide(
            LineCaretakerDecisionInput(
                isSending: recentSendTracker.isSending,
                sentRecently: recentSendTracker.sentWithin(seconds: Constants.recentSendQuietPeriod),
                inCooldown: now < currentCooldownUntil(),
                lineRunning: true,
                watcherStale: isWatcherStale(watcherSnapshot, now: now),
                surfaceAbnormal: surfaceSnapshot?.abnormal ?? true,
                forcedReanchorDue: now >= currentForcedRepairDueAt()
            )
        )

        updateState(lastAssessmentReason: decision.assessmentReason)
        guard decision.shouldRepair, let mode = decision.mode, let repairReason = decision.repairReason else {
            return
        }

        let previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        do {
            let recoveredSnapshot: LineSurfaceHealthSnapshot
            switch mode {
            case .probeOnly:
                recoveredSnapshot = try lineAdapter.probeDefaultConversationSurface()
            case .recoverIfNeeded:
                recoveredSnapshot = try lineAdapter.recoverDefaultConversationSurfaceIfNeeded()
            case .forceRecover:
                recoveredSnapshot = try lineAdapter.forceRecoverDefaultConversationSurface()
            }

            updateState(
                lastAssessmentReason: decision.assessmentReason,
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: !recoveredSnapshot.abnormal,
                lastSurface: recoveredSnapshot,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(
                .info,
                "LineHealthCaretaker: repaired surface reason=\(repairReason) mode=\(mode.rawValue) abnormal_after=\(recoveredSnapshot.abnormal)"
            )
        } catch let error as BridgeRuntimeError {
            updateState(
                lastAssessmentReason: decision.assessmentReason,
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: false,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(
                .warning,
                "LineHealthCaretaker: repair failed code=\(error.code) reason=\(repairReason) assessment=\(decision.assessmentReason) surface_reason=\(surfaceSnapshot?.reason ?? "none")"
            )
        } catch {
            updateState(
                lastAssessmentReason: decision.assessmentReason,
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: false,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(.warning, "LineHealthCaretaker: repair failed reason=\(repairReason) assessment=\(decision.assessmentReason) error=\(error)")
        }

        restoreFrontmostApplication(previousFrontmostApp)
    }

    private func isWatcherStale(_ snapshot: LineDetectionStateSnapshot, now: Date) -> Bool {
        guard let lastCompleted = parseISODate(snapshot.lastCompletedPollAt) else {
            return true
        }
        return now.timeIntervalSince(lastCompleted) > Constants.watcherStaleThreshold
    }

    private func restoreFrontmostApplication(_ app: NSRunningApplication?) {
        guard let app,
              app.bundleIdentifier != lineAdapter.bundleIdentifier else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            _ = app.activate(options: [.activateIgnoringOtherApps])
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
    }

    private func currentForcedRepairDueAt() -> Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nextForcedRepairDueAt
    }

    private func currentCooldownUntil() -> Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cooldownUntil
    }

    private func parseISODate(_ value: String) -> Date? {
        guard value != "never" else { return nil }
        return Self.isoFormatter.date(from: value)
    }

    private func isoString(_ date: Date) -> String {
        guard date != .distantPast else { return "never" }
        return Self.isoFormatter.string(from: date)
    }

    private func updateState(
        lastProbeAt: Date? = nil,
        lastAssessmentReason: String? = nil,
        lastRepairAt: Date? = nil,
        lastRepairReason: String? = nil,
        lastRepairSucceeded: Bool? = nil,
        lastSurface: LineSurfaceHealthSnapshot? = nil,
        nextForcedRepairDueAt: Date? = nil,
        cooldownUntil: Date? = nil
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let lastProbeAt { self.lastProbeAt = lastProbeAt }
        if let lastAssessmentReason { self.lastAssessmentReason = lastAssessmentReason }
        if let lastRepairAt { self.lastRepairAt = lastRepairAt }
        if let lastRepairReason { self.lastRepairReason = lastRepairReason }
        if let lastRepairSucceeded { self.lastRepairSucceeded = lastRepairSucceeded }
        if let lastSurface { self.lastSurface = lastSurface }
        if let nextForcedRepairDueAt { self.nextForcedRepairDueAt = nextForcedRepairDueAt }
        if let cooldownUntil { self.cooldownUntil = cooldownUntil }
    }
}
