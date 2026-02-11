import Foundation

/// Thin wrapper around the `tmux` CLI.
/// All methods are synchronous and should be called from `BlockingWork.queue`.
enum TmuxShell {

    private static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    private static var tmuxPath: String {
        candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/tmux"
    }

    /// Send literal text to a tmux pane, optionally followed by Enter.
    /// Uses `-l` for literal mode (no special-character interpretation).
    @discardableResult
    static func sendKeys(target: String, text: String, enter: Bool) throws -> String {
        // Send literal text
        var output = try run(arguments: ["send-keys", "-t", target, "-l", text])

        // Send Enter separately (not literal)
        if enter {
            let enterOutput = try run(arguments: ["send-keys", "-t", target, "Enter"])
            output += enterOutput
        }

        return output
    }

    /// Capture the visible content of a tmux pane.
    /// Returns the last `lines` lines of the pane buffer.
    static func capturePane(target: String, lines: Int = 50) throws -> String {
        try run(arguments: ["capture-pane", "-t", target, "-p", "-S", "-\(lines)"])
    }

    /// List all tmux sessions.
    static func listSessions() throws -> [String] {
        let output = try run(arguments: ["list-sessions", "-F", "#{session_name}"])
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Keys that must NEVER be sent — they exit Claude Code to raw shell.
    private static let forbiddenKeys: Set<String> = ["C-c", "C-d", "C-z", "C-\\"]

    /// Send a special key (non-literal) to a tmux pane.
    /// Examples: "Up", "Down", "BTab", "Escape", "Enter", "y"
    /// SECURITY: C-c, C-d, C-z, C-\ are blocked — they exit CC to raw shell.
    @discardableResult
    static func sendSpecialKey(target: String, key: String) throws -> String {
        guard !forbiddenKeys.contains(key) else {
            throw BridgeRuntimeError(
                code: "forbidden_key",
                message: "Key '\(key)' is forbidden — it would exit Claude Code to raw shell",
                retriable: false,
                failedStep: "send_special_key",
                details: nil
            )
        }
        return try run(arguments: ["send-keys", "-t", target, key])
    }

    // MARK: - Private

    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BridgeRuntimeError(
                code: "tmux_command_failed",
                message: "tmux \(arguments.first ?? "") failed (exit \(process.terminationStatus))",
                retriable: true,
                failedStep: "tmux_shell",
                details: errStr.isEmpty ? outStr : errStr
            )
        }

        return outStr
    }
}
