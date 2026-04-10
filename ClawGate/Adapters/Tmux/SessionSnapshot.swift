import Foundation

/// A source-agnostic snapshot of a Claude Code / Codex session state.
///
/// Both `CCStatusBarClient` (WebSocket) and `TmuxDirectPoller` (direct tmux)
/// emit this type. Downstream consumers (`TmuxInboundWatcher`, `TmuxAdapter`,
/// `MainPanelView`) work exclusively with this type and never see the source.
struct SessionSnapshot {
    // MARK: - Identity

    let id: String               // Stable session identifier (== sourceID for backward compat)
    let sourceID: String         // Physical source ID: "session:window.pane" (pane-specific)
    let logicalKey: String       // Logical continuity key: "<sessionType>|<normalizedProject>|<rootHint>"
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

    /// Build a logical key from session type, project name, and optional root hint.
    /// Same pane reincarnations (tmux restart, window index change) should map to
    /// the same logicalKey so downstream dedup / continuity holds.
    static func makeLogicalKey(sessionType: String, project: String, rootHint: String = "") -> String {
        let normalizedType = sessionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedProject = project
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedRoot = rootHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedType)|\(normalizedProject)|\(normalizedRoot)"
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

/// Proxy that holds a swappable underlying TmuxSessionSource.
///
/// Passed to downstream consumers (TmuxAdapter, TmuxInboundWatcher) so the
/// real source can be selected at startup time (after probing cc-status-bar)
/// without re-initializing the consumers. Callbacks are held on the proxy
/// and forwarded to whichever underlying source is currently active.
final class TmuxSessionSourceProxy: TmuxSessionSource {
    private var underlying: TmuxSessionSource?

    private var _onStateChange: ((SessionSnapshot, String, String) -> Void)?
    private var _onProgress: ((SessionSnapshot) -> Void)?
    private var _onSessionsChanged: (() -> Void)?

    var onStateChange: ((SessionSnapshot, String, String) -> Void)? {
        get { _onStateChange }
        set {
            _onStateChange = newValue
            underlying?.onStateChange = newValue
        }
    }
    var onProgress: ((SessionSnapshot) -> Void)? {
        get { _onProgress }
        set {
            _onProgress = newValue
            underlying?.onProgress = newValue
        }
    }
    var onSessionsChanged: (() -> Void)? {
        get { _onSessionsChanged }
        set {
            _onSessionsChanged = newValue
            underlying?.onSessionsChanged = newValue
        }
    }

    /// Swap in a new underlying source. Existing callbacks are forwarded.
    /// Old source is cleanly detached (callbacks nil'd, disconnected) before
    /// the new one is wired up, so late emits from the old source are ignored.
    func setUnderlying(_ source: TmuxSessionSource) {
        if let old = underlying {
            old.onStateChange = nil
            old.onProgress = nil
            old.onSessionsChanged = nil
            old.disconnect()
        }
        underlying = source
        source.onStateChange = _onStateChange
        source.onProgress = _onProgress
        source.onSessionsChanged = _onSessionsChanged
    }

    func connect() { underlying?.connect() }
    func disconnect() { underlying?.disconnect() }
    func session(forProject project: String) -> SessionSnapshot? {
        underlying?.session(forProject: project)
    }
    func sessions(forProject project: String) -> [SessionSnapshot] {
        underlying?.sessions(forProject: project) ?? []
    }
    func allSessions() -> [SessionSnapshot] {
        underlying?.allSessions() ?? []
    }
}
