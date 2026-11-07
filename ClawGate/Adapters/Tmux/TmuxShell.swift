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

    /// One process-table snapshot, indexed once and reused across all unresolved
    /// panes in a poll. Never cache this across polls: exited/reused PIDs must not
    /// keep a stale session classification alive.
    struct ProcessSnapshot {
        private struct Row {
            let pid: Int32
            let command: String
        }
        private var children: [Int32: [Row]] = [:]

        init(output: String) {
            for line in output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                let scanner = Scanner(string: text)
                scanner.charactersToBeSkipped = .whitespaces
                var pidValue: Int64 = 0
                var parentValue: Int64 = 0
                guard scanner.scanInt64(&pidValue), scanner.scanInt64(&parentValue),
                      let pid = Int32(exactly: pidValue), pid > 0,
                      let parent = Int32(exactly: parentValue), parent >= 0 else { continue }
                let command = String(text[scanner.currentIndex...])
                    .trimmingCharacters(in: .whitespaces)
                children[parent, default: []].append(Row(pid: pid, command: command))
            }
        }

        func descendantArgs(rootPID: Int32, maxDepth: Int = 3) -> [String] {
            guard rootPID > 0, maxDepth > 0 else { return [] }
            var result: [String] = []
            var queue: [(pid: Int32, depth: Int)] = [(rootPID, 0)]
            var visited = Set<Int32>([rootPID])
            var cursor = 0
            while cursor < queue.count {
                let (pid, depth) = queue[cursor]
                cursor += 1
                guard depth < maxDepth else { continue }
                for child in children[pid] ?? [] where visited.insert(child.pid).inserted {
                    result.append(child.command)
                    queue.append((child.pid, depth + 1))
                }
            }
            return result
        }
    }

    static func processSnapshot() -> ProcessSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,command="]
        guard let output = try? captureOutput(of: process), output.status == 0 else {
            return ProcessSnapshot(output: "")
        }
        return ProcessSnapshot(output: output.stdout)
    }

    static func descendantProcessArgs(rootPID: Int32, maxDepth: Int = 3) -> [String] {
        guard rootPID > 0, maxDepth > 0 else { return [] }
        return processSnapshot().descendantArgs(rootPID: rootPID, maxDepth: maxDepth)
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

    /// Merges LC_ALL=en_US.UTF-8 into `base` without discarding any other
    /// variable. GUI-launched processes on this Mac carry no locale vars at
    /// all, which puts tmux's `-F` formatter in the POSIX/C locale — there it
    /// treats the tab byte (0x09) as non-printable and substitutes `_`,
    /// silently breaking every tab-delimited field split downstream.
    static func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        process.environment = processEnvironment()

        let output = try captureOutput(of: process)
        guard output.status == 0 else {
            throw BridgeRuntimeError(
                code: "tmux_command_failed",
                message: "tmux \(arguments.first ?? "") failed (exit \(output.status))",
                retriable: true,
                failedStep: "tmux_shell",
                details: output.stderr.isEmpty ? output.stdout : output.stderr
            )
        }

        return output.stdout
    }

    struct CommandOutput {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func store(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func load() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Drain BOTH streams while the child runs. Waiting for exit first, or
    /// draining only stdout, deadlocks when either pipe fills (wide tmux panes
    /// and large process tables can exceed the pipe's capacity).
    static func captureOutput(of process: Process) throws -> CommandOutput {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        try process.run()
        let errors = CapturedData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.store(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        readers.wait()
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errors.load(), encoding: .utf8) ?? ""
        )
    }
}
