import AppKit
import Combine
import Foundation

/// ViewModel for the pet character system
final class PetModel: NSObject, ObservableObject {
    private struct PetRenderMetrics {
        static let assetWidth: CGFloat = 688
        static let assetHeight: CGFloat = 768
        static let baselineCharacterSize: CGFloat = 128
        static let baselineWindowSize: CGFloat = baselineCharacterSize + 20
        static let baselineRenderedWidth: CGFloat = assetWidth * (baselineWindowSize / assetHeight)
        static let overlapRatio: CGFloat = (baselineCharacterSize * 0.15) / baselineRenderedWidth

        let windowSize: CGFloat
        let scale: CGFloat
        let renderedWidth: CGFloat
        let renderedHeight: CGFloat
        let horizontalInset: CGFloat
        let overlap: CGFloat

        init(windowSize: CGFloat) {
            self.windowSize = windowSize
            scale = windowSize / Self.assetHeight
            renderedWidth = Self.assetWidth * scale
            renderedHeight = Self.assetHeight * scale
            horizontalInset = (windowSize - renderedWidth) / 2.0
            overlap = renderedWidth * Self.overlapRatio
        }

        func hiddenPoseOffsetX(for expression: PetExpression, side: PlacementSide) -> CGFloat {
            // Asset-pixel horizontal shift applied on top of the flush-edge
            // position when Chi is in a hide-peek pose. Values tuned so the
            // peeking body sits flush against the window edge without biting
            // into the window content. Tweaked 2026-04-10 from 77/95 → 74/92
            // → 72/90 (pulled 5 asset px outward on all three peek variants).
            let deltaPx: CGFloat
            switch expression {
            case .hidePeek, .hidePeek3:
                deltaPx = 72
            case .hidePeek2:
                deltaPx = 90
            default:
                deltaPx = 0
            }
            let deltaPt = deltaPx * scale
            return side == .right ? -deltaPt : deltaPt
        }

        var clawFix: CGFloat {
            overlap - horizontalInset
        }
    }

    // MARK: - Persistence keys (UserDefaults)
    private enum PersistKey {
        static let isVisible           = "pet.isVisible"
        static let isTrackingEnabled   = "pet.isTrackingEnabled"
        static let isBubbleEnabled     = "pet.isBubbleEnabled"
        static let isWhisperEnabled    = "pet.isWhisperEnabled"
        static let characterSize       = "pet.characterSize"
        static let opacity             = "pet.opacity"
        static let hideAfterMinutes    = "pet.hideAfterMinutes"
    }

    @Published var messages: [OpenClawChatMessage] = []
    @Published var inputText: String = ""
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isStreaming = false
    @Published var opacity: Double = PetModel.loadOpacity() {
        didSet { UserDefaults.standard.set(opacity, forKey: PersistKey.opacity) }
    }
    @Published var streamingText: String = ""
    @Published var whisperText: String?       // Layer 1: brief reaction text
    @Published var notificationMessage: OpenClawChatMessage?  // Independent notification
    @Published var pendingScreenshotOffer: ScreenshotOffer?
    @Published var petMode: PetMode = .secretary
    private var hasEverConnected = false
    @Published var isVisible: Bool = PetModel.loadBool(PersistKey.isVisible, default: true) {
        didSet { UserDefaults.standard.set(isVisible, forKey: PersistKey.isVisible) }
    }
    @Published var isTrackingEnabled: Bool = PetModel.loadBool(PersistKey.isTrackingEnabled, default: true) {
        didSet { UserDefaults.standard.set(isTrackingEnabled, forKey: PersistKey.isTrackingEnabled) }
    }
    @Published var isBubbleEnabled: Bool = PetModel.loadBool(PersistKey.isBubbleEnabled, default: true) {
        didSet { UserDefaults.standard.set(isBubbleEnabled, forKey: PersistKey.isBubbleEnabled) }
    }
    @Published var isWhisperEnabled: Bool = PetModel.loadBool(PersistKey.isWhisperEnabled, default: true) {
        didSet { UserDefaults.standard.set(isWhisperEnabled, forKey: PersistKey.isWhisperEnabled) }
    }
    @Published var characterSize: CGFloat = PetModel.loadCharacterSize() {
        didSet { UserDefaults.standard.set(Double(characterSize), forKey: PersistKey.characterSize) }
    }

    private static func loadBool(_ key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
    private static func loadOpacity() -> Double {
        if UserDefaults.standard.object(forKey: PersistKey.opacity) == nil { return 1.0 }
        let v = UserDefaults.standard.double(forKey: PersistKey.opacity)
        return (v > 0) ? v : 1.0
    }
    private static func loadCharacterSize() -> CGFloat {
        if UserDefaults.standard.object(forKey: PersistKey.characterSize) == nil { return 128 }
        let v = UserDefaults.standard.double(forKey: PersistKey.characterSize)
        return (v > 0) ? CGFloat(v) : 128
    }
    private static func loadHideAfterMinutes() -> Double {
        if UserDefaults.standard.object(forKey: PersistKey.hideAfterMinutes) == nil { return 0.5 }
        return UserDefaults.standard.double(forKey: PersistKey.hideAfterMinutes)
    }
    @Published var notificationHistory: [NotificationEntry] = []
    @Published var summonResults: [NotificationEntry] = []
    @Published var logReplies: [NotificationEntry] = []
    @Published var logSceneNames: [String: String] = [:]  // scene id -> ちー命名 (memory only)
    @Published var logThreadPaneOpen: Bool = true
    @Published var logAwaitingReply: Bool = false
    @Published var localResults: [NotificationEntry] = []
    @Published var showSummonTab: Bool = false  // Auto-open summon tab on response

    let stateMachine = PetStateMachine()
    let characterManager = CharacterManager()
    lazy var moveController = MoveController(stateMachine: stateMachine)

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
    private var trackingTickCount = 0
    @Published var isPinned: Bool = false
    private(set) var lastTrackedApp: NSRunningApplication?
    /// The AX window element Chi is currently following (for context capture)
    private var lastTrackedWindow: AXUIElement?
    private var lastTrackedWindowFrame: CGRect?
    enum PlacementSide { case left, right }
    private(set) var lastPlacementSide: PlacementSide = .right
    private var lockedPlacementSide: PlacementSide?
    private var lockedPlacementWindowFrame: CGRect?

    // MARK: - Hide behind window
    @Published var isHiding = false
    /// Minutes of idle before hiding. 0 = disabled. Min 0.5.
    var hideAfterMinutes: Double = PetModel.loadHideAfterMinutes() {
        didSet { UserDefaults.standard.set(hideAfterMinutes, forKey: PersistKey.hideAfterMinutes) }
    }
    private var lastActivityTime = Date()
    private var hideCheckTimer: Timer?
    private var clawWaveTimer: Timer?
    private var zzzTimer: Timer?
    private var lastZzzAt: Date?
    private var unhideWaveOnArrival = false

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
        guard let gatewayConfig = readOpenClawGatewayConfig() else {
            NSLog("[Pet] Gateway config not found in ~/.openclaw/openclaw.json")
            connectionState = .disconnected
            return
        }

        let appConfig = ConfigStore().load()
        let host = appConfig.openclawHost.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let port = appConfig.openclawPort
        guard !host.isEmpty,
              (1...65535).contains(port),
              let url = URL(string: "ws://\(host):\(port)/") else {
            connectionState = .error("Invalid URL")
            return
        }
        NSLog("[Pet] Connecting to Gateway: %@", url.absoluteString)

        connectionState = .connecting

        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await wsClient.connect(url: url, token: gatewayConfig.token)
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

    /// Idle window after the last delta before an in-flight streaming reply is
    /// finalized with whatever text has accumulated so far. Overridable for tests.
    static var deltaIdleTimeoutNanos: UInt64 = 5_000_000_000

    func handleEvent(_ event: OpenClawEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch event {
            case .connected(_, let key):
                let wasConnected = (self.connectionState == .connected)
                self.sessionKey = key
                self.connectionState = .connected
                self.stateMachine.handle(.reconnected)
                NSLog("[Pet] Connected to Gateway, sessionKey=%@", key)
                if self.hasEverConnected && !wasConnected {
                    self.showWhisper("Connected")
                }
                self.hasEverConnected = true
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
                        try? await Task.sleep(nanoseconds: Self.deltaIdleTimeoutNanos)
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
                let wasConnected = (self.connectionState == .connected)
                self.connectionState = .disconnected
                self.stateMachine.handle(.disconnected)
                if self.hasEverConnected && wasConnected {
                    self.showWhisper("link lost")
                }
                // A mid-stream disconnect must not let the delta-idle timer
                // finalize the in-flight reply with whatever partial text has
                // accumulated so far. Cancel it and leave pendingSummonSource
                // intact so the real final — delivered via reconnect +
                // resubscribe — still routes to its correct destination
                // (log/summon) instead of falling through to plain chat.
                self.deltaIdleTask?.cancel()
                self.deltaIdleTask = nil
                self.isStreaming = false
                self.streamingMessageId = nil
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
        notificationMessage = msg
        notificationDismissTask?.cancel()
        notificationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notificationMessage = nil
        }
    }

    func dismissNotification() {
        notificationDismissTask?.cancel()
        notificationMessage = nil
    }

    func showScreenshotOffer(_ offer: ScreenshotOffer) {
        addLocalEntry(text: offer.mentionText, source: offer.sourceKind.rawValue)
        showWhisper("Screenshot ready.", duration: 2.5)

        guard isBubbleEnabled, !stateMachine.isChatOpen else {
            NSLog("[Pet] screenshot offer suppressed")
            return
        }
        pendingScreenshotOffer = offer
    }

    func dismissScreenshotOffer() {
        pendingScreenshotOffer = nil
    }

    func toggleChat() {
        noteActivity()
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

    private var randomActions: [PetExpression] {
        var base: [PetExpression] = [.wave, .react, .blush, .idleBreathe, .funny, .secretary]
        if characterManager.selectedName == "chi-claw" {
            base += [.clawProud, .clawSnap, .clawGuard, .clawBye,
                     .clawShy, .clawClack, .clawThink, .clawPump,
                     .clawBeckon, .clawSurprise, .clawCombo]
        }
        return base
    }

    /// Randomized idle cycle — varying length, random blink timing, more action slots
    private func runCycle() {
        cycleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            let cycleLength = Double.random(in: 25...35)
            var events: [(Double, PetExpression, Double)] = []

            // 6-8 random blinks — frequent, natural
            for _ in 0..<Int.random(in: 6...8) {
                let t = Double.random(in: 1...(cycleLength - 1))
                let style: PetExpression = Bool.random() ? .blinkA : .blinkB
                events.append((t, style, Double.random(in: 0.3...0.5)))
            }

            // 2-4 random actions from the pool
            let actions = self.randomActions
            for _ in 0..<Int.random(in: 2...4) {
                let t = Double.random(in: 3...(cycleLength - 3))
                let action = actions.randomElement() ?? .wave
                events.append((t, action, Double.random(in: 3.5...6.0)))
            }

            // 1-2 body sway
            for _ in 0..<Int.random(in: 1...2) {
                let t = Double.random(in: 3...(cycleLength - 3))
                let body: PetExpression = Bool.random() ? .bodyA : .bodyB
                events.append((t, body, Double.random(in: 0.5...1.0)))
            }

            // Sort by time, remove overlaps (minimum 0.8s gap)
            events.sort { $0.0 < $1.0 }
            var filtered: [(Double, PetExpression, Double)] = []
            var lastEnd = 0.0
            for e in events {
                if e.0 > lastEnd + 0.8 {
                    filtered.append(e)
                    lastEnd = e.0 + e.2
                }
            }

            for (time, state, duration) in filtered {
                self.scheduleCycleAction(at: time, state: state, duration: duration)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + cycleLength) { [weak self] in
                self?.runCycle()
            }
        }
        cycleWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func scheduleCycleAction(at seconds: Double, state: PetExpression, duration: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.stateMachine.expression == .idle, !self.isHiding else { return }
            // NOTE: idle cycle animations are NOT activity — don't reset lastActivityTime
            self.stateMachine.expression = state
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.stateMachine.expression == state else { return }
                self.stateMachine.expression = .idle
            }
        }
    }

    // MARK: - Window Tracking (follow active window)

    func onPetDragged() {
        isPinned = true
        clearPlacementLock()
        noteActivity()
    }

    func startWindowTracking() {
        windowTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isHiding {
                self.updateTargetPosition()
            } else {
                // Normal: throttle to every 5th tick (0.5s)
                self.trackingTickCount += 1
                if self.trackingTickCount >= 5 {
                    self.trackingTickCount = 0
                    self.updateTargetPosition()
                }
            }
        }
    }

    private func clearPlacementLock() {
        lockedPlacementSide = nil
        lockedPlacementWindowFrame = nil
    }

    private func releasePinIfNeeded() {
        guard isPinned else { return }
        isPinned = false
        noteActivity()
    }

    func unpinFromClickIfNeeded() -> Bool {
        guard isPinned else { return false }
        releasePinIfNeeded()
        return true
    }

    private func pinnedFrameIsOnAnyScreen() -> Bool {
        guard let origin = moveController.currentOrigin else { return true }
        let petSize: CGFloat = characterSize + 20
        let frame = CGRect(x: origin.x, y: origin.y, width: petSize, height: petSize)
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func setPlacementLock(side: PlacementSide, frame: CGRect) {
        lockedPlacementSide = side
        lockedPlacementWindowFrame = frame
    }

    private func setHiddenSide(_ side: PlacementSide, resetPeekPose: Bool = false) {
        hidingSide = side
        lastPlacementSide = side
        stateMachine.hideAnimationSuffix = side == .left ? "-left" : ""

        guard resetPeekPose else { return }
        switch stateMachine.expression {
        case .hidePeek, .hidePeek2, .hidePeek3:
            stateMachine.expression = .hideClaw
        default:
            break
        }
    }

    private func appKitRectForTrackedFrame(_ frame: CGRect) -> CGRect {
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? (NSScreen.main?.frame.maxY ?? frame.maxY)
        return PetGeometry.appKitRect(forTrackedFrame: frame, desktopMaxY: desktopMaxY)
    }

    private func screenForTrackedFrame(_ frame: CGRect) -> NSScreen? {
        func area(_ rect: CGRect) -> CGFloat {
            guard !rect.isNull, !rect.isEmpty else { return 0 }
            return rect.width * rect.height
        }

        let appKitRect = appKitRectForTrackedFrame(frame)
        return NSScreen.screens.max { lhs, rhs in
            let lhsArea = area(lhs.frame.intersection(appKitRect))
            let rhsArea = area(rhs.frame.intersection(appKitRect))
            return lhsArea < rhsArea
        } ?? NSScreen.main
    }

    private func resolveTrackedWindow(for app: NSRunningApplication) -> (element: AXUIElement?, frame: CGRect, appKitFrame: CGRect, screen: NSScreen)? {
        guard let cgBounds = AXQuery.topmostWindowBounds(pid: app.processIdentifier) else { return nil }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        let windows = AXQuery.windows(appElement: appElement)
        let focused = AXQuery.focusedWindow(appElement: appElement)

        var candidates: [AXUIElement] = []
        for window in [focused].compactMap({ $0 }) + windows {
            if candidates.contains(where: { CFEqual($0, window) }) { continue }
            candidates.append(window)
        }
        for candidate in candidates {
            if let axFrame = AXQuery.copyFrameAttribute(candidate), PetGeometry.roughlySameFrame(axFrame, cgBounds) {
                if let screen = screenForTrackedFrame(axFrame) {
                    return (candidate, axFrame, appKitRectForTrackedFrame(axFrame), screen)
                }
                return (candidate, axFrame, appKitRectForTrackedFrame(axFrame), NSScreen.main ?? NSScreen.screens.first!)
            }
        }

        if let screen = screenForTrackedFrame(cgBounds) {
            return (nil, cgBounds, appKitRectForTrackedFrame(cgBounds), screen)
        }
        return (nil, cgBounds, appKitRectForTrackedFrame(cgBounds), NSScreen.main ?? NSScreen.screens.first!)
    }

    /// Teleport to normal position without walk animation
    private func updateTargetPositionImmediate() {
        let saved = isHiding
        isHiding = false  // temporarily to get normal position
        // Calculate where we should be, then teleport
        guard isTrackingEnabled else { isHiding = saved; return }
        guard let app = lastTrackedApp else { isHiding = saved; return }
        guard let resolved = resolveTrackedWindow(for: app) else { isHiding = saved; return }
        lastTrackedWindow = resolved.element
        lastTrackedWindowFrame = resolved.frame
        let frame = resolved.frame
        let screen = resolved.screen.visibleFrame
        let petSize: CGFloat = characterSize + 20
        let appKitFrame = resolved.appKitFrame
        let appKitY = appKitFrame.origin.y
        let metrics = PetRenderMetrics(windowSize: petSize)
        let overlap = metrics.overlap
        let rightX = frame.origin.x + frame.width - overlap
        let leftX = frame.origin.x - petSize + overlap
        let bottomY = appKitY
        var target: NSPoint
        if lastPlacementSide == .right && rightX + petSize <= screen.maxX {
            target = NSPoint(x: rightX, y: bottomY)
        } else if leftX >= screen.minX {
            target = NSPoint(x: leftX, y: bottomY)
        } else {
            target = NSPoint(x: screen.maxX - petSize - 8, y: screen.minY + 8)
        }
        target.x = max(screen.minX, min(target.x, screen.maxX - petSize))
        target.y = max(screen.minY, min(target.y, screen.maxY - petSize))
        moveController.moveTo(target, waveOnArrival: false, style: .immediate)
        isHiding = saved
    }

    private func updateTargetPosition(forceSide: PlacementSide? = nil) {
        guard isTrackingEnabled else { return }
        if isPinned {
            if !pinnedFrameIsOnAnyScreen() {
                isPinned = false
            } else {
                return
            }
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        var waveOnArrival = unhideWaveOnArrival
        unhideWaveOnArrival = false

        // Track last non-ClawGate frontmost app (ClawGate becomes frontmost on pet click)
        if let app = frontmost, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            if lastTrackedApp?.processIdentifier != app.processIdentifier {
                clearPlacementLock()
                lastTrackedWindow = nil
                lastTrackedWindowFrame = nil
                if isHiding {
                    // Stay hidden — just teleport to the new window's edge
                    lastTrackedApp = app
                    noteActivity(unhideIfNeeded: false)
                    // Fall through to the hiding branch below for immediate repositioning
                } else {
                    waveOnArrival = true
                    noteActivity(unhideIfNeeded: true)
                }
            }
            lastTrackedApp = app
        }

        guard let app = lastTrackedApp else { return }

        guard let resolved = resolveTrackedWindow(for: app) else {
            if isHiding {
                NSLog("[PetHide] No on-screen window for tracked app — unhiding")
                unhide()
            } else {
                moveController.stop()
            }
            lastTrackedWindow = nil
            lastTrackedWindowFrame = nil
            clearPlacementLock()
            return
        }
        let focusedWin = resolved.element
        let frame = resolved.frame
        let appKitFrame = resolved.appKitFrame
        let hostScreen = resolved.screen

        // Track the specific window Chi is following (for context capture)
        lastTrackedWindow = focusedWin
        lastTrackedWindowFrame = frame

        if let lockFrame = lockedPlacementWindowFrame, !PetGeometry.roughlySameFrame(lockFrame, frame) {
            clearPlacementLock()
        }

        let screen = hostScreen.visibleFrame
        let petSize: CGFloat = characterSize + 20  // match actual window size

        // Skip small windows (popups, dialogs) — but clear walk first
        if frame.width < 300 || frame.height < 200 {
            clearPlacementLock()
            moveController.stop()
            return
        }

        // Skip fullscreen apps — but clear walk first
        if abs(frame.width - hostScreen.frame.width) < 10 && abs(frame.height - hostScreen.frame.height) < 40 {
            clearPlacementLock()
            moveController.stop()
            return
        }

        // Use desktop-global AppKit coordinates derived from the tracked frame.
        let appKitY = appKitFrame.origin.y

        let metrics = PetRenderMetrics(windowSize: petSize)
        let overlap = metrics.overlap
        let rightX = frame.origin.x + frame.width - overlap
        let leftX = frame.origin.x - petSize + overlap
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
            let fallback = NSPoint(x: screen.maxX - petSize - 8, y: screen.minY + 8)
            moveController.moveTo(fallback, waveOnArrival: waveOnArrival)
            return
        }

        // Hidden: stick to the side we entered hiding on, immediate move + pose offset
        if isHiding {
            var activeSide = hidingSide
            if candidates.first(where: { $0.side == activeSide }) == nil {
                if let opposite = candidates.first(where: { $0.side != activeSide }) {
                    setHiddenSide(opposite.side, resetPeekPose: true)
                    activeSide = opposite.side
                } else {
                    unhide()
                    clearPlacementLock()
                    moveController.stop()
                    return
                }
            }

            if let fixed = candidates.first(where: { $0.side == activeSide }) {
                var t = fixed.point
                // Claw-only: compensate for overlap + height-fit inset.
                // Peek variants use hiddenPoseOffsetX() below for their own
                // asset-pixel tuning (see PetRenderMetrics).
                if stateMachine.expression == .hideClaw {
                    if activeSide == .right {
                        t.x += metrics.clawFix
                    } else {
                        t.x -= metrics.clawFix
                    }
                }
                t.x += metrics.hiddenPoseOffsetX(for: stateMachine.expression, side: activeSide)
                t.x = max(screen.minX, min(t.x, screen.maxX - petSize))
                t.y = max(screen.minY, min(t.y, screen.maxY - petSize))
                moveController.moveTo(t, waveOnArrival: false, style: .immediate)
            }
            return
        }

        // Normal: pick candidate
        var target: NSPoint
        var bestSide: PlacementSide

        let effectiveForcedSide: PlacementSide?
        if let forced = forceSide {
            effectiveForcedSide = forced
        } else if moveController.isMoving, let locked = lockedPlacementSide {
            effectiveForcedSide = locked
        } else {
            clearPlacementLock()
            effectiveForcedSide = nil
        }

        if let forced = effectiveForcedSide, let match = candidates.first(where: { $0.side == forced }) {
            target = match.point
            bestSide = match.side
        } else {
            let petPos = moveController.currentOrigin ?? NSPoint(x: screen.maxX - petSize, y: screen.minY)
            target = candidates[0].point
            var bestDist = Double.infinity
            bestSide = candidates[0].side
            for c in candidates {
                let bonus: Double = c.side == lastPlacementSide ? -50 : 0
                let d = sqrt(pow(c.point.x - petPos.x, 2) + pow(c.point.y - petPos.y, 2)) + bonus
                if d < bestDist {
                    bestDist = d
                    target = c.point
                    bestSide = c.side
                }
            }
        }
        lastPlacementSide = bestSide

        target.x = max(screen.minX, min(target.x, screen.maxX - petSize))
        target.y = max(screen.minY, min(target.y, screen.maxY - petSize))
        moveController.moveTo(target, waveOnArrival: waveOnArrival)
    }

    /// Move to opposite side of tracked window
    func moveToOppositeSide() {
        guard isTrackingEnabled, !isHiding else { return }
        releasePinIfNeeded()
        let opposite: PlacementSide = lastPlacementSide == .right ? .left : .right
        lastPlacementSide = opposite
        if let frame = lastTrackedWindowFrame {
            setPlacementLock(side: opposite, frame: frame)
        }
        noteActivity()
        updateTargetPosition(forceSide: opposite)
    }

    // MARK: - Lifecycle

    func start() {
        // Restore persisted logs
        notificationHistory = PetLogStore.load(file: "notifications.json")
        summonResults = PetLogStore.load(file: "summon.json")
        logReplies = PetLogStore.load(file: "log.json")
        localResults = PetLogStore.load(file: "local.json")

        characterManager.scan()
        _ = try? OpenClawDeviceIdentity.loadOrCreate()
        connect()
        startIdleTimer()
        startReconnectTimer()
        startWindowTracking()
        startClipboardWatcher()
        startScreenshotWatcher()
        startHideCheck()

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

    /// Retry connection every 15s if not connected (handles Gateway-after-ClawGate startup
    /// and recovers from stuck .error states after transient failures like /ready timeout).
    private func startReconnectTimer() {
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch self.connectionState {
            case .connected, .connecting:
                return
            case .disconnected, .error:
                self.connect()
            }
        }
    }

    func cleanup() {
        disconnect()
        moveController.stop()
        idleTimer?.invalidate()
        idleTimer = nil
        cycleWorkItem?.cancel()
        cycleWorkItem = nil
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
        hideCheckTimer?.invalidate()
        hideCheckTimer = nil
        clawWaveTimer?.invalidate()
        clawWaveTimer = nil
        ScreenshotWatcher.shared.stop()
    }

    // MARK: - Hide Behind Window

    func noteActivity(unhideIfNeeded: Bool = true) {
        lastActivityTime = Date()
        if unhideIfNeeded && isHiding {
            unhide()
        }
    }

    private func startHideCheck() {
        hideCheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.hideAfterMinutes > 0, !self.isHiding else { return }
            let elapsed = Date().timeIntervalSince(self.lastActivityTime)
            if elapsed >= self.hideAfterMinutes * 60 {
                self.enterHiding()
            }
        }
    }

    /// Which side the pet is hiding on (for sprite selection)
    private(set) var hidingSide: PlacementSide = .right

    private func enterHiding() {
        guard !isPinned, !isHiding, characterManager.selectedName == "chi-claw" else { return }
        isHiding = true
        setHiddenSide(lastPlacementSide)

        // Instant: lock expression, stop cycle, switch sprite
        cycleWorkItem?.cancel()
        moveController.stop()
        stateMachine.isExpressionLocked = true
        stateMachine.hideAnimationSuffix = hidingSide == .left ? "-left" : ""
        stateMachine.expression = .hideClaw

        // Micro-loop: occasional peek while hiding
        startHideMicroLoop()
        scheduleNextZzz(initial: true)
        NSLog("[PetHide] Entered hiding (side=%@)", hidingSide == .left ? "left" : "right")
    }

    /// Schedule the next sleep whisper attempt while Chi is hiding.
    /// Fires only if still in `.hideClaw` (not peeking), with 25% `zzz…`, 15% `mm…`, 8-15s cadence, and 30s shared cooldown.
    private func scheduleNextZzz(initial: Bool) {
        zzzTimer?.invalidate()
        let delay: Double = initial ? Double.random(in: 8...12) : Double.random(in: 8...15)
        zzzTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isHiding, !self.isPinned else { return }
            // Face visible (peek variants) — never whisper sleep whispers with face showing
            guard self.stateMachine.expression == .hideClaw else {
                self.scheduleNextZzz(initial: false)
                return
            }
            // Cooldown: at least 30s since the last sleep whisper
            if let last = self.lastZzzAt, Date().timeIntervalSince(last) < 30 {
                self.scheduleNextZzz(initial: false)
                return
            }
            let roll = Double.random(in: 0..<1)
            if roll < 0.25 {
                self.showWhisper("zzz…")
                self.lastZzzAt = Date()
            } else if roll < 0.40 {
                self.showWhisper("mm…")
                self.lastZzzAt = Date()
            }
            self.scheduleNextZzz(initial: false)
        }
    }

    private func startHideMicroLoop() {
        clawWaveTimer?.invalidate()
        clawWaveTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 6...12), repeats: true) { [weak self] _ in
            guard let self, self.isHiding else { return }
            if self.stateMachine.expression == .hideClaw {
                if self.whisperText == "zzz…" || self.whisperText == "mm…" {
                    self.dismissWhisper()
                }
                let peeks: [PetExpression] = [.hidePeek, .hidePeek2, .hidePeek3]
                let peek = peeks.randomElement() ?? .hidePeek
                self.stateMachine.expression = peek
                self.updateTargetPosition()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.isHiding else { return }
                    self.stateMachine.expression = .hideClaw
                    self.updateTargetPosition()
                }
            }
        }
    }

    func unhide() {
        guard isHiding else { return }
        isHiding = false
        clawWaveTimer?.invalidate()
        clawWaveTimer = nil
        zzzTimer?.invalidate()
        zzzTimer = nil
        lastActivityTime = Date()
        stateMachine.isExpressionLocked = false
        // Keep hideAnimationSuffix for emerge animation (cleared after emerge finishes)
        updateTargetPositionImmediate()
        stateMachine.expression = .hideEmerge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.stateMachine.hideAnimationSuffix = ""
            self.stateMachine.expression = .idle
            self.runCycle()
        }
        NSLog("[PetHide] Unhidden")
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
        NSLog("[Pet] Omakase context: app=%@, title=%@, textLen=%d", ctx.appName, ctx.windowTitle, ctx.visibleText.count)
        guard !ctx.visibleText.isEmpty || !ctx.windowTitle.isEmpty else {
            showWhisper("Nothing to read on screen")
            return
        }
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
        NSLog("[Pet] Ask context: app=%@, title=%@, textLen=%d", ctx.appName, ctx.windowTitle, ctx.visibleText.count)
        guard !ctx.visibleText.isEmpty || !ctx.windowTitle.isEmpty else {
            showWhisper("Nothing to read on screen")
            return
        }
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

    var pendingSummonSource: String?
    var isSummonBusy: Bool { pendingSummonSource != nil }
    private var pendingOmakaseContext: OmakaseContext?
    private var pendingSceneNamingIDs: [String] = []
    private var logAwaitingReplyToken: UUID?

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

    func sendLogInstruction(instruction: String, transcript: String) {
        let userEntry = NotificationEntry(
            id: UUID().uuidString, text: instruction,
            source: "log_user", timestamp: Date()
        )
        logReplies.append(userEntry)
        if logReplies.count > 100 {
            logReplies.removeFirst(logReplies.count - 100)
        }
        PetLogStore.save(logReplies, file: "log.json")
        logThreadPaneOpen = true
        let token = UUID()
        logAwaitingReplyToken = token
        logAwaitingReply = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.logAwaitingReplyToken == token, self.logAwaitingReply else { return }
            self.logAwaitingReply = false
            self.logAwaitingReplyToken = nil
        }
        let maxTranscriptCharacters = 12_000
        let trimmedTranscript = String(transcript.suffix(maxTranscriptCharacters))
        let prompt: String
        if trimmedTranscript.isEmpty {
            prompt = instruction
        } else {
            prompt = "\(instruction)\n\n--- 会話ログ ---\n\(trimmedTranscript)"
        }
        sendSummon(prompt, source: "log")
    }

    func requestSceneNaming(scenes: [(id: String, timeLabel: String, excerpt: String)]) {
        guard !scenes.isEmpty else { return }
        guard !isSummonBusy else { return }
        guard pendingSceneNamingIDs.isEmpty else { return }
        pendingSceneNamingIDs = scenes.map { $0.id }
        var prompt = "今日の会話ログは以下のシーンに分かれている。私個人のカレンダーの予定だけを使って（他の人のカレンダーや共有カレンダーは参照しないで）、各シーンに短い名前を付けて。個人カレンダーに一致する予定が見つからないシーンは、その番号の行を出力しないで（予定なし/不明/該当なし等のプレースホルダーも出力しない）。出力は各行 \"番号: 名前\" のみ（説明文なし）。"
        for (index, scene) in scenes.enumerated() {
            let excerpt = String(scene.excerpt.prefix(200))
            prompt += "\n\(index + 1). [\(scene.timeLabel)] 抜粋: \(excerpt)"
        }
        sendSummon(prompt, source: "log_scene_naming")
    }

    static func parseSceneNaming(_ text: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstChar = line.first, firstChar.isNumber else { continue }
            var digits = ""
            var rest = Substring(line)
            for char in line {
                if char.isNumber {
                    digits.append(char)
                    rest = rest.dropFirst()
                } else {
                    break
                }
            }
            guard let number = Int(digits) else { continue }
            let separators: Set<Character> = [":", "：", ".", "、", ")", "）", " ", "\t", "-"]
            while let head = rest.first, separators.contains(head) {
                rest = rest.dropFirst()
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !isNegativeSceneNamingPlaceholder(name) else { continue }
            result[number] = name
        }
        return result
    }

    private static func isNegativeSceneNamingPlaceholder(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        let placeholders: Set<String> = [
            "なし", "無し", "予定なし", "予定無し", "該当なし", "該当無し",
            "該当予定なし", "該当予定無し", "予定該当なし", "予定該当無し",
            "カレンダー予定なし", "カレンダー予定無し", "個人予定なし", "個人予定無し",
            "不明", "未定", "n/a", "na", "none", "unknown", "-", "—", "–",
        ]
        return placeholders.contains(normalized)
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
        if source == "log_scene_naming" {
            let names = Self.parseSceneNaming(text)
            for (number, name) in names {
                let index = number - 1
                guard index >= 0, index < pendingSceneNamingIDs.count else { continue }
                logSceneNames[pendingSceneNamingIDs[index]] = name
            }
            pendingSceneNamingIDs = []
            return
        }
        if source == "log" {
            logAwaitingReply = false
            logAwaitingReplyToken = nil
            let entry = NotificationEntry(
                id: UUID().uuidString, text: text,
                source: source, timestamp: Date()
            )
            logReplies.append(entry)
            if logReplies.count > 100 {
                logReplies.removeFirst(logReplies.count - 100)
            }
            PetLogStore.save(logReplies, file: "log.json")
            return
        }
        if Self.isLocalSource(source) {
            addLocalEntry(text: text, source: source)
            return
        }
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

    private static func isLocalSource(_ source: String) -> Bool {
        switch source {
        case "clipboard", "clipboard_offer", "clipboard_image", "saved_file":
            return true
        default:
            return false
        }
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
                self.addLocalEntry(text: enriched.text, source: "clipboard_offer")
                // Show offer as notification bubble with action buttons
                self.pendingClipboardOffer = enriched
            }
        }
        ClipboardWatcher.shared.start()
    }

    private func startScreenshotWatcher() {
        ScreenshotWatcher.shared.onScreenshot = { [weak self] offer in
            DispatchQueue.main.async {
                guard let self else { return }
                let enriched = ScreenshotOffer(
                    id: offer.id,
                    sourceKind: offer.sourceKind,
                    originalPath: offer.originalPath,
                    tempPath: offer.tempPath,
                    mentionText: offer.mentionText,
                    capturedAt: offer.capturedAt,
                    pixelSize: offer.pixelSize,
                    sourceApp: self.lastTrackedApp?.localizedName,
                    fingerprint: offer.fingerprint
                )
                self.showScreenshotOffer(enriched)
            }
        }
        ScreenshotWatcher.shared.start()
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

    func executeScreenshotAction(_ action: ScreenshotAction) {
        guard let offer = pendingScreenshotOffer else { return }

        switch action {
        case .copyMention:
            ClipboardWatcher.shared.suppress()
            ScreenshotWatcher.shared.suppress()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(offer.mentionText, forType: .string)
            showWhisper("Copied \(offer.mentionText)", duration: 3.0)
        }

        pendingScreenshotOffer = nil
    }

    // MARK: - Chrome Page Capture

    /// Timeout for waiting on Chrome extension response (seconds).
    private var pendingChromeCapture = false

    /// User clicked "Get this page" from the right-click menu.
    /// Fires chrome_capture_request into the EventBus so the Chrome extension can pick it up.
    func requestChromePage() {
        NotificationCenter.default.post(name: .petChromeCaptureFired, object: nil)
        stateMachine.expression = .wave
        pendingChromeCapture = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pendingChromeCapture else { return }
            self.pendingChromeCapture = false
            self.showWhisper("Chrome extension or Gateway is not responding.")
        }
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

    func addLocalEntry(text: String, source: String) {
        let entry = NotificationEntry(
            id: UUID().uuidString, text: text,
            source: source, timestamp: Date()
        )
        localResults.append(entry)
        if localResults.count > 100 {
            localResults.removeFirst(localResults.count - 100)
        }
        PetLogStore.save(localResults, file: "local.json")
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
    /// internal (not private): test seam. XCTest must redirect this to a temp
    /// directory before touching PetLogStore — a real PetModel() starts with
    /// empty in-memory arrays (load only happens in start()), so any save()
    /// during a test overwrites the user's real persisted history with test
    /// fixtures. See feedback_test_data_isolation incident, 2026-07-14.
    static var dir = NSString("~/.clawgate/logs").expandingTildeInPath

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
