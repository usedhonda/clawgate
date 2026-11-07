import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
import XCTest

/// The bridge's admission handler sees a request only after HTTP decoding.
/// Guard the dependency boundaries that application-level checks cannot cover.
final class NIOParserBoundaryTests: XCTestCase {
    func testDefaultHTTPDecoderBoundsAggregateHeaders() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
        defer { _ = try? channel.finish() }
        var request = channel.allocator.buffer(capacity: 100_000)
        request.writeString("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n")
        // Each field is small; only their combined size exceeds the bound.
        for index in 0..<200 {
            request.writeString("X-Field-\(index): \(String(repeating: "a", count: 512))\r\n")
        }
        request.writeString("\r\n")

        XCTAssertThrowsError(try channel.writeInbound(request)) { error in
            XCTAssertEqual(error as? HTTPParserError, .headerOverflow)
        }
        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self),
                     "oversized headers must fail before a request reaches admission")
    }

    func testWebSocketDecoderRejectsUnrepresentableLengthWithoutTrapping() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(WebSocketFrameDecoder()))
        defer { _ = try? channel.finish() }
        var frame = channel.allocator.buffer(capacity: 10)
        frame.writeInteger(UInt8(0x82))
        frame.writeInteger(UInt8(127))
        frame.writeInteger(UInt64.max, endianness: .big)

        XCTAssertThrowsError(try channel.writeInbound(frame)) { error in
            XCTAssertEqual(error as? NIOWebSocketError, .invalidFrameLength)
        }
        XCTAssertNil(try channel.readInbound(as: WebSocketFrame.self))
    }
}
