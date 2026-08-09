import AppKit
import Combine
import CryptoKit
import Foundation
import os

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
    /// Durable, user-facing warnings that persisted history could not be fully
    /// read at load — whole-file corruption OR a partial drop of undecodable
    /// entries (which is silent loss in miniature: the next save rewrites
    /// without the dropped entries). Body-free, persisted across launches until
    /// the user acknowledges, and exposed as a Published status a future UI
    /// (rendering is Wave C) can bind to — NEVER injected into the conversation
    /// as a "ちー" (source == "log") entry.
    /// Typed, body-free Log dispatch status (D3/D110-form): surfaced instead of
    /// persisting a meaningless model body into the conversation. `nil` when
    /// there is nothing to show. Wave C renders it; it is never mixed into
    /// `logReplies`.
    @Published var logDispatchStatus: PetLogDispatchStatus?
    @Published var logRecoveryWarnings: [PetLogRecoveryWarning] = []
    /// True when the durable warning store itself could not be trusted — either
    /// its persisted state was unreadable at load (both primary and backup) or a
    /// write/acknowledge could not be committed. A fail-visible signal that the
    /// "warnings survive until acknowledged" guarantee is currently degraded.
    @Published var recoveryWarningPersistenceDegraded: Bool = false
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

    /// How long to wait for a "質問まとめ" (Log summarize) reply before giving up.
    /// 600s (mitigation): a real answer can take many minutes (2026-08-09
    /// incident: a 9m9s reply was dropped by the old 180s deadline). This is a
    /// provisional mitigation, NOT a D61/D62 completion. Overridable for tests.
    static var logAwaitingReplyTimeoutSeconds: TimeInterval = 600

    /// Structured, retroactively-queryable telemetry for Pet Log envelope
    /// dispatch. Body-free: request/action ids, sizes, and policy only — never
    /// the instruction or transcript text. `log show --predicate
    /// 'subsystem == "com.clawgate" && category == "PetLog"'`.
    static let petLogTelemetry = Logger(subsystem: "com.clawgate", category: "PetLog")

    /// How long a shared-path summon (scene naming / omakase / ask / draft_pr)
    /// may wait for a reply before its slot is reclaimed. Overridable for tests.
    static var summonReplyTimeoutSeconds: TimeInterval = 180

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
                // Bounded, non-content metadata only — never the message body,
                // which for Pet Log answers can contain private
                // ambient-transcript-derived content (leaks into the unified
                // system log otherwise).
                NSLog("[Pet] message event: role=%@ proactive=%d id=%@",
                      msg.role == .assistant ? "assistant" : "user",
                      msg.isProactive ? 1 : 0, msg.id)

                // Proactive messages always go to Notifications, never
                // Summon — checked first and unconditionally, independent of
                // any pending summon's run correlation.
                if msg.isProactive {
                    if self.pendingSummonSource == nil {
                        self.isStreaming = false
                        self.streamingText = ""
                    }
                    self.showNotification(msg)
                    self.stateMachine.handle(.assistantFinished)
                    break
                }

                // Route summon responses to Summon tab — but only if it's
                // actually our run. A stale run's late final (e.g. a
                // superseded/duplicate chat.send) must not touch ANY state
                // belonging to a different, still-in-flight summon —
                // including isStreaming/streamingText — so this check runs
                // before any state mutation, not after.
                if msg.role == .assistant, let source = self.pendingSummonSource {
                    if let expectedRunId = self.pendingSummonRunId, expectedRunId != msg.id {
                        break
                    }
                    self.isStreaming = false
                    self.streamingText = ""
                    self.summonWatchdogToken = nil
                    self.pendingSummonSource = nil
                    self.pendingSummonRunId = nil
                    self.addSummonResult(text: msg.text, source: source, parseAsStructured: source == "log")
                    self.stateMachine.handle(.assistantFinished)
                    break
                }

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
                // Show notification for new assistant messages (independent of state machine)
                if isNew && msg.role == .assistant {
                    self.showNotification(msg)
                }

            case .delta(let messageId, let text):
                if let expectedRunId = self.pendingSummonRunId, expectedRunId != messageId {
                    // Delta from a stale/different run — drop it rather than
                    // let it pollute the pending summon's accumulation or
                    // leak into the plain chat pane.
                    break
                }
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
                if let expectedRunId = self.pendingSummonRunId,
                   expectedRunId != messageId {
                    break
                }
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
                // accumulated so far. Cancel it and keep log in-flight state
                // intact so the real final — delivered via reconnect +
                // resubscribe — can still route correctly.
                // For non-log summons (scene naming / omakase / draft), clear
                // the slot on disconnect to prevent a stale pending state from
                // permanently blocking new Log actions.
                self.deltaIdleTask?.cancel()
                self.deltaIdleTask = nil
                self.isStreaming = false
                self.streamingMessageId = nil
                self.streamingText = ""
                if self.pendingSummonSource != "log" {
                    self.summonWatchdogToken = nil
                    self.pendingSummonSource = nil
                    self.pendingSummonRunId = nil
                    self.pendingLogRequest = nil
                    self.pendingSceneNamingIDs = []
                }
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
        NSLog("[Pet] showNotification: bubbleEnabled=%d chatOpen=%d id=%@", isBubbleEnabled ? 1 : 0, stateMachine.isChatOpen ? 1 : 0, msg.id)

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

    /// Loads one persisted log file through the hardened store, mapping its
    /// outcome onto the visible corrupt status. Corruption is reported as a
    /// Published status flag ONLY — never as a conversation entry.
    /// Restores all four persisted log files through the hardened outcome API,
    /// surfacing any corruption / partial-drop as durable recovery warnings.
    /// `start()` calls this; a ForTesting wrapper exercises the same path (the
    /// full `start()` isn't unit-testable — it opens a WS connection and arms
    /// timers).
    /// Uniform outcome->state rule for every warnings-store persist (F2/K).
    /// `.committed` publishes the set and marks persistence healthy;
    /// `.committedBackupDegraded` publishes (the primary IS durable) but flags
    /// degraded redundancy; `.failed` does not publish and flags degraded.
    /// Returns whether the primary is durable.
    @discardableResult
    private func commitRecoveryWarnings(_ set: [PetLogRecoveryWarning]) -> Bool {
        switch PetLogStore.saveRecoveryWarnings(set) {
        case .committed:
            logRecoveryWarnings = set
            recoveryWarningPersistenceDegraded = false
            return true
        case .committedBackupDegraded:
            logRecoveryWarnings = set
            recoveryWarningPersistenceDegraded = true
            return true
        case .failed:
            recoveryWarningPersistenceDegraded = true
            return false
        }
    }

    /// Persists a main store, surfacing a promote failure as a durable
    /// `backupDegraded` warning rather than swallowing it. Returns whether the
    /// primary is durable (the append landed).
    @discardableResult
    private func persistStore(_ entries: [NotificationEntry], file: String) -> Bool {
        switch PetLogStore.saveOutcome(entries, file: file) {
        case .committed:
            return true
        case .committedBackupDegraded:
            upsertRecoveryWarning(file: file, kind: "backupDegraded", droppedCount: 0, quarantine: nil)
            commitRecoveryWarnings(logRecoveryWarnings)
            return true
        case .failed:
            return false
        }
    }

    private func restorePersistedLogs() {
        // Carry forward warnings persisted from a prior launch (durable until
        // the user acknowledges), then layer on anything this load detects.
        let loaded = PetLogStore.loadRecoveryWarnings()
        logRecoveryWarnings = loaded.warnings
        recoveryWarningPersistenceDegraded = loaded.degraded
        // Track which files' perms converged cleanly this launch, so a repaired
        // insecurePermissions status can be DERIVED-cleared under commit
        // discipline (I) — the warnings store itself included.
        restoreConvergedPermissions = loaded.permissionsInsecure ? [] : [PetLogStore.recoveryWarningsFile]
        if loaded.permissionsInsecure {
            // The warnings store's own perms couldn't be tightened. Surface it as
            // a typed status this launch; it re-derives every launch (perms are
            // re-checked) until actually repaired, so it never silently vanishes.
            upsertRecoveryWarning(file: PetLogStore.recoveryWarningsFile,
                                  kind: "insecurePermissions", droppedCount: 0, quarantine: nil)
        }
        if loaded.degraded {
            // Both copies of the warning store were unreadable. A clean empty
            // would let the very next launch (which reads the rewritten valid
            // store) erase the evidence — so commit a durable synthetic marker
            // that survives restart until the user acknowledges it.
            upsertRecoveryWarning(file: PetLogStore.recoveryWarningsFile,
                                  kind: "warningStoreCorrupt", droppedCount: 0, quarantine: nil)
        }
        notificationHistory = restorePersistedLog(file: "notifications.json")
        summonResults = restorePersistedLog(file: "summon.json")
        logReplies = restorePersistedLog(file: "log.json")
        localResults = restorePersistedLog(file: "local.json")
        // Derived clear (I) with commit discipline: build a candidate that drops
        // stale insecurePermissions for every file whose perms converged cleanly
        // this launch. Applied only via commitRecoveryWarnings, so the clear is
        // published/durable ONLY on a successful persist; a failed clear leaves
        // the warning visible and flags degraded.
        var candidate = logRecoveryWarnings
        candidate.removeAll { $0.kind == "insecurePermissions" && restoreConvergedPermissions.contains($0.file) }
        // Derived reconcile of writeBlocked (L): an ACTIVE block is exactly a
        // current poison incident. A stale writeBlocked on a now-healthy file
        // (e.g. a resolve whose warning-clear commit failed, or the store fixed
        // out-of-band) is cleared under commit discipline so it can't become an
        // unresolvable dead-end.
        candidate.removeAll { $0.kind == "writeBlocked" && !PetLogStore.isPoisoned($0.file) }
        commitRecoveryWarnings(candidate)
    }

    /// Files whose permission convergence succeeded during the current restore —
    /// used to derive-clear their stale insecurePermissions warnings.
    private var restoreConvergedPermissions: Set<String> = []

    /// Test seam: run the real restore path without the rest of `start()`.
    func restorePersistedLogsForTesting() { restorePersistedLogs() }

    /// Clears ALL durable recovery warnings once the user has seen them —
    /// treated as a commit: the in-memory/published state is only cleared after
    /// the empty set is persisted. On failure the warnings are kept visible and
    /// the durability-degraded flag is raised, so acknowledgement can't silently
    /// drop state ahead of disk.
    func acknowledgeLogRecoveryWarnings() {
        // Only kind == "writeBlocked" is an ACTIVE block that ack must not clear
        // (H) — every other kind, even on a poisoned file, is informational and
        // acknowledgeable. Only resolveLogStoreCorruption() recovers a block.
        let remaining = logRecoveryWarnings.filter { $0.kind == "writeBlocked" }
        commitRecoveryWarnings(remaining)
    }

    /// Explicit recover/start-fresh for a write-blocked (poisoned) store — the
    /// action a UI "Resolve" control (Wave C) drives, kept separate from
    /// acknowledgement (D99). Requires the corrupt original to be preserved in a
    /// quarantine copy; on success the store is writable again and its warnings
    /// clear. Returns whether recovery succeeded.
    @discardableResult
    func resolveLogStoreCorruption(file: String) -> Bool {
        let outcome = PetLogStore.resolveLogStoreCorruption(file: file)
        guard outcome != .failed else { return false }
        // The store is recovered; surface a stale fresh-store backup as its own
        // durable warning (L point 4) rather than collapsing it into the Bool.
        if outcome == .committedBackupDegraded {
            upsertRecoveryWarning(file: file, kind: "backupDegraded", droppedCount: 0, quarantine: nil)
        }
        // Resolve clears ONLY the writeBlocked warning for this file (H); other
        // kinds coexist. TRANSACTIONAL (L): the clear is only durable on a
        // successful warnings-store commit — if it fails, return false and flag
        // degraded so the caller knows the visible warning didn't clear. The
        // stale writeBlocked is then reconciled on the next restore (the store is
        // healthy, so it derive-clears) — no ack/resolve dead-end.
        let remaining = logRecoveryWarnings.filter { !($0.file == file && $0.kind == "writeBlocked") }
        return commitRecoveryWarnings(remaining)
    }

    /// Acknowledges a SINGLE issue independently (identity = file + kind), so
    /// e.g. a resolved permission problem can be dismissed without dropping a
    /// still-open partial-drop warning on the same file. Same commit discipline.
    /// Refuses (returns false) ONLY for kind == "writeBlocked" — the active
    /// write-block D99 protects; only resolveLogStoreCorruption clears it. Every
    /// other kind (even on the same poisoned file) is independently ackable.
    @discardableResult
    func acknowledgeLogRecoveryWarning(file: String, kind: String) -> Bool {
        if kind == "writeBlocked" { return false }
        let remaining = logRecoveryWarnings.filter { !($0.file == file && $0.kind == kind) }
        return commitRecoveryWarnings(remaining)
    }

    /// Warning identity is (file, kind): distinct failure kinds for the same
    /// file are independent issues that coexist — a permission problem and a
    /// partial drop on the same file must BOTH stay visible, neither erasing
    /// the other. Only a re-detection of the SAME kind refreshes in place.
    private func upsertRecoveryWarning(file: String, kind: String, droppedCount: Int, quarantine: String?) {
        logRecoveryWarnings.removeAll { $0.file == file && $0.kind == kind }
        logRecoveryWarnings.append(PetLogRecoveryWarning(
            file: file, kind: kind, droppedCount: droppedCount,
            quarantine: quarantine, detectedAt: Date()))
    }

    private func restorePersistedLog(file: String) -> [NotificationEntry] {
        // Converge existing perms to owner-only BEFORE reading, so the dir is
        // 0700 when a corrupt load writes a quarantine copy and older 0644/0755
        // files are tightened even on a load-only startup. Never touches bytes;
        // a chmod failure surfaces as a durable security warning.
        if PetLogStore.convergePermissionsOnLoad(file: file) {
            restoreConvergedPermissions.insert(file)  // derive-clear candidate (I)
        } else {
            upsertRecoveryWarning(file: file, kind: "insecurePermissions", droppedCount: 0, quarantine: nil)
        }
        let outcome = PetLogStore.loadOutcome(file: file)
        // The single expression of an ACTIVE write-block is a writeBlocked
        // warning (H): raise it for any poisoned file, carrying the current
        // incident's quarantine reference. Only resolve clears it — informational
        // kinds (corrupt/partialDrop/insecurePermissions) coexist and are
        // independently acknowledgeable.
        if let incident = PetLogStore.poisonIncident(file) {
            upsertRecoveryWarning(file: file, kind: "writeBlocked", droppedCount: 0, quarantine: incident.quarantineName)
        }
        switch outcome {
        case .missing:
            return []
        case let .success(entries, dropped, quarantine):
            // A partial drop is silent loss in miniature — surface it durably.
            if dropped > 0 {
                upsertRecoveryWarning(file: file, kind: "partialDrop", droppedCount: dropped, quarantine: quarantine)
            }
            return entries
        case let .corrupt(entries, _, quarantine):
            // A poisoned corrupt is already represented by the writeBlocked
            // warning above; only a RECOVERED corrupt (from backup, not poisoned)
            // needs a separate informational "corrupt" note.
            if !PetLogStore.isPoisoned(file) {
                upsertRecoveryWarning(file: file, kind: "corrupt", droppedCount: 0, quarantine: quarantine)
            }
            return entries
        }
    }

    func start() {
        // Restore persisted logs. Each goes through the hardened outcome API so
        // an unreadable file surfaces as a durable recovery warning (and holds
        // its writes fail-closed) instead of silently loading as [] and letting
        // the next append overwrite the real history (2026-08 data-loss path).
        restorePersistedLogs()

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
            NSLog("[Pet] bubble_notify received (%d chars)", text.count)
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
        // If this was a summon response, route to summon results — but only
        // if it's actually OUR run. A stale run's late completion (e.g. a
        // superseded/duplicate chat.send) must not resolve a different,
        // still-in-flight summon.
        if let source = pendingSummonSource {
            if let expectedRunId = pendingSummonRunId, let messageId, expectedRunId != messageId {
                return
            }
            summonWatchdogToken = nil
            pendingSummonSource = nil
            pendingSummonRunId = nil
            let text = streamingText.isEmpty ? "(empty response)" : streamingText
            streamingText = ""
            // Remove from messages if it leaked there
            if let messageId, let idx = messages.firstIndex(where: { $0.id == messageId }) {
                messages.remove(at: idx)
            }
            addSummonResult(text: text, source: source, parseAsStructured: source == "log")
            return
        }

        guard let messageId else { return }
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].isStreaming = false
        }
    }

    var pendingSummonSource: String?
    /// The Gateway `runId` (from chat.send's ACK payload) for the in-flight
    /// summon, once resolved. nil until the ACK returns, or if this summon
    /// was started via a path that doesn't track it (kept nil = "any run
    /// accepted", preserving prior best-effort routing for those callers).
    var pendingSummonRunId: String?

    /// Per-request state for the in-flight "log" summon, carried from
    /// `sendLogInstruction` through to the reply so the parser can validate the
    /// model's segment claims against exactly what was sent, and the persisted
    /// `logMetadata` can record the client's own completeness signal. Tracks
    /// 1:1 with whether a Log summon is actually in flight — set when the
    /// summon starts, cleared everywhere the summon terminates.
    private struct PendingLogRequest {
        let requestId: String
        let segmentIds: [String]
        let completeBeforeAnchor: Bool
        let dispatch: PetLogDispatchAck?
        // Correlation metadata (D7) captured from the originating envelope, so
        // the persisted reply/user entries record the exact request behind them.
        let actionId: String
        let anchor: Date
        let selectedDay: Date?
        let segmentCount: Int
        let scopeOverride: [String]?
        let selectionMode: String
        let coverageStart: Date?
        let coverageEnd: Date?
        // D153: the REQUEST-side truncation bit. The parser branches on THIS
        // (not the model's self-reported response) so a model can't fake the
        // relaxed truncated-answer path. Default false covers non-Log/test paths.
        var retrievalTruncatedBeforeCoverage: Bool = false

        /// The correlation metadata to stamp onto a persisted log entry.
        func entryMetadata(contextDecision: PetLogContextDecision? = nil,
                           completeBeforeAnchor: Bool? = nil,
                           dispatch: PetLogDispatchMetadata? = nil) -> PetLogEntryMetadata {
            PetLogEntryMetadata(
                contextDecision: contextDecision,
                completeBeforeAnchor: completeBeforeAnchor,
                dispatch: dispatch,
                requestId: requestId,
                actionId: actionId,
                anchor: anchor,
                selectedDay: selectedDay,
                segmentCount: segmentCount,
                scopeOverride: scopeOverride,
                selectionMode: selectionMode,
                coverageStart: coverageStart,
                coverageEnd: coverageEnd,
                policyVersion: PetLogPromptBuilder.policyVersion,
                sourceFingerprint: PetLogSourceFingerprint.make(
                    policyVersion: PetLogPromptBuilder.policyVersion, segmentIds: segmentIds),
                retrievalTruncatedBeforeCoverage: retrievalTruncatedBeforeCoverage
            )
        }
    }
    private var pendingLogRequest: PendingLogRequest?

    private enum PetLogAdmissionEvent {
        case actionReceived(requestId: String, actionId: String, segmentCount: Int)
        case busyRefused(requestId: String)
        case disconnectedRefused(requestId: String)
        case envelopeAccepted(requestId: String)
        case dispatchAttempted(requestId: String)
        case persistenceFailure(file: String, requestId: String?)
        /// D16/D20 fail-closed: the history could not be dispatched intact (sanity
        /// cap or over budget) — refused before any side-effect. `reason` records
        /// the specific cause (sanityCap / automaticScopeOverBudget /
        /// explicitScopeOverBudget) for forensics.
        case historyIncompleteRefused(requestId: String, reason: String)
    }

    /// Emits admission-lifecycle events through the same os.Logger as
    /// `envelopeSent` (D139) — so `log show` can retroactively query the whole
    /// Pet Log lifecycle by requestId, which NSLog never allowed. Body-free:
    /// only bounded request/action/count/file metadata; never the instruction,
    /// STT, or any error body.
    private func recordPetLogAdmissionEvent(_ event: PetLogAdmissionEvent) {
        let log = Self.petLogTelemetry
        switch event {
        case let .actionReceived(requestId, actionId, segmentCount):
            log.info("actionReceived request=\(requestId, privacy: .public) action=\(actionId, privacy: .public) segments=\(segmentCount, privacy: .public)")
        case let .busyRefused(requestId):
            log.notice("actionBusyRefused request=\(requestId, privacy: .public)")
        case let .disconnectedRefused(requestId):
            log.notice("actionDisconnectedRefused request=\(requestId, privacy: .public)")
        case let .envelopeAccepted(requestId):
            log.info("envelopeAccepted request=\(requestId, privacy: .public)")
        case let .dispatchAttempted(requestId):
            log.info("dispatchAttempted request=\(requestId, privacy: .public)")
        case let .persistenceFailure(file, requestId):
            log.error("persistenceFailure file=\(file, privacy: .public) request=\(requestId ?? "unknown", privacy: .public)")
        case let .historyIncompleteRefused(requestId, reason):
            log.notice("historyIncompleteRefused request=\(requestId, privacy: .public) reason=\(reason, privacy: .public)")
        }
    }

    var isSummonBusy: Bool { pendingSummonSource != nil }

    #if DEBUG
    /// Test seam: inject a session key so the connected-path Log summon logic
    /// runs without a live Gateway handshake (`sessionKey` is otherwise private).
    func setSessionKeyForTesting(_ key: String?) { sessionKey = key }
    /// Test seam: when true, `sendLogSummon` and the shared `sendSummon` both
    /// claim the summon slot but skip the real WS send, so their reply-timeout
    /// watchdogs ("send succeeded, reply never arrived") can be exercised
    /// deterministically without a live-or-failing socket racing the watchdog.
    var suppressLogSendForTesting = false
    /// Test seam: force a small D16 request budget so the enforcer engages on a
    /// tiny envelope (production always uses `PetLogRequestBudget.maxRequestBytes`).
    var petLogRequestBudgetForTesting: Int?
    /// Test seam: drive the shared-path summon claim (`sendSummon`) with an
    /// arbitrary source, exercising the real slot-claim + watchdog-arming path
    /// (`sendSummon` is otherwise private). Pair with `suppressLogSendForTesting`
    /// and a session key to make the shared watchdog the sole release mechanism.
    func claimSharedSummonForTesting(source: String) {
        sendSummon("test prompt", source: source)
    }
    /// Test seam: read-only view of the scene-naming in-flight ids (private), so
    /// a test can assert a wedged naming request's ids were reclaimed on timeout.
    var pendingSceneNamingIDsForTesting: [String] { pendingSceneNamingIDs }
    /// Test seam: establish the pending log request that a structured "log"
    /// reply is validated against, without going through `sendLogInstruction`
    /// (which also arms the reply-timeout watchdog). Mirrors what a real
    /// in-flight Log summon leaves behind (`pendingLogRequest` is private).
    func setPendingLogRequestForTesting(segmentIds: [String], completeBeforeAnchor: Bool,
                                        dispatch: PetLogDispatchAck? = nil,
                                        actionId: String = "test-action",
                                        anchor: Date = Date(),
                                        selectedDay: Date? = nil,
                                        scopeOverride: [String]? = nil,
                                        selectionMode: String = "automatic",
                                        coverageStart: Date? = nil,
                                        coverageEnd: Date? = nil) {
        pendingLogRequest = PendingLogRequest(
            requestId: UUID().uuidString,
            segmentIds: segmentIds,
            completeBeforeAnchor: completeBeforeAnchor,
            dispatch: dispatch,
            actionId: actionId,
            anchor: anchor,
            selectedDay: selectedDay,
            segmentCount: segmentIds.count,
            scopeOverride: scopeOverride,
            selectionMode: selectionMode,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd
        )
    }
    /// Test seam: the CURRENT shared-path watchdog token (private), so a test can
    /// drive `invokeSummonSendFailureForTesting` with a matching (current) token
    /// vs a stale one.
    var summonWatchdogTokenForTesting: UUID? { summonWatchdogToken }
    /// Test seam: drive the shared summon send-failure cleanup directly. The real
    /// catch body is otherwise unreachable without a live socket throw racing the
    /// test, so this exposes the same `handleSummonSendFailure` the catch calls —
    /// letting the token+source guard be exercised deterministically.
    func invokeSummonSendFailureForTesting(token: UUID, source: String, error: Error) {
        handleSummonSendFailure(token: token, source: source, error: error)
    }
    #endif
    private var pendingOmakaseContext: OmakaseContext?
    private var pendingSceneNamingIDs: [String] = []
    private var logAwaitingReplyToken: UUID?
    /// Identity of the CURRENT shared-path summon's watchdog. Regenerated on
    /// every claim and invalidated (nil) at every normal termination, so a
    /// stale watchdog firing late can never release a newer summon's slot.
    private var summonWatchdogToken: UUID?

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

        // Arm a self-release watchdog: if the send succeeds but no terminal WS
        // event ever arrives (e.g. the reply was emitted during a connection-down
        // window and reconnect never replays missed events), this slot would
        // otherwise stay claimed forever and refuse every subsequent Log action.
        // The token+source double match below guarantees a stale watchdog can
        // never release a newer summon that reused the slot.
        let token = UUID()
        summonWatchdogToken = token
        // D139: emit the START of a shared summon with the same bounded owner
        // token as the timeout, so started/timeout correlate in log show. Body-
        // free: fixed source + owner prefix only (no prompt/STT).
        Self.petLogTelemetry.info("sharedSummonStarted source=\(source, privacy: .public) owner=\(token.uuidString.prefix(8), privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.summonReplyTimeoutSeconds) { [weak self] in
            guard let self else { return }
            guard self.summonWatchdogToken == token,
                  let currentSource = self.pendingSummonSource, currentSource == source else { return }
            self.summonWatchdogToken = nil
            self.pendingSummonSource = nil
            self.pendingSummonRunId = nil
            if source == "log_scene_naming" {
                // Scene naming also gates on pendingSceneNamingIDs — a wedged
                // naming request must not block tomorrow's auto-naming. It is a
                // background nicety, so its failure gets telemetry only and never
                // surfaces into the Log conversation pane.
                self.pendingSceneNamingIDs = []
                Self.petLogTelemetry.notice("summonReplyTimeout source=\(source, privacy: .public) owner=\(token.uuidString.prefix(8), privacy: .public) slotReclaimed=1")
            } else {
                Self.petLogTelemetry.notice("summonReplyTimeout source=\(source, privacy: .public) owner=\(token.uuidString.prefix(8), privacy: .public) slotReclaimed=1")
                self.addSummonResult(
                    text: "Error: no reply received within \(Int(Self.summonReplyTimeoutSeconds))s",
                    source: source)
            }
        }

        #if DEBUG
        // Test seam: claim the slot + arm the watchdog but skip the real WS send,
        // so the reply-timeout watchdog ("send succeeded, reply never arrived")
        // can be exercised deterministically without a socket racing it.
        if suppressLogSendForTesting { return }
        #endif

        Task { [weak self] in
            guard let self else { return }
            do {
                try await wsClient.sendMessage(prompt, sessionKey: sessionKey)
            } catch {
                await MainActor.run {
                    self.handleSummonSendFailure(token: token, source: source, error: error)
                }
            }
        }
    }

    /// Clean up after a shared-path summon's async send throws. A late throw
    /// from a SUPERSEDED send — its slot already released by a disconnect and
    /// possibly re-claimed by a newer summon — must not touch the current
    /// summon's state. The token+source double match mirrors the watchdog's
    /// invariant: only when this send still owns the slot do we release it and
    /// surface the error.
    private func handleSummonSendFailure(token: UUID, source: String, error: Error) {
        guard summonWatchdogToken == token,
              pendingSummonSource == source else { return }
        summonWatchdogToken = nil
        pendingSummonSource = nil
        addSummonResult(text: "Error: \(error)", source: source)
    }

    /// Log-specific summon send. Threads `requestId` through as the
    /// Gateway's `idempotencyKey` and captures the returned `runId` so
    /// `.message`/`.delta`/`finishStreamingMessage` can correlate against it
    /// — a stale/different run's late event can't resolve or corrupt this
    /// in-flight Log request. Other summon sources (omakase, scene naming,
    /// ask, draft_pr) keep using the plain `sendSummon` above, unchanged.
    private func sendLogSummon(_ prompt: String, requestId: String) {
        guard let sessionKey else { return }

        recordPetLogAdmissionEvent(.dispatchAttempted(requestId: requestId))
        pendingSummonSource = "log"
        pendingSummonRunId = nil
        showWhisper("Working on it...")

        #if DEBUG
        if suppressLogSendForTesting { return }
        #endif

        Task { [weak self] in
            guard let self else { return }
            do {
                let ack = try await wsClient.sendMessageAwaitingPetLogDispatchAck(
                    prompt, sessionKey: sessionKey, idempotencyKey: requestId)
                await MainActor.run {
                    // Only claim the runId if we're still the same in-flight
                    // summon — a fast completion (or a newer summon starting)
                    // could have already resolved/replaced this one.
                    guard self.pendingSummonSource == "log",
                          let pending = self.pendingLogRequest,
                          pending.requestId == requestId else { return }
                    self.pendingSummonRunId = ack.runId
                    self.pendingLogRequest = PendingLogRequest(
                        requestId: pending.requestId,
                        segmentIds: pending.segmentIds,
                        completeBeforeAnchor: pending.completeBeforeAnchor,
                        dispatch: ack,
                        actionId: pending.actionId,
                        anchor: pending.anchor,
                        selectedDay: pending.selectedDay,
                        segmentCount: pending.segmentCount,
                        scopeOverride: pending.scopeOverride,
                        selectionMode: pending.selectionMode,
                        coverageStart: pending.coverageStart,
                        coverageEnd: pending.coverageEnd
                    )
                }
            } catch {
                    await MainActor.run {
                        self.summonWatchdogToken = nil
                        self.pendingSummonSource = nil
                        self.pendingSummonRunId = nil
                        self.pendingLogRequest = nil
                        self.addSummonResult(text: "Error: Pet Log request could not be dispatched", source: "log")
                    }
                }
            }
        }

    /// Single entry point for every Log action (preset/custom slot/free
    /// text). `envelope` carries the full query-time raw history (not the
    /// display-capped transcript) plus anchor/scope metadata — see
    /// PetLogContext.swift and AmbientLogModel.buildQueryEnvelope.
    /// `selectedDay` is the Ambient-log day the query was scoped to — sourced
    /// from the caller rather than derived from the anchor (an empty past day's
    /// anchor lands on the next day's start), and persisted for forensics.
    @discardableResult
    func sendLogInstruction(envelope requestedEnvelope: PetLogQueryEnvelope, selectedDay: Date? = nil) -> Bool {
        recordPetLogAdmissionEvent(
            .actionReceived(
                requestId: requestedEnvelope.requestId,
                actionId: requestedEnvelope.actionId,
                segmentCount: requestedEnvelope.segments.count
            )
        )
        // D156: an explicit selection that went stale was cleared (not silently
        // widened to the full day). Cancel THIS action with a distinct typed
        // status — the chip is already cleared, so the next click is automatic.
        // Checked before the generic empty-scope refusal so the remedy is clear.
        guard !requestedEnvelope.staleScopeCleared else {
            logThreadPaneOpen = true
            logDispatchStatus = .staleScopeRefused(requestId: requestedEnvelope.requestId)
            return false
        }
        // D3 fail-fast: an empty-scope envelope (e.g. a stale explicit scene
        // selection) has nothing to summarize — refuse before building/dispatch
        // as a TYPED status, never a conversation entry or a fake watchdog wait.
        guard !requestedEnvelope.segments.isEmpty else {
            logThreadPaneOpen = true
            logDispatchStatus = .emptyScopeRefused(requestId: requestedEnvelope.requestId)
            return false
        }
        // D159/D163 fail-closed — the backward source scan hit a completeness
        // issue (unreadable session, malformed line, or an undated real
        // utterance). Refuse before any side-effect rather than sending a
        // silently partial/undated view (typed status + body-free telemetry,
        // draft preserved).
        guard !requestedEnvelope.sourceReadIncomplete else {
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(
                .historyIncompleteRefused(requestId: requestedEnvelope.requestId, reason: "sourceReadIncomplete"))
            logDispatchStatus = .sourceReadIncompleteRefused(requestId: requestedEnvelope.requestId)
            return false
        }
        // D153 client invariant — before any admission side-effect. Explicit
        // scope is always non-truncated (day-scoped exact-all); a truncated
        // explicit envelope is a client bug, so refuse it before dispatch rather
        // than sending a contradictory envelope. Automatic truncation does NOT
        // refuse here (A案): it dispatches with the wire flag set, and the model
        // decides answer-with-boundary vs typed insufficient.
        if requestedEnvelope.scopeOverride != nil && requestedEnvelope.retrievalTruncatedBeforeCoverage {
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(
                .historyIncompleteRefused(requestId: requestedEnvelope.requestId, reason: "explicitTruncatedInvariant"))
            logDispatchStatus = .historyIncompleteRefused(requestId: requestedEnvelope.requestId)
            return false
        }
        // D16 budget fail-closed — a pure envelope property, evaluated ahead of
        // busy/not-connected admission so an over-budget request refuses with a
        // TYPED status only (no log_user entry, no slot claim, no watchdog, no
        // "Error" marker) and the draft is preserved (D60) even while busy/offline.
        let requestBudget: Int
        #if DEBUG
        requestBudget = petLogRequestBudgetForTesting ?? PetLogRequestBudget.maxRequestBytes
        #else
        requestBudget = PetLogRequestBudget.maxRequestBytes
        #endif
        let envelope: PetLogQueryEnvelope
        switch PetLogRequestEnforcer.enforce(requestedEnvelope, budget: requestBudget) {
        case .fits(let e):
            envelope = e
        case .refused(let reason):
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(
                .historyIncompleteRefused(requestId: requestedEnvelope.requestId, reason: reason.rawValue))
            logDispatchStatus = .historyIncompleteRefused(requestId: requestedEnvelope.requestId)
            return false
        }
        // Admission control follows the envelope-level fail-closed checks, before
        // any user-visible entry, save, or watchdog timer is created:
        //  - Busy: a previous Chi summon (scene naming or anything else) is
        //    still in flight. Starting a Log summon here would silently
        //    overwrite pendingSummonSource/RunId/pendingLogRequest out from
        //    under it, so refuse with a bounded, immediate marker instead.
        //  - Not connected: sendLogSummon silently no-ops without a sessionKey,
        //    which previously left a saved log_user entry and a fake
        //    180s watchdog wait before any error surfaced. Surface the error
        //    immediately instead.
        guard !isSummonBusy else {
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(.busyRefused(requestId: requestedEnvelope.requestId))
            appendLogErrorEntry("Error: busy — a previous Chi request is still in progress")
            return false
        }
        guard connectionState == .connected else {
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(.disconnectedRefused(requestId: requestedEnvelope.requestId))
            appendLogErrorEntry("Error: not connected")
            return false
        }
        guard sessionKey != nil else {
            logThreadPaneOpen = true
            recordPetLogAdmissionEvent(.disconnectedRefused(requestId: requestedEnvelope.requestId))
            appendLogErrorEntry("Error: not connected")
            return false
        }
        recordPetLogAdmissionEvent(.envelopeAccepted(requestId: requestedEnvelope.requestId))
        // D3: a newly accepted Log request supersedes any prior dispatch status
        // (e.g. a previous "ログ不足"). Owner-scoped clear — unrelated summon
        // successes never touch it.
        logDispatchStatus = nil

        let selectionMode = envelope.scopeOverride == nil ? "automatic" : "explicit"
        let sourceFingerprint = PetLogSourceFingerprint.make(
            policyVersion: PetLogPromptBuilder.policyVersion,
            segmentIds: envelope.segments.map(\.id))
        // Correlation metadata stamped onto both the request-side (`log_user`)
        // entry and, later, its answer — so the two pair up and the exact
        // envelope behind the answer is reconstructable after the fact. The
        // request side carries `completeBeforeAnchor` too: if the answer never
        // arrives (crash/timeout), the request entry is the sole evidence of
        // whether retrieval could vouch for the anchor cutoff.
        let correlation = PetLogEntryMetadata(
            completeBeforeAnchor: envelope.completeBeforeAnchor,
            requestId: envelope.requestId,
            actionId: envelope.actionId,
            anchor: envelope.anchorTimestamp,
            selectedDay: selectedDay,
            segmentCount: envelope.segments.count,
            scopeOverride: envelope.scopeOverride,
            selectionMode: selectionMode,
            coverageStart: envelope.coverageStart,
            coverageEnd: envelope.coverageEnd,
            policyVersion: PetLogPromptBuilder.policyVersion,
            sourceFingerprint: sourceFingerprint,
            retrievalTruncatedBeforeCoverage: envelope.retrievalTruncatedBeforeCoverage
        )
        let userEntry = NotificationEntry(
            id: UUID().uuidString, text: envelope.instruction,
            source: "log_user", timestamp: Date(),
            logMetadata: correlation
        )
        appendPersistentLogReplyEntry(userEntry)
        logThreadPaneOpen = true
        let token = UUID()
        logAwaitingReplyToken = token
        logAwaitingReply = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logAwaitingReplyTimeoutSeconds) { [weak self] in
            guard let self, self.logAwaitingReplyToken == token, self.logAwaitingReply else { return }
            // No terminal WS event (message/messageComplete/idle-finalize) ever
            // arrived for this request — e.g. a sustained ping-timeout/reconnect
            // loop (OpenClawWSClient) can tear the connection down before the
            // server's response is received, with no replay-on-reconnect to
            // recover it (2026-07-15 incident: log_user prompt with no matching
            // reply in log.json). Release the summon slot and leave a visible
            // marker instead of leaving pendingSummonSource wedged forever with
            // no user-facing signal.
            self.logAwaitingReply = false
            self.logAwaitingReplyToken = nil
            if self.pendingSummonSource == "log" {
                self.summonWatchdogToken = nil
                self.pendingSummonSource = nil
                self.pendingSummonRunId = nil
                self.pendingLogRequest = nil
            }
            // D110-neutral: no answer was observed within the deadline. Do NOT
            // assert a transport cause unless there is actual evidence (the
            // connection is currently down); a slow-but-fine reply must not be
            // mislabeled as a connection problem.
            let transportDown = self.connectionState != .connected
            let connectionNote = transportDown ? "（接続が不安定な可能性があります）" : ""
            self.appendSummonEntry(
                text: "応答を確認できませんでした（requestId: \(envelope.requestId.prefix(8))）\(connectionNote)",
                source: "log")
        }
        guard let message = try? PetLogPromptBuilder.buildMessage(envelope: envelope) else {
            logAwaitingReply = false
            logAwaitingReplyToken = nil
            appendSummonEntry(text: "Error: failed to build log query", source: "log")
            return false
        }
        // Envelope telemetry: structured, queryable, and body-free (never the
        // instruction or any transcript text). os.Logger — NSLog is not
        // retroactively queryable via `log show`.
        Self.petLogTelemetry.info(
            "envelopeSent request=\(envelope.requestId, privacy: .public) action=\(envelope.actionId, privacy: .public) bytes=\(message.utf8.count, privacy: .public) segments=\(envelope.segments.count, privacy: .public) selection=\(selectionMode, privacy: .public) policyVersion=\(PetLogPromptBuilder.policyVersion, privacy: .public) fingerprint=\(sourceFingerprint, privacy: .public)"
        )
        pendingLogRequest = PendingLogRequest(
            requestId: envelope.requestId,
            segmentIds: envelope.segments.map(\.id),
            completeBeforeAnchor: envelope.completeBeforeAnchor,
            dispatch: nil,
            actionId: envelope.actionId,
            anchor: envelope.anchorTimestamp,
            selectedDay: selectedDay,
            segmentCount: envelope.segments.count,
            scopeOverride: envelope.scopeOverride,
            selectionMode: selectionMode,
            coverageStart: envelope.coverageStart,
            coverageEnd: envelope.coverageEnd,
            retrievalTruncatedBeforeCoverage: envelope.retrievalTruncatedBeforeCoverage
        )
        sendLogSummon(message, requestId: envelope.requestId)
        return true
    }

    /// Appends a bounded, immediate, persisted "log"-sourced error/status
    /// marker straight into the Log pane, bypassing the structured-parse and
    /// awaiting-reply machinery. Used for admission-control refusals (busy /
    /// not connected) that must be visible without ever creating a `log_user`
    /// entry or arming the reply watchdog.
    private func appendLogErrorEntry(_ text: String) {
        appendPersistentLogReplyEntry(
            NotificationEntry(id: UUID().uuidString, text: text, source: "log", timestamp: Date())
        )
    }

    private func appendPersistentLogReplyEntry(_ entry: NotificationEntry) {
        logReplies.append(entry)
        if logReplies.count > 100 {
            logReplies.removeFirst(logReplies.count - 100)
        }
        guard persistStore(logReplies, file: "log.json") else {
            appendLogPersistenceFailureMarker(requestId: entry.logMetadata?.requestId)
            return
        }
    }

    private func appendLogPersistenceFailureMarker(requestId: String?) {
        let marker = NotificationEntry(
            id: UUID().uuidString,
            text: "Error: failed to persist log entry to disk",
            source: "log",
            timestamp: Date()
        )
        logReplies.append(marker)
        if logReplies.count > 100 {
            logReplies.removeFirst(logReplies.count - 100)
        }
        recordPetLogAdmissionEvent(.persistenceFailure(file: "log.json", requestId: requestId))
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

    func addSummonResult(text: String, source: String, parseAsStructured: Bool = false) {
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
        appendSummonEntry(text: text, source: source, parseAsStructured: parseAsStructured)
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

    private func appendSummonEntry(text: String, source: String, parseAsStructured: Bool = false) {
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
            let entry: NotificationEntry
            if parseAsStructured {
                // Validate the model's segment claims against exactly what the
                // originating request sent (ordered ids), and stamp the
                // client's own completeness signal onto the metadata. A pending
                // request is REQUIRED — never fabricate an empty allowed-id set
                // or a default completeness signal.
                if let pending = pendingLogRequest {
                    // D148: an unknown/typo selectionMode fails closed — never
                    // silently validated under the permissive automatic path.
                    guard let mode = PetLogSelectionMode(persisted: pending.selectionMode) else {
                        let dispatch = pending.dispatch.map {
                            PetLogDispatchMetadata(
                                runId: $0.runId, resolvedModel: $0.resolvedModel,
                                resolvedThinking: $0.resolvedThinking, degraded: $0.degraded,
                                fallbackReason: $0.fallbackReason)
                        }
                        let failed = NotificationEntry(
                            id: UUID().uuidString,
                            text: "Error: unrecognized selection mode — reply rejected",
                            source: source, timestamp: Date(),
                            logMetadata: pending.entryMetadata(contextDecision: nil,
                                                               completeBeforeAnchor: pending.completeBeforeAnchor,
                                                               dispatch: dispatch))
                        pendingLogRequest = nil
                        appendPersistentLogReplyEntry(failed)
                        return
                    }
                    switch PetLogResultParser.parse(text, allowedSegmentIds: pending.segmentIds, selectionMode: mode,
                                                    truncatedBeforeCoverage: pending.retrievalTruncatedBeforeCoverage) {
                    case .success(let result) where result.outcome == .insufficientEvidence:
                        // D3/D145: the model's typed discriminator (not an
                        // inference) says the log is insufficient. Surface a fixed
                        // status — never persist the (null) model body as a "ちー"
                        // reply. No conversation entry is created.
                        logDispatchStatus = .insufficientEvidence(requestId: pending.requestId)
                        pendingLogRequest = nil
                        return
                    case .success(let result):
                        let dispatch = pending.dispatch.map {
                            PetLogDispatchMetadata(
                                runId: $0.runId,
                                resolvedModel: $0.resolvedModel,
                                resolvedThinking: $0.resolvedThinking,
                                degraded: $0.degraded,
                                fallbackReason: $0.fallbackReason
                            )
                        }
                        // A real answer clears any prior dispatch status.
                        logDispatchStatus = nil
                        entry = NotificationEntry(
                            id: UUID().uuidString, text: result.answer ?? "",
                            source: source, timestamp: Date(),
                            logMetadata: pending.entryMetadata(
                                contextDecision: result.contextDecision,
                                completeBeforeAnchor: pending.completeBeforeAnchor,
                                dispatch: dispatch
                            )
                        )
                    case .failure:
                        // Fail closed: never show a raw/garbled model reply as if
                        // it were the answer. D72: retain the request correlation
                        // metadata (contextDecision nil) so a malformed reply is
                        // still traceable to its request.
                        let dispatch = pending.dispatch.map {
                            PetLogDispatchMetadata(
                                runId: $0.runId, resolvedModel: $0.resolvedModel,
                                resolvedThinking: $0.resolvedThinking, degraded: $0.degraded,
                                fallbackReason: $0.fallbackReason)
                        }
                        entry = NotificationEntry(
                            id: UUID().uuidString,
                            text: "Error: model response did not match the expected structured format",
                            source: source, timestamp: Date(),
                            logMetadata: pending.entryMetadata(
                                contextDecision: nil,
                                completeBeforeAnchor: pending.completeBeforeAnchor,
                                dispatch: dispatch)
                        )
                    }
                } else {
                    // No pending request to validate the reply against — never
                    // fabricate an empty allowed-id set or a default completeness
                    // signal. Fail closed without even attempting to parse.
                    entry = NotificationEntry(
                        id: UUID().uuidString,
                        text: "Error: no pending log request to validate the response against",
                        source: source, timestamp: Date()
                    )
                }
            } else {
                entry = NotificationEntry(
                    id: UUID().uuidString, text: text,
                    source: source, timestamp: Date()
                )
            }
            // This log summon is terminal (success, parse failure, timeout,
            // send error, or build failure all route here) — drop the pending
            // request so it always tracks 1:1 with an in-flight Log summon.
            pendingLogRequest = nil
            appendPersistentLogReplyEntry(entry)
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
        persistStore(summonResults, file: "summon.json")
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
        persistStore(notificationHistory, file: "notifications.json")
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
        persistStore(localResults, file: "local.json")
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
    /// Structured context-selection metadata — populated only for "log"
    /// source entries whose model reply parsed as the expected structured
    /// JSON. nil for every other source, for pre-Phase-A log entries, and
    /// for fail-closed synthetic error markers (parse/policy/timeout/send
    /// failures never carry model-reported metadata).
    ///
    /// `var` (not `let`) with a default: Swift only threads a defaulted
    /// stored property through the synthesized memberwise init AND through
    /// `Decodable`'s `decodeIfPresent` when it is a `var`. A `let ... = nil`
    /// is treated as a fixed constant — omitted from the memberwise init and
    /// never decoded (always nil) — which would defeat both backward-compat
    /// decode of new entries and the `logMetadata:` init parameter.
    var logMetadata: PetLogEntryMetadata? = nil
}

// MARK: - Local Persistence for Summon/Notification logs

enum PetLogStore {
    /// internal (not private): test seam. XCTest may still redirect this to a
    /// per-case temp directory for parallel fixture isolation — but it no longer
    /// HAS to: `defaultDir()` structurally refuses the production path whenever
    /// the process is running under XCTest, so a case that forgets to override
    /// can never overwrite the user's real history (2026-07-14 incident class).
    static var dir = defaultDir()

    /// The default store directory. Safe-by-construction (D37): under XCTest the
    /// production `~/.clawgate/logs` path is unreachable — a process-wide temp
    /// root is used instead, so no test can touch real data even without the
    /// per-case override below. The env var isn't guaranteed under every test
    /// runner, but the XCTest class being loaded into the process is, and neither
    /// signal is ever true in the shipping app.
    /// internal (not private): test seam for the D37 guard.
    static func defaultDir() -> String {
        if isUnderXCTest {
            return NSTemporaryDirectory() + "clawgate-xctest-store-\(ProcessInfo.processInfo.processIdentifier)"
        }
        return productionDir
    }

    private static let productionDir = NSString("~/.clawgate/logs").expandingTildeInPath

    private static var isUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// PRIMARY D37 guard (runtime, not source-scan): under XCTest, refuse any
    /// real I/O against the production store directory no matter how `dir` was
    /// overridden — a literal, a variable, a function result. This makes
    /// production data structurally untouchable from a test even if a case
    /// assigns `dir` to the real path through an indirection the source scan
    /// can't see. Never true in the shipping app.
    ///
    /// Comparison is by RESOLVED TARGET, not string equality (D97): a trailing
    /// slash, a `..` segment, or a symlink alias all normalize to the same
    /// canonical path, so none of them can slip past the guard onto real data.
    static func productionAccessBlocked() -> Bool {
        isUnderXCTest && resolvedTarget(dir) == resolvedTarget(productionDir)
    }

    /// Canonical target of a path for same-target comparison: symlinks resolved
    /// and `.`/`..`/trailing-slash normalized. For a non-existent leaf (the dir
    /// may not exist yet) `resolvingSymlinksInPath` still resolves the existing
    /// ancestor components, so a symlinked PARENT is caught too; `standardized`
    /// then folds `..`/`.`/trailing slash lexically.
    private static func resolvedTarget(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// internal (not private): test seam. `dir` is a process-global static,
    /// so parallel test execution across XCTestCase classes could otherwise
    /// race and momentarily observe another test's override (or the
    /// production default) mid-test. Any XCTestCase that overrides `dir`
    /// must `wait()` in setUp and `signal()` in tearDown, holding it for the
    /// entire test lifetime. DispatchSemaphore has no thread-affinity
    /// requirement, so this is safe even if an async test body resumes on a
    /// different thread than setUp/tearDown.
    static let testIsolationSemaphore = DispatchSemaphore(value: 1)

    private static let logger = Logger(subsystem: "com.clawgate", category: "PetLog")

    /// Provenance of a current write-blocking incident (H): the reason and, when
    /// the corrupt original could be preserved, the exact quarantine copy that
    /// preserves it. A quarantine-FAILURE incident carries nil name/hash — which
    /// makes it structurally unresolvable (there is no preserved evidence to
    /// vouch that overwriting is safe).
    struct PoisonIncident: Equatable {
        let reason: String
        let quarantineName: String?
        let quarantineSHA256: String?
    }

    /// Files held fail-closed, keyed to their CURRENT incident. While a file is
    /// here `save` refuses to overwrite it — a fresh append can never destroy
    /// history we could not read. Process-global like `dir`; guarded by
    /// `testIsolationSemaphore` and reset via `resetPoisonedForTesting`.
    private static var poisonedIncidents: [String: PoisonIncident] = [:]

    /// internal (not private): test seam. Clears poison state between tests;
    /// callers must already hold `testIsolationSemaphore` (see setUp/tearDown).
    static func resetPoisonedForTesting() { poisonedIncidents = [:] }

    /// True while `file` is held fail-closed. Poisoning can be raised on a
    /// `.success` path too (partial decode whose quarantine failed), so callers
    /// surface the visible status from this, not only from a `.corrupt` outcome.
    static func isPoisoned(_ file: String) -> Bool { poisonedIncidents[file] != nil }

    /// The current write-blocking incident for `file`, so the model can stamp its
    /// quarantine reference into the writeBlocked warning.
    static func poisonIncident(_ file: String) -> PoisonIncident? { poisonedIncidents[file] }

    /// Resolves a poisoned store — the explicit "recover / start fresh" action,
    /// distinct from acknowledging the warning (D99). Permitted ONLY when: the
    /// file is CURRENTLY poisoned; the current incident recorded a quarantine
    /// name + hash (a quarantine-failure incident is unresolvable); and that
    /// exact quarantine file reads back with the matching hash (so stale debris
    /// from an OLD incident can't authorize overwriting the CURRENT corrupt
    /// bytes). On success clears the poison and commits a fresh empty store so
    /// saves resume; a failed fresh write re-arms the same incident.
    /// Returns the fresh-store commit outcome: `.failed` means resolve was
    /// refused or the fresh write failed (stays poisoned); `.committed` /
    /// `.committedBackupDegraded` mean the store is recovered (the latter with a
    /// stale backup the caller surfaces).
    static func resolveLogStoreCorruption(file: String) -> CommitOutcome {
        if productionAccessBlocked() { return .failed }
        guard let incident = poisonedIncidents[file],
              let name = incident.quarantineName,
              let expectedHash = incident.quarantineSHA256 else { return .failed }
        // The current incident's exact quarantine must exist and match — not
        // merely some same-prefix debris from a prior incident.
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name))) else {
            return .failed
        }
        let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else { return .failed }

        poisonedIncidents[file] = nil
        let outcome = saveOutcome([], file: file)
        if outcome == .failed {
            poisonedIncidents[file] = incident  // fresh write failed — stay fail-closed
        }
        return outcome
    }

    /// Owner-only (0600): every persisted file is a copy of conversation text.
    private static let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    /// Owner-only (0700) for the store directory, so quarantine/backup file
    /// names aren't enumerable by other local users (D54).
    private static let ownerOnlyDir: [FileAttributeKey: Any] = [.posixPermissions: 0o700]

    /// internal (not private): test seam. When set, permission application is
    /// simulated by this hook (keyed on path, returns success) instead of a real
    /// `setAttributes`, so a test can inject a chmod failure at a specific path.
    /// Process-global — reset it in setUp/tearDown under `testIsolationSemaphore`.
    static var applyPermissionsHookForTesting: ((String) -> Bool)?

    /// Applies POSIX permissions to `realPath`, but keys the test hook on
    /// `hookKey` — so an atomic write can chmod a temp file while a test still
    /// injects failure by the file's FINAL name. Returns whether it was set; a
    /// failure is surfaced (fail-visible), never swallowed.
    private static func applyPermissions(_ attrs: [FileAttributeKey: Any], realPath: String, hookKey: String) -> Bool {
        if let hook = applyPermissionsHookForTesting { return hook(hookKey) }
        do {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: realPath)
            return true
        } catch {
            return false
        }
    }

    private static func applyPermissions(_ attrs: [FileAttributeKey: Any], path: String) -> Bool {
        applyPermissions(attrs, realPath: path, hookKey: path)
    }

    /// Atomic, owner-only durable write: writes to a sibling temp file, sets
    /// 0600 on it, then atomically renames it onto `path`. Permissions are
    /// established BEFORE the file is visible at its final name, so there is no
    /// window where the final path exists at the wrong mode — closing the
    /// write-succeeds-then-chmod-fails partial-commit gap. On any failure the
    /// temp is removed and `path` is left untouched. `hookKey` (the final name)
    /// lets a test inject a chmod failure.
    private static func atomicWrite(_ data: Data, to path: String, hookKey: String) -> Bool {
        let tmp = path + ".tmp-\(UUID().uuidString)"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return false
        }
        guard applyPermissions(ownerOnly, realPath: tmp, hookKey: hookKey) else {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        // rename(2) atomically replaces the destination on the same filesystem
        // (same dir), handling both an existing and a non-existent target.
        let renamed = path.withCString { cPath in tmp.withCString { cTmp in rename(cTmp, cPath) } }
        if renamed != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    /// The three ways a load can end. `success` carries `dropped` — the count of
    /// individual entries that failed to decode (unknown/legacy shapes) and were
    /// skipped, so a single bad entry never sinks the whole array yet the loss is
    /// still surfaced. `corrupt` means the top-level JSON itself was unreadable;
    /// `recovered` is true when a `.bak` supplied the returned entries.
    enum LoadOutcome {
        case missing
        case success(entries: [NotificationEntry], dropped: Int, quarantine: String?)
        case corrupt(entries: [NotificationEntry], recovered: Bool, quarantine: String?)
    }

    /// The result of a two-copy commit. `committed` = both primary and backup
    /// durable. `committedBackupDegraded` = primary is durable but the backup
    /// couldn't be refreshed (redundancy lost, NOT a failed save — the append
    /// landed). `failed` = primary not committed; both copies remain at their
    /// prior state.
    enum CommitOutcome: Equatable { case committed, committedBackupDegraded, failed }

    /// Canonical durable save. Prefer this where the backup-degraded state must
    /// surface; `save` is the Bool-returning compatibility wrapper.
    static func saveOutcome(_ entries: [NotificationEntry], file: String) -> CommitOutcome {
        if productionAccessBlocked() { return .failed }
        if poisonedIncidents[file] != nil { return .failed }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        guard applyPermissions(ownerOnlyDir, path: dir) else {
            logger.error("PetLogStore dir permission set failed for \(file, privacy: .public); reporting save failure")
            return .failed
        }
        let path = (dir as NSString).appendingPathComponent(file)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return .failed }
        return commitTwoCopy(data, primaryPath: path)
    }

    /// Bool-returning compatibility wrapper (test-facing): true unless the
    /// primary commit itself failed. A `committedBackupDegraded` outcome still
    /// returns true because the primary IS durable — production callers use
    /// `saveOutcome` to also surface the degraded redundancy.
    @discardableResult
    static func save(_ entries: [NotificationEntry], file: String) -> Bool {
        saveOutcome(entries, file: file) != .failed
    }

    /// Two-copy durable commit via pending-temp promotion (F2). The committed
    /// `.bak` is NEVER touched until the primary commit succeeds:
    ///  1. stage the new data to a loader-ignored pending temp (0600),
    ///  2. atomically commit the PRIMARY,
    ///  3. only then promote the pending temp onto `.bak`.
    /// A primary failure leaves BOTH committed copies structurally untouched (we
    /// only ever cleaned up the pending temp). A promote failure means the
    /// primary is durable but the backup is stale — reported as
    /// `committedBackupDegraded`, never disguised as a failed save. So a later
    /// corrupt-primary recovery can never adopt an un-committed snapshot.
    private static func commitTwoCopy(_ data: Data, primaryPath path: String) -> CommitOutcome {
        let bakPath = path + ".bak"
        let pendingPath = bakPath + ".pending-\(UUID().uuidString)"

        // 1. Stage to pending (hookKey = bakPath so the existing bak-chmod test
        //    still injects here). A stage failure touches nothing committed.
        guard atomicWrite(data, to: pendingPath, hookKey: bakPath) else {
            logger.error("PetLogStore backup staging failed for \(path, privacy: .public); nothing committed, reporting save failure")
            return .failed
        }
        // 2. Commit the primary. On failure the committed .bak is untouched
        //    (we never wrote it) — just clean up the pending temp.
        guard atomicWrite(data, to: path, hookKey: path) else {
            logger.error("PetLogStore primary write failed for \(path, privacy: .public); discarding pending backup, reporting save failure")
            try? FileManager.default.removeItem(atPath: pendingPath)
            return .failed
        }
        // 3. Promote pending -> .bak (bare rename; mode travels with the file).
        let promoted = bakPath.withCString { cBak in pendingPath.withCString { cPending in rename(cPending, cBak) } }
        if promoted != 0 {
            logger.error("PetLogStore backup promote failed for \(path, privacy: .public); primary committed, backup redundancy degraded")
            try? FileManager.default.removeItem(atPath: pendingPath)
            return .committedBackupDegraded
        }
        return .committed
    }

    /// Converges EXISTING on-disk permissions to owner-only at load time — the
    /// store dir to 0700 and the primary + `.bak` to 0600 — so a load-only
    /// startup, or files written by an older 0644/0755 version, never leave
    /// conversation bytes readable or the directory enumerable by other local
    /// users. NEVER touches file CONTENTS. Returns false if any chmod of an
    /// existing item failed, so the caller can surface a durable security
    /// warning; the bytes are untouched regardless. Run before `loadOutcome`
    /// so the dir is already 0700 when a corrupt load writes a quarantine copy.
    @discardableResult
    static func convergePermissionsOnLoad(file: String) -> Bool {
        // D37 runtime guard: never chmod real files/dir from a test.
        if productionAccessBlocked() { return true }
        var ok = true
        if FileManager.default.fileExists(atPath: dir) {
            if !applyPermissions(ownerOnlyDir, path: dir) { ok = false }
        }
        let path = (dir as NSString).appendingPathComponent(file)
        for p in [path, path + ".bak"] where FileManager.default.fileExists(atPath: p) {
            if !applyPermissions(ownerOnly, path: p) { ok = false }
        }
        if !ok {
            logger.error("PetLogStore permission convergence failed on load for \(file, privacy: .public)")
        }
        return ok
    }

    /// Backward-compatible convenience for callers that only need the entries.
    /// Prefer `loadOutcome` where the missing/corrupt distinction matters.
    static func load(file: String) -> [NotificationEntry] {
        switch loadOutcome(file: file) {
        case .missing: return []
        case let .success(entries, _, _): return entries
        case let .corrupt(entries, _, _): return entries
        }
    }

    static func loadOutcome(file: String) -> LoadOutcome {
        // D37 runtime guard: never read real data from a test, however `dir` was
        // overridden. Report missing rather than touching the production path.
        if productionAccessBlocked() { return .missing }
        let path = (dir as NSString).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // Exists but unreadable — treat as corrupt and hold writes.
            return handleCorrupt(file: file, path: path, data: nil)
        }
        if let (entries, dropped) = decodeEntries(data) {
            // Partial decode is still silent loss in miniature: the next save
            // rewrites without the dropped entries, so preserve a quarantine
            // copy of the original first. Writes stay allowed (recovery of the
            // good entries succeeded — do NOT poison).
            var quarantineName: String? = nil
            if dropped > 0 {
                quarantineName = quarantine(path: path, data: data)?.name
                if quarantineName != nil {
                    logger.error("PetLogStore dropped \(dropped, privacy: .public) undecodable entries loading \(file, privacy: .public); original quarantined")
                } else {
                    // No safe copy of the original — hold writes fail-closed so
                    // the next save can't drop the bad entry by overwriting it.
                    poisonedIncidents[file] = PoisonIncident(reason: "partialDropQuarantineFailed", quarantineName: nil, quarantineSHA256: nil)
                    logger.error("PetLogStore dropped \(dropped, privacy: .public) undecodable entries loading \(file, privacy: .public); quarantine failed, writes held fail-closed")
                }
            }
            return .success(entries: entries, dropped: dropped, quarantine: quarantineName)
        }
        // Top-level JSON is not even a decodable array — genuine corruption.
        return handleCorrupt(file: file, path: path, data: data)
    }

    /// Per-entry resilient decode: returns nil only when the top-level value is
    /// not a JSON array of objects at all. A single element that fails to decode
    /// is dropped (counted), not fatal.
    private static func decodeEntries(_ data: Data) -> (entries: [NotificationEntry], dropped: Int)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let wrapped = try? decoder.decode([FailableEntry].self, from: data) else { return nil }
        let entries = wrapped.compactMap(\.value)
        return (entries, wrapped.count - entries.count)
    }

    private static func handleCorrupt(file: String, path: String, data: Data?) -> LoadOutcome {
        // Preserve the corrupt original first (copy, never move). If we cannot —
        // disk full, permission, name collision — there is NO safe copy, so
        // poison and refuse writes: the next append must not overwrite the
        // un-preserved original.
        guard let quarantined = quarantine(path: path, data: data) else {
            poisonedIncidents[file] = PoisonIncident(reason: "corruptQuarantineFailed", quarantineName: nil, quarantineSHA256: nil)
            logger.error("PetLogStore corrupt load for \(file, privacy: .public); quarantine failed, writes held fail-closed")
            return .corrupt(entries: [], recovered: false, quarantine: nil)
        }
        let quarantineName = quarantined.name

        // Recover ONLY from a fully-decodable backup. A partially-corrupt `.bak`
        // (dropped > 0) is not a trustworthy last-known-good — reject it rather
        // than silently adopting the salvageable subset.
        if let bakData = try? Data(contentsOf: URL(fileURLWithPath: path + ".bak")),
           let (entries, dropped) = decodeEntries(bakData), dropped == 0 {
            // Body-free provenance: entry count + a hash of the recovered bytes
            // (never any conversation text) so a recovery is auditable.
            let hash = SHA256.hash(data: bakData).map { String(format: "%02x", $0) }.joined()
            logger.error("PetLogStore recovered \(entries.count, privacy: .public) entries from backup for \(file, privacy: .public) after corrupt load, sha256=\(hash, privacy: .public)")
            return .corrupt(entries: entries, recovered: true, quarantine: quarantineName)
        }
        // Unrecoverable: empty start, and hold writes fail-closed so the
        // quarantined original remains the sole surviving copy. Record the
        // incident with its exact quarantine provenance so resolve can verify it.
        poisonedIncidents[file] = PoisonIncident(reason: "corruptNoBackup",
                                                 quarantineName: quarantined.name,
                                                 quarantineSHA256: quarantined.sha256)
        logger.error("PetLogStore corrupt load for \(file, privacy: .public), no usable backup; writes held fail-closed")
        return .corrupt(entries: [], recovered: false, quarantine: quarantineName)
    }

    /// Copies the original bytes to a timestamped, owner-only quarantine file in
    /// the same directory. The name carries a readable timestamp PLUS a UUID, and
    /// the file is created with `O_EXCL` at 0600 — so two quarantines within the
    /// same second (re-entrant load, rapid restart, partial-decode re-load) can
    /// never collide and overwrite or fail-poison each other (D103). Returns the
    /// file NAME and a SHA-256 of the preserved bytes on success, nil on failure
    /// — a failure means the original could not be preserved and the caller must
    /// fail closed rather than allow a later overwrite.
    private static func quarantine(path: String, data: Data?) -> (name: String, sha256: String)? {
        guard let bytes = data ?? (try? Data(contentsOf: URL(fileURLWithPath: path))) else { return nil }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let base = ((path as NSString).lastPathComponent) + ".corrupt-\(quarantineTimestamp())"
        for _ in 0..<3 {
            let name = base + "-\(UUID().uuidString)"
            let full = (dir as NSString).appendingPathComponent(name)
            let fd = full.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
            if fd < 0 { continue }  // EEXIST (astronomically unlikely) or error — retry with a fresh UUID
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: bytes)
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: full)
                continue
            }
            return (name, sha)
        }
        return nil
    }

    private static func quarantineTimestamp() -> String {
        // Colon-free (Finder renders ':' as '/'): 2026-08-09T12-34-56Z.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: Date())
    }

    // MARK: Durable recovery warnings (D39)

    static let recoveryWarningsFile = "recovery-warnings.json"

    /// Loads the durable recovery warnings persisted from prior launches, with
    /// the same last-known-good `.bak` resilience as the main store. `degraded`
    /// is true only when something WAS persisted but neither the primary nor the
    /// backup can be decoded — a genuine loss of durable warning state that the
    /// caller must surface (never silently swallowed to []). This file is
    /// bookkeeping, never conversation data — it must not recurse the
    /// poison/quarantine machinery onto itself.
    static func loadRecoveryWarnings() -> (warnings: [PetLogRecoveryWarning], degraded: Bool, permissionsInsecure: Bool) {
        if productionAccessBlocked() { return ([], false, false) }
        // Tighten the warnings store's own perms (dir 0700, primary/.bak 0600)
        // before reading — best-effort on content, but the failure is NO LONGER
        // discarded (D100): it is returned so the caller surfaces a typed status.
        // Because this re-checks perms every load, a still-insecure store
        // re-derives the same status next launch until it is actually repaired.
        let permissionsInsecure = !convergePermissionsOnLoad(file: recoveryWarningsFile)
        let path = (dir as NSString).appendingPathComponent(recoveryWarningsFile)
        let bakPath = path + ".bak"
        if let warnings = decodeRecoveryWarnings(path) { return (warnings, false, permissionsInsecure) }
        let primaryExisted = FileManager.default.fileExists(atPath: path)
        if let warnings = decodeRecoveryWarnings(bakPath) {
            if primaryExisted {
                logger.error("PetLogStore recovery-warnings primary corrupt; recovered from backup")
            }
            return (warnings, false, permissionsInsecure)
        }
        if primaryExisted || FileManager.default.fileExists(atPath: bakPath) {
            logger.error("PetLogStore recovery-warnings primary+backup both unreadable; durable warning state lost")
            return ([], true, permissionsInsecure)
        }
        return ([], false, permissionsInsecure)  // fresh — nothing persisted yet
    }

    private static func decodeRecoveryWarnings(_ path: String) -> [PetLogRecoveryWarning]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([PetLogRecoveryWarning].self, from: data)
    }

    /// Persists the warning set via the same two-copy pending-temp commit as the
    /// main store, returning the full outcome so the model can distinguish a
    /// durable-but-redundancy-degraded write from a failure.
    static func saveRecoveryWarnings(_ warnings: [PetLogRecoveryWarning]) -> CommitOutcome {
        if productionAccessBlocked() { return .failed }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        guard applyPermissions(ownerOnlyDir, path: dir) else { return .failed }
        let path = (dir as NSString).appendingPathComponent(recoveryWarningsFile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(warnings) else { return .failed }
        return commitTwoCopy(data, primaryPath: path)
    }
}

/// A durable, user-facing warning that persisted history could not be fully
/// read at load — either whole-file corruption or a partial drop of undecodable
/// entries. Body-free: it names the file, the drop count, and the quarantine
/// copy, never any conversation text. Persisted until the user acknowledges it.
struct PetLogRecoveryWarning: Codable, Equatable {
    let file: String
    /// "corrupt" (whole file unreadable) or "partialDrop" (some entries skipped).
    /// A String, not an enum, so an unknown future value never fails decode.
    let kind: String
    let droppedCount: Int
    /// Quarantine file name preserving the original bytes, nil if the copy could
    /// not be created (in which case writes are held fail-closed).
    let quarantine: String?
    let detectedAt: Date
}

/// Decodes a `NotificationEntry` without failing the enclosing array — one
/// unknown/legacy element decodes to `value == nil` instead of throwing, so a
/// single bad entry can't sink the whole history. See `PetLogStore.loadOutcome`.
private struct FailableEntry: Decodable {
    let value: NotificationEntry?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(NotificationEntry.self)
    }
}
