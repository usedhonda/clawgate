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

    /// Why a recover is due, or nil. Pure, so the decision is testable apart
    /// from the timer. Two conditions qualify:
    ///  - while streaming, the tap has gone stale long enough to call the
    ///    engine wedged (liveness is only measured while streaming);
    ///  - while the microphone is open at all, the engine is on a different
    ///    input device from the one that was requested. That is not a wedge --
    ///    audio still flows -- but it is the wrong audio, and with AirPods it
    ///    also degrades the user's output, so it is recovered the same way:
    ///    fresh engine, re-apply, verify.
    static func recoveryReason(for s: AmbientController.Status) -> String? {
        if s.streaming, s.captureLiveness == "wedged" {
            return "health-monitor: tap stale \(s.secondsSinceLastTap)s"
        }
        if s.captureState == "capturing", s.inputDeviceDrifted {
            let requested = s.requestedInputDeviceUID ?? "?"
            let actual = s.actualInputDeviceName ?? s.actualInputDeviceUID ?? "unknown"
            return "health-monitor: input drifted (requested \(requested), engine on \(actual))"
        }
        return nil
    }

    private func tick() {
        guard let controller else { return }
        let s = controller.snapshot()
        guard let reason = Self.recoveryReason(for: s) else { return }

        stateLock.lock()
        let onCooldown = Date().timeIntervalSince(lastRecoverAt) <= Constants.recoverCooldown
        if !onCooldown { lastRecoverAt = Date() }
        stateLock.unlock()

        if onCooldown {
            log("AmbientHealthMonitor: recover due (\(reason)) but on cooldown")
            return
        }

        log("AmbientHealthMonitor: \(reason) (chunksSurfaced=\(s.chunksSurfaced)), hard-recovering")
        controller.recover(reason: reason)
    }
}
