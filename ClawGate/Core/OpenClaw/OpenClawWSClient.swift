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
    private var pingDeadline: Task<Void, Error>?
    private var pingInFlight = false
    private var inFlightAcks: [String: CheckedContinuation<Void, Error>] = [:]
    /// Requests that need the response payload back (e.g. ambient.ingest's
    /// stateAccepted), not just an ok/err ACK.
    private var inFlightResponses: [String: CheckedContinuation<IncomingPayload?, Error>] = [:]

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

        // Wait for Gateway to be ready. Gateway init (bonjour/telegram/model-pricing)
        // can take ~30s after a restart — longer than the 10s handshake timeout below.
        // Without this poll we would tear down the WS before Gateway sends connect.challenge,
        // then reconnect into the same trap (logged 5+ times over 2026-04-22/23).
        try await waitForGatewayReady(url: url)

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
            await self.teardown()
        }

        return stream
    }

    func disconnect() {
        teardown()
    }

    /// Poll Gateway's HTTP /ready endpoint with exponential backoff until 200 OK or total ~60s elapsed.
    /// Derives the HTTP base URL from the ws URL (ws→http, wss→https).
    private func waitForGatewayReady(url wsURL: URL) async throws {
        guard var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            throw OpenClawError.connectionFailed("Invalid WS URL for /ready probe")
        }
        comps.scheme = (wsURL.scheme == "wss") ? "https" : "http"
        comps.path = "/ready"
        comps.query = nil
        guard let readyURL = comps.url else {
            throw OpenClawError.connectionFailed("Failed to derive /ready URL")
        }

        // Probe schedule: 500ms, 2s, 5s, 10s, 10s, 10s, 10s, 10s — total ~57.5s
        let delaysNs: [UInt64] = [500_000_000, 2_000_000_000, 5_000_000_000]
        let steadyDelayNs: UInt64 = 10_000_000_000
        let maxElapsed: TimeInterval = 60
        let started = Date()
        var attempt = 0
        let probeSession = URLSessionConfiguration.ephemeral
        probeSession.timeoutIntervalForRequest = 5
        probeSession.timeoutIntervalForResource = 5
        let client = URLSession(configuration: probeSession)
        defer { client.finishTasksAndInvalidate() }

        while Date().timeIntervalSince(started) < maxElapsed {
            try Task.checkCancellation()
            var req = URLRequest(url: readyURL)
            req.timeoutInterval = 5
            if let (_, resp) = try? await client.data(for: req),
               let http = resp as? HTTPURLResponse,
               http.statusCode == 200 {
                if attempt > 0 {
                    logger.info("Gateway /ready OK after \(attempt, privacy: .public) probe(s)")
                }
                return
            }
            let delay = attempt < delaysNs.count ? delaysNs[attempt] : steadyDelayNs
            try await Task.sleep(nanoseconds: delay)
            attempt += 1
        }
        throw OpenClawError.connectionFailed("Gateway not ready within \(Int(maxElapsed))s")
    }

    private func teardown() {
        isConnected = false
        handshakeComplete = false
        pingTask?.cancel()
        pingTask = nil
        pingDeadline?.cancel()
        pingDeadline = nil
        pingInFlight = false
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

    func chatHistory(sessionKey: String, limit: Int = 50) async throws -> [[String: Any]] {
        let requestId = UUID().uuidString
        let request = GatewayRequest(
            type: "req", id: requestId, method: "chat.history",
            params: ChatHistoryParams(sessionKey: sessionKey, limit: limit)
        )
        try await sendJSON(request)
        // History comes back as a response — handled in handleResponse
        return []  // Messages delivered via event stream
    }

    func subscribeToSession(sessionKey: String) async throws {
        let request = GatewayRequest(
            type: "req", id: UUID().uuidString,
            method: "sessions.messages.subscribe",
            params: SessionSubscribeParams(key: sessionKey)
        )
        try await sendJSON(request)
    }

    /// Generic RPC: send a request and return the response payload (ok:true),
    /// or throw the server error. Used by ambient.ingest, which needs
    /// payload.stateAccepted rather than a bare ACK.
    func request<T: Encodable>(method: String, params: T) async throws -> IncomingPayload? {
        let requestId = UUID().uuidString
        let req = GatewayRequest(type: "req", id: requestId, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            inFlightResponses[requestId] = cont
            Task {
                do {
                    try await self.sendJSON(req)
                } catch {
                    if let c = self.inFlightResponses.removeValue(forKey: requestId) {
                        c.resume(throwing: error)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: Self.chatSendAckTimeout)
                if let c = self.inFlightResponses.removeValue(forKey: requestId) {
                    c.resume(throwing: OpenClawError.timeout)
                }
            }
        }
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
            NSLog("[Pet] Loading device identity...")
            let identity = try OpenClawDeviceIdentity.loadOrCreate()
            NSLog("[Pet] Device identity loaded, building connect request...")
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
                    minProtocol: 3, maxProtocol: 4,
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
            NSLog("[Pet] Connect request sent, waiting for hello-ok...")
        } catch {
            NSLog("[Pet] Connect request FAILED: %@", "\(error)")
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
                    teardown()
                }
                break
            }
        }
    }

    private func handleData(_ data: Data) async {
        // Try standard decode first
        if let msg = try? JSONDecoder().decode(IncomingMessage.self, from: data) {
            switch msg.type {
            case "event":
                guard let eventName = msg.event else { return }
                await handleEvent(eventName, payload: msg.payload)
            case "res":
                handleResponse(msg)
            default:
                break
            }
            return
        }

        // Fallback: try raw JSON parse for responses with unknown fields (e.g. chat.history)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "res",
              let ok = json["ok"] as? Bool, ok,
              let payload = json["payload"] as? [String: Any],
              let rawMessages = payload["messages"] as? [[String: Any]] else {
            NSLog("[Pet] Failed to decode message: %@", String(data: data.prefix(200), encoding: .utf8) ?? "?")
            return
        }

        // Parse chat.history manually
        let messages: [OpenClawChatMessage] = rawMessages.compactMap { m in
            guard let role = m["role"] as? String else { return nil }
            var text = m["text"] as? String
            if text == nil, let content = m["content"] as? [[String: Any]] {
                text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            }
            guard let text, !text.isEmpty else { return nil }
            let chatRole: OpenClawChatMessage.Role = role == "user" ? .user : .assistant
            let ts = Self.parseTimestamp(m["createdAt"] ?? m["timestamp"])
            return OpenClawChatMessage(id: m["id"] as? String ?? UUID().uuidString, role: chatRole, text: text, timestamp: ts)
        }
        if !messages.isEmpty {
            continuation?.yield(.history(messages))
        }
        return
    }

    private static func parseTimestamp(_ value: Any?) -> Date {
        if let str = value as? String {
            // Try ISO8601 with fractional seconds
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: str) { return d }
            // Try ISO8601 without fractional seconds
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let d = f2.date(from: str) { return d }
            // Try epoch string
            if let ms = Int64(str) {
                return Date(timeIntervalSince1970: Double(ms) / (ms > 9_999_999_999 ? 1000.0 : 1.0))
            }
        }
        if let num = value as? NSNumber {
            let ms = num.int64Value
            return Date(timeIntervalSince1970: Double(ms) / (ms > 9_999_999_999 ? 1000.0 : 1.0))
        }
        return Date()
    }

    private func handleEvent(_ name: String, payload: IncomingPayload?) async {
        switch name {
        case "connect.challenge":
            NSLog("[Pet] Received connect.challenge, sending connect request...")
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
                    let isProactive = payload?.sessionKey?.contains("proactive") == true
                    let msg = OpenClawChatMessage(id: runId, role: .assistant, text: text, isProactive: isProactive)
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
        NSLog("[Pet] handleResponse: ok=%d id=%@ type=%@ error=%@", ok ? 1 : 0, responseId, msg.payload?.type ?? "nil", msg.error?.message ?? "none")

        // Payload-returning requests (ambient.ingest etc.)
        if !responseId.isEmpty, let cont = inFlightResponses.removeValue(forKey: responseId) {
            if ok {
                cont.resume(returning: msg.payload)
            } else if let err = msg.error {
                cont.resume(throwing: OpenClawError.serverError(code: err.code, message: err.message))
            } else {
                cont.resume(throwing: OpenClawError.unknown("Request failed"))
            }
            return
        }

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

        // Chat history response
        if ok, let historyMsgs = msg.payload?.messages {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let messages = historyMsgs.compactMap { hm -> OpenClawChatMessage? in
                guard let role = hm.role else { return nil }
                let text = hm.text ?? hm.content?.compactMap({ $0.type == "text" ? $0.text : nil }).joined(separator: "\n\n") ?? ""
                guard !text.isEmpty else { return nil }
                let chatRole: OpenClawChatMessage.Role = role == "user" ? .user : .assistant
                let ts = (hm.createdAt ?? hm.timestamp).flatMap { isoFormatter.date(from: $0) } ?? Date()
                return OpenClawChatMessage(id: hm.id ?? UUID().uuidString, role: chatRole, text: text, timestamp: ts)
            }
            if !messages.isEmpty {
                continuation?.yield(.history(messages))
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
        let pendingResponses = inFlightResponses
        inFlightResponses.removeAll()
        for (_, cont) in pendingResponses { cont.resume(throwing: error) }
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
        guard let task = webSocketTask, !pingInFlight else { return }
        pingInFlight = true

        pingDeadline?.cancel()
        pingDeadline = Task { [weak self] in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.handlePingTimeout()
        }

        task.sendPing { [weak self] error in
            Task { [weak self] in
                await self?.handlePingComplete(error: error)
            }
        }
    }

    private func handlePingComplete(error: Error?) {
        pingInFlight = false
        pingDeadline?.cancel()
        pingDeadline = nil
        if let error {
            // Immediate ping error means the socket is no longer viable.
            // Without teardown here, receiveLoop stays blocked on task.receive()
            // and the connection sits in a false-.connected state forever
            // (observed: 10h silent drop with CLOSED socket, no reconnect).
            logger.warning("Ping failed: \(error.localizedDescription, privacy: .public) — tearing down")
            teardown()
        }
    }

    private func handlePingTimeout() {
        guard pingInFlight else { return }
        logger.warning("Ping timeout — tearing down connection")
        pingInFlight = false
        pingDeadline = nil
        teardown()
    }

    func isHandshakeStuck() -> Bool {
        isConnected && !handshakeComplete
    }
}

// MARK: - Config Reader

/// Read OpenClaw Gateway config from ~/.openclaw/openclaw.json
func readOpenClawGatewayConfig() -> (token: String, port: Int, host: String)? {
    guard let info = OpenClawGatewayInfo.load() else { return nil }
    return (token: info.token, port: info.port, host: info.host ?? "127.0.0.1")
}
