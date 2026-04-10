import Foundation

/// Thin wrapper around the `tmux` CLI.
/// All methods are synchronous and should be called from `BlockingWork.queue`.
enum TmuxShell {
    struct PaneDescriptor {
        let session: String
        let window: String
        let pane: String
        let currentCommand: String
        let title: String
        let currentPath: String
        let tty: String
        let isAttached: Bool
        let panePID: Int32

        var target: String { "\(session):\(window).\(pane)" }
    }

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
        // Small delay before Enter: Codex CLI needs time to process pasted text
        // before accepting Enter. CC (readline-based) doesn't need this but it's harmless.
        if enter {
            // Scale delay with text length (longer pastes need more processing time)
            let baseDelay = 0.15
            let extraDelay = min(Double(text.count) / 5000.0, 0.35)
            Thread.sleep(forTimeInterval: baseDelay + extraDelay)
            let enterOutput = try run(arguments: ["send-keys", "-t", target, "Enter"])
            output += enterOutput

            // Post-send verification: if text is still at the prompt, retry Enter.
            // This catches cases where the target app didn't accept Enter
            // (e.g., still processing pasted text, tmux timing race).
            let snippet = String(text.prefix(40))
            for retry in 1...2 {
                Thread.sleep(forTimeInterval: 0.3)
                guard let pane = try? capturePane(target: target, lines: 5) else { break }
                let lines = pane.split(separator: "\n", omittingEmptySubsequences: false)
                // Find the last line starting with a prompt marker (❯ › >)
                let promptLine = lines.last(where: {
                    $0.range(of: #"^\s*[\u{203A}\u{276F}>]\s*"#, options: .regularExpression) != nil
                })
                guard let promptLine, promptLine.contains(snippet) else { break }
                // Text still at prompt — retry Enter with increasing delay
                Thread.sleep(forTimeInterval: 0.15 * Double(retry))
                let retryOutput = try run(arguments: ["send-keys", "-t", target, "Enter"])
                output += retryOutput
            }
        }

        return output
    }

    /// Capture the visible content of a tmux pane.
    /// Returns the last `lines` lines of the pane buffer.
    static func capturePane(target: String, lines: Int = 50) throws -> String {
        try run(arguments: ["capture-pane", "-t", target, "-p", "-S", "-\(lines)"])
    }

    /// Capture with -e flag (preserves ANSI escape sequences for SGR detection).
    static func capturePaneRaw(target: String, lines: Int = 50) throws -> String {
        try run(arguments: ["capture-pane", "-e", "-t", target, "-p", "-S", "-\(lines)"])
    }

    /// List all tmux sessions.
    static func listSessions() throws -> [String] {
        let output = try run(arguments: ["list-sessions", "-F", "#{session_name}"])
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// List all panes with enough metadata for direct session discovery.
    static func listPanes() throws -> [PaneDescriptor] {
        let output = try run(arguments: [
            "list-panes", "-a", "-F",
            "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{pane_tty}\t#{session_attached}\t#{pane_pid}"
        ])

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 9 else { return nil }
                return PaneDescriptor(
                    session: parts[0],
                    window: parts[1],
                    pane: parts[2],
                    currentCommand: parts[3],
                    title: parts[4],
                    currentPath: parts[5],
                    tty: parts[6],
                    isAttached: parts[7] == "1",
                    panePID: Int32(parts[8]) ?? 0
                )
            }
    }

    /// Walk the process tree starting at `rootPID` and return all descendant
    /// process argument lines. Uses a single `ps` invocation and filters in
    /// Swift to avoid multiple exec calls.
    static func descendantProcessArgs(rootPID: Int32, maxDepth: Int = 3) -> [String] {
        guard rootPID > 0 else { return [] }
        // Single ps snapshot: pid, ppid, args
        guard let raw = try? run(arguments: [], launchPath: "/bin/ps", psArgs: ["-A", "-o", "pid=,ppid=,command="]) else {
            return []
        }
        struct ProcRow {
            let pid: Int32
            let ppid: Int32
            let command: String
        }
        var rows: [ProcRow] = []
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Parse: "<pid> <ppid> <command...>"
            let scanner = Scanner(string: trimmed)
            scanner.charactersToBeSkipped = .whitespaces
            var pidVal: Int64 = 0
            var ppidVal: Int64 = 0
            guard scanner.scanInt64(&pidVal), scanner.scanInt64(&ppidVal) else { continue }
            let cmd = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: scanner.currentIndex.utf16Offset(in: trimmed))...])
                .trimmingCharacters(in: .whitespaces)
            rows.append(ProcRow(pid: Int32(pidVal), ppid: Int32(ppidVal), command: cmd))
        }
        // BFS from rootPID
        var result: [String] = []
        var queue: [(pid: Int32, depth: Int)] = [(rootPID, 0)]
        var visited = Set<Int32>([rootPID])
        while let (pid, depth) = queue.first {
            queue.removeFirst()
            if depth > 0 {  // skip root itself
                if let row = rows.first(where: { $0.pid == pid }) {
                    result.append(row.command)
                }
            }
            if depth >= maxDepth { continue }
            for child in rows where child.ppid == pid && !visited.contains(child.pid) {
                visited.insert(child.pid)
                queue.append((child.pid, depth + 1))
            }
        }
        return result
    }

    /// Overload that allows running an arbitrary executable (used for /bin/ps above).
    /// IMPORTANT: drain the pipe BEFORE waiting for exit. Otherwise large outputs
    /// (e.g. `ps -A`) can fill the pipe buffer (~64KB) and deadlock both sides.
    private static func run(arguments: [String], launchPath: String, psArgs: [String]) throws -> String {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = psArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        // Drain stdout first — readDataToEndOfFile blocks until EOF (process exit)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()  // cleanup after drain
        return String(data: data, encoding: .utf8) ?? ""
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

    /// Set a pane-local option on the given target.
    /// Returns true on success; fails silently (returns false) if the pane is gone.
    @discardableResult
    static func setPaneOption(target: String, name: String, value: String) -> Bool {
        (try? run(arguments: ["set-option", "-p", "-t", target, name, value])) != nil
    }

    /// Resolve a tty path to a tmux session:window.pane target.
    /// Returns nil if the tty is not found in any tmux pane.
    static func resolveTarget(tty: String) -> String? {
        guard let output = try? run(arguments: [
            "list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"
        ]) else { return nil }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if String(parts[0]) == tty {
                return String(parts[1])
            }
        }
        return nil
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
