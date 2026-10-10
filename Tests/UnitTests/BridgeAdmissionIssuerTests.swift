import CryptoKit
import XCTest
@testable import ClawGate

final class BridgeAdmissionIssuerTests: XCTestCase {
    private func makeIssuer(maxRecords: Int = 4, maxBytes: Int = 16_384) throws -> (BridgeAdmissionIssuer, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("issuer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let keyURL = root.appendingPathComponent("issuer.key")
        try key.rawRepresentation.write(to: keyURL)
        chmod(keyURL.path, 0o600)
        return (BridgeAdmissionIssuer(directory: root, maxRecords: maxRecords, maxBytes: maxBytes, initializeForTesting: true), root)
    }

    private func cleanup(_ root: URL) { try? FileManager.default.removeItem(at: root) }

    func testCanonicalBytesAreDeterministicAndAdmissionIsBodyFree() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawgate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let keyURL = root.appendingPathComponent("issuer.key")
        try key.rawRepresentation.write(to: keyURL)
        chmod(keyURL.path, 0o600)
        defer { try? FileManager.default.removeItem(at: root) }

        let issuer = BridgeAdmissionIssuer(directory: root, maxRecords: 2, maxBytes: 4096, initializeForTesting: true)
        let first = issuer.admission(eventId: 1, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z", provenance: .watcherAccepted)
        XCTAssertEqual(first.provenance, .watcherAccepted)
        XCTAssertNil(first.failureReason)
        let body = Data("{\"body\":\"not persisted\"}".utf8)
        let a = BridgeAdmissionIssuer.canonicalBytes(method: "GET", uri: "/v1/poll?since=1", challenge: String(repeating: "a", count: 64), status: 200, keyId: first.issuerKeyId!, body: body)
        XCTAssertEqual(a, BridgeAdmissionIssuer.canonicalBytes(method: "GET", uri: "/v1/poll?since=1", challenge: String(repeating: "a", count: 64), status: 200, keyId: first.issuerKeyId!, body: body))
        let persisted = try Data(contentsOf: root.appendingPathComponent("admissions.jsonl"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("not persisted"))
    }

    func testSharedSigningVector() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/bridge-poll-signing-v1.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let body = Data((fixture["body"] as! String).utf8)
        let keyId = fixture["keyId"] as! String
        let bytes = BridgeAdmissionIssuer.canonicalBytes(method: fixture["method"] as! String, uri: fixture["uri"] as! String, challenge: fixture["challenge"] as! String, status: fixture["status"] as! Int, keyId: keyId, body: body)
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), fixture["signingBytesHex"] as! String)
    }

    func testEventBusRetryGenericCapacityAndDebugProvenance() throws {
        let (issuer, root) = try makeIssuer(maxRecords: 1)
        defer { cleanup(root) }
        let bus = EventBus(admissionIssuer: issuer)
        let first = bus.appendWatcherAccepted(type: "inbound_message", adapter: "line", payload: ["text": "x"])
        let retry = bus.poll(since: 0).events.first!
        XCTAssertEqual(first.admission?.admissionId, retry.admission?.admissionId)
        let generic = bus.append(type: "inbound_message", adapter: "tmux", payload: ["admission": "watcher_accepted"])
        XCTAssertEqual(generic.admission?.provenance, .unknown)
        XCTAssertEqual(generic.admission?.admissionId, "unknown")
        let debug = bus.appendDebugInjected(type: "inbound_message", adapter: "line", payload: ["admission": "watcher_accepted"])
        XCTAssertEqual(debug.admission?.provenance, .unknown)
        XCTAssertNotEqual(debug.admission?.admissionId, "unknown")
    }

    func testProvisionedLimitsRejectBooleanAndUnknownFields() throws {
        let (_, root) = try makeIssuer()
        defer { cleanup(root) }
        let limits = root.appendingPathComponent("limits.json")
        for value in ["{\"max_records\":true,\"max_bytes\":4096}", "{\"max_records\":4,\"max_bytes\":4096,\"unknown\":1}"] {
            try Data(value.utf8).write(to: limits)
            chmod(limits.path, 0o600)
            XCTAssertNil(BridgeAdmissionIssuer(provisionedDirectory: root))
        }
        try Data("{\"max_records\":4,\"max_bytes\":4096}".utf8).write(to: limits)
        XCTAssertNotNil(BridgeAdmissionIssuer(provisionedDirectory: root))
    }

    func testMissingPairByteCapAndSymlinkStayUnknown() throws {
        let (issuer, root) = try makeIssuer(maxBytes: 2)
        defer { cleanup(root) }
        let bus = EventBus(admissionIssuer: issuer)
        let event = bus.appendWatcherAccepted(type: "inbound_message", adapter: "line", payload: ["text": "synthetic-body"])
        XCTAssertEqual(event.payload["text"], "synthetic-body")
        XCTAssertEqual(event.admission?.failureReason, "issuer_capacity")
        XCTAssertEqual(event.admission?.provenance, .unknown)
        try FileManager.default.removeItem(at: root.appendingPathComponent("generation.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("admissions.jsonl"))
        let missing = BridgeAdmissionIssuer(directory: root, maxRecords: 4, maxBytes: 4096)
        XCTAssertEqual(missing.admission(eventId: 2, type: "inbound_message", adapter: "line", observedAt: "synthetic", provenance: .watcherAccepted).provenance, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("generation.json").path))
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("admissions.jsonl"), withDestinationURL: target)
        let symlinked = BridgeAdmissionIssuer(directory: root, maxRecords: 4, maxBytes: 4096)
        XCTAssertEqual(symlinked.admission(eventId: 3, type: "inbound_message", adapter: "line", observedAt: "synthetic", provenance: .watcherAccepted).provenance, .unknown)
        XCTAssertEqual(try String(contentsOf: target), "untouched")
    }

    func testReopenCorruptionAndDirectoryReplacementStayUnknown() throws {
        let (issuer, root) = try makeIssuer()
        let first = issuer.admission(eventId: 1, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z", provenance: .watcherAccepted)
        XCTAssertEqual(first.provenance, .watcherAccepted)
        let reopened = BridgeAdmissionIssuer(directory: root, maxRecords: 4, maxBytes: 16_384)
        let second = reopened.admission(eventId: 2, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:01Z", provenance: .watcherAccepted)
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertNotEqual(second.admissionId, first.admissionId)
        cleanup(root)

        let (corruptIssuer, corruptRoot) = try makeIssuer()
        _ = corruptIssuer.admission(eventId: 1, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z", provenance: .watcherAccepted)
        let journal = corruptRoot.appendingPathComponent("admissions.jsonl")
        try Data("not-json\n".utf8).write(to: journal)
        let corrupt = BridgeAdmissionIssuer(directory: corruptRoot, maxRecords: 4, maxBytes: 16_384)
        XCTAssertEqual(corrupt.admission(eventId: 2, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:01Z", provenance: .watcherAccepted).provenance, .unknown)
        cleanup(corruptRoot)

        let (replaceIssuer, replaceRoot) = try makeIssuer()
        _ = replaceIssuer.admission(eventId: 1, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:00Z", provenance: .watcherAccepted)
        let replaceJournal = replaceRoot.appendingPathComponent("admissions.jsonl")
        try FileManager.default.removeItem(at: replaceJournal)
        try FileManager.default.createDirectory(at: replaceJournal, withIntermediateDirectories: false)
        XCTAssertEqual(replaceIssuer.admission(eventId: 2, type: "inbound_message", adapter: "line", observedAt: "2026-01-01T00:00:01Z", provenance: .watcherAccepted).provenance, .unknown)
        cleanup(replaceRoot)
    }
}
