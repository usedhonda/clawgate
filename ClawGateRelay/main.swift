import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

struct RelayConfig {
    let host: String
    let port: Int
    let federationPort: Int
    let gatewayToken: String
    let federationToken: String
    let tmuxEnabled: Bool
    let ccStatusURL: String
    let tmuxSessionModes: [String: String]

    static func fromArgs() -> RelayConfig {
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }
        func values(_ key: String) -> [String] {
            var out: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == key, i + 1 < args.count {
                    out.append(args[i + 1])
                    i += 2
                    continue
                }
                i += 1
            }
            return out
        }
        func boolValue(_ key: String, defaultValue: Bool) -> Bool {
            guard let raw = value(key)?.lowercased() else { return defaultValue }
            return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
        }

        let host = value("--host") ?? "0.0.0.0"
        let port = Int(value("--port") ?? "8765") ?? 8765
        let federationPort = Int(value("--federation-port") ?? "\(port + 1)") ?? (port + 1)
        let gatewayToken = value("--token") ?? ""
        let federationToken = value("--federation-token") ?? gatewayToken
        let tmuxEnabled = boolValue("--tmux-enabled", defaultValue: true)
        let ccStatusURL = value("--cc-status-url") ?? "ws://localhost:8080/ws/sessions"
        var tmuxSessionModes: [String: String] = [:]
        for item in values("--tmux-mode") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let mode = parts[1]
                if mode == "ignore" || mode == "observe" || mode == "auto" || mode == "autonomous" {
                    tmuxSessionModes[parts[0]] = mode
                }
            }
        }

        return RelayConfig(
            host: host,
            port: port,
            federationPort: federationPort,
            gatewayToken: gatewayToken,
            federationToken: federationToken,
            tmuxEnabled: tmuxEnabled,
            ccStatusURL: ccStatusURL,
            tmuxSessionModes: tmuxSessionModes
        )
    }
}

struct RelayEvent: Codable {
    let id: Int64
    let type: String
    let adapter: String
    let payload: [String: String]
    let observedAt: String
}

struct RelaySendPayload: Codable {
    let conversationHint: String
    let text: String
    let enterToSend: Bool

    enum CodingKeys: String, CodingKey {
        case conversationHint = "conversation_hint"
        case text
        case enterToSend = "enter_to_send"
    }
}

struct RelaySendRequest: Codable {
    let adapter: String
    let action: String
    let payload: RelaySendPayload
}

enum RelayTmuxShell {
    private static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    private static var tmuxPath: String {
        candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/tmux"
    }

    static func sendKeys(target: String, text: String, enter: Bool) throws {
        _ = try run(arguments: ["send-keys", "-t", target, "-l", text])
        if enter {
            _ = try run(arguments: ["send-keys", "-t", target, "Enter"])
        }
    }

    static func listSessions() throws -> [String] {
        let output = try run(arguments: ["list-sessions", "-F", "#{session_name}"])
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func capturePane(target: String, lines: Int = 50) throws -> String {
        try run(arguments: ["capture-pane", "-t", target, "-p", "-S", "-\(lines)"])
    }

    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RelayTmuxShell", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: err.isEmpty ? out : err,
            ])
        }
        return out
    }
}

struct RelayCCSession {
    let id: String
    let project: String
    let status: String
    let tmuxTarget: String?
    let isAttached: Bool
    let attentionLevel: Int
    let waitingReason: String?
}

final class RelayCCStatusClient: NSObject, URLSessionWebSocketDelegate {
    var onStateChange: ((RelayCCSession, String, String) -> Void)?
    var onSessionsChanged: (() -> Void)?

    private let url: URL
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var sessions: [String: RelayCCSession] = [:]
    private var shouldReconnect = true
    private var reconnectAttempts = 0

    init(urlString: String) {
        self.url = URL(string: urlString) ?? URL(string: "ws://localhost:8080/ws/sessions")!
        super.init()
    }

    func connect() {
        shouldReconnect = true
        reconnectAttempts = 0
        doConnect()
    }

    func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    func allSessions() -> [RelayCCSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted { $0.project < $1.project }
    }

    func session(forProject project: String) -> RelayCCSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.project == project && $0.isAttached }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        reconnectAttempts = 0
        receiveLoop()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        scheduleReconnect()
    }

    private func doConnect() {
        guard shouldReconnect else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        urlSession = session
        webSocketTask = task
        task.resume()
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 3.0, 60.0)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.doConnect()
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text): self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure:
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "sessions.list":
            guard let arr = obj["sessions"] as? [[String: Any]] else { return }
            var next: [String: RelayCCSession] = [:]
            arr.compactMap(parseSession).forEach { next[$0.id] = $0 }
            lock.lock()
            sessions = next
            lock.unlock()
            onSessionsChanged?()
        case "session.updated":
            guard let raw = obj["session"] as? [String: Any], let session = parseSession(raw) else { return }
            lock.lock()
            let old = sessions[session.id]?.status ?? "unknown"
            sessions[session.id] = session
            lock.unlock()
            if old != session.status {
                onStateChange?(session, old, session.status)
            }
            onSessionsChanged?()
        case "session.added":
            guard let raw = obj["session"] as? [String: Any], let session = parseSession(raw) else { return }
            lock.lock()
            sessions[session.id] = session
            lock.unlock()
            onSessionsChanged?()
        case "session.removed":
            guard let id = obj["session_id"] as? String else { return }
            lock.lock()
            sessions.removeValue(forKey: id)
            lock.unlock()
            onSessionsChanged?()
        default:
            break
        }
    }

    private func parseSession(_ dict: [String: Any]) -> RelayCCSession? {
        guard (dict["type"] as? String ?? "") == "claude_code" else { return nil }
        guard let id = dict["id"] as? String, let project = dict["project"] as? String else { return nil }
        let tmux = dict["tmux"] as? [String: Any]
        let tmuxSession = tmux?["session"] as? String
        let tmuxWindow = (tmux?["window"]).flatMap { "\($0)" }
        let tmuxPane = (tmux?["pane"]).flatMap { "\($0)" }
        let target: String?
        if let s = tmuxSession, let w = tmuxWindow, let p = tmuxPane {
            target = "\(s):\(w).\(p)"
        } else if let s = tmuxSession, let w = tmuxWindow {
            target = "\(s):\(w)"
        } else {
            target = tmuxSession
        }
        return RelayCCSession(
            id: id,
            project: project,
            status: dict["status"] as? String ?? "unknown",
            tmuxTarget: target,
            isAttached: tmux?["is_attached"] as? Bool ?? false,
            attentionLevel: dict["attention_level"] as? Int ?? 0,
            waitingReason: dict["waiting_reason"] as? String
        )
    }
}

final class RelayTmuxRouter {
    private let ccClient: RelayCCStatusClient
    private let eventBus: RelayEventBus
    private let enabled: Bool
    private let sessionModes: [String: String]

    init(config: RelayConfig, eventBus: RelayEventBus) {
        self.ccClient = RelayCCStatusClient(urlString: config.ccStatusURL)
        self.eventBus = eventBus
        self.enabled = config.tmuxEnabled
        self.sessionModes = config.tmuxSessionModes
    }

    func start() {
        guard enabled else { return }
        ccClient.onStateChange = { [weak self] session, oldStatus, newStatus in
            guard let self else { return }
            if oldStatus == "running" && newStatus == "waiting_input" {
                _ = self.eventBus.append(type: "inbound_message", adapter: "tmux", payload: [
                    "project": session.project,
                    "status": "completed",
                    "source": "completion",
                ])
            }
            if newStatus == "waiting_input", let reason = session.waitingReason, reason == "permission_prompt" {
                let mode = self.mode(for: session.project)
                if mode == "auto" || mode == "autonomous" {
                    _ = self.eventBus.append(type: "inbound_message", adapter: "tmux", payload: [
                        "project": session.project,
                        "status": "waiting_input",
                        "source": "permission_prompt",
                    ])
                }
            }
        }
        ccClient.connect()
    }

    func stop() {
        ccClient.disconnect()
    }

    func send(_ payload: RelaySendPayload) throws -> [String: Any] {
        guard enabled else {
            throw NSError(domain: "RelayTmuxRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: "tmux adapter is disabled"])
        }
        let project = payload.conversationHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            throw NSError(domain: "RelayTmuxRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: "conversation_hint is required"])
        }
        let mode = mode(for: project)
        if mode == "ignore" {
            throw NSError(domain: "RelayTmuxRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: "session is not enabled"])
        }
        if mode == "observe" {
            throw NSError(domain: "RelayTmuxRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: "session is read-only"])
        }
        guard let session = ccClient.session(forProject: project) else {
            throw NSError(domain: "RelayTmuxRouter", code: 503, userInfo: [NSLocalizedDescriptionKey: "session not found"])
        }
        guard session.status == "waiting_input" else {
            throw NSError(domain: "RelayTmuxRouter", code: 503, userInfo: [NSLocalizedDescriptionKey: "session is busy"])
        }
        guard let target = session.tmuxTarget else {
            throw NSError(domain: "RelayTmuxRouter", code: 503, userInfo: [NSLocalizedDescriptionKey: "tmux target missing"])
        }

        try RelayTmuxShell.sendKeys(target: target, text: payload.text, enter: payload.enterToSend)
        _ = eventBus.append(type: "outbound_message", adapter: "tmux", payload: [
            "project": project,
            "text": String(payload.text.prefix(80)),
            "tmux_target": target,
        ])
        return [
            "adapter": "tmux",
            "action": "send_message",
            "message_id": UUID().uuidString,
            "timestamp": FederationMessage.now(),
        ]
    }

    func context() -> [String: Any] {
        let active = activeSessions()
        return [
            "adapter": "tmux",
            "conversation_name": active.first?.project as Any,
            "has_input_field": active.contains { $0.status == "waiting_input" },
            "window_title": "tmux(\(active.count) sessions)",
            "timestamp": FederationMessage.now(),
        ]
    }

    func conversations(limit: Int) -> [String: Any] {
        let active = activeSessions().prefix(limit)
        let rows = active.enumerated().map { i, s in
            [
                "name": s.project,
                "y_order": i,
                "has_unread": s.status == "waiting_input" && s.attentionLevel > 0,
            ] as [String: Any]
        }
        return [
            "adapter": "tmux",
            "conversations": rows,
            "count": rows.count,
            "timestamp": FederationMessage.now(),
        ]
    }

    func messages(limit: Int, project: String?) throws -> [String: Any] {
        let targetProject = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? activeSessions().first?.project
        guard let targetProject, !targetProject.isEmpty else {
            return [
                "adapter": "tmux",
                "conversation_name": NSNull(),
                "messages": [],
                "message_count": 0,
                "timestamp": FederationMessage.now(),
            ]
        }
        guard let session = ccClient.session(forProject: targetProject), let target = session.tmuxTarget else {
            throw NSError(domain: "RelayTmuxRouter", code: 503, userInfo: [NSLocalizedDescriptionKey: "session not found"])
        }
        let captured = try RelayTmuxShell.capturePane(target: target, lines: limit)
        let lines = captured.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rows = lines.suffix(limit).enumerated().map { i, line in
            ["text": line, "sender": "other", "y_order": i] as [String: Any]
        }
        return [
            "adapter": "tmux",
            "conversation_name": targetProject,
            "messages": rows,
            "message_count": rows.count,
            "timestamp": FederationMessage.now(),
        ]
    }

    private func activeSessions() -> [RelayCCSession] {
        let all = ccClient.allSessions().filter { $0.isAttached }
        return all.filter { mode(for: $0.project) != "ignore" }
    }

    private func mode(for project: String) -> String {
        sessionModes[project] ?? "ignore"
    }
}

struct RelayHTTPResult {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: Data
}

struct PendingCommand {
    let id: String
    let promise: EventLoopPromise<FederationResponsePayload>
}

final class RelayEventBus {
    private let lock = NSLock()
    private var events: [RelayEvent] = []
    private var nextID: Int64 = 1
    private var subscribers: [UUID: (RelayEvent) -> Void] = [:]
    private let maxEvents = 2000

    @discardableResult
    func append(type: String, adapter: String, payload: [String: String]) -> RelayEvent {
        lock.lock()
        let event = RelayEvent(
            id: nextID,
            type: type,
            adapter: adapter,
            payload: payload,
            observedAt: ISO8601DateFormatter().string(from: Date())
        )
        nextID += 1
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        let callbacks = Array(subscribers.values)
        lock.unlock()

        callbacks.forEach { $0(event) }
        return event
    }

    func appendForwarded(_ event: RelayEvent) {
        _ = append(type: event.type, adapter: event.adapter, payload: event.payload)
    }

    func poll(since: Int64?) -> (events: [RelayEvent], nextCursor: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let filtered: [RelayEvent]
        if let since {
            filtered = events.filter { $0.id > since }
        } else {
            filtered = events
        }
        return (filtered, nextID - 1)
    }

    @discardableResult
    func subscribe(_ callback: @escaping (RelayEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = callback
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}

final class RelayState {
    private let lock = NSLock()
    private var federationChannel: Channel?
    private var pending: [String: EventLoopPromise<FederationResponsePayload>] = [:]

    let eventBus = RelayEventBus()

    func setFederationChannel(_ channel: Channel?) {
        lock.lock()
        federationChannel = channel
        if channel == nil {
            let failures = pending.values
            pending.removeAll()
            lock.unlock()
            failures.forEach { $0.fail(RelayError.federationUnavailable) }
            return
        }
        lock.unlock()
    }

    func hasFederationConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return federationChannel != nil
    }

    func sendCommand(_ command: FederationCommandPayload, on eventLoop: EventLoop) -> EventLoopFuture<FederationResponsePayload> {
        lock.lock()
        guard let channel = federationChannel else {
            lock.unlock()
            return eventLoop.makeFailedFuture(RelayError.federationUnavailable)
        }

        let promise = eventLoop.makePromise(of: FederationResponsePayload.self)
        pending[command.id] = promise
        lock.unlock()

        let envelope = FederationEnvelope(type: "command", timestamp: FederationMessage.now(), payload: command)
        guard let data = try? JSONEncoder().encode(envelope), let text = String(data: data, encoding: .utf8) else {
            resolvePending(id: command.id, result: .failure(RelayError.encodeFailed))
            return promise.futureResult
        }

        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(frame, promise: nil)
        }

        return promise.futureResult
    }

    func completeCommand(_ response: FederationResponsePayload) {
        resolvePending(id: response.id, result: .success(response))
    }

    private func resolvePending(id: String, result: Result<FederationResponsePayload, Error>) {
        lock.lock()
        let promise = pending.removeValue(forKey: id)
        lock.unlock()
        guard let promise else { return }
        switch result {
        case .success(let response): promise.succeed(response)
        case .failure(let error): promise.fail(error)
        }
    }
}

enum RelayError: Error {
    case federationUnavailable
    case encodeFailed
}

struct FederationEnvelope<T: Codable>: Codable {
    let type: String
    let timestamp: String
    let payload: T
}

struct FederationResponsePayload: Codable {
    let id: String
    let status: Int
    let headers: [String: String]
    let body: String
}

struct FederationCommandPayload: Codable {
    let id: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: String?
}

struct FederationEventPayload: Codable {
    let event: RelayEvent
}

enum FederationMessage {
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

final class RelayHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: RelayConfig
    private let state: RelayState
    private let tmuxRouter: RelayTmuxRouter

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private var sseSubscriberID: UUID?

    init(config: RelayConfig, state: RelayState, tmuxRouter: RelayTmuxRouter) {
        self.config = config
        self.state = state
        self.tmuxRouter = tmuxRouter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
        case .body(var chunk):
            bodyBuffer.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else { return }
            handle(context: context, head: head, body: Data(bodyBuffer.readableBytesView))
            requestHead = nil
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let id = sseSubscriberID {
            state.eventBus.unsubscribe(id)
            sseSubscriberID = nil
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let components = URLComponents(string: "http://localhost\(head.uri)")
        let path = components?.path ?? head.uri

        if path == "/v1/health" && head.method == .GET {
            let body = jsonData([
                "ok": true,
                "version": "0.1.0-relay",
                "federation_connected": state.hasFederationConnection(),
                "node_role": "client",
                "line_local_enabled": false,
            ])
            write(context: context, status: .ok, body: body)
            return
        }

        if !authorized(head.headers) {
            let body = jsonData(["ok": false, "error": ["code": "unauthorized", "message": "missing or invalid bearer token", "retriable": false]])
            write(context: context, status: .unauthorized, body: body)
            return
        }

        if path == "/v1/poll" && head.method == .GET {
            let since = components?.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int64.init)
            let polled = state.eventBus.poll(since: since)
            let body = jsonData([
                "ok": true,
                "events": polled.events.map { [
                    "id": $0.id,
                    "type": $0.type,
                    "adapter": $0.adapter,
                    "payload": $0.payload,
                    "observedAt": $0.observedAt,
                ] },
                "next_cursor": polled.nextCursor,
            ])
            write(context: context, status: .ok, body: body)
            return
        }

        if path == "/v1/events" && head.method == .GET {
            startSSE(context: context)
            return
        }

        if let localResult = handleLocalAdapterRoute(head: head, path: path, components: components, body: body) {
            write(context: context, status: localResult.status, headers: localResult.headers, body: localResult.body)
            return
        }

        let command = FederationCommandPayload(
            id: UUID().uuidString,
            method: head.method.rawValue,
            path: head.uri,
            headers: headersDict(head.headers),
            body: body.isEmpty ? nil : String(data: body, encoding: .utf8)
        )

        state.sendCommand(command, on: context.eventLoop)
            .flatMapErrorThrowing { _ in
                FederationResponsePayload(
                    id: command.id,
                    status: 503,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: "{\"ok\":false,\"error\":{\"code\":\"federation_unavailable\",\"message\":\"federation connection is not active\",\"retriable\":true}}"
                )
            }
            .whenSuccess { response in
                context.eventLoop.execute {
                    var headers = HTTPHeaders()
                    for (k, v) in response.headers { headers.add(name: k, value: v) }
                    let data = Data(response.body.utf8)
                    if !headers.contains(name: "Content-Length") {
                        headers.add(name: "Content-Length", value: "\(data.count)")
                    }
                    if !headers.contains(name: "Content-Type") {
                        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
                    }
                    self.write(context: context, status: HTTPResponseStatus(statusCode: response.status), headers: headers, body: data)
                }
            }
    }

    private func handleLocalAdapterRoute(head: HTTPRequestHead, path: String, components: URLComponents?, body: Data) -> RelayHTTPResult? {
        if head.method == .POST && path == "/v1/send" {
            guard let request = try? JSONDecoder().decode(RelaySendRequest.self, from: body) else {
                return jsonError(status: .badRequest, code: "invalid_json", message: "invalid request json", retriable: false)
            }
            if request.adapter == "line" {
                return nil
            }
            if request.adapter != "tmux" {
                return jsonError(status: .badRequest, code: "adapter_not_found", message: "adapter not found", retriable: false)
            }
            if request.action != "send_message" {
                return jsonError(status: .badRequest, code: "unsupported_action", message: "only send_message is supported", retriable: false)
            }
            do {
                let result = try tmuxRouter.send(request.payload)
                let response: [String: Any] = [
                    "ok": true,
                    "result": result,
                ]
                return jsonResult(status: .ok, object: response)
            } catch {
                return jsonError(
                    status: .serviceUnavailable,
                    code: "tmux_command_failed",
                    message: "tmux send failed",
                    retriable: true,
                    details: String(describing: error)
                )
            }
        }

        if head.method == .GET && path == "/v1/context" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            if adapter == "line" { return nil }
            if adapter != "tmux" {
                return jsonError(status: .badRequest, code: "adapter_not_found", message: "adapter not found", retriable: false)
            }
            let result: [String: Any] = [
                "ok": true,
                "result": tmuxRouter.context(),
            ]
            return jsonResult(status: .ok, object: result)
        }

        if head.method == .GET && path == "/v1/conversations" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            if adapter == "line" { return nil }
            if adapter != "tmux" {
                return jsonError(status: .badRequest, code: "adapter_not_found", message: "adapter not found", retriable: false)
            }
            let limit = min(components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50, 200)
            let result: [String: Any] = [
                "ok": true,
                "result": tmuxRouter.conversations(limit: limit),
            ]
            return jsonResult(status: .ok, object: result)
        }

        if head.method == .GET && path == "/v1/messages" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            if adapter == "line" { return nil }
            if adapter != "tmux" {
                return jsonError(status: .badRequest, code: "adapter_not_found", message: "adapter not found", retriable: false)
            }
            let limit = min(components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50, 200)
            let project = components?.queryItems?.first(where: { $0.name == "project" })?.value
            do {
                let result: [String: Any] = [
                    "ok": true,
                    "result": try tmuxRouter.messages(limit: limit, project: project),
                ]
                return jsonResult(status: .ok, object: result)
            } catch {
                return jsonError(
                    status: .serviceUnavailable,
                    code: "tmux_command_failed",
                    message: "tmux capture failed",
                    retriable: true,
                    details: String(describing: error)
                )
            }
        }

        return nil
    }

    private func startSSE(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.flush()

        let initial = state.eventBus.poll(since: nil).events.suffix(10)
        for event in initial {
            writeSSE(context: context, event: event)
        }

        sseSubscriberID = state.eventBus.subscribe { [weak context] event in
            guard let context else { return }
            context.eventLoop.execute { [weak self] in
                self?.writeSSE(context: context, event: event)
            }
        }
    }

    private func writeSSE(context: ChannelHandlerContext, event: RelayEvent) {
        guard let payload = try? JSONEncoder().encode(event) else { return }
        var buffer = context.channel.allocator.buffer(capacity: payload.count + 32)
        buffer.writeString("id: \(event.id)\ndata: ")
        buffer.writeBytes(payload)
        buffer.writeString("\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.count)")
        write(context: context, status: status, headers: headers, body: body)
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, headers: HTTPHeaders, body: Data) {
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func authorized(_ headers: HTTPHeaders) -> Bool {
        let token = config.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return true }
        return headers.first(name: "Authorization") == "Bearer \(token)"
    }

    private func headersDict(_ headers: HTTPHeaders) -> [String: String] {
        var dict: [String: String] = [:]
        for h in headers {
            dict[h.name] = h.value
        }
        return dict
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }

    private func jsonResult(status: HTTPResponseStatus, object: Any) -> RelayHTTPResult {
        let body = jsonData(object)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.count)")
        return RelayHTTPResult(status: status, headers: headers, body: body)
    }

    private func jsonError(status: HTTPResponseStatus, code: String, message: String, retriable: Bool, details: String? = nil) -> RelayHTTPResult {
        var error: [String: Any] = [
            "code": code,
            "message": message,
            "retriable": retriable,
        ]
        if let details {
            error["details"] = details
        }
        return jsonResult(status: status, object: ["ok": false, "error": error])
    }
}

final class RelayWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let state: RelayState

    init(state: RelayState) {
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        print("[relay] federation websocket handler added")
        state.setFederationChannel(context.channel)
        state.eventBus.append(type: "federation_connected", adapter: "relay", payload: ["state": "connected"])
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        print("[relay] federation websocket handler removed")
        state.setFederationChannel(nil)
        state.eventBus.append(type: "federation_disconnected", adapter: "relay", payload: ["state": "disconnected"])
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else {
            return
        }

        var payloadBuffer = frame.unmaskedData
        guard let text = payloadBuffer.readString(length: payloadBuffer.readableBytes) else {
            return
        }

        guard let payload = text.data(using: String.Encoding.utf8),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = root["type"] as? String else {
            return
        }

        if type == "response",
           let p = root["payload"] as? [String: Any],
           let id = p["id"] as? String,
           let status = p["status"] as? Int,
           let body = p["body"] as? String {
            let headers = p["headers"] as? [String: String] ?? [:]
            state.completeCommand(FederationResponsePayload(id: id, status: status, headers: headers, body: body))
            return
        }

        if type == "event",
           let p = root["payload"] as? [String: Any],
           let eventObj = p["event"] as? [String: Any],
           let adapter = eventObj["adapter"] as? String,
           let eventType = eventObj["type"] as? String,
           let payloadDict = eventObj["payload"] as? [String: String] {
            state.eventBus.append(type: eventType, adapter: adapter, payload: payloadDict)
            return
        }

        if type == "hello" {
            let welcome: [String: Any] = [
                "type": "welcome",
                "timestamp": FederationMessage.now(),
                "payload": ["server_version": "0.1.0-relay"],
            ]
            if let encoded = try? JSONSerialization.data(withJSONObject: welcome),
               let text = String(data: encoded, encoding: .utf8) {
                var out = context.channel.allocator.buffer(capacity: text.utf8.count)
                out.writeString(text)
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: out)), promise: nil)
            }
        }
    }
}

let config = RelayConfig.fromArgs()
let state = RelayState()
let tmuxRouter = RelayTmuxRouter(config: config, eventBus: state.eventBus)
tmuxRouter.start()
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

let upgrader = NIOWebSocketServerUpgrader(
    shouldUpgrade: { channel, head in
        guard head.uri.hasPrefix("/federation") else {
            return channel.eventLoop.makeFailedFuture(NIOWebSocketUpgradeError.invalidUpgradeHeader)
        }
        print("[relay] federation upgrade requested: \(head.uri)")
        let expected = config.federationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if expected.isEmpty {
            print("[relay] federation auth disabled")
            return channel.eventLoop.makeSucceededFuture([:])
        }
        let auth = head.headers.first(name: "Authorization") ?? ""
        guard auth == "Bearer \(expected)" else {
            print("[relay] federation auth rejected")
            return channel.eventLoop.makeFailedFuture(NIOWebSocketUpgradeError.invalidUpgradeHeader)
        }
        print("[relay] federation auth accepted")
        return channel.eventLoop.makeSucceededFuture([:])
    },
    upgradePipelineHandler: { channel, _ in
        return channel.pipeline.addHandler(RelayWebSocketHandler(state: state))
    }
)

let federationUpgrade = NIOHTTPServerUpgradeConfiguration(
    upgraders: [upgrader],
    completionHandler: { _ in }
)

let httpBootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(RelayHTTPHandler(config: config, state: state, tmuxRouter: tmuxRouter))
        }
    }
    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

let federationBootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: federationUpgrade)
    }
    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

let httpChannel = try httpBootstrap.bind(host: config.host, port: config.port).wait()
let federationChannel = try federationBootstrap.bind(host: config.host, port: config.federationPort).wait()
print("ClawGateRelay started on \(config.host):\(config.port) [http]")
print("ClawGateRelay federation endpoint on \(config.host):\(config.federationPort)/federation [ws]")
print("Gateway auth: \(config.gatewayToken.isEmpty ? "disabled" : "enabled")")
print("Federation auth: \(config.federationToken.isEmpty ? "disabled" : "enabled")")

try httpChannel.closeFuture.wait()
try federationChannel.closeFuture.wait()
tmuxRouter.stop()
try group.syncShutdownGracefully()
