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
    @Published var petMode: PetMode = .secretary
    @Published var isVisible: Bool = true
    @Published var isTrackingEnabled: Bool = true
    @Published var isBubbleEnabled: Bool = true
    @Published var isWhisperEnabled: Bool = true
    @Published var characterSize: CGFloat = 128
    @Published var targetPosition: NSPoint?   // Window tracking target

    let stateMachine = PetStateMachine()
    let characterManager = CharacterManager()

    private let wsClient = OpenClawWSClient()
    private var sessionKey: String?
    private var eventTask: Task<Void, Never>?
    private var streamingMessageId: String?
    private var whisperDismissTask: Task<Void, Never>?
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
                }

            case .message(let msg):
                NSLog("[Pet] message event: role=%@ text=%@", msg.role == .assistant ? "assistant" : "user", String(msg.text.prefix(50)))
                self.isStreaming = false
                self.streamingText = ""
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
                // Show notification bubble for new assistant messages (proactive)
                if isNew && msg.role == .assistant && !self.stateMachine.isChatOpen && self.isBubbleEnabled {
                    self.stateMachine.isBubbleVisible = true
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
                            self.streamingMessageId = nil
                            self.stateMachine.handle(.assistantFinished)
                        }
                    }
                }

            case .messageComplete(let messageId):
                NSLog("[Pet] messageComplete: %@", messageId)
                self.isStreaming = false
                self.streamingMessageId = nil
                if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[idx].isStreaming = false
                }
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
        let petSize: CGFloat = 148

        // Skip fullscreen apps
        if let screenFull = NSScreen.main?.frame,
           abs(frame.width - screenFull.width) < 10 && abs(frame.height - screenFull.height) < 40 {
            return
        }

        // AX coordinates (top-left origin) → AppKit coordinates (bottom-left origin)
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let appKitY = screenHeight - frame.origin.y - frame.height

        let rightX = frame.origin.x + frame.width - 20
        let leftX = frame.origin.x - petSize + 20
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
        // Pre-load device identity into cache to avoid Keychain dialog during handshake
        _ = try? OpenClawDeviceIdentity.loadOrCreate()
        connect()
        startIdleTimer()
        startReconnectTimer()
        startWindowTracking()
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
}
