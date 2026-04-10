import Foundation

/// A source-agnostic snapshot of a Claude Code / Codex session state.
///
/// Both `CCStatusBarClient` (WebSocket) and `TmuxDirectPoller` (direct tmux)
/// emit this type. Downstream consumers (`TmuxInboundWatcher`, `TmuxAdapter`,
/// `MainPanelView`) work exclusively with this type and never see the source.
struct SessionSnapshot {
    // MARK: - Identity

    let id: String               // Stable session identifier
    let project: String          // Project / repo name
    let sessionType: String      // "claude_code" | "codex"

    // MARK: - Tmux Location

    let tmuxSession: String?
    let tmuxWindow: String?
    let tmuxPane: String?

    // MARK: - Status

    var status: String           // "running" | "waiting_input" | "stopped"
    let waitingReason: String?   // nil | "permission_prompt" | "askUserQuestion" | "stop"
    let attentionLevel: Int      // 0 = normal, 1 = warning, 2 = urgent

    // MARK: - Question Data (structured, optional)

    let questionText: String?
    let questionOptions: [String]?
    let questionSelected: Int?

    // MARK: - Pane Capture

    var paneCapture: String?
    let captureSource: CaptureSource?

    enum CaptureSource: String {
        case websocket = "websocket"
        case tmuxDirect = "tmux_direct"
    }

    // MARK: - Informational

    let isAttached: Bool

    // MARK: - Computed

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

    /// Whether structured question data OR pane capture is available for
    /// question detection.
    var hasQuestionData: Bool {
        if let opts = questionOptions, opts.count >= 2, questionText != nil {
            return true
        }
        if let capture = paneCapture, !capture.isEmpty {
            return true
        }
        return false
    }

    /// Whether this session is ready to receive keyboard input.
    var readyForSend: Bool {
        tmuxTarget != nil && status == "waiting_input"
    }
}

protocol TmuxSessionSource: AnyObject {
    var onStateChange: ((SessionSnapshot, String, String) -> Void)? { get set }
    var onProgress: ((SessionSnapshot) -> Void)? { get set }
    var onSessionsChanged: (() -> Void)? { get set }

    func connect()
    func disconnect()
    func session(forProject project: String) -> SessionSnapshot?
    func sessions(forProject project: String) -> [SessionSnapshot]
    func allSessions() -> [SessionSnapshot]
}
