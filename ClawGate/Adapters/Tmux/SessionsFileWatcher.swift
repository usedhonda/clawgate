import Foundation

/// Watches `~/Library/Application Support/CCStatusBar/sessions.json` for changes
/// using DispatchSource (EVFILT_VNODE). Detects status transitions and fires a callback
/// compatible with `TmuxInboundWatcher.handleStateChange`.
///
/// This provides a direct, low-latency path for detecting Claude Code state changes
/// without depending on the cc-status-bar WebSocket relay.
final class SessionsFileWatcher {

    /// Callback: (session, oldStatus, newStatus) — same signature as CCStatusBarClient.onStateChange
    var onStateChange: ((CCStatusBarClient.CCSession, String, String) -> Void)?

    private let filePath: String
    private let configStore: ConfigStore
    private let logger: AppLogger
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.clawgate.sessions-file-watcher", qos: .utility)
    private let lock = NSLock()

    /// Tracks previous status per session key (sessionId:tty or sessionId)
    private var previousStates: [String: String] = [:]

    /// Cache of resolved tty -> tmux target mappings (refreshed periodically)
    private var ttyTargetCache: [String: String] = [:]
    private var lastCacheRefresh: Date = .distantPast
    private let cacheRefreshInterval: TimeInterval = 10

    init(configStore: ConfigStore, logger: AppLogger) {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CCStatusBar")
        self.filePath = appSupport.appendingPathComponent("sessions.json").path
        self.configStore = configStore
        self.logger = logger
    }

    func start() {
        // Initial read to seed previousStates
        if let sessions = readSessions() {
            lock.lock()
            for (key, session) in sessions {
                previousStates[key] = session["status"] as? String ?? "unknown"
            }
            lock.unlock()
            logger.log(.info, "SessionsFileWatcher: seeded \(sessions.count) sessions from \(filePath)")
        }

        startFileMonitor()
        logger.log(.info, "SessionsFileWatcher: started monitoring \(filePath)")
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        logger.log(.info, "SessionsFileWatcher: stopped")
    }

    // MARK: - File Monitoring

    private func startFileMonitor() {
        debugLog("startFileMonitor: opening \(filePath)")
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            debugLog("startFileMonitor: FAILED to open fd=\(fd) errno=\(errno)")
            logger.log(.warning, "SessionsFileWatcher: cannot open \(filePath) for monitoring (fd=\(fd))")
            // Retry after delay — file may not exist yet
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startFileMonitor()
            }
            return
        }
        debugLog("startFileMonitor: opened fd=\(fd)")

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.handleFileChange()

            // Atomic writes (temp -> rename) invalidate our fd.
            // Re-create the DispatchSource to track the new inode.
            if flags.contains(.rename) || flags.contains(.delete) {
                source.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startFileMonitor()
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        dispatchSource = source
        source.resume()
    }

    private func handleFileChange() {
        debugLog("handleFileChange: triggered")
        // Small delay to let the writer finish atomic write
        Thread.sleep(forTimeInterval: 0.05)

        guard let sessions = readSessions() else {
            debugLog("handleFileChange: readSessions returned nil")
            return
        }
        debugLog("handleFileChange: parsed \(sessions.count) sessions")

        let config = configStore.load()

        lock.lock()
        let oldStates = previousStates
        lock.unlock()

        var changes: [(key: String, session: CCStatusBarClient.CCSession, oldStatus: String, newStatus: String)] = []

        for (key, dict) in sessions {
            let newStatus = dict["status"] as? String ?? "unknown"
            let oldStatus = oldStates[key] ?? "unknown"

            guard oldStatus != newStatus else { continue }

            // Only process tmux sessions
            let termProgram = dict["term_program"] as? String
            guard termProgram == "tmux" else { continue }

            // Build project name from cwd basename
            let cwd = dict["cwd"] as? String ?? ""
            let project = (cwd as NSString).lastPathComponent

            // Mode filter — skip ignored sessions
            let mode = config.tmuxSessionModes[project] ?? "ignore"
            guard mode != "ignore" else { continue }

            // Resolve tty to tmux target
            let tty = dict["tty"] as? String
            let tmuxTarget = resolveTmuxTarget(tty: tty)

            // Parse tmux target into components
            let (tmuxSession, tmuxWindow, tmuxPane) = parseTmuxTarget(tmuxTarget)

            let sessionId = dict["session_id"] as? String ?? key
            let waitingReason = dict["waiting_reason"] as? String
            let ccSession = CCStatusBarClient.CCSession(
                id: sessionId,
                project: project,
                status: newStatus,
                tmuxSession: tmuxSession,
                tmuxWindow: tmuxWindow,
                tmuxPane: tmuxPane,
                isAttached: true,
                attentionLevel: 0,
                waitingReason: waitingReason
            )

            changes.append((key: key, session: ccSession, oldStatus: oldStatus, newStatus: newStatus))
        }

        // Update previousStates
        lock.lock()
        for (key, dict) in sessions {
            previousStates[key] = dict["status"] as? String ?? "unknown"
        }
        lock.unlock()

        // Fire callbacks
        for change in changes {
            debugLog("file-watch: \(change.session.project) \(change.oldStatus)->\(change.newStatus) tty=\(change.session.tmuxTarget ?? "nil")")
            onStateChange?(change.session, change.oldStatus, change.newStatus)
        }
    }

    // MARK: - JSON Parsing

    private func readSessions() -> [String: [String: Any]]? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: [String: Any]] else {
            return nil
        }
        return sessions
    }

    // MARK: - Tmux Target Resolution

    private func resolveTmuxTarget(tty: String?) -> String? {
        guard let tty else { return nil }

        // Check cache
        if Date().timeIntervalSince(lastCacheRefresh) < cacheRefreshInterval,
           let cached = ttyTargetCache[tty] {
            return cached
        }

        // Refresh cache
        refreshTtyCache()
        return ttyTargetCache[tty]
    }

    private func refreshTtyCache() {
        lastCacheRefresh = Date()
        ttyTargetCache.removeAll()

        let process = Process()
        let candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let tmuxPath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/tmux"
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                ttyTargetCache[String(parts[0])] = String(parts[1])
            }
        } catch {
            logger.log(.debug, "SessionsFileWatcher: tmux list-panes failed: \(error)")
        }
    }

    /// Parse "session:window.pane" into components.
    private func parseTmuxTarget(_ target: String?) -> (session: String?, window: String?, pane: String?) {
        guard let target else { return (nil, nil, nil) }
        // Format: "sessionName:windowIndex.paneIndex"
        let colonParts = target.split(separator: ":", maxSplits: 1)
        guard colonParts.count == 2 else { return (String(target), nil, nil) }

        let sessionName = String(colonParts[0])
        let windowPane = String(colonParts[1])

        let dotParts = windowPane.split(separator: ".", maxSplits: 1)
        if dotParts.count == 2 {
            return (sessionName, String(dotParts[0]), String(dotParts[1]))
        }
        return (sessionName, windowPane, nil)
    }

    private func debugLog(_ line: String) {
        let path = "/tmp/clawgate-captureAndEmit.log"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let entry = "\(Date()) [SessionsFileWatcher] \(line)\n"
        try? (existing + entry).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
