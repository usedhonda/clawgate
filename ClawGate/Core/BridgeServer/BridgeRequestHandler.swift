import Dispatch
import Foundation
import NIOCore
import NIOHTTP1

/// Shared serial queue for all blocking work (AX queries, Keychain access, etc.)
/// Serializes AX access between HTTP handlers and LINEInboundWatcher.
enum BlockingWork {
    static let queue = DispatchQueue(
        label: "com.clawgate.blocking",
        qos: .userInitiated
    )
}

final class BridgeRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let routes: [(HTTPMethod, String)] = [
        (.GET, "/v1/health"),
        (.GET, "/v1/poll"),
        (.POST, "/v1/pair/generate"),
        (.POST, "/v1/pair/request"),
        (.POST, "/v1/send"),
        (.GET, "/v1/context"),
        (.GET, "/v1/messages"),
        (.GET, "/v1/conversations"),
        (.GET, "/v1/axdump"),
        (.GET, "/v1/doctor"),
        (.GET, "/v1/events"),
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

        // Non-blocking: health check responds immediately on event loop
        if head.method == .GET && path == "/v1/health" {
            writeResponse(context: context, result: core.health())
            return
        }

        // Poll: EventBus.poll() is lightweight (NSLock only), but auth check
        // hits Keychain so we offload the whole thing to avoid blocking on
        // SecItemCopyMatching if a Keychain UI dialog appears.
        if head.method == .GET && path == "/v1/poll" {
            let requestHeaders = head.headers
            let since = components?.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int64.init)
            BlockingWork.queue.async { [self, core] in
                guard core.isAuthorized(headers: requestHeaders) else {
                    context.eventLoop.execute {
                        self.writeUnauthorized(context: context)
                    }
                    return
                }
                let result = core.poll(since: since)
                context.eventLoop.execute {
                    self.writeResponse(context: context, result: result)
                }
            }
            return
        }

        // Generate pairing code - no auth, no Keychain, safe on event loop
        if head.method == .POST && path == "/v1/pair/generate" {
            writeResponse(context: context, result: core.generatePairCode())
            return
        }

        // Pairing endpoint - no auth required, but Keychain access -> offload
        if head.method == .POST && path == "/v1/pair/request" {
            let bodyData = body.data
            let headers = head.headers
            offloadToBlockingQueue(context: context) { [core] in
                core.pair(body: bodyData, headers: headers)
            }
            return
        }

        // SSE: auth check offloaded, then SSE starts on event loop
        if head.method == .GET && path == "/v1/events" {
            let lastEventID = head.headers.first(name: "Last-Event-ID").flatMap(Int64.init)
            let requestHeaders = head.headers
            BlockingWork.queue.async { [self, core] in
                guard core.isAuthorized(headers: requestHeaders) else {
                    context.eventLoop.execute {
                        self.writeUnauthorized(context: context)
                    }
                    return
                }
                context.eventLoop.execute {
                    self.startSSE(context: context, lastEventID: lastEventID)
                }
            }
            return
        }

        // All other endpoints: auth + business logic offloaded to blocking queue
        let bodyData = body.data
        let requestHeaders = head.headers
        let method = head.method

        BlockingWork.queue.async { [self, core] in
            guard core.isAuthorized(headers: requestHeaders) else {
                context.eventLoop.execute {
                    self.writeUnauthorized(context: context)
                }
                return
            }

            let result: HTTPResult

            if method == .POST && path == "/v1/send" {
                result = core.send(body: bodyData)
            } else if method == .GET && path == "/v1/context" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                result = core.context(adapter: adapter)
            } else if method == .GET && path == "/v1/messages" {
                let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
                let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
                let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
                result = core.messages(adapter: adapter, limit: limit)
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

    private func offloadToBlockingQueue(
        context: ChannelHandlerContext,
        work: @escaping () -> HTTPResult
    ) {
        BlockingWork.queue.async {
            let result = work()
            context.eventLoop.execute {
                self.writeResponse(context: context, result: result)
            }
        }
    }

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

    private func writeUnauthorized(context: ChannelHandlerContext) {
        let payload = APIResponse<String>(
            ok: false,
            result: nil,
            error: ErrorPayload(code: "unauthorized", message: "Invalid X-Bridge-Token", retriable: false, failedStep: "auth", details: nil)
        )
        let data = try! JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        writeResponse(context: context, result: HTTPResult(status: .unauthorized, headers: headers, body: data))
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
