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
    private(set) var lastTrackedApp: NSRunningApplication?
    /// The AX window element Chi is currently following (for context capture)
    private var lastTrackedWindow: AXUIElement?
    private var lastTrackedWindowFrame: CGRect?
    @Published var shouldWaveOnArrival = false
    var isAnimatingMove = false  // Set by PetWindowController during move animation
    var moveGeneration: UInt = 0  // Incremented on each move, used to guard wave timeout
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
                NSLog("[Pet] message event: role=%@ proactive=%d text=%@",
                      msg.role == .assistant ? "assistant" : "user",
                      msg.isProactive ? 1 : 0, String(msg.text.prefix(50)))
                self.isStreaming = false
                self.streamingText = ""

                // Proactive messages always go to Notifications, never Summon
                if msg.isProactive {
                    self.showNotification(msg)
                    self.stateMachine.handle(.assistantFinished)
                    break
                }

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
                let isSummon = self.pendingSummonSource != nil
                if self.streamingMessageId != messageId {
                    self.streamingMessageId = messageId
                    self.streamingText = text
                    self.isStreaming = true
                    if !isSummon {
                        let streamingMsg = OpenClawChatMessage(
                            id: messageId, role: .assistant, text: text, isStreaming: true)
                        self.messages.append(streamingMsg)
                    }
                    // Only show speak animation if chat is open
                    if self.stateMachine.isChatOpen {
                        self.stateMachine.handle(.assistantStarted)
                    }
                } else {
                    self.streamingText += text
                    if !isSummon, let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
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
              let frame = AXQuery.copyFrameAttribute(focusedWin) else {
            // Window closed or inaccessible — clear walk state to avoid stuck animation
            let current = stateMachine.current
            if current == .walkFront || current == .walkBack
                || current == .walkLeft || current == .walkRight {
                stateMachine.current = .idle
            }
            return
        }

        // Track the specific window Chi is following (for context capture)
        lastTrackedWindow = focusedWin
        lastTrackedWindowFrame = frame

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let petSize: CGFloat = characterSize + 20  // match actual window size

        // Skip small windows (popups, dialogs) — but clear walk first
        if frame.width < 300 || frame.height < 200 {
            clearWalkIfNeeded()
            return
        }

        // Skip fullscreen apps — but clear walk first
        if let screenFull = NSScreen.main?.frame,
           abs(frame.width - screenFull.width) < 10 && abs(frame.height - screenFull.height) < 40 {
            clearWalkIfNeeded()
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

        // Walk direction based on movement delta (skip if mid-animation to avoid stutter)
        if !isAnimatingMove, let current = currentWindowOrigin {
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
                // Set walk unless actively speaking or waving (protect wave arrival animation)
                let current = stateMachine.current
                let isSpeaking = current == .speak || current == .speakMix
                    || current == .speakTilt || current == .talk
                let isWaving = current == .wave
                if !isSpeaking && !isWaving {
                    NSLog("[PetWalk] SET walk=%@ dist=%.0f from=%@ animating=%d gen=%u",
                          String(describing: walkState), distance, String(describing: current),
                          isAnimatingMove ? 1 : 0, moveGeneration)
                    stateMachine.current = walkState
                }
            } else if stateMachine.current == .walkFront || stateMachine.current == .walkBack
                        || stateMachine.current == .walkLeft || stateMachine.current == .walkRight {
                NSLog("[PetWalk] CLEAR walk→idle from=%@ dist=%.0f animating=%d gen=%u",
                      String(describing: stateMachine.current), distance,
                      isAnimatingMove ? 1 : 0, moveGeneration)
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

    /// Clear walk state if currently walking (used by early-return paths)
    private func clearWalkIfNeeded() {
        let current = stateMachine.current
        if current == .walkFront || current == .walkBack
            || current == .walkLeft || current == .walkRight {
            stateMachine.current = .idle
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Restore persisted logs
        notificationHistory = PetLogStore.load(file: "notifications.json")
        summonResults = PetLogStore.load(file: "summon.json")

        characterManager.scan()
        _ = try? OpenClawDeviceIdentity.loadOrCreate()
        connect()
        startIdleTimer()
        startReconnectTimer()
        startWindowTracking()
        startClipboardWatcher()

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
        let isBrowser = DraftPlacer.browserBundles.contains(bundleId)

        var windowTitle = ""
        var visibleText = ""

        if let pid = app?.processIdentifier {
            let appElement = AXQuery.applicationElement(pid: pid)
            // Use the window Chi is following, not just the focused window
            let targetWin = lastTrackedWindow ?? AXQuery.focusedWindow(appElement: appElement)
            if let focusedWin = targetWin {
                windowTitle = AXQuery.copyStringAttribute(focusedWin, attribute: kAXTitleAttribute as String) ?? ""

                // Browser AX trees are deeper — increase search depth for Gmail etc.
                let maxDepth = isBrowser ? 7 : 3
                let maxNodes = isBrowser ? 1000 : 100
                let nodes = AXQuery.descendants(of: focusedWin, maxDepth: maxDepth, maxNodes: maxNodes)
                let textRoles: Set<String> = isBrowser
                    ? ["AXStaticText", "AXTextField", "AXTextArea", "AXCell",
                       "AXHeading", "AXLink", "AXListItem"]
                    : ["AXStaticText", "AXTextField", "AXTextArea", "AXCell"]
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

                // OCR fallback: if AX yielded little/no text, try screenshot + Vision OCR
                // This handles Qt apps (LINE), Electron, and any app with sparse AX trees
                if visibleText.count < 50, let pid = app?.processIdentifier {
                    let winFrame = AXQuery.copyFrameAttribute(focusedWin)
                    // Find the CGWindowID matching this specific window (not just any window of the app)
                    let windowID = Self.findWindowIDByFrame(pid: pid, targetFrame: winFrame)
                        ?? AXActions.findWindowID(pid: pid) // fallback to first window
                    if let windowID, let frame = winFrame {
                        let ocrText = VisionOCR.extractText(
                            from: frame, windowID: windowID,
                            config: .init(confidenceAccept: 0.35, candidateCount: 3)
                        )
                        if let ocr = ocrText, ocr.count > visibleText.count {
                            visibleText = String(ocr.prefix(2000))
                            NSLog("[Pet] captureScreenContext: OCR fallback used (%d chars)", visibleText.count)
                        }
                    }
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

    /// Find CGWindowID matching a specific AX window frame (for multi-window apps like LINE).
    /// Returns nil if no matching window found.
    private static func findWindowIDByFrame(pid: pid_t, targetFrame: CGRect?) -> CGWindowID? {
        guard let target = targetFrame else { return nil }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            // Match by frame position (within tolerance for coordinate system differences)
            if abs(x - target.origin.x) < 5 && abs(y - target.origin.y) < 5
                && abs(w - target.width) < 5 && abs(h - target.height) < 5 {
                return number
            }
        }
        return nil
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
        If it's a message or email and you draft a reply, wrap ONLY the reply text in <draft_reply>...</draft_reply> tags.
        Do NOT use this tag for summaries, explanations, or code suggestions.
        """

        // Capture target app context for post-response draft placement
        if let app = lastTrackedApp ?? NSWorkspace.shared.frontmostApplication {
            let isMessaging: Bool = {
                if Self.messagingBundles.contains(ctx.bundleId) { return true }
                if DraftPlacer.browserBundles.contains(ctx.bundleId) {
                    let title = ctx.windowTitle.lowercased()
                    return title.contains("gmail") || title.contains("outlook.live")
                        || title.contains("outlook.office") || title.contains("yahoo mail")
                        || title.contains("slack") || title.contains("messenger.com")
                        || title.contains("web.whatsapp") || title.contains("discord")
                }
                return false
            }()
            pendingOmakaseContext = OmakaseContext(
                bundleId: ctx.bundleId,
                appName: ctx.appName,
                pid: app.processIdentifier,
                isMessagingApp: isMessaging
            )
        }

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
        // If this was a summon response, route to summon results
        if let source = pendingSummonSource {
            pendingSummonSource = nil
            let text = streamingText.isEmpty ? "(empty response)" : streamingText
            streamingText = ""
            // Remove from messages if it leaked there
            if let messageId, let idx = messages.firstIndex(where: { $0.id == messageId }) {
                messages.remove(at: idx)
            }
            addSummonResult(text: text, source: source)
            return
        }

        guard let messageId else { return }
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].isStreaming = false
        }
    }

    private var pendingSummonSource: String?
    private var pendingOmakaseContext: OmakaseContext?

    private static let messagingBundles: Set<String> = [
        "jp.naver.line.mac",
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "ru.keepcoder.Telegram",
        "com.hnc.Discord",
    ]

    private func sendSummon(_ prompt: String, source: String) {
        guard let sessionKey else { return }

        pendingSummonSource = source
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
        // Draft reply detection: if messaging app + <draft_reply> tag → place in input field
        if source == "omakase",
           let ctx = pendingOmakaseContext,
           ctx.isMessagingApp,
           let draftText = TagExtractor.extractDraftReply(from: text) {
            pendingOmakaseContext = nil
            BlockingWork.queue.async { [weak self] in
                let result = DraftPlacer.placeDraft(text: draftText, context: ctx)
                DispatchQueue.main.async {
                    self?.handleDraftResult(result, fullText: text, appName: ctx.appName, source: source)
                }
            }
            return
        }
        pendingOmakaseContext = nil
        appendSummonEntry(text: text, source: source)
    }

    private func handleDraftResult(
        _ result: DraftPlacer.PlaceResult,
        fullText: String, appName: String, source: String
    ) {
        switch result {
        case .placed:
            showWhisper("Draft placed in \(appName)")
            appendSummonEntry(text: fullText, source: "omakase_draft")
        case .fallback, .appNotRunning:
            appendSummonEntry(text: fullText, source: source)
        }
    }

    private func appendSummonEntry(text: String, source: String) {
        let entry = NotificationEntry(
            id: UUID().uuidString, text: text,
            source: source, timestamp: Date()
        )
        summonResults.append(entry)
        if summonResults.count > 100 {
            summonResults.removeFirst(summonResults.count - 100)
        }
        PetLogStore.save(summonResults, file: "summon.json")
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

    // MARK: - Clipboard Watcher

    @Published var pendingClipboardOffer: ClipboardOffer?

    private func startClipboardWatcher() {
        ClipboardWatcher.shared.onOffer = { [weak self] offer in
            DispatchQueue.main.async {
                guard let self else { return }
                // Enrich with source app context
                var enriched = offer
                enriched = ClipboardOffer(
                    text: offer.text,
                    contentType: offer.contentType,
                    actions: offer.actions,
                    sourceApp: self.lastTrackedApp?.localizedName
                )
                // Auto-execute local actions (no user interaction needed)
                if let firstAction = enriched.actions.first,
                   let result = ClipboardExecutor.executeLocal(firstAction.type, text: enriched.text) {
                    ClipboardWatcher.shared.suppress()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                    let appHint = enriched.sourceApp.map { " (\($0))" } ?? ""
                    self.showWhisper("\(firstAction.label) done\(appHint)", duration: 3.0)
                    return
                }

                // Gateway actions: show offer whisper (user needs to act)
                self.pendingClipboardOffer = enriched
                let label = enriched.actions.first?.label ?? "Clipboard"
                let appHint = enriched.sourceApp.map { " (\($0))" } ?? ""
                self.showWhisper("\(label)?\(appHint)", duration: 5.0)
            }
        }
        ClipboardWatcher.shared.start()
    }

    func executeClipboardAction(_ action: ClipboardAction) {
        guard let offer = pendingClipboardOffer else { return }
        pendingClipboardOffer = nil

        // Try local execution first
        if let result = ClipboardExecutor.executeLocal(action.type, text: offer.text) {
            // Write result to clipboard
            ClipboardWatcher.shared.suppress()  // Don't re-trigger on our own write
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            showWhisper("Done — copied to clipboard", duration: 3.0)
            return
        }

        // Gateway action — build prompt based on action type
        let prompt: String
        switch action.type {
        case .translate(let to):
            let lang = to == "ja" ? "Japanese" : "English"
            prompt = "[Clipboard:\(action.label)]\nTranslate to \(lang):\n\(offer.text)"
        case .explain:
            prompt = "[Clipboard:\(action.label)]\nExplain this:\n\(offer.text)"
        case .summarize:
            prompt = "[Clipboard:\(action.label)]\nSummarize concisely:\n\(offer.text)"
        case .draftReply:
            prompt = "[Clipboard:\(action.label)]\nDraft a reply to this message:\n\(offer.text)"
        case .review:
            prompt = "[Clipboard:\(action.label)]\nReview this code briefly:\n\(offer.text)"
        default:
            return
        }
        sendSummon(prompt, source: "clipboard")
    }

    // MARK: - Notification History

    func addNotificationEntry(text: String, source: String) {
        let entry = NotificationEntry(
            id: UUID().uuidString, text: text,
            source: source, timestamp: Date()
        )
        notificationHistory.append(entry)
        if notificationHistory.count > 200 {
            notificationHistory.removeFirst(notificationHistory.count - 200)
        }
        PetLogStore.save(notificationHistory, file: "notifications.json")
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

struct NotificationEntry: Identifiable, Codable {
    let id: String
    let text: String
    let source: String  // "omakase", "ask", "draft_pr", "proactive", "gateway"
    let timestamp: Date
}

// MARK: - Local Persistence for Summon/Notification logs

enum PetLogStore {
    private static let dir = NSString("~/.clawgate/logs").expandingTildeInPath

    private static func ensureDir() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    static func save(_ entries: [NotificationEntry], file: String) {
        ensureDir()
        let path = (dir as NSString).appendingPathComponent(file)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func load(file: String) -> [NotificationEntry] {
        let path = (dir as NSString).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NotificationEntry].self, from: data)) ?? []
    }
}
