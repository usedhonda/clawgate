import Dispatch
import Foundation
import NIOCore
import NIOHTTP1

/// Shared serial queue for all blocking work (AX queries, etc.)
/// Serializes AX access between HTTP handlers and LINEInboundWatcher.
enum BlockingWork {
    static let queue = DispatchQueue(
        label: "com.clawgate.blocking",
        qos: .userInitiated
    )
}

final class BridgeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct RouteKey: Hashable {
        let method: HTTPMethod
        let path: String
        init(_ method: HTTPMethod, _ path: String) {
            self.method = method
            self.path = path
        }
        // HTTPMethod is Equatable but not Hashable in this NIO version, so hash
        // on its stable string form.
        static func == (lhs: RouteKey, rhs: RouteKey) -> Bool {
            lhs.method == rhs.method && lhs.path == rhs.path
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine("\(method)")
            hasher.combine(path)
        }
    }

    /// A blocking-queue endpoint handler. Receives the parsed query components,
    /// the request head, and the body so per-route parsing lives with the route.
    typealias BlockingRouteHandler = (BridgeCore, URLComponents?, HTTPRequestHead, Data) -> HTTPResult

    /// Endpoints answered synchronously on the event loop (health check, config
    /// reads, poll, SSE). Their dispatch stays inline in `handleRequest` because
    /// each has a bespoke position relative to the auth/CSRF/tracking pipeline;
    /// listing them here only feeds the 405/404 route table below.
    private static let eventLoopRoutes: [RouteKey] = [
        RouteKey(.GET, "/v1/health"),
        RouteKey(.GET, "/v1/openclaw-info"),
        RouteKey(.GET, "/v1/config"),
        RouteKey(.GET, "/v1/adapters"),
        RouteKey(.GET, "/v1/stats"),
        RouteKey(.GET, "/v1/autonomous/status"),
        RouteKey(.GET, "/v1/poll"),
        RouteKey(.GET, "/v1/ops/logs"),
        RouteKey(.GET, "/v1/events"),
    ]

    /// Endpoints offloaded to the blocking queue (AX queries, subprocesses,
    /// forwards). This dictionary is the single source of truth for both the
    /// dispatch (see `handleRequest`) and the 405/404 route table.
    private static let blockingRoutes: [RouteKey: BlockingRouteHandler] = [
        RouteKey(.GET, "/v1/debug/line-dedup"): { core, _, _, _ in core.handleLineDedupDebug() },
        RouteKey(.GET, "/v1/debug/line-health"): { core, _, _, _ in core.handleLineHealthDebug() },
        RouteKey(.GET, "/v1/debug/tmux-direct"): { core, _, _, _ in core.handleTmuxDirectDebug() },
        RouteKey(.POST, "/v1/debug/inject"): { core, _, _, body in core.debugInject(body: body) },
        RouteKey(.POST, "/v1/oauth/safari-open"): { core, _, _, body in core.oauthSafariOpen(body: body) },
        RouteKey(.POST, "/v1/send"): { core, _, head, body in
            let traceID = head.headers.first(name: "X-Trace-ID") ?? head.headers.first(name: "x-trace-id")
            return core.send(body: body, traceID: traceID, pathAndQuery: head.uri, headers: head.headers)
        },
        RouteKey(.POST, "/v1/bubble-notify"): { core, _, _, body in core.bubbleNotify(body: body) },
        RouteKey(.GET, "/v1/context"): { core, components, head, _ in
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            return core.context(adapter: adapter, pathAndQuery: head.uri, headers: head.headers)
        },
        RouteKey(.GET, "/v1/messages"): { core, components, head, _ in
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
            let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
            let conversation = components?.queryItems?.first(where: { $0.name == "conversation" })?.value
            return core.messages(adapter: adapter, limit: limit, conversation: conversation, pathAndQuery: head.uri, headers: head.headers)
        },
        RouteKey(.GET, "/v1/conversations"): { core, components, head, _ in
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
            let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
            return core.conversations(adapter: adapter, limit: limit, pathAndQuery: head.uri, headers: head.headers)
        },
        RouteKey(.GET, "/v1/axdump"): { core, components, head, _ in
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            return core.axdump(adapter: adapter, pathAndQuery: head.uri, headers: head.headers)
        },
        RouteKey(.GET, "/v1/doctor"): { core, _, _, _ in core.doctor() },
        RouteKey(.GET, "/v1/tmux/session-mode"): { core, components, _, _ in
            let sessionType = components?.queryItems?.first(where: { $0.name == "session_type" })?.value ?? ""
            let project = components?.queryItems?.first(where: { $0.name == "project" })?.value ?? ""
            return core.tmuxSessionMode(sessionType: sessionType, project: project)
        },
        RouteKey(.PUT, "/v1/tmux/session-mode"): { core, _, _, body in core.setTmuxSessionMode(body: body) },
        RouteKey(.GET, "/v1/tmux/prompt-state"): { core, components, _, _ in
            let project = components?.queryItems?.first(where: { $0.name == "project" })?.value ?? ""
            return core.tmuxPromptState(project: project)
        },
        RouteKey(.POST, "/v1/tproj-msg-deliver"): { core, _, _, body in core.tprojMsgDeliver(body: body) },
        RouteKey(.GET, "/v1/project-context-read"): { core, components, _, _ in
            let cmd = components?.queryItems?.first(where: { $0.name == "cmd" })?.value ?? "list"
            let arg = components?.queryItems?.first(where: { $0.name == "arg" })?.value ?? ""
            let federation = components?.queryItems?.first(where: { $0.name == "federation" })?.value == "1"
            let project = components?.queryItems?.first(where: { $0.name == "project" })?.value ?? ""
            return core.projectContextRead(cmd: cmd, arg: arg, federation: federation, project: project)
        },
        RouteKey(.POST, "/v1/line/ensure-conversation"): { core, _, head, body in
            let traceID = head.headers.first(name: "X-Trace-ID") ?? head.headers.first(name: "x-trace-id")
            return core.ensureLineConversation(body: body, pathAndQuery: head.uri, headers: head.headers, traceID: traceID)
        },
        RouteKey(.POST, "/v1/debug/reset-line-baseline"): { core, _, _, _ in core.resetLineBaseline() },
        RouteKey(.GET, "/v1/ambient/status"): { core, _, _, _ in core.ambientStatus() },
        RouteKey(.POST, "/v1/ambient/stream/start"): { core, _, _, _ in core.ambientStreamStart() },
        RouteKey(.POST, "/v1/ambient/stream/stop"): { core, _, _, _ in core.ambientStreamStop() },
        RouteKey(.POST, "/v1/ambient/capture/pause"): { core, _, _, _ in core.ambientCapturePause() },
        RouteKey(.POST, "/v1/ambient/capture/resume"): { core, _, _, _ in core.ambientCaptureResume() },
        RouteKey(.POST, "/v1/ambient/capture/recover"): { core, _, _, _ in core.ambientCaptureRecover() },
        RouteKey(.POST, "/v1/ambient/capture/_simulate_wedge"): { core, _, _, _ in core.ambientSimulateWedge() },
        RouteKey(.GET, "/v1/ambient/sessions"): { core, _, _, _ in core.ambientSessions() },
        RouteKey(.GET, "/v1/ambient/transcript"): { core, components, _, _ in
            let sessionID = components?.queryItems?.first(where: { $0.name == "session_id" })?.value ?? ""
            return core.ambientTranscript(sessionID: sessionID)
        },
    ]

    /// Canonical (method, path) table used for the 405/404 decision. Derived
    /// from the two route sources above so route membership is declared exactly
    /// once (event-loop routes) or lives with its handler (blocking routes).
    static let routes: [(HTTPMethod, String)] = {
        eventLoopRoutes.map { ($0.method, $0.path) }
            + blockingRoutes.keys.map { ($0.method, $0.path) }
    }()

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()

    private var sseSubscriberID: UUID?

    private let core: BridgeCore

    init(core: BridgeCore) {
        self.core = core
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
            handleRequest(context: context, head: head, body: bodyBuffer)
            requestHead = nil
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let id = sseSubscriberID {
            core.eventBus.unsubscribe(id)
            sseSubscriberID = nil
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        let components = URLComponents(string: "http://localhost\(head.uri)")
        let path = components?.path ?? head.uri

        // Method mismatch check: known path but wrong method -> 405
        let knownPaths = Self.routes.map(\.1)
        if knownPaths.contains(path) && !Self.routes.contains(where: { $0.0 == head.method && $0.1 == path }) {
            writeMethodNotAllowed(context: context)
            return
        }

        // CSRF protection: reject POST requests with Origin header
        if let csrfResult = core.checkOrigin(method: head.method, headers: head.headers) {
            writeResponse(context: context, result: csrfResult)
            return
        }

        // Track meaningful API requests (exclude high-frequency polling/monitoring)
        let noTrack = ["/v1/poll", "/v1/health", "/v1/events", "/v1/stats", "/v1/ops/logs", "/v1/autonomous/status", "/v1/debug/line-dedup", "/v1/debug/line-health", "/v1/debug/tmux-direct"]
        if !noTrack.contains(path) {
            core.statsCollector.increment("api_requests", adapter: "system")
        }

        // Non-blocking: health check responds immediately on event loop
        if head.method == .GET && path == "/v1/health" {
            writeResponse(context: context, result: core.health())
            return
        }

        // Source-IP filter: loopback + Tailscale CGNAT only
        let remoteIP = context.channel.remoteAddress?.ipAddress
        if let authResult = core.checkAuthorization(remoteAddress: remoteIP) {
            writeResponse(context: context, result: authResult)
            return
        }

        // Non-blocking: openclaw-info reads local files only
        if head.method == .GET && path == "/v1/openclaw-info" {
            writeResponse(context: context, result: core.openclawInfo(headers: head.headers))
            return
        }

        // Non-blocking: config responds immediately on event loop (UserDefaults read only)
        if head.method == .GET && path == "/v1/config" {
            writeResponse(context: context, result: core.config())
            return
        }

        // Non-blocking: adapter status is config-derived only
        if head.method == .GET && path == "/v1/adapters" {
            writeResponse(context: context, result: core.adapters())
            return
        }

        // Stats: lightweight in-memory read, respond on event loop
        if head.method == .GET && path == "/v1/stats" {
            let daysStr = components?.queryItems?.first(where: { $0.name == "days" })?.value
            let days = min(daysStr.flatMap(Int.init) ?? 7, 90)
            writeResponse(context: context, result: core.stats(days: days))
            return
        }

        if head.method == .GET && path == "/v1/autonomous/status" {
            writeResponse(context: context, result: core.autonomousStatus())
            return
        }

        // Poll: EventBus.poll() is lightweight (NSLock only), respond on event loop
        if head.method == .GET && path == "/v1/poll" {
            let since = components?.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int64.init)
            let result = core.poll(since: since)
            writeResponse(context: context, result: result)
            return
        }
        // Ops logs should remain available even when blocking work queue is busy.
        if head.method == .GET && path == "/v1/ops/logs" {
            let limit = min(max(components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 20, 1), 200)
            let level = components?.queryItems?.first(where: { $0.name == "level" })?.value
            let traceID = components?.queryItems?.first(where: { $0.name == "trace_id" })?.value
            let result = core.opsLogs(limit: limit, level: level, traceID: traceID)
            writeResponse(context: context, result: result)
            return
        }

        // SSE: start on event loop
        if head.method == .GET && path == "/v1/events" {
            let lastEventID = head.headers.first(name: "Last-Event-ID").flatMap(Int64.init)
            startSSE(context: context, lastEventID: lastEventID)
            return
        }

        // All other endpoints: offload to blocking queue (AX queries, etc.)
        let bodyData = body.data
        let method = head.method

        BlockingWork.queue.async { [self, core] in
            let result: HTTPResult

            if let handler = Self.blockingRoutes[RouteKey(method, path)] {
                result = handler(core, components, head, bodyData)
            } else {
                let notFound = Data("{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"not found\",\"retriable\":false}}".utf8)
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
                headers.add(name: "Content-Length", value: "\(notFound.count)")
                result = HTTPResult(status: .notFound, headers: headers, body: notFound)
            }

            context.eventLoop.execute {
                self.writeResponse(context: context, result: result)
            }
        }
    }

    // MARK: - Helpers

    private func writeMethodNotAllowed(context: ChannelHandlerContext) {
        let payload = APIResponse<String>(
            ok: false,
            result: nil,
            error: ErrorPayload(code: "method_not_allowed", message: "Method not allowed", retriable: false, failedStep: "routing", details: nil)
        )
        let data = try! JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        writeResponse(context: context, result: HTTPResult(status: .methodNotAllowed, headers: headers, body: data))
    }

    // MARK: - SSE

    private func startSSE(context: ChannelHandlerContext, lastEventID: Int64?) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.flush()

        if let lastEventID {
            let replay = core.eventBus.poll(since: lastEventID).events
            for event in replay {
                writeSSE(context: context, event: event)
            }
        } else {
            let initial = core.eventBus.poll(since: nil).events.suffix(3)
            for event in initial {
                writeSSE(context: context, event: event)
            }
        }

        sseSubscriberID = core.eventBus.subscribe { [weak context] event in
            guard let context else { return }
            context.eventLoop.execute {
                self.writeSSE(context: context, event: event)
            }
        }
    }

    private func writeSSE(context: ChannelHandlerContext, event: BridgeEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count + 32)
        buffer.writeString("id: \(event.id)\ndata: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    // MARK: - Response writing

    private func writeResponse(context: ChannelHandlerContext, result: HTTPResult) {
        let responseHead = HTTPResponseHead(version: .http1_1, status: result.status, headers: result.headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: result.body.count)
        buffer.writeBytes(result.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private extension ByteBuffer {
    var data: Data {
        Data(readableBytesView)
    }
}
