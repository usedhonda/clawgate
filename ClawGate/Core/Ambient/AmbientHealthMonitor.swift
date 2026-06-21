import Foundation

/// Watches ambient capture liveness and hard-recovers in-process when the
/// AVAudioEngine silently wedges (taps stop while captureState still says
/// "capturing"). This is the in-app self-heal: it closes the gap that pgrep /
/// /v1/health watchdogs miss (2026-06-21 wedge cost ~80min of lost recording).
///
/// Mirrors GatewayHealthMonitor: a utility-queue timer with a stale check and a
/// cooldown so a persistently-failing engine can't restart-loop. Detection is
/// keyed on `captureLiveness == "wedged"` (tap-staleness, silence-safe), never
/// on transcript output.
final class AmbientHealthMonitor {
    private enum Constants {
        static let tickInterval: TimeInterval = 20
        /// At most one hard-recover per this window. If recovery doesn't revive
        /// the engine, captureLiveness stays "wedged"; the external watchdog
        /// (WATCHDOG_AMBIENT_CHECK) then escalates to a process restart.
        static let recoverCooldown: TimeInterval = 120
    }

    private weak var controller: AmbientController?
    private let log: (String) -> Void

    private let timerQueue = DispatchQueue(label: "ai.clawgate.ambient-health-monitor", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastRecoverAt: Date = .distantPast

    init(controller: AmbientController, log: @escaping (String) -> Void = { _ in }) {
        self.controller = controller
        self.log = log
    }

    func start() {
        stateLock.lock()
        guard timer == nil else { stateLock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(
            deadline: .now() + Constants.tickInterval,
            repeating: Constants.tickInterval,
            leeway: .seconds(3)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        stateLock.unlock()
        source.resume()
        log("AmbientHealthMonitor started (tick=\(Int(Constants.tickInterval))s cooldown=\(Int(Constants.recoverCooldown))s)")
    }

    func stop() {
        stateLock.lock()
        let source = timer
        timer = nil
        stateLock.unlock()
        source?.cancel()
        log("AmbientHealthMonitor stopped")
    }

    private func tick() {
        guard let controller else { return }
        let s = controller.snapshot()
        // Only act on a confirmed wedge while actively streaming.
        guard s.streaming, s.captureLiveness == "wedged" else { return }

        stateLock.lock()
        let onCooldown = Date().timeIntervalSince(lastRecoverAt) <= Constants.recoverCooldown
        if !onCooldown { lastRecoverAt = Date() }
        stateLock.unlock()

        if onCooldown {
            log("AmbientHealthMonitor: capture wedged (sinceTap=\(s.secondsSinceLastTap)s) but recover on cooldown")
            return
        }

        log("AmbientHealthMonitor: capture wedged (sinceTap=\(s.secondsSinceLastTap)s, chunksSurfaced=\(s.chunksSurfaced)), hard-recovering")
        controller.recover(reason: "health-monitor: tap stale \(s.secondsSinceLastTap)s")
    }
}
