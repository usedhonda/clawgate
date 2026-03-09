import Foundation
import ServiceManagement
import Darwin

enum LaunchAtLoginLogLevel: String {
    case debug
    case info
    case warning
    case error
}

@available(macOS 13.0, *)
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let fileManager: FileManager
    private let legacyLaunchAgentURL: URL
    private let disabledLegacyLaunchAgentURL: URL
    private let launchctlPath = "/bin/launchctl"
    private let migrationLock = NSLock()
    private var didAttemptStartupMigration = false

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.legacyLaunchAgentURL = homeDirectoryURL
            .appendingPathComponent("Library/LaunchAgents/com.clawgate.app.plist")
        self.disabledLegacyLaunchAgentURL = homeDirectoryURL
            .appendingPathComponent("Library/LaunchAgents/com.clawgate.app.plist.disabled")
    }

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var hasLegacyLaunchAgent: Bool {
        fileManager.fileExists(atPath: legacyLaunchAgentURL.path)
    }

    func migrateLegacyLaunchAgentIfNeeded(
        log: (LaunchAtLoginLogLevel, String) -> Void = { _, _ in }
    ) {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        guard !didAttemptStartupMigration else { return }
        didAttemptStartupMigration = true

        guard hasLegacyLaunchAgent else { return }

        log(.info, "launch_at_login: detected legacy LaunchAgent at \(legacyLaunchAgentURL.path)")

        if status != .enabled {
            do {
                try SMAppService.mainApp.register()
                log(.info, "launch_at_login: registered SMAppService main app")
            } catch {
                log(.error, "launch_at_login: failed to register SMAppService main app: \(error.localizedDescription)")
                return
            }
        } else {
            log(.info, "launch_at_login: SMAppService main app already enabled")
        }

        guard status == .enabled else {
            log(.warning, "launch_at_login: SMAppService status is \(statusDescription(status)); keeping legacy LaunchAgent")
            return
        }

        unloadLegacyLaunchAgent(log: log)

        do {
            try disableLegacyLaunchAgent()
            log(.info, "launch_at_login: disabled legacy LaunchAgent")
        } catch {
            log(.error, "launch_at_login: failed to disable legacy LaunchAgent: \(error.localizedDescription)")
        }
    }

    func setEnabled(
        _ enabled: Bool,
        log: (LaunchAtLoginLogLevel, String) -> Void = { _, _ in }
    ) throws {
        if enabled {
            try SMAppService.mainApp.register()
            log(.info, "launch_at_login: enabled via SMAppService")

            if hasLegacyLaunchAgent {
                unloadLegacyLaunchAgent(log: log)
                do {
                    try disableLegacyLaunchAgent()
                    log(.info, "launch_at_login: disabled legacy LaunchAgent after enable")
                } catch {
                    log(.error, "launch_at_login: failed to disable legacy LaunchAgent after enable: \(error.localizedDescription)")
                }
            }
        } else {
            try SMAppService.mainApp.unregister()
            log(.info, "launch_at_login: disabled via SMAppService")
        }
    }

    func statusDescription(_ status: SMAppService.Status? = nil) -> String {
        switch status ?? self.status {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires_approval"
        case .notFound:
            return "not_found"
        case .notRegistered:
            return "not_registered"
        @unknown default:
            return "unknown"
        }
    }

    private func disableLegacyLaunchAgent() throws {
        guard hasLegacyLaunchAgent else { return }

        if fileManager.fileExists(atPath: disabledLegacyLaunchAgentURL.path) {
            try fileManager.removeItem(at: disabledLegacyLaunchAgentURL)
        }

        try fileManager.moveItem(at: legacyLaunchAgentURL, to: disabledLegacyLaunchAgentURL)
    }

    private func unloadLegacyLaunchAgent(
        log: (LaunchAtLoginLogLevel, String) -> Void
    ) {
        let uid = getuid()
        let commands = [
            ["bootout", "gui/\(uid)", legacyLaunchAgentURL.path],
            ["unload", legacyLaunchAgentURL.path],
        ]

        for args in commands {
            let (success, output) = runLaunchctl(args)
            if success {
                log(.info, "launch_at_login: unloaded legacy LaunchAgent via launchctl \(args[0])")
                return
            }
            if !output.isEmpty {
                log(.debug, "launch_at_login: launchctl \(args[0]) returned: \(output)")
            }
        }
    }

    private func runLaunchctl(_ arguments: [String]) -> (Bool, String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: launchctlPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile() +
                stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
