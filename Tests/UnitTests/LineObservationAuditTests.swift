import XCTest
@testable import ClawGate

final class LineObservationAuditTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("line-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    private func request(at root: URL, expires: Date, mode: Int = 0o600) throws -> String {
        let id = UUID().uuidString
        let formatter = ISO8601DateFormatter()
        let value: [String: Any] = ["version": 1, "requestId": id, "expiresAt": formatter.string(from: expires)]
        let data = try JSONSerialization.data(withJSONObject: value)
        let url = root.appendingPathComponent(LineObservationAudit.requestName)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data,
                                                     attributes: [.posixPermissions: mode]))
        return id
    }

    func testNoRequestDoesNotWrite() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: [], capturedAt: "now", root: root), .noRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LineObservationAudit.resultName).path))
    }

    func testValidRequestIsConsumedAndWritesExactMachinePayload() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = try request(at: root, expires: Date().addingTimeInterval(60))
        let snapshots: [[String: Any]] = [["scope": "selected_thread_visible_window", "ocrSpans": []]]
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: snapshots, capturedAt: "captured", root: root), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LineObservationAudit.requestName).path))
        let output = try Data(contentsOf: root.appendingPathComponent(LineObservationAudit.resultName))
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(value["requestId"] as? String, id)
        XCTAssertEqual(value["capturedAt"] as? String, "captured")
        XCTAssertNotNil(value["snapshots"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(LineObservationAudit.resultName).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExpiredBadPermissionAndSymlinkRequestsAreRejected() throws {
        let expiredRoot = try root(); defer { try? FileManager.default.removeItem(at: expiredRoot) }
        _ = try request(at: expiredRoot, expires: Date().addingTimeInterval(-1))
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: [], capturedAt: "x", root: expiredRoot), .expiredRequest)

        let modeRoot = try root(); defer { try? FileManager.default.removeItem(at: modeRoot) }
        _ = try request(at: modeRoot, expires: Date().addingTimeInterval(60), mode: 0o644)
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: [], capturedAt: "x", root: modeRoot), .rejected)

        let symlinkRoot = try root(); defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let target = symlinkRoot.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent(LineObservationAudit.requestName), withDestinationURL: target)
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: [], capturedAt: "x", root: symlinkRoot), .rejected)
    }

    func testInvalidSnapshotReportsWriteFailureAfterConsumingRequest() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try request(at: root, expires: Date().addingTimeInterval(60))
        let invalid: [[String: Any]] = [["notJSON": Date()]]
        XCTAssertEqual(LineObservationAudit.consumeIfRequested(snapshots: invalid, capturedAt: "x", root: root), .auditWriteFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LineObservationAudit.requestName).path))
    }
}
