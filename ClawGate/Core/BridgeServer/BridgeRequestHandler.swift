import Foundation
import NIOCore
import NIOHTTP1

final class BridgeRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

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

        if head.method == .GET && path == "/v1/health" {
            writeResponse(context: context, result: core.health())
            return
        }

        guard core.isAuthorized(headers: head.headers) else {
            let payload = APIResponse<String>(
                ok: false,
                result: nil,
                error: ErrorPayload(code: "unauthorized", message: "X-Bridge-Tokenが不正です", retriable: false, failedStep: "auth", details: nil)
            )
            let data = try! JSONEncoder().encode(payload)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(data.count)")
            writeResponse(context: context, result: HTTPResult(status: .unauthorized, headers: headers, body: data))
            return
        }

        if head.method == .POST && path == "/v1/send" {
            writeResponse(context: context, result: core.send(body: body.data))
            return
        }

        if head.method == .GET && path == "/v1/context" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            writeResponse(context: context, result: core.context(adapter: adapter))
            return
        }

        if head.method == .GET && path == "/v1/messages" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
            let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
            writeResponse(context: context, result: core.messages(adapter: adapter, limit: limit))
            return
        }

        if head.method == .GET && path == "/v1/conversations" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limitStr = components?.queryItems?.first(where: { $0.name == "limit" })?.value
            let limit = min(limitStr.flatMap(Int.init) ?? 50, 200)
            writeResponse(context: context, result: core.conversations(adapter: adapter, limit: limit))
            return
        }

        if head.method == .GET && path == "/v1/poll" {
            let since = components?.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int64.init)
            writeResponse(context: context, result: core.poll(since: since))
            return
        }

        if head.method == .GET && path == "/v1/axdump" {
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            writeResponse(context: context, result: core.axdump(adapter: adapter))
            return
        }

        if head.method == .GET && path == "/v1/events" {
            let lastEventID = head.headers.first(name: "Last-Event-ID").flatMap(Int64.init)
            startSSE(context: context, lastEventID: lastEventID)
            return
        }

        let notFound = Data("{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"not found\",\"retriable\":false}}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(notFound.count)")
        writeResponse(context: context, result: HTTPResult(status: .notFound, headers: headers, body: notFound))
    }

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
