import Foundation

/// Monitors Gateway poll freshness and auto-restarts via launchctl when stale.
/// Runs on the server (Host A) where Gateway is a local launchd service.
final class GatewayHealthMonitor {
    private enum Constants {
        static let tickInterval: TimeInterval = 60
        static let staleThreshold: TimeInterval = 180   // 3 minutes without poll → stale
        static let restartCooldown: TimeInterval = 300   // 5 minutes between restarts
    }

    private let core: BridgeCore
    private let logger: AppLogger

    private let timerQueue = DispatchQueue(label: "com.clawgate.gateway-health-monitor", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastRestartAt: Date = .distantPast

    init(core: BridgeCore, logger: AppLogger) {
        self.core = core
        self.logger = logger
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
            self?.tick()
        }
        timer = source
        stateLock.unlock()

        source.resume()
        logger.log(
            .info,
            "GatewayHealthMonitor started (tick=\(Int(Constants.tickInterval))s stale=\(Int(Constants.staleThreshold))s cooldown=\(Int(Constants.restartCooldown))s)"
        )
    }

    func stop() {
        stateLock.lock()
        let source = timer
        timer = nil
        stateLock.unlock()
        source?.cancel()
        logger.log(.info, "GatewayHealthMonitor stopped")
    }

    private func tick() {
        let pollAge = Date().timeIntervalSince(core.lastGatewayPollAt)

        // Not stale yet, or Gateway has never polled (may not be configured)
        guard core.lastGatewayPollAt != .distantPast, pollAge > Constants.staleThreshold else {
            return
        }

        // Cooldown check
        guard Date().timeIntervalSince(lastRestartAt) > Constants.restartCooldown else {
            logger.log(.info, "GatewayHealthMonitor: poll stale (age=\(Int(pollAge))s) but restart on cooldown")
            return
        }

        logger.log(.warning, "GatewayHealthMonitor: poll stale (age=\(Int(pollAge))s), restarting Gateway via launchctl")
        lastRestartAt = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway"]
            do {
                try process.run()
                process.waitUntilExit()
                let code = process.terminationStatus
                if code == 0 {
                    self?.logger.log(.info, "GatewayHealthMonitor: launchctl restart succeeded")
                } else {
                    self?.logger.log(.error, "GatewayHealthMonitor: launchctl restart exited with code \(code)")
                }
            } catch {
                self?.logger.log(.error, "GatewayHealthMonitor: launchctl restart failed: \(error)")
            }
        }
    }
}
