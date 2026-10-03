import XCTest
import CryptoKit
@testable import ClawGate

final class AudioHubOriginalTransportTests: XCTestCase {
    private final class Stub: URLProtocol {
        static var handler: ((URLRequest, Data) throws -> (Int, Data))!
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while stream.hasBytesAvailable {
                        let n = stream.read(&buffer, maxLength: buffer.count)
                        if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n))
                    }
                }
                let (code, data) = try Self.handler(request, body)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
                    httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    private let source = "00000000-0000-4000-8000-000000000010"
    private let uploadID = "00000000-0000-4000-8000-000000000020"
    private let eventID = "00000000-0000-4000-8000-000000000030"
    private let jobID = "00000000-0000-4000-8000-000000000040"
    private var root: URL!
    private var file: URL { root.appendingPathComponent("originals/meetings/example/audio/clip.bin") }
    private var queueRoot: URL { root.appendingPathComponent("queue") }
    private var controlRoot: URL { root.appendingPathComponent("control") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { Stub.handler = nil; try? FileManager.default.removeItem(at: root) }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func queue() throws -> AudioHubOutbox { try .init(directory: queueRoot, maxMetadataBytes: 32_000, sourceUUID: source) }
    private func control() throws -> AudioHubControlStore { try .init(directory: controlRoot, sourceUUID: source, maxControlBytes: 16_000) }
    private func transport() throws -> AudioHubOriginalTransport {
        let provision = try HubProducerProvision.parse(json([
            "schema_version": 1, "source": "clawgate", "base_url": "https://hub.example.invalid/",
            "bearer_token": "original-fixture-token", "allowed_domains": ["audio"]]), source: "clawgate")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        return .init(provision: provision, configuration: config)
    }
    private func caps() throws -> Data { try json([
        "version": 1, "source": "clawgate", "domains": ["audio"], "storage_receipt_version": 1,
        "max_event_bytes": 20 * 1024 * 1024, "max_chunk_bytes": 4 * 1024 * 1024, "finalize_replay_safe": true,
        "processing_receipt_version": 1, "processing_pipeline": "fixture-v1", "audio_original_kinds": ["selected-meeting-original"]]) }
    private func enqueue(_ bytes: Data, into queue: AudioHubOutbox) throws -> AudioHubOutbox.PendingRecord {
        try bytes.write(to: file)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/example/audio/clip.bin", sha256: sha, byteLength: Int64(bytes.count))
        _ = try queue.enqueue(sourceRecordRef: "selected-fixture", revision: "sha256:" + sha, original: original) { uuid, id in
            try self.json(["source": "clawgate", "domain": "audio", "kind": "selected-meeting-original",
                "external_id": id, "occurred_at": "2020-01-01T00:00:00Z", "blob_sha256": sha,
                "metadata": ["source_uuid": uuid, "source_record_ref": "selected-fixture", "revision_ref": "sha256:" + sha, "privacy_flags": NSNull()]])
        }
        return try XCTUnwrap(queue.pending(limit: 1).first)
    }
    private func receipt(_ record: AudioHubOutbox.PendingRecord, includeIntent: Bool = true, job: String? = nil) throws -> Data {
        var body: [String: Any] = ["storage_receipt": ["receipt_version": 1, "source": "clawgate",
            "external_id": record.externalID, "event_id": eventID, "sha256": record.original!.sha256,
            "byte_length": record.original!.byteLength, "ingest_sequence": 1]]
        if includeIntent { body["processing_receipt"] = ["receipt_version": 1, "intent_committed": true,
            "job_id": job ?? jobID, "original_event_id": eventID, "pipeline_version": "fixture-v1", "state": "pending"] }
        return try json(body)
    }

    func testLostChunkReplyReplaysSameUploadAndRequiresBothReceipts() async throws {
        var q = try queue(); var c = try control()
        let data = Data(repeating: 42, count: 4 * 1024 * 1024 + 3)
        let record = try enqueue(data, into: q)
        var stored = Data(); var lost = false; var intents = false; var creates = 0; var puts: [Int64] = []
        Stub.handler = { request, body in
            let path = request.url!.path
            if path == "/v1/capabilities" { return (200, try self.caps()) }
            if path == "/v1/uploads" { creates += 1; return (201, try self.json(["upload_id": self.uploadID])) }
            if request.httpMethod == "PUT" {
                let offset = Int64(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
                puts.append(offset); XCTAssertLessThanOrEqual(body.count, 4 * 1024 * 1024)
                if Int(offset) == stored.count { stored.append(body) }
                else { XCTAssertEqual(Data(stored[Int(offset)..<(Int(offset) + body.count)]), body) }
                if !lost { lost = true; throw URLError(.networkConnectionLost) }
                return (200, try self.json(["next_offset": stored.count]))
            }
            if path.hasSuffix("/finalize") { XCTAssertEqual(stored, data); return (200, try self.json(["blob_sha256": record.original!.sha256])) }
            XCTAssertEqual(path, "/v1/events"); XCTAssertEqual(body, record.envelope)
            return (201, try self.receipt(record, includeIntent: intents))
        }
        do { _ = try await transport().deliverOne(outbox: q, control: c, originalsRoot: root.appendingPathComponent("originals")); XCTFail("lost reply") } catch { }
        XCTAssertEqual(try q.pending(limit: 1).first, record)
        q = try queue(); c = try control()
        do { _ = try await transport().deliverOne(outbox: q, control: c, originalsRoot: root.appendingPathComponent("originals")); XCTFail("missing intent") }
        catch { XCTAssertEqual(error as? AudioHubOriginalTransport.Failure, .invalidReceipt) }
        XCTAssertEqual(try q.pending(limit: 1).first, record)
        q = try queue(); c = try control(); intents = true
        let delivered = try await transport().deliverOne(outbox: q, control: c, originalsRoot: root.appendingPathComponent("originals"))
        XCTAssertTrue(delivered); XCTAssertEqual(creates, 1); XCTAssertEqual(puts, [0, 0, 4 * 1024 * 1024])
        XCTAssertTrue(try queue().pending(limit: 1).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testMissingOriginalRecordsGapWithoutPostOrAck() async throws {
        let q = try queue(); let c = try control(); let record = try enqueue(Data("fixture".utf8), into: q)
        try FileManager.default.removeItem(at: file)
        Stub.handler = { request, _ in XCTAssertEqual(request.httpMethod, "GET"); return (200, try self.caps()) }
        do { _ = try await transport().deliverOne(outbox: q, control: c, originalsRoot: root.appendingPathComponent("originals")); XCTFail("missing source") }
        catch { XCTAssertEqual(error as? AudioHubOriginalReader.Error, .missingOriginal) }
        let saved = try control().startUpload(record: record, pipeline: "fixture-v1")
        XCTAssertEqual(saved.gapReason, "source_original_missing"); XCTAssertNil(saved.binding)
        XCTAssertEqual(saved.gapCoverage, "excluded")
        XCTAssertEqual(try queue().pending(limit: 1).first, record)
    }

    func testPersistedIntentBindingCannotChangeOnRetry() async throws {
        let q = try queue(); let c = try control(); let record = try enqueue(Data("fixture".utf8), into: q)
        var nextJob = jobID
        Stub.handler = { request, _ in
            switch request.url!.path {
            case "/v1/capabilities": return (200, try self.caps())
            case "/v1/uploads": return (201, try self.json(["upload_id": self.uploadID]))
            case "/v1/events": return (200, try self.receipt(record, job: nextJob))
            default:
                if request.httpMethod == "PUT" { return (200, try self.json(["next_offset": record.original!.byteLength])) }
                return (200, try self.json(["blob_sha256": record.original!.sha256]))
            }
        }
        // Receipt committed to control, crash before outbox acknowledge.
        _ = try await transport().send(record, control: c, originalsRoot: root.appendingPathComponent("originals"))
        nextJob = "00000000-0000-4000-8000-000000000099"
        do { _ = try await transport().deliverOne(outbox: queue(), control: control(), originalsRoot: root.appendingPathComponent("originals")); XCTFail("changed job") }
        catch { XCTAssertEqual(error as? AudioHubOriginalTransport.Failure, .invalidReceipt) }
        XCTAssertEqual(try queue().pending(limit: 1).first, record)
    }
}
