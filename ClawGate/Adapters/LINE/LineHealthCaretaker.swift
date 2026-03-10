import AppKit
import Foundation

final class LineHealthCaretaker {
    private enum Constants {
        static let probeInterval: TimeInterval = 60
        static let watcherStaleThreshold: TimeInterval = 60
        static let forcedRepairInterval: TimeInterval = 600
        static let repairCooldown: TimeInterval = 180
        static let repairQuietPeriodAfterSend: TimeInterval = 60
    }

    private let lineAdapter: LINEAdapter
    private let inboundWatcher: LINEInboundWatcher
    private let recentSendTracker: RecentSendTracker
    private let configStore: ConfigStore
    private let logger: AppLogger

    private let timerQueue = DispatchQueue(label: "com.clawgate.line.health-caretaker", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var tickInFlight = false

    private var lastProbeAt: Date = .distantPast
    private var lastAssessmentReason = "never_started"
    private var lastRepairAt: Date = .distantPast
    private var lastRepairReason = "never"
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
        logger: AppLogger
    ) {
        self.lineAdapter = lineAdapter
        self.inboundWatcher = inboundWatcher
        self.recentSendTracker = recentSendTracker
        self.configStore = configStore
        self.logger = logger
        self.nextForcedRepairDueAt = Date().addingTimeInterval(Constants.forcedRepairInterval)
    }

    func start() {
        stateLock.lock()
        if timer != nil {
            stateLock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(
            deadline: .now() + Constants.probeInterval,
            repeating: Constants.probeInterval,
            leeway: .seconds(5)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleTick(trigger: "interval")
        }
        timer = source
        stateLock.unlock()

        source.resume()
        logger.log(.info, "LineHealthCaretaker started (probe=\(Int(Constants.probeInterval))s forced=\(Int(Constants.forcedRepairInterval))s cooldown=\(Int(Constants.repairCooldown))s)")
        scheduleTick(trigger: "startup")
    }

    func stop() {
        stateLock.lock()
        let current = timer
        timer = nil
        tickInFlight = false
        stateLock.unlock()

        current?.setEventHandler {}
        current?.cancel()
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
            timestamp: isoString(Date())
        )
    }

    private func scheduleTick(trigger: String) {
        stateLock.lock()
        if tickInFlight {
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
        let now = Date()
        updateState(lastProbeAt: now, lastAssessmentReason: "probe_started_\(trigger)")

        let cfg = configStore.load()
        let defaultConversation = cfg.lineDefaultConversation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cfg.nodeRole != .client, cfg.lineEnabled else {
            updateState(lastAssessmentReason: "line_disabled")
            return
        }
        guard !defaultConversation.isEmpty else {
            updateState(lastAssessmentReason: "default_conversation_missing")
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: lineAdapter.bundleIdentifier).first != nil else {
            updateState(lastAssessmentReason: "line_not_running")
            return
        }
        if recentSendTracker.isSending {
            updateState(lastAssessmentReason: "send_in_flight")
            return
        }

        let watcher = inboundWatcher.snapshotState()
        let watcherStale = isWatcherStale(watcher, now: now)
        let forcedDue = now >= snapshot().nextForcedRepairDueAtDate

        var surface: LineSurfaceHealthSnapshot?
        var probeErrorCode: String?
        do {
            surface = try lineAdapter.probeDefaultConversationSurface()
            updateState(lastSurface: surface)
        } catch let err as BridgeRuntimeError {
            probeErrorCode = err.code
            logger.log(.warning, "LineHealthCaretaker probe failed code=\(err.code) step=\(err.failedStep ?? "-")")
        } catch {
            probeErrorCode = "probe_unknown_error"
            logger.log(.warning, "LineHealthCaretaker probe failed error=\(error)")
        }

        let surfaceAbnormal = surface?.abnormal ?? true
        let shouldRepair = watcherStale || surfaceAbnormal || forcedDue
        if !shouldRepair {
            updateState(lastAssessmentReason: "probe_ok")
            return
        }

        let repairReason: String
        if watcherStale {
            repairReason = "watcher_stale"
        } else if forcedDue {
            repairReason = "forced_reanchor"
        } else if let reason = surface?.reason {
            repairReason = "surface_\(reason)"
        } else if let probeErrorCode {
            repairReason = "probe_error_\(probeErrorCode)"
        } else {
            repairReason = "surface_unknown"
        }

        let lastSendAge = recentSendTracker.lastSendAt.map { now.timeIntervalSince($0) }
        if let lastSendAge, lastSendAge < Constants.repairQuietPeriodAfterSend {
            updateState(lastAssessmentReason: "repair_deferred_recent_send_\(repairReason)")
            return
        }

        stateLock.lock()
        let cooldown = cooldownUntil
        stateLock.unlock()
        if now < cooldown {
            updateState(lastAssessmentReason: "repair_deferred_cooldown_\(repairReason)")
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        do {
            let recovered = try lineAdapter.ensureDefaultConversationSurface(forceRecover: forcedDue || watcherStale)
            updateState(
                lastAssessmentReason: "repair_ok_\(repairReason)",
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: true,
                lastSurface: recovered,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(.info, "LineHealthCaretaker repaired LINE surface reason=\(repairReason) abnormal_after=\(recovered.abnormal)")
        } catch let err as BridgeRuntimeError {
            updateState(
                lastAssessmentReason: "repair_failed_\(repairReason)",
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: false,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(.warning, "LineHealthCaretaker repair failed code=\(err.code) reason=\(repairReason)")
        } catch {
            updateState(
                lastAssessmentReason: "repair_failed_\(repairReason)",
                lastRepairAt: now,
                lastRepairReason: repairReason,
                lastRepairSucceeded: false,
                nextForcedRepairDueAt: now.addingTimeInterval(Constants.forcedRepairInterval),
                cooldownUntil: now.addingTimeInterval(Constants.repairCooldown)
            )
            logger.log(.warning, "LineHealthCaretaker repair failed reason=\(repairReason) error=\(error)")
        }

        restoreFrontmostApplication(frontmost)
    }

    private func isWatcherStale(_ snapshot: LineDetectionStateSnapshot, now: Date) -> Bool {
        guard snapshot.lastCompletedPollAt != "never" else {
            return true
        }
        guard let lastCompleted = Self.isoFormatter.date(from: snapshot.lastCompletedPollAt) else {
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
        semaphore.wait()
    }

    private func isoString(_ date: Date) -> String {
        if date == .distantPast {
            return "never"
        }
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

private extension LineCaretakerSnapshot {
    var nextForcedRepairDueAtDate: Date {
        guard nextForcedRepairDueAt != "never",
              let date = ISO8601DateFormatter().date(from: nextForcedRepairDueAt) else {
            return .distantPast
        }
        return date
    }
}
