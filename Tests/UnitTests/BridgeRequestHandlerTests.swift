import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import ClawGate

final class BridgeRequestHandlerTests: XCTestCase {
    func testRejectsAdvertisedOversizeBeforeReadingBody() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }
        var head = healthHead()
        head.headers.add(name: "Content-Length", value: String(BridgeRequestHandler.maximumRequestBodyBytes + 1))
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        let result = try readResponse(channel)
        XCTAssertEqual(result.head.status.code, 413)
        XCTAssertEqual(result.head.headers.first(name: "Connection"), "close")
        XCTAssertEqual(result.error?.code, "request_body_too_large")
    }

    func testChunkedBodyCannotGrowPastLimit() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }
        var head = healthHead()
        head.headers.add(name: "Transfer-Encoding", value: "chunked")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        var chunk = ByteBufferAllocator().buffer(capacity: BridgeRequestHandler.maximumRequestBodyBytes)
        chunk.writeRepeatingByte(65, count: BridgeRequestHandler.maximumRequestBodyBytes)
        try channel.writeInbound(HTTPServerRequestPart.body(chunk))
        XCTAssertNil(try channel.readOutbound(as: HTTPServerResponsePart.self))
        var extra = ByteBufferAllocator().buffer(capacity: 1)
        extra.writeInteger(UInt8(66))
        try channel.writeInbound(HTTPServerRequestPart.body(extra))
        XCTAssertEqual(try readResponse(channel).head.status.code, 413)
    }

    func testAcceptedBodyAtLimitCompletesAndCancelsDeadline() throws {
        let loop = EmbeddedEventLoop()
        let channel = try makeChannel(loop: loop)
        defer { _ = try? channel.finish() }
        var head = healthHead()
        head.headers.add(name: "Content-Length", value: String(BridgeRequestHandler.maximumRequestBodyBytes))
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        var body = ByteBufferAllocator().buffer(capacity: BridgeRequestHandler.maximumRequestBodyBytes)
        body.writeRepeatingByte(65, count: BridgeRequestHandler.maximumRequestBodyBytes)
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        XCTAssertEqual(try readResponse(channel).head.status, .ok)
        loop.advanceTime(by: .seconds(16))
        XCTAssertNil(try channel.readOutbound(as: HTTPServerResponsePart.self))
    }

    func testIncompleteBodyTimesOutWithoutEndPart() throws {
        let loop = EmbeddedEventLoop()
        let channel = try makeChannel(loop: loop)
        defer { _ = try? channel.finish() }
        var head = healthHead()
        head.headers.add(name: "Content-Length", value: "20")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        loop.advanceTime(by: .seconds(15))
        let result = try readResponse(channel)
        XCTAssertEqual(result.head.status, .requestTimeout)
        XCTAssertEqual(result.error?.code, "request_timeout")
    }

    func testSourceAdmissionRunsBeforeBodyBuffering() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }
        // Embedded channels have no peer address. A protected endpoint must
        // reject this at the head even if a caller never finishes its body.
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/send", headers: HTTPHeaders([("Host", "127.0.0.1:8765"), ("Content-Length", "100")]))
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        XCTAssertEqual(try readResponse(channel).error?.code, "forbidden_source_ip")
    }

    func testBrowserReadsAndPutRejectedBeforeAnyBody() throws {
        let requests: [(HTTPMethod, String)] = [(.GET, "/v1/openclaw-info"), (.PUT, "/v1/tmux/session-mode")]
        for (method, path) in requests {
            let channel = try makeChannel()
            defer { _ = try? channel.finish() }
            let head = HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: HTTPHeaders([("Host", "127.0.0.1:8765"), ("Origin", "https://attacker.example")]))
            try channel.writeInbound(HTTPServerRequestPart.head(head))
            XCTAssertEqual(try readResponse(channel).error?.code, "browser_origin_rejected")
        }
    }

    func testRebindingHostBlockedEvenWithoutBrowserHeaders() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }
        var head = healthHead()
        head.headers.replaceOrAdd(name: "Host", value: "attacker.example:8765")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        XCTAssertEqual(try readResponse(channel).error?.code, "invalid_host")
    }

    private func healthHead() -> HTTPRequestHead {
        HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/health", headers: HTTPHeaders([("Host", "127.0.0.1:8765")]))
    }

    private func makeChannel(loop: EmbeddedEventLoop = EmbeddedEventLoop()) throws -> EmbeddedChannel {
        let suite = "clawgate.tests.request.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clawgate-request-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let config = ConfigStore(defaults: defaults)
        let core = BridgeCore(eventBus: EventBus(), registry: AdapterRegistry(adapters: []), logger: AppLogger(configStore: config), opsLogStore: OpsLogStore(logDirectory: directory.appendingPathComponent("logs")), configStore: config, statsCollector: StatsCollector(filePath: directory.appendingPathComponent("stats.json").path))
        return EmbeddedChannel(handler: BridgeRequestHandler(core: core), loop: loop)
    }

    private func readResponse(_ channel: EmbeddedChannel) throws -> (head: HTTPResponseHead, error: ErrorPayload?) {
        let first = try channel.readOutbound(as: HTTPServerResponsePart.self)
        guard case .head(let head)? = first else {
            XCTFail("Expected an HTTP response before completing the request")
            throw ResponseError.missingHead
        }
        var body = Data()
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .body(.byteBuffer(let buffer)): body.append(contentsOf: buffer.readableBytesView)
            case .end: return (head, (try? JSONDecoder().decode(APIResponse<String>.self, from: body))?.error)
            default: break
            }
        }
        XCTFail("Expected an HTTP response end")
        throw ResponseError.missingEnd
    }

    private enum ResponseError: Error { case missingHead, missingEnd }
}
