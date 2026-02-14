import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket

/// Server-side federation handler: accepts WebSocket connections from Client ClawGates
/// and routes events/commands between server and connected clients.
final class FederationServer {
    private let lock = NSLock()
    private var clients: [String: Channel] = [:]           // clientID → Channel
    private var projectRoutes: [String: String] = [:]      // project → clientID
    private var pending: [String: EventLoopPromise<FederationResponsePayload>] = [:]

    let eventBus: EventBus
    private let configStore: ConfigStore
    private let core: BridgeCore
    private let logger: AppLogger
    private var eventSubscriptionID: UUID?

    init(eventBus: EventBus, configStore: ConfigStore, core: BridgeCore, logger: AppLogger) {
        self.eventBus = eventBus
        self.configStore = configStore
        self.core = core
        self.logger = logger
    }

    func start() {
        eventSubscriptionID = eventBus.subscribe { [weak self] event in
            self?.broadcastLocalEvent(event)
        }
        logger.log(.info, "FederationServer started, accepting clients")
    }

    func stop() {
        if let id = eventSubscriptionID {
            eventBus.unsubscribe(id)
            eventSubscriptionID = nil
        }
        lock.lock()
        let channels = clients.values
        clients.removeAll()
        projectRoutes.removeAll()
        let failures = pending.values
        pending.removeAll()
        lock.unlock()
        for channel in channels {
            channel.close(mode: .all, promise: nil)
        }
        for promise in failures {
            promise.fail(FederationServerError.shutdownInProgress)
        }
        logger.log(.info, "FederationServer stopped")
    }

    // MARK: - Client management

    func addClient(_ clientID: String, channel: Channel) {
        lock.lock()
        clients[clientID] = channel
        lock.unlock()
        logger.log(.info, "FederationServer: client connected: \(clientID)")
        emitStatus(state: "client_connected", detail: "clientID=\(clientID) total=\(clientCount())")
    }

    func removeClient(_ clientID: String) {
        lock.lock()
        clients.removeValue(forKey: clientID)
        // Remove project routes pointing to this client
        projectRoutes = projectRoutes.filter { $0.value != clientID }
        // Fail pending commands for this client
        let clientPending = pending.filter { _ in true }  // We don't track which client owns which pending
        lock.unlock()
        logger.log(.info, "FederationServer: client disconnected: \(clientID)")
        emitStatus(state: "client_disconnected", detail: "clientID=\(clientID) total=\(clientCount())")
    }

    func clientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    func hasConnectedClient() -> Bool {
        clientCount() > 0
    }

    func hasRoute(for project: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return projectRoutes[project] != nil
    }

    // MARK: - Event handling from clients

    func handleClientEvent(from clientID: String, adapter: String, eventType: String, payload: [String: String]) {
        // Update project routing
        let project = payload["project"] ?? payload["conversation"] ?? ""
        if !project.isEmpty {
            lock.lock()
            projectRoutes[project] = clientID
            lock.unlock()
        }

        // Mode resolution: local config overrides, then trust the client's event mode
        if adapter == "tmux" {
            let sessionType = payload["session_type"] ?? "claude_code"
            let localMode = configStore.load().tmuxSessionModes[AppConfig.modeKey(sessionType: sessionType, project: project)]  // nil = not configured
            let eventMode = payload["mode"] ?? "ignore"
            let effectiveMode = localMode ?? eventMode  // local config wins if set, otherwise trust client
            if effectiveMode == "ignore" {
                logger.log(.debug, "FederationServer: dropping ignored tmux event for \(project) (local=\(localMode ?? "nil") event=\(eventMode))")
                return
            }
        }

        var marked = payload
        marked["_from_federation"] = "1"
        _ = eventBus.append(type: eventType, adapter: adapter, payload: marked)
        let source = payload["source"] ?? "-"
        logger.log(.info, "FederationServer: client event: \(adapter).\(eventType) project=\(project) source=\(source)")
    }

    // MARK: - Command forwarding to clients

    func sendCommand(forProject project: String, _ command: FederationCommandPayload) -> EventLoopFuture<FederationResponsePayload> {
        lock.lock()
        guard let clientID = projectRoutes[project], let channel = clients[clientID] else {
            // No explicit route — broadcast to all clients (first success wins)
            // This handles: fresh restart (empty routes), stale connections, multi-client setups
            let allChannels = Array(clients.values)
            lock.unlock()
            guard let first = allChannels.first else {
                let el = MultiThreadedEventLoopGroup.singleton.any()
                return el.makeFailedFuture(FederationServerError.noRouteForProject(project))
            }
            logger.log(.info, "No route for project=\(project), broadcasting to \(allChannels.count) client(s)")
            let promise = first.eventLoop.makePromise(of: FederationResponsePayload.self)
            pending[command.id] = promise
            sendFrame(channel: first, type: "command", payload: command)
            return promise.futureResult
        }
        let promise = channel.eventLoop.makePromise(of: FederationResponsePayload.self)
        pending[command.id] = promise
        lock.unlock()
        sendFrame(channel: channel, type: "command", payload: command)
        return promise.futureResult
    }

    // MARK: - Response handling from clients

    func completeCommand(_ response: FederationResponsePayload) {
        lock.lock()
        let promise = pending.removeValue(forKey: response.id)
        lock.unlock()
        promise?.succeed(response)
    }

    // MARK: - Broadcast local events to all clients

    private func broadcastLocalEvent(_ event: BridgeEvent) {
        // Don't echo federation-origin events back
        if event.payload["_from_federation"] == "1" { return }
        // Only forward tmux and outbound events
        guard event.adapter == "tmux" || event.type == "outbound_message" || event.type == "inbound_message" else { return }

        let eventPayload = FederationEventPayload(event: event)
        let envelope = FederationEnvelope(type: "event", timestamp: FederationMessage.now(), payload: eventPayload)
        guard let data = try? JSONEncoder().encode(envelope), let text = String(data: data, encoding: .utf8) else {
            return
        }

        lock.lock()
        let channels = Array(clients.values)
        lock.unlock()

        for channel in channels {
            channel.eventLoop.execute {
                var buffer = channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                channel.writeAndFlush(frame, promise: nil)
            }
        }
    }

    private func sendFrame<T: Codable>(channel: Channel, type: String, payload: T) {
        let envelope = FederationEnvelope(type: type, timestamp: FederationMessage.now(), payload: payload)
        guard let data = try? JSONEncoder().encode(envelope), let text = String(data: data, encoding: .utf8) else {
            return
        }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(frame, promise: nil)
        }
    }

    private func emitStatus(state: String, detail: String) {
        _ = eventBus.append(
            type: "federation_status",
            adapter: "federation",
            payload: [
                "state": state,
                "detail": String(detail.prefix(160)),
            ]
        )
    }
}

enum FederationServerError: Error, CustomStringConvertible {
    case noRouteForProject(String)
    case shutdownInProgress

    var description: String {
        switch self {
        case .noRouteForProject(let project): return "No federation client route for project: \(project)"
        case .shutdownInProgress: return "Federation server is shutting down"
        }
    }
}

// MARK: - WebSocket Handler

final class FederationServerHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let federationServer: FederationServer
    private let logger: AppLogger
    private let clientID: String

    init(federationServer: FederationServer, logger: AppLogger) {
        self.federationServer = federationServer
        self.logger = logger
        self.clientID = UUID().uuidString
    }

    func handlerAdded(context: ChannelHandlerContext) {
        federationServer.addClient(clientID, channel: context.channel)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        federationServer.removeClient(clientID)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var buf = frame.unmaskedData
            guard let text = buf.readString(length: buf.readableBytes) else { return }
            handleText(text, context: context)

        case .ping:
            var pongData = context.channel.allocator.buffer(capacity: 0)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            context.close(promise: nil)

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(.warning, "FederationServerHandler error: \(error)")
        context.close(promise: nil)
    }

    private func handleText(_ text: String, context: ChannelHandlerContext) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "hello":
            // Send welcome response
            let welcome: [String: Any] = [
                "type": "welcome",
                "timestamp": FederationMessage.now(),
                "payload": ["server_version": "0.1.0"],
            ]
            if let encoded = try? JSONSerialization.data(withJSONObject: welcome),
               let welcomeText = String(data: encoded, encoding: .utf8) {
                var out = context.channel.allocator.buffer(capacity: welcomeText.utf8.count)
                out.writeString(welcomeText)
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: out)), promise: nil)
            }

        case "ping":
            let pong = FederationEnvelope(type: "pong", timestamp: FederationMessage.now(), payload: ["ok": true])
            if let encoded = try? JSONEncoder().encode(pong), let pongText = String(data: encoded, encoding: .utf8) {
                var out = context.channel.allocator.buffer(capacity: pongText.utf8.count)
                out.writeString(pongText)
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: out)), promise: nil)
            }

        case "event":
            guard let payloadObj = json["payload"] as? [String: Any],
                  let eventObj = payloadObj["event"] as? [String: Any],
                  let adapter = eventObj["adapter"] as? String,
                  let eventType = eventObj["type"] as? String else {
                logger.log(.warning, "FederationServerHandler: malformed event payload")
                return
            }
            let rawPayload = eventObj["payload"] as? [String: Any] ?? [:]
            var payload: [String: String] = [:]
            for (key, value) in rawPayload {
                if let s = value as? String { payload[key] = s }
                else if let n = value as? NSNumber { payload[key] = n.stringValue }
                else if let b = value as? Bool { payload[key] = b ? "true" : "false" }
                else { payload[key] = String(describing: value) }
            }
            federationServer.handleClientEvent(from: clientID, adapter: adapter, eventType: eventType, payload: payload)

        case "response":
            guard let p = json["payload"] as? [String: Any],
                  let id = p["id"] as? String,
                  let status = p["status"] as? Int,
                  let body = p["body"] as? String else {
                return
            }
            let headers = p["headers"] as? [String: String] ?? [:]
            federationServer.completeCommand(FederationResponsePayload(id: id, status: status, headers: headers, body: body))

        default:
            logger.log(.debug, "FederationServerHandler: unhandled message type: \(type)")
        }
    }
}
