import Foundation

/// WebSocket client for cc-status-bar.
/// Auto-scans ports 8080-8089 to find the running instance.
/// Tracks Claude Code session state and notifies on status changes.
final class CCStatusBarClient: NSObject, URLSessionWebSocketDelegate {

    /// A Claude Code or Codex session reported by cc-status-bar.
    struct CCSession {
        let id: String
        let project: String
        var status: String              // "running" | "waiting_input" | "stopped"
        let sessionType: String         // "claude_code" | "codex"
        let tmuxSession: String?
        let tmuxWindow: String?
        let tmuxPane: String?
        let isAttached: Bool            // tmux session is currently attached (informational only)
        let attentionLevel: Int         // 0=green, 1=yellow, 2=red
        let waitingReason: String?      // "permission_prompt" | "askUserQuestion" | "stop" | nil
        var paneCapture: String?        // pane output from cc-status-bar
        let questionText: String?       // AskUserQuestion: question text (from cc-status-bar)
        let questionOptions: [String]?  // AskUserQuestion: option labels
        let questionSelected: Int?      // AskUserQuestion: currently selected index

        var tmuxTarget: String? {
            guard let session = tmuxSession else { return nil }
            if let window = tmuxWindow, let pane = tmuxPane {
                return "\(session):\(window).\(pane)"
            }
            if let window = tmuxWindow {
                return "\(session):\(window)"
            }
            return session
        }
    }

    /// Callback: (session, oldStatus, newStatus)
    var onStateChange: ((CCSession, String, String) -> Void)?

    /// Callback: fired when session.progress arrives with pane_capture
    var onProgress: ((CCSession) -> Void)?

    /// Callback: fired when the sessions dictionary is updated (for UI refresh)
    var onSessionsChanged: (() -> Void)?

    private static let portRange: ClosedRange<Int> = 8080...8089
    private static let wsPathSuffix = "/ws/sessions"

    private let logger: AppLogger
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let lock = NSLock()
    private var _sessions: [String: CCSession] = [:]
    private var reconnectAttempts = 0
    private var connectedPort: Int?
    private var isConnected = false
    private var shouldReconnect = true
    private var preferredWebSocketURL: String?
    /// Sessions that have already received a synthetic bootstrap state change.
    private var bootstrappedSessions: Set<String> = []

    init(logger: AppLogger) {
        self.logger = logger
        super.init()
    }

    // MARK: - Public

    func connect() {
        shouldReconnect = true
        reconnectAttempts = 0
        doConnect()
    }

    func setPreferredWebSocketURL(_ url: String?) {
        preferredWebSocketURL = url
    }

    func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
    }

    func session(forProject project: String) -> CCSession? {
        lock.lock()
        defer { lock.unlock() }
        return _sessions.values.first { $0.project == project }
    }

    /// Returns all sessions matching a project name (may include both CC and Codex).
    func sessions(forProject project: String) -> [CCSession] {
        lock.lock()
        defer { lock.unlock() }
        return _sessions.values.filter { $0.project == project }
    }

    func allSessions() -> [CCSession] {
        lock.lock()
        defer { lock.unlock() }
        return _sessions.values
            .sorted { $0.project < $1.project }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // Extract port from the URL for logging
        if let port = webSocketTask.originalRequest?.url?.port {
            connectedPort = port
            logger.log(.info, "CCStatusBarClient: connected on port \(port)")
        } else {
            logger.log(.info, "CCStatusBarClient: WebSocket connected")
        }
        isConnected = true
        reconnectAttempts = 0
        receiveMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        logger.log(.info, "CCStatusBarClient: WebSocket closed (code=\(closeCode.rawValue))")
        isConnected = false
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.log(.debug, "CCStatusBarClient: connection error: \(error.localizedDescription)")
        }
        isConnected = false
        scheduleReconnect()
    }

    // MARK: - Private

    private func doConnect() {
        guard shouldReconnect else { return }

        if let preferredWebSocketURL,
           let preferredURL = URL(string: preferredWebSocketURL) {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: preferredURL)
            self.urlSession = session
            self.webSocketTask = task
            task.resume()
            return
        }

        // Build port list: try last-known port first, then scan all others
        var ports = Array(Self.portRange)
        if let last = connectedPort, ports.contains(last) {
            ports.removeAll { $0 == last }
            ports.insert(last, at: 0)
        }

        for port in ports {
            guard shouldReconnect else { return }
            let urlString = "ws://localhost:\(port)\(Self.wsPathSuffix)"
            guard let url = URL(string: urlString) else { continue }

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            self.urlSession = session
            self.webSocketTask = task
            task.resume()
            return  // URLSessionWebSocketDelegate callbacks handle the rest
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectAttempts += 1
        // No max limit — keep trying indefinitely (cc-status-bar may start later)
        let delay = min(Double(reconnectAttempts) * 3.0, 60.0)
        logger.log(.debug, "CCStatusBarClient: reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.doConnect()
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                self.logger.log(.debug, "CCStatusBarClient: receive error: \(error.localizedDescription)")
                // Connection will be re-established via didCompleteWithError
            }
        }
    }

    private func logRawMessage(type: String, json: [String: Any]) {
        let sessionData = json["session"] as? [String: Any]
        let id = sessionData?["id"] as? String ?? "-"
        let project = sessionData?["project"] as? String ?? "-"
        let status = sessionData?["status"] as? String ?? "-"
        let line = "\(Date()) type=\(type) id=\(id) project=\(project) status=\(status)\n"
        let path = "/tmp/clawgate-ccsb-raw.log"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + line).write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        logRawMessage(type: type, json: json)

        switch type {
        case "sessions.list":
            // Initial full session list
            guard let sessions = json["sessions"] as? [[String: Any]] else { return }
            lock.lock()
            let oldSessions = _sessions
            _sessions.removeAll()
            for s in sessions {
                if let session = parseSession(s) {
                    _sessions[session.id] = session
                }
            }
            let newSessions = _sessions
            lock.unlock()
            logger.log(.info, "CCStatusBarClient: received \(newSessions.count) sessions")

            // Detect status changes by project name (handles session ID changes across reconnects)
            var diffFiredProjects: Set<String> = []
            for (_, newSession) in newSessions {
                if let oldSession = oldSessions.values.first(where: { $0.project == newSession.project }),
                   oldSession.status != newSession.status {
                    logger.log(.info, "CCStatusBarClient: \(newSession.project) status \(oldSession.status) -> \(newSession.status) (via sessions.list diff)")
                    onStateChange?(newSession, oldSession.status, newSession.status)
                    diffFiredProjects.insert(newSession.project)
                }
            }

            onSessionsChanged?()

            // Bootstrap: fire synthetic running→waiting_input for sessions already idle.
            // This kicks off auto-continue for sessions that were waiting before ClawGate started.
            lock.lock()
            let allSessions = Array(_sessions.values)
            lock.unlock()
            let waitingSessions = allSessions.filter { $0.status == "waiting_input" }
            logger.log(.info, "CCStatusBarClient: bootstrap check: \(allSessions.count) total, \(waitingSessions.count) waiting_input")
            // Debug: write to file for diagnostics
            let dbg = "bootstrap: total=\(allSessions.count) waiting=\(waitingSessions.count) projects=\(allSessions.map(\.project))\n"
            try? dbg.write(toFile: "/tmp/clawgate-bootstrap.log", atomically: true, encoding: .utf8)
            var bootstrapLog = dbg
            for session in waitingSessions {
                bootstrapLog += "candidate: \(session.project) id=\(session.id) tmux=\(session.tmuxTarget ?? "nil")\n"
                guard !bootstrappedSessions.contains(session.id) else {
                    bootstrapLog += "  skip (already done)\n"
                    continue
                }
                // Skip projects already fired by diff detection to prevent duplicate onStateChange
                guard !diffFiredProjects.contains(session.project) else {
                    bootstrappedSessions.insert(session.id)
                    bootstrapLog += "  skip (already fired by diff)\n"
                    continue
                }
                bootstrappedSessions.insert(session.id)
                let hasHandler = onStateChange != nil
                bootstrapLog += "  firing (hasHandler=\(hasHandler)) waitingReason=\(session.waitingReason ?? "nil")\n"
                // Use "bootstrap" as oldStatus so TmuxInboundWatcher can skip
                // permission auto-approve (which may be stale at startup).
                onStateChange?(session, "bootstrap", "waiting_input")
                bootstrapLog += "  fired\n"
            }
            try? bootstrapLog.write(toFile: "/tmp/clawgate-bootstrap.log", atomically: true, encoding: .utf8)

        case "session.updated":
            guard let sessionData = json["session"] as? [String: Any],
                  let session = parseSession(sessionData) else { return }

            lock.lock()
            let oldStatus = _sessions[session.id]?.status ?? "unknown"
            _sessions[session.id] = session
            lock.unlock()

            if oldStatus != session.status {
                logger.log(.info, "CCStatusBarClient: \(session.project) status \(oldStatus) -> \(session.status)")
                onStateChange?(session, oldStatus, session.status)
            }
            onSessionsChanged?()

        case "session.progress":
            guard let sessionData = json["session"] as? [String: Any],
                  let session = parseSession(sessionData) else { return }

            // Detect status changes from progress events (fallback for missing session.updated)
            lock.lock()
            let oldProgressStatus = _sessions[session.id]?.status
            _sessions[session.id] = session
            lock.unlock()

            if let old = oldProgressStatus, old != session.status {
                logger.log(.info, "CCStatusBarClient: \(session.project) status \(old) -> \(session.status) (via progress)")
                onStateChange?(session, old, session.status)
            }

            onProgress?(session)

        case "session.added":
            guard let sessionData = json["session"] as? [String: Any],
                  let session = parseSession(sessionData) else { return }

            lock.lock()
            // Check if existing session for same project had different status
            let existingForProject = _sessions.values.first {
                $0.project == session.project && $0.id != session.id
            }
            _sessions[session.id] = session
            lock.unlock()

            logger.log(.info, "CCStatusBarClient: session added: \(session.project) (id=\(session.id))")

            if let existing = existingForProject, existing.status != session.status {
                logger.log(.info, "CCStatusBarClient: \(session.project) status \(existing.status) -> \(session.status) (via added, project match)")
                onStateChange?(session, existing.status, session.status)
            }

            onSessionsChanged?()

        case "session.removed":
            if let sessionId = json["session_id"] as? String {
                lock.lock()
                let removed = _sessions.removeValue(forKey: sessionId)
                lock.unlock()
                if let removed {
                    logger.log(.info, "CCStatusBarClient: session removed: \(removed.project)")
                }
                onSessionsChanged?()
            }

        default:
            logger.log(.debug, "CCStatusBarClient: unknown message type: \(type)")
        }
    }

    private func parseSession(_ dict: [String: Any]) -> CCSession? {
        let sessionType = dict["type"] as? String ?? "claude_code"
        guard sessionType == "claude_code" || sessionType == "codex" else { return nil }

        guard let id = dict["id"] as? String,
              let project = dict["project"] as? String else { return nil }

        let tmux = dict["tmux"] as? [String: Any]

        return CCSession(
            id: id,
            project: project,
            status: dict["status"] as? String ?? "unknown",
            sessionType: sessionType,
            tmuxSession: tmux?["session"] as? String,
            tmuxWindow: (tmux?["window"]).flatMap { "\($0)" },
            tmuxPane: (tmux?["pane"]).flatMap { "\($0)" },
            isAttached: tmux?["is_attached"] as? Bool ?? true,
            attentionLevel: dict["attention_level"] as? Int ?? 0,
            waitingReason: dict["waiting_reason"] as? String,
            paneCapture: dict["pane_capture"] as? String,
            questionText: dict["question_text"] as? String,
            questionOptions: dict["question_options"] as? [String],
            questionSelected: dict["question_selected"] as? Int
        )
    }
}
