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

    let stateMachine = PetStateMachine()
    let characterManager = CharacterManager()

    private let wsClient = OpenClawWSClient()
    private var sessionKey: String?
    private var eventTask: Task<Void, Never>?
    private var streamingMessageId: String?
    private var whisperDismissTask: Task<Void, Never>?
    private var idleTimer: Timer?

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
            connectionState = .disconnected  // Silently stay disconnected, pet still works without Gateway
            return
        }
        guard let url = URL(string: "ws://127.0.0.1:\(config.port)/websocket") else {
            connectionState = .error("Invalid URL")
            return
        }

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
                self.showWhisper("接続しました")
                Task { [weak self] in
                    guard let self, let key = self.sessionKey else { return }
                    try? await self.wsClient.subscribeToSession(sessionKey: key)
                }

            case .message(let msg):
                self.isStreaming = false
                self.streamingText = ""
                if let idx = self.messages.firstIndex(where: { $0.id == msg.id }) {
                    self.messages[idx].text = msg.text
                    self.messages[idx].isStreaming = false
                } else {
                    self.messages.append(msg)
                }
                self.stateMachine.handle(.assistantFinished)

            case .delta(let messageId, let text):
                if self.streamingMessageId != messageId {
                    self.streamingMessageId = messageId
                    self.streamingText = text
                    self.isStreaming = true
                    let streamingMsg = OpenClawChatMessage(
                        id: messageId, role: .assistant, text: text, isStreaming: true)
                    self.messages.append(streamingMsg)
                    self.stateMachine.handle(.assistantStarted)
                } else {
                    self.streamingText += text
                    if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                        self.messages[idx].text = self.streamingText
                    }
                }

            case .messageComplete(let messageId):
                self.isStreaming = false
                self.streamingMessageId = nil
                if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[idx].isStreaming = false
                }
                self.stateMachine.handle(.assistantFinished)

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

    // MARK: - Layer 1: Whisper (brief reaction)

    func showWhisper(_ text: String, duration: TimeInterval = 3.0) {
        guard petMode != .quiet else { return }
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

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.stateMachine.current == .idle else { return }
            self.stateMachine.handle(.idleTimeout)
        }
    }

    // MARK: - Lifecycle

    func start() {
        characterManager.scan()
        connect()
        startIdleTimer()
        startReconnectTimer()
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
    }
}
