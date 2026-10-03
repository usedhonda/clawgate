import Foundation
import CryptoKit
import XCTest
@testable import ClawGate

final class AudioHubMetadataTransportTests: XCTestCase {
    private final class StubProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (HTTPURLResponse, Data))!
        static var requests: [URLRequest] = []
        static var bodies: [Data?] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var collected = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count <= 0 { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            }
            Self.bodies.append(body)
            let (response, data) = Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func provision() throws -> HubProducerProvision {
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "source": "clawgate", "base_url": "https://hub.example.invalid/",
            "bearer_token": "audio-fixture-token", "allowed_domains": ["audio"]
        ])
        return try HubProducerProvision.parse(data, source: "clawgate")
    }

    private func capabilities() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "source": "clawgate", "domains": ["audio"],
            "storage_receipt_version": 1, "max_event_bytes": 20 * 1024 * 1024,
            "max_chunk_bytes": 4 * 1024 * 1024, "finalize_replay_safe": true
        ])
    }

    private func receipt(externalID: String, eventID: String = "00000000-0000-4000-8000-000000000001") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["storage_receipt": [
            "receipt_version": 1, "source": "clawgate", "external_id": externalID,
            "event_id": eventID, "sha256": NSNull(), "byte_length": 0, "ingest_sequence": 1
        ]])
    }

    private func record(original: AudioHubOutbox.OriginalReference? = nil,
                        envelope: Data? = nil) -> AudioHubOutbox.PendingRecord {
        let sourceUUID = "00000000-0000-4000-8000-000000000010"
        let externalID = AudioHubOutbox.externalID(sourceUUID: sourceUUID, sourceRecordRef: "source", revision: "revision")
        let body = envelope ?? (try! JSONSerialization.data(withJSONObject: [
            "domain": "audio", "external_id": externalID, "kind": "clawgate.audio-transcript.v1",
            "metadata": ["source_uuid": sourceUUID, "source_record_ref": "source", "revision_ref": "revision"],
            "source": "clawgate"
        ], options: [.sortedKeys]))
        let hash = CryptoKit.SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return AudioHubOutbox.PendingRecord(externalID: externalID, sourceRecordRef: "source", revision: "revision", envelope: body, bodySHA256: hash, original: original)
    }

    private func transport() throws -> AudioHubMetadataTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return AudioHubMetadataTransport(provision: try provision(), configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubProtocol.requests = []
        StubProtocol.bodies = []
    }

    func testSuccessUsesCapabilitiesAndUnchangedEnvelopeAndReceipt() async throws {
        let expected = try capabilities()
        let item = record()
        let ack = try receipt(externalID: item.externalID)
        StubProtocol.handler = { request in
            if request.url?.path == "/v1/capabilities" { return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, expected) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer audio-fixture-token")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, ack)
        }
        _ = try await transport().send(item)
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(StubProtocol.bodies.last, item.envelope)
    }

    func testNon2xxRetainsRecordByNotReturningAck() async throws {
        StubProtocol.handler = { request in
            if request.url?.path == "/v1/capabilities" { return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try! self.capabilities()) }
            let wrong = try! self.receipt(externalID: "other")
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, wrong)
        }
        do { _ = try await transport().send(record()); XCTFail("expected failure") }
        catch let error as AudioHubMetadataTransport.Failure { XCTAssertEqual(error, .unexpectedStatus) }
    }

    func testMismatchedReceiptIsRejected() async throws {
        StubProtocol.handler = { request in
            if request.url?.path == "/v1/capabilities" { return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try! self.capabilities()) }
            let wrong = try! self.receipt(externalID: "other")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, wrong)
        }
        do { _ = try await transport().send(record()); XCTFail("expected failure") }
        catch let error as AudioHubMetadataTransport.Failure { XCTAssertEqual(error, .invalidReceipt) }
    }

    func testRedirectIsRefused() async throws {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example.invalid/v1/capabilities"])!
            return (response, Data())
        }
        do { _ = try await transport().send(record()); XCTFail("expected failure") }
        catch let error as AudioHubMetadataTransport.Failure { XCTAssertEqual(error, .capabilitiesRejected) }
    }

    func testOriginalRecordIsRejectedBeforeNetwork() async throws {
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m/audio/x.m4a", sha256: String(repeating: "a", count: 64), byteLength: 1)
        do { _ = try await transport().send(record(original: original)); XCTFail("expected failure") }
        catch let error as AudioHubMetadataTransport.Failure { XCTAssertEqual(error, .invalidRecord) }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testOversizedResponseIsRejected() async throws {
        StubProtocol.handler = { request in
            let data = Data(repeating: 0x7f, count: AudioHubMetadataTransport.maxResponseBytes + 1)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        do { _ = try await transport().send(record()); XCTFail("expected failure") }
        catch let error as AudioHubMetadataTransport.Failure { XCTAssertEqual(error, .responseTooLarge) }
    }
}
