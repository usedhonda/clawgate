import AppKit
import Combine
import Foundation

/// ViewModel for the pet character system
final class PetModel: NSObject, ObservableObject {
    @Published var messages: [OpenClawChatMessage] = []
    @Published var inputText: String = ""
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isStreaming = false
    @Published var opacity: Double = 1.0
    @Published var streamingText: String = ""
    @Published var whisperText: String?       // Layer 1: brief reaction text
    @Published var notificationMessage: OpenClawChatMessage?  // Independent notification
    @Published var petMode: PetMode = .secretary
    @Published var isVisible: Bool = true
    @Published var isTrackingEnabled: Bool = true
    @Published var isBubbleEnabled: Bool = true
    @Published var isWhisperEnabled: Bool = true
    @Published var characterSize: CGFloat = 128
    @Published var notificationHistory: [NotificationEntry] = []
    @Published var summonResults: [NotificationEntry] = []
    @Published var showSummonTab: Bool = false  // Auto-open summon tab on response
    @Published var targetPosition: NSPoint?   // Window tracking target

    let stateMachine = PetStateMachine()
    let characterManager = CharacterManager()

    private let wsClient = OpenClawWSClient()
    private var sessionKey: String?
    private var eventTask: Task<Void, Never>?
    private var streamingMessageId: String?
    private var whisperDismissTask: Task<Void, Never>?
    private var notificationDismissTask: Task<Void, Never>?
    private var speakTimeoutTask: Task<Void, Never>?
    private var deltaIdleTask: Task<Void, Never>?
    private var idleTimer: Timer?
    private var windowTrackingTimer: Timer?
    private var dragPauseUntil: Date?
    private var lastTrackedApp: NSRunningApplication?
    @Published var shouldWaveOnArrival = false
    private enum PlacementSide { case left, right }
    private var lastPlacementSide: PlacementSide = .right
    @Published var currentWindowOrigin: NSPoint?  // For walk direction calculation

    /// Pet interaction mode (right-click menu)
    enum PetMode: String, CaseIterable {
        case secretary = "秘書"
        case watching = "見守り"
        case quiet = "静音"
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // MARK: - Connection

    func connect() {
        guard connectionState != .connecting && connectionState != .connected else { return }
        guard let config = readOpenClawGatewayConfig() else {
            NSLog("[Pet] Gateway config not found in ~/.openclaw/openclaw.json")
            connectionState = .disconnected
            return
        }
        // Use localhost (SSH tunnel) for secure context compatibility
        guard let url = URL(string: "ws://127.0.0.1:\(config.port)/") else {
            connectionState = .error("Invalid URL")
            return
        }
        NSLog("[Pet] Connecting to Gateway: %@", url.absoluteString)

        connectionState = .connecting

        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await wsClient.connect(url: url, token: config.token)
                for await event in stream {
                    self.handleEvent(event)
                }
                // Stream ended
                await MainActor.run {
                    self.connectionState = .disconnected
                    self.stateMachine.handle(.disconnected)
                }
            } catch {
                NSLog("[Pet] Connection error: %@", "\(error)")
                await MainActor.run {
                    self.connectionState = .error("\(error)")
                    self.stateMachine.handle(.disconnected)
                }
            }
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        Task { await wsClient.disconnect() }
        connectionState = .disconnected
        stateMachine.handle(.disconnected)
    }

    // MARK: - Send

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionKey else { return }

        let userMsg = OpenClawChatMessage(role: .user, text: text)
        messages.append(userMsg)
        inputText = ""

        Task { [weak self] in
            guard let self else { return }
            do {
                try await wsClient.sendMessage(text, sessionKey: sessionKey)
            } catch {
                await MainActor.run {
                    self.messages.append(OpenClawChatMessage(
                        role: .assistant, text: "Error: \(error)"))
                }
            }
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: OpenClawEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch event {
            case .connected(_, let key):
                self.sessionKey = key
                self.connectionState = .connected
                self.stateMachine.handle(.reconnected)
                NSLog("[Pet] Connected to Gateway, sessionKey=%@", key)
                self.showWhisper("接続しました")
                Task { [weak self] in
                    guard let self, let key = self.sessionKey else { return }
                    try? await self.wsClient.subscribeToSession(sessionKey: key)
                    // Subscribe to proactive heartbeat for realtime notifications
                    try? await self.wsClient.subscribeToSession(sessionKey: "agent:main:proactive:heartbeat")
                }

            case .message(let msg):
                NSLog("[Pet] message event: role=%@ text=%@", msg.role == .assistant ? "assistant" : "user", String(msg.text.prefix(50)))
                self.isStreaming = false
                self.streamingText = ""

                // Route summon responses to Summon tab
                if msg.role == .assistant, let source = self.pendingSummonSource {
                    self.pendingSummonSource = nil
                    self.addSummonResult(text: msg.text, source: source)
                    self.stateMachine.handle(.assistantFinished)
                    break
                }

                let isNew: Bool
                if let idx = self.messages.firstIndex(where: { $0.id == msg.id }) {
                    self.messages[idx].text = msg.text
                    self.messages[idx].isStreaming = false
                    isNew = false
                } else {
                    self.messages.append(msg)
                    isNew = true
                }
                self.stateMachine.handle(.assistantFinished)
                // Show notification for new assistant messages (independent of state machine)
                if isNew && msg.role == .assistant {
                    self.showNotification(msg)
                }

            case .delta(let messageId, let text):
                if self.streamingMessageId != messageId {
                    self.streamingMessageId = messageId
                    self.streamingText = text
                    self.isStreaming = true
                    let streamingMsg = OpenClawChatMessage(
                        id: messageId, role: .assistant, text: text, isStreaming: true)
                    self.messages.append(streamingMsg)
                    // Only show speak animation if chat is open
                    if self.stateMachine.isChatOpen {
                        self.stateMachine.handle(.assistantStarted)
                    }
                } else {
                    self.streamingText += text
                    if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                        self.messages[idx].text = self.streamingText
                    }
                    // Reset idle timer on each delta — stop speak 5s after last delta
                    self.deltaIdleTask?.cancel()
                    self.deltaIdleTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        if self.isStreaming {
                            self.isStreaming = false
                            let mid = self.streamingMessageId
                            self.streamingMessageId = nil
                            self.finishStreamingMessage(messageId: mid)
                            self.stateMachine.handle(.assistantFinished)
                        }
                    }
                }

            case .messageComplete(let messageId):
                NSLog("[Pet] messageComplete: %@", messageId)
                self.isStreaming = false
                self.streamingMessageId = nil
                self.finishStreamingMessage(messageId: messageId)
                self.stateMachine.handle(.assistantFinished)

            case .history(let msgs):
                NSLog("[Pet] Loaded %d history messages", msgs.count)
                self.messages = msgs

            case .error(let err):
                switch err {
                case .connectionFailed(let msg):
                    self.connectionState = .error(msg)
                case .serverError(_, let msg):
                    self.connectionState = .error(msg)
                default:
                    self.connectionState = .error("\(err)")
                }

            case .disconnected:
                self.connectionState = .disconnected
                self.stateMachine.handle(.disconnected)
                self.showWhisper("すぅ…")
            }
        }
    }

    // MARK: - History

    func loadHistory() {
        guard let sessionKey else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.wsClient.chatHistory(sessionKey: sessionKey, limit: 50)
        }
    }

    // MARK: - Notification (independent of state machine)

    func showNotification(_ msg: OpenClawChatMessage) {
        NSLog("[Pet] showNotification: bubbleEnabled=%d chatOpen=%d text=%@", isBubbleEnabled ? 1 : 0, stateMachine.isChatOpen ? 1 : 0, String(msg.text.prefix(30)))

        // Always save to history
        addNotificationEntry(text: msg.text, source: msg.isProactive ? "proactive" : "gateway")

        guard isBubbleEnabled, !stateMachine.isChatOpen else {
            NSLog("[Pet] showNotification suppressed")
            return
        }
        // Duration scales with text length: 15s base + 1s per 20 chars, max 60s
        let duration = min(max(15.0, Double(msg.text.count) / 20.0 + 15.0), 60.0)
        notificationMessage = msg
        notificationDismissTask?.cancel()
        notificationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notificationMessage = nil
        }
    }

    func dismissNotification() {
        notificationDismissTask?.cancel()
        notificationMessage = nil
    }

    func toggleChat() {
        if stateMachine.isChatOpen {
            stateMachine.isChatOpen = false
        } else {
            stateMachine.isChatOpen = true
            dismissNotification()
        }
    }

    // MARK: - Layer 1: Whisper (brief reaction)

    func showWhisper(_ text: String, duration: TimeInterval = 3.0) {
        guard petMode != .quiet, isWhisperEnabled else { return }
        whisperText = text
        whisperDismissTask?.cancel()
        whisperDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.whisperText = nil
        }
    }

    func dismissWhisper() {
        whisperDismissTask?.cancel()
        whisperText = nil
    }

    // MARK: - Idle Variation Timer

    private var cycleWorkItem: DispatchWorkItem?

    private func startIdleTimer() {
        idleTimer?.invalidate()
        cycleWorkItem?.cancel()
        runCycle()
    }

    private let randomActions: [PetState] = [.wave, .react, .blush, .idleBreathe, .funny, .secretary]

    /// 30-second cycle with random actions mixed in
    private func runCycle() {
        cycleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Pick two random actions for this cycle
            let rand1 = self.randomActions.randomElement() ?? .wave
            let rand2 = self.randomActions.randomElement() ?? .blush

            self.scheduleCycleAction(at: 3,  state: .blinkA, duration: 0.5)
            self.scheduleCycleAction(at: 6,  state: rand1,   duration: 3.0)   // ランダム表情
            self.scheduleCycleAction(at: 10, state: .blinkA, duration: 0.5)
            self.scheduleCycleAction(at: 13, state: .blinkB, duration: 0.6)
            self.scheduleCycleAction(at: 16, state: .bodyA,  duration: 0.7)
            self.scheduleCycleAction(at: 19, state: .blinkA, duration: 0.5)
            self.scheduleCycleAction(at: 22, state: rand2,   duration: 3.0)   // ランダム表情
            self.scheduleCycleAction(at: 26, state: .blinkB, duration: 0.6)
            self.scheduleCycleAction(at: 29, state: .blinkA, duration: 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.runCycle()
            }
        }
        cycleWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func scheduleCycleAction(at seconds: Double, state: PetState, duration: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.stateMachine.current == .idle else { return }
            self.stateMachine.current = state
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.stateMachine.current == state else { return }
                self.stateMachine.current = .idle
            }
        }
    }

    // MARK: - Window Tracking (follow active window)

    func onPetDragged() {
        dragPauseUntil = Date().addingTimeInterval(30)
    }

    func startWindowTracking() {
        windowTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateTargetPosition()
        }
    }

    private func updateTargetPosition() {
        guard isTrackingEnabled else { return }
        if let pause = dragPauseUntil, Date() < pause { return }

        let frontmost = NSWorkspace.shared.frontmostApplication

        // Track last non-ClawGate frontmost app (ClawGate becomes frontmost on pet click)
        if let app = frontmost, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            if lastTrackedApp?.processIdentifier != app.processIdentifier {
                shouldWaveOnArrival = true  // New window — wave on arrival
            }
            lastTrackedApp = app
        }

        guard let app = lastTrackedApp else { return }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let focusedWin = AXQuery.focusedWindow(appElement: appElement),
              let frame = AXQuery.copyFrameAttribute(focusedWin) else { return }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let petSize: CGFloat = characterSize + 20  // match actual window size

        // Skip small windows (popups, dialogs)
        if frame.width < 300 || frame.height < 200 { return }

        // Skip fullscreen apps
        if let screenFull = NSScreen.main?.frame,
           abs(frame.width - screenFull.width) < 10 && abs(frame.height - screenFull.height) < 40 {
            return
        }

        // AX coordinates (top-left origin) → AppKit coordinates (bottom-left origin)
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let appKitY = screenHeight - frame.origin.y - frame.height

        let overlap = characterSize * 0.15  // scale overlap with size
        let rightX = frame.origin.x + frame.width - overlap
        let leftX = frame.origin.x - petSize + overlap
        let topY = appKitY + frame.height - petSize
        let bottomY = appKitY

        // Candidate positions: always bottom, left or right
        var candidates: [(point: NSPoint, side: PlacementSide)] = []
        if rightX + petSize <= screen.maxX {
            candidates.append((NSPoint(x: rightX, y: bottomY), .right))
        }
        if leftX >= screen.minX {
            candidates.append((NSPoint(x: leftX, y: bottomY), .left))
        }

        guard !candidates.isEmpty else {
            // No valid position, fallback
            targetPosition = NSPoint(x: screen.maxX - petSize - 8, y: screen.minY + 8)
            return
        }

        // Pick closest candidate to current pet position
        let petPos = currentWindowOrigin ?? NSPoint(x: screen.maxX - petSize, y: screen.minY)
        var target = candidates[0].point
        var bestDist = Double.infinity
        var bestSide = candidates[0].side
        for c in candidates {
            // Hysteresis: slight preference for current side
            let bonus: Double = c.side == lastPlacementSide ? -50 : 0
            let d = sqrt(pow(c.point.x - petPos.x, 2) + pow(c.point.y - petPos.y, 2)) + bonus
            if d < bestDist {
                bestDist = d
                target = c.point
                bestSide = c.side
            }
        }
        lastPlacementSide = bestSide

        target.x = max(screen.minX, min(target.x, screen.maxX - petSize))
        target.y = max(screen.minY, min(target.y, screen.maxY - petSize))

        // Walk direction based on movement delta
        if let current = currentWindowOrigin {
            let dx = target.x - current.x
            let dy = target.y - current.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance > 20 {
                // Set walk state based on dominant direction
                let walkState: PetState
                if abs(dx) > abs(dy) {
                    walkState = dx > 0 ? .walkRight : .walkLeft
                } else {
                    walkState = dy > 0 ? .walkBack : .walkFront
                }
                // Set walk unless actively speaking
                let current = stateMachine.current
                let isSpeaking = current == .speak || current == .speakMix
                    || current == .speakTilt || current == .talk
                if !isSpeaking {
                    stateMachine.current = walkState
                }
            } else if stateMachine.current == .walkFront || stateMachine.current == .walkBack
                        || stateMachine.current == .walkLeft || stateMachine.current == .walkRight {
                stateMachine.current = .idle
            }
        }

        // Only update if target moved significantly (avoid interrupting animation)
        if let prev = targetPosition {
            let moveDist = sqrt(pow(target.x - prev.x, 2) + pow(target.y - prev.y, 2))
            if moveDist < 10 { return }
        }
        targetPosition = target
    }

    // MARK: - Lifecycle

    func start() {
        characterManager.scan()
        _ = try? OpenClawDeviceIdentity.loadOrCreate()
        connect()
        startIdleTimer()
        startReconnectTimer()
        startWindowTracking()

        // Listen for bubble_notify from bridge
        NotificationCenter.default.addObserver(forName: .petBubbleNotify, object: nil, queue: .main) { [weak self] notif in
            guard let self, let text = notif.userInfo?["text"] as? String else {
                NSLog("[Pet] bubble_notify: missing text")
                return
            }
            NSLog("[Pet] bubble_notify received: %@", String(text.prefix(50)))
            let source = notif.userInfo?["source"] as? String ?? "bridge"
            let msg = OpenClawChatMessage(role: .assistant, text: text)
            self.messages.append(msg)
            self.addNotificationEntry(text: text, source: source)
            self.showNotification(msg)
        }
    }

    /// Retry connection every 15s if disconnected (handles Gateway-after-ClawGate startup)
    private func startReconnectTimer() {
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.connectionState == .disconnected {
                self.connect()
            }
        }
    }

    func cleanup() {
        disconnect()
        idleTimer?.invalidate()
        idleTimer = nil
        cycleWorkItem?.cancel()
        cycleWorkItem = nil
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
    }

    // MARK: - Screen Context Capture (on-demand AX)

    func captureScreenContext() -> ScreenContext {
        let app = lastTrackedApp ?? NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleId = app?.bundleIdentifier ?? ""

        let terminalBundles: Set<String> = [
            "com.mitchellh.ghostty", "com.apple.Terminal",
            "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        ]
        let isTerminal = terminalBundles.contains(bundleId)

        var windowTitle = ""
        var visibleText = ""

        if let pid = app?.processIdentifier {
            let appElement = AXQuery.applicationElement(pid: pid)
            if let focusedWin = AXQuery.focusedWindow(appElement: appElement) {
                windowTitle = AXQuery.copyStringAttribute(focusedWin, attribute: kAXTitleAttribute as String) ?? ""

                let nodes = AXQuery.descendants(of: focusedWin, maxDepth: 3, maxNodes: 100)
                let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXCell"]
                var parts: [String] = []
                var seen = Set<String>()
                for node in nodes {
                    guard let role = node.role, textRoles.contains(role) else { continue }
                    let text = node.value ?? node.title ?? node.description ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                    seen.insert(trimmed)
                    parts.append(trimmed)
                }
                visibleText = parts.joined(separator: "\n")
                if visibleText.count > 2000 {
                    visibleText = String(visibleText.prefix(2000))
                }
            }
        }

        // For terminal apps, try to get tmux pane content (richer than AX)
        var paneContent = ""
        var paneCwd = ""
        if isTerminal {
            if let info = captureTmuxPaneInfo() {
                paneContent = info.content
                paneCwd = info.cwd
                // Tmux pane content is usually better than AX for terminals
                if !paneContent.isEmpty { visibleText = paneContent }
            }
        }

        return ScreenContext(
            appName: appName, bundleId: bundleId,
            windowTitle: windowTitle, visibleText: visibleText,
            isTerminal: isTerminal, paneCwd: paneCwd
        )
    }

    /// Capture active tmux pane content and cwd
    private func captureTmuxPaneInfo() -> (content: String, cwd: String)? {
        // Get active pane's content via capture-pane
        let captureProc = Process()
        captureProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        captureProc.arguments = ["tmux", "capture-pane", "-p", "-S", "-50"]
        let capturePipe = Pipe()
        captureProc.standardOutput = capturePipe
        captureProc.standardError = Pipe()
        try? captureProc.run()
        captureProc.waitUntilExit()
        guard captureProc.terminationStatus == 0 else { return nil }
        var content = String(data: capturePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if content.count > 2000 { content = String(content.suffix(2000)) }

        // Get active pane's cwd
        let cwdProc = Process()
        cwdProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cwdProc.arguments = ["tmux", "display-message", "-p", "#{pane_current_path}"]
        let cwdPipe = Pipe()
        cwdProc.standardOutput = cwdPipe
        cwdProc.standardError = Pipe()
        try? cwdProc.run()
        cwdProc.waitUntilExit()
        let cwd = String(data: cwdPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (content: content, cwd: cwd)
    }

    // MARK: - Summon (right-click actions)

    func summonOmakase() {
        guard sessionKey != nil else {
            showWhisper("Not connected")
            return
        }
        let ctx = captureScreenContext()
        let cwdLine = ctx.paneCwd.isEmpty ? "" : "\nWorking directory: \(ctx.paneCwd)"
        let prompt = """
        [Summon:Omakase]
        [Context]
        App: \(ctx.appName)
        Window: \(ctx.windowTitle)\(cwdLine)
        Screen text:
        \(ctx.visibleText)

        Based on what I'm looking at, give me the most useful response.
        If it's an error, explain the cause and fix.
        If it's a message/email, summarize and draft a reply.
        If it's code, point out issues or suggest improvements.
        If it's an article, summarize the key points.
        Keep it concise.
        """
        sendSummon(prompt, source: "omakase")
    }

    func summonAsk(instruction: String) {
        guard sessionKey != nil else {
            showWhisper("Not connected")
            return
        }
        let ctx = captureScreenContext()
        let cwdLine = ctx.paneCwd.isEmpty ? "" : "\nWorking directory: \(ctx.paneCwd)"
        let prompt = """
        [Summon:Ask]
        [Context]
        App: \(ctx.appName)
        Window: \(ctx.windowTitle)\(cwdLine)
        Screen text:
        \(ctx.visibleText)

        User instruction: \(instruction)
        """
        sendSummon(prompt, source: "ask")
    }

    func summonDraftPR() {
        guard sessionKey != nil else {
            showWhisper("Not connected")
            return
        }

        // Get tmux pane cwd via tty mapping
        BlockingWork.queue.async { [weak self] in
            guard let self else { return }
            let cwd = self.detectTmuxPaneCwd()
            guard let cwd, !cwd.isEmpty else {
                DispatchQueue.main.async { self.showWhisper("No git repo found") }
                return
            }

            // Check if git repo
            let gitCheck = Process()
            gitCheck.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            gitCheck.arguments = ["-C", cwd, "rev-parse", "--is-inside-work-tree"]
            gitCheck.standardOutput = Pipe()
            gitCheck.standardError = Pipe()
            try? gitCheck.run()
            gitCheck.waitUntilExit()
            guard gitCheck.terminationStatus == 0 else {
                DispatchQueue.main.async { self.showWhisper("Not a git repo") }
                return
            }

            // Get git diff
            let diffProc = Process()
            diffProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            diffProc.arguments = ["-C", cwd, "diff", "--stat", "--unified=3"]
            let diffPipe = Pipe()
            diffProc.standardOutput = diffPipe
            diffProc.standardError = Pipe()
            try? diffProc.run()
            diffProc.waitUntilExit()
            let diffData = diffPipe.fileHandleForReading.readDataToEndOfFile()
            var diffText = String(data: diffData, encoding: .utf8) ?? ""
            if diffText.count > 4000 { diffText = String(diffText.prefix(4000)) }

            guard !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async { self.showWhisper("No changes to diff") }
                return
            }

            let prompt = """
            [Summon:DraftPR]
            Here's the git diff for this project. Write a PR description.

            \(diffText)

            Format:
            ## Summary
            - bullet points

            ## Changes
            - file-by-file summary
            """

            DispatchQueue.main.async {
                self.sendSummon(prompt, source: "draft_pr")
            }
        }
    }

    /// Handle streaming message completion — route to summon or regular chat
    private func finishStreamingMessage(messageId: String?) {
        guard let messageId else { return }
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].isStreaming = false
            // If this was a summon response, move it to summon results
            if let source = pendingSummonSource {
                pendingSummonSource = nil
                let text = messages[idx].text
                messages.remove(at: idx)
                addSummonResult(text: text, source: source)
            }
        }
    }

    private var pendingSummonSource: String?

    private func sendSummon(_ prompt: String, source: String) {
        guard let sessionKey else { return }

        pendingSummonSource = source

        // Record pending state
        addNotificationEntry(text: "Requesting \(source)...", source: source)
        showWhisper("Working on it...")

        Task { [weak self] in
            guard let self else { return }
            do {
                try await wsClient.sendMessage(prompt, sessionKey: sessionKey)
            } catch {
                await MainActor.run {
                    self.pendingSummonSource = nil
                    self.addSummonResult(text: "Error: \(error)", source: source)
                }
            }
        }
    }

    func addSummonResult(text: String, source: String) {
        let entry = NotificationEntry(
            id: UUID().uuidString, text: text,
            source: source, timestamp: Date()
        )
        summonResults.append(entry)
        if summonResults.count > 50 {
            summonResults.removeFirst(summonResults.count - 50)
        }
        // Auto-open chat window on Summon tab
        showSummonTab = true
    }

    private func detectTmuxPaneCwd() -> String? {
        // List all tmux panes with tty and cwd
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{pane_current_path}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Try to match frontmost terminal's tty
        // For now, use the first pane as fallback — could be improved with AX tty detection
        guard let first = lines.first else { return nil }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return parts.dropFirst().joined(separator: " ")
    }

    // MARK: - Notification History

    func addNotificationEntry(text: String, source: String) {
        let entry = NotificationEntry(
            id: UUID().uuidString, text: text,
            source: source, timestamp: Date()
        )
        notificationHistory.append(entry)
        // Keep max 100 entries
        if notificationHistory.count > 100 {
            notificationHistory.removeFirst(notificationHistory.count - 100)
        }
    }
}

// MARK: - Supporting Types

struct ScreenContext {
    let appName: String
    let bundleId: String
    let windowTitle: String
    let visibleText: String
    let isTerminal: Bool
    var paneCwd: String = ""
}

struct NotificationEntry: Identifiable {
    let id: String
    let text: String
    let source: String  // "omakase", "ask", "draft_pr", "proactive", "gateway"
    let timestamp: Date
}
