import Foundation
import os

private let logger = Logger(subsystem: "com.clawgate", category: "OpenClawWS")

/// WebSocket client for OpenClaw Gateway v3 protocol (macOS port of VibeTerm client)
actor OpenClawWSClient {
    private static let chatSendAckTimeout: UInt64 = 15_000_000_000

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var continuation: AsyncStream<OpenClawEvent>.Continuation?
    private var isConnected = false
    private var pingTask: Task<Void, Never>?
    private var inFlightAcks: [String: CheckedContinuation<Void, Error>] = [:]

    private var authToken: String?
    private var pendingRequestId: String?
    private var handshakeComplete = false

    // MARK: - Connection

    /// Connect to local OpenClaw Gateway
    func connect(url: URL, token: String) async throws -> AsyncStream<OpenClawEvent> {
        guard !isConnected else {
            throw OpenClawError.connectionFailed("Already connected")
        }

        authToken = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.setValue("clawgate-macos/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Connection-Nonce")

        guard let session else {
            throw OpenClawError.connectionFailed("Failed to create session")
        }

        webSocketTask = session.webSocketTask(with: request)

        let stream = AsyncStream<OpenClawEvent> { continuation in
            self.continuation = continuation
        }

        webSocketTask?.resume()
        isConnected = true

        Task { await receiveLoop() }
        startPingTask()

        // Handshake timeout
        let ws = webSocketTask
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            let stuck = await self.isHandshakeStuck()
            guard stuck else { return }
            logger.warning("Handshake timeout — no challenge in 10s")
            ws?.cancel(with: .abnormalClosure, reason: "handshake timeout".data(using: .utf8))
        }

        return stream
    }

    func disconnect() {
        teardown()
    }

    private func teardown() {
        isConnected = false
        handshakeComplete = false
        pingTask?.cancel()
        pingTask = nil
        authToken = nil
        pendingRequestId = nil
        failAllAcks(error: OpenClawError.connectionFailed("Disconnected"))

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        continuation?.yield(.disconnected(reason: nil))
        continuation?.finish()
        continuation = nil

        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Send

    func sendMessage(_ text: String, sessionKey: String) async throws {
        let requestId = UUID().uuidString
        let request = GatewayRequest(
            type: "req", id: requestId, method: "chat.send",
            params: ChatSendParams(
                sessionKey: sessionKey,
                message: text,
                idempotencyKey: UUID().uuidString
            )
        )
        try await sendAndAwaitAck(request, requestId: requestId)
    }

    func subscribeToSession(sessionKey: String) async throws {
        let request = GatewayRequest(
            type: "req", id: UUID().uuidString,
            method: "sessions.messages.subscribe",
            params: SessionSubscribeParams(key: sessionKey)
        )
        try await sendJSON(request)
    }

    private func sendAndAwaitAck<T: Encodable>(_ request: T, requestId: String) async throws {
        try await withCheckedThrowingContinuation { cont in
            inFlightAcks[requestId] = cont
            Task {
                do {
                    try await self.sendJSON(request)
                } catch {
                    if let c = self.inFlightAcks.removeValue(forKey: requestId) {
                        c.resume(throwing: error)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: Self.chatSendAckTimeout)
                if let c = self.inFlightAcks.removeValue(forKey: requestId) {
                    c.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    private func sendJSON<T: Encodable>(_ request: T) async throws {
        guard isConnected, let task = webSocketTask else {
            throw OpenClawError.connectionFailed("Not connected")
        }
        let data = try JSONEncoder().encode(request)
        try await task.send(.data(data))
    }

    // MARK: - Connect Handshake

    private func sendConnectRequest(nonce: String?) async {
        guard let token = authToken else {
            continuation?.yield(.error(.connectionFailed("No auth token")))
            return
        }

        let requestId = UUID().uuidString
        pendingRequestId = requestId

        do {
            let identity = try OpenClawDeviceIdentity.loadOrCreate()
            let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            let normalizedNonce = nonce?.isEmpty == false ? nonce : nil
            let role = "operator"
            let scopes = ["operator.read", "operator.write", "operator.admin"]

            // Build signature payload
            let version = normalizedNonce != nil ? "v2" : "v1"
            var components = [version, identity.deviceId, "cli", "cli", role,
                              scopes.joined(separator: ","), String(signedAtMs), token]
            if let n = normalizedNonce { components.append(n) }
            let payload = components.joined(separator: "|")
            let signature = try identity.signPayload(payload)

            let connectReq = ConnectRequest(
                type: "req", id: requestId, method: "connect",
                params: ConnectParams(
                    minProtocol: 3, maxProtocol: 3,
                    client: ClientInfo(id: "cli", version: "1.0.0", platform: "macos", mode: "cli"),
                    role: role, scopes: scopes,
                    auth: AuthParams(token: token),
                    locale: "ja-JP",
                    userAgent: "clawgate-macos/1.0",
                    device: ConnectDeviceParams(
                        id: identity.deviceId,
                        publicKey: identity.publicKeyRawBase64URL,
                        signature: signature,
                        signedAt: signedAtMs,
                        nonce: normalizedNonce
                    )
                )
            )

            try await sendJSON(connectReq)
        } catch {
            continuation?.yield(.error(.connectionFailed("Connect request failed: \(error)")))
        }
    }

    // MARK: - Receive

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while isConnected {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    await handleData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        await handleData(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    continuation?.yield(.error(.connectionFailed("\(error)")))
                    continuation?.yield(.disconnected(reason: "\(error)"))
                }
                break
            }
        }
    }

    private func handleData(_ data: Data) async {
        guard let msg = try? JSONDecoder().decode(IncomingMessage.self, from: data) else { return }

        switch msg.type {
        case "event":
            guard let eventName = msg.event else { return }
            await handleEvent(eventName, payload: msg.payload)
        case "res":
            handleResponse(msg)
        default:
            break
        }
    }

    private func handleEvent(_ name: String, payload: IncomingPayload?) async {
        switch name {
        case "connect.challenge":
            await sendConnectRequest(nonce: payload?.nonce)

        case "agent":
            guard payload?.stream == "assistant",
                  let delta = payload?.data?.delta,
                  let runId = payload?.runId else { return }
            continuation?.yield(.delta(messageId: runId, text: delta))

        case "chat":
            guard let state = payload?.state, let runId = payload?.runId else { return }
            if state == "final" {
                let text = payload?.message?.content?
                    .compactMap { $0.type == "text" ? $0.text : nil }
                    .joined(separator: "\n\n")
                if let text, !text.isEmpty {
                    let msg = OpenClawChatMessage(id: runId, role: .assistant, text: text)
                    continuation?.yield(.message(msg))
                }
            }

        case "assistant.message":
            guard let id = payload?.messageId, let content = payload?.content else { return }
            let msg = OpenClawChatMessage(id: id, role: .assistant, text: content)
            continuation?.yield(.message(msg))

        case "assistant.delta":
            guard let id = payload?.messageId, let delta = payload?.delta else { return }
            continuation?.yield(.delta(messageId: id, text: delta))

        case "assistant.message_complete":
            guard let id = payload?.messageId else { return }
            continuation?.yield(.messageComplete(messageId: id))

        case "health", "tick", "presence", "telemetry.ack":
            break

        default:
            break
        }
    }

    private func handleResponse(_ msg: IncomingMessage) {
        let ok = msg.ok ?? false
        let responseId = msg.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Check in-flight ACKs
        if !responseId.isEmpty, let ack = inFlightAcks.removeValue(forKey: responseId) {
            if ok {
                ack.resume()
            } else if let err = msg.error {
                ack.resume(throwing: OpenClawError.serverError(code: err.code, message: err.message))
            } else {
                ack.resume(throwing: OpenClawError.unknown("Request failed"))
            }
            return
        }

        // Connect response
        if let pendingId = pendingRequestId, responseId == pendingId {
            pendingRequestId = nil
            if ok, let p = msg.payload, p.type == "hello-ok" {
                let sessionKey = p.snapshot?.sessionDefaults?.mainSessionKey ?? "agent:main:main"
                let sessionId = p.sessionId ?? p.sessionKey ?? responseId
                handshakeComplete = true
                continuation?.yield(.connected(sessionId: sessionId, sessionKey: sessionKey))
            } else if let err = msg.error {
                continuation?.yield(.error(.serverError(code: err.code, message: err.message)))
            }
            return
        }

        // Fallback for responses without matching id
        if ok, let p = msg.payload, p.type == "hello-ok" {
            let sessionKey = p.snapshot?.sessionDefaults?.mainSessionKey ?? "agent:main:main"
            handshakeComplete = true
            continuation?.yield(.connected(sessionId: "unknown", sessionKey: sessionKey))
        } else if !ok, let err = msg.error {
            continuation?.yield(.error(.serverError(code: err.code, message: err.message)))
        }
    }

    private func failAllAcks(error: Error) {
        let pending = inFlightAcks
        inFlightAcks.removeAll()
        for (_, cont) in pending { cont.resume(throwing: error) }
    }

    // MARK: - Ping

    private func startPingTask() {
        pingTask = Task { [weak self] in
            while await self?.isConnected == true {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    await self?.sendPing()
                } catch { break }
            }
        }
    }

    private func sendPing() {
        guard let task = webSocketTask else { return }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            task.cancel(with: .abnormalClosure, reason: "pong timeout".data(using: .utf8))
        }
        task.sendPing { _ in deadline.cancel() }
    }

    func isHandshakeStuck() -> Bool {
        isConnected && !handshakeComplete
    }
}

// MARK: - Config Reader

/// Read OpenClaw Gateway config from ~/.openclaw/openclaw.json
func readOpenClawGatewayConfig() -> (token: String, port: Int)? {
    let configPath = NSString("~/.openclaw/openclaw.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let gateway = json["gateway"] as? [String: Any],
          let auth = gateway["auth"] as? [String: Any],
          let token = auth["token"] as? String, !token.isEmpty else {
        return nil
    }
    let port = gateway["port"] as? Int ?? 18789
    return (token: token, port: port)
}
