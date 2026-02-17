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

    private static let routes: [(HTTPMethod, String)] = [
        (.GET, "/v1/health"),
        (.GET, "/v1/config"),
        (.GET, "/v1/poll"),
        (.GET, "/v1/stats"),
        (.GET, "/v1/ops/logs"),
        (.POST, "/v1/send"),
        (.GET, "/v1/context"),
        (.GET, "/v1/messages"),
        (.GET, "/v1/conversations"),
        (.GET, "/v1/axdump"),
        (.GET, "/v1/doctor"),
        (.GET, "/v1/openclaw-info"),
        (.GET, "/v1/events"),
        (.POST, "/v1/debug/inject"),
    ]

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
        let noTrack = ["/v1/poll", "/v1/health", "/v1/events", "/v1/stats", "/v1/ops/logs"]
        if !noTrack.contains(path) {
            core.statsCollector.increment("api_requests", adapter: "system")
        }

        // Non-blocking: health check responds immediately on event loop
        if head.method == .GET && path == "/v1/health" {
            writeResponse(context: context, result: core.health())
            return
        }

        // Optional auth (enabled only in remote access mode)
        if let authResult = core.checkAuthorization(headers: head.headers) {
            writeResponse(context: context, result: authResult)
            return
        }

        // Non-blocking: openclaw-info reads local files only
        if head.method == .GET && path == "/v1/openclaw-info" {
            writeResponse(context: context, result: core.openclawInfo())
            return
        }

        // Non-blocking: config responds immediately on event loop (UserDefaults read only)
        if head.method == .GET && path == "/v1/config" {
            writeResponse(context: context, result: core.config())
            return
        }

        // Stats: lightweight in-memory read, respond on event loop
        if head.method == .GET && path == "/v1/stats" {
            let daysStr = components?.queryItems?.first(where: { $0.name == "days" })?.value
            let days = min(daysStr.flatMap(Int.init) ?? 7, 90)
            writeResponse(context: context, result: core.stats(days: days))
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

            if method == .POST && path == "/v1/debug/inject" {
                result = core.debugInject(body: bodyData)
            } else if method == .POST && path == "/v1/send" {
                let traceID = head.headers.first(name: "X-Trace-ID") ?? head.headers.first(name: "x-trace-id")
                result = core.send(body: bodyData, traceID: traceID)
            } else if method == .GET && path == "/v1/context" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                result = core.context(adapter: adapter)
            } else if method == .GET && path == "/v1/messages" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
                let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
                let conversation = components?.queryItems?.first(where: { $0.name == "conversation" })?.value
                result = core.messages(adapter: adapter, limit: limit, conversation: conversation)
            } else if method == .GET && path == "/v1/conversations" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
                let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
                result = core.conversations(adapter: adapter, limit: limit)
            } else if method == .GET && path == "/v1/axdump" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                result = core.axdump(adapter: adapter)
            } else if method == .GET && path == "/v1/doctor" {
                result = core.doctor()
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
