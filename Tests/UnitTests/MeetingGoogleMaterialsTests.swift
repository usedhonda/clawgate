import XCTest
@testable import ClawGate

final class MeetingGoogleMaterialsTests: XCTestCase {
    private func candidate(attachments: Bool = true) -> MeetingCandidate {
        MeetingCandidate(id: "calendar:event", calendarID: "calendar", calendarEventID: "event",
            title: "Planning", start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600), microphoneSeconds: 0,
            roughCharacters: 0, proposedStart: nil, proposedEnd: nil, boundaryEvidence: "",
            matchStatus: "noConversation", matchedMeetingID: nil, matchingMeetingIDs: [],
            calendarAccount: "reader@example.test",
            attachmentURLs: attachments ? ["https://docs.google.com/document/d/test-doc/edit"] : [])
    }

    private var tabs: Data {
        Data(#"{"documentId":"test-doc","tabs":[{"tabProperties":{"tabId":"notes","title":"メモ"},"documentTab":{"body":{"content":[{"paragraph":{"elements":[{"textRun":{"content":"発言と文字起こしを参考にした要約。\n"}}]}}]}},"childTabs":[{"tabProperties":{"tabId":"transcript","title":"文字起こし"},"documentTab":{"body":{"content":[{"paragraph":{"elements":[{"textRun":{"content":"00:01:00\nSpeaker A: Budget is 23 million.\n00:02:00\nSpeaker B: Approval is still pending.\n"}}]}}]}}}]}]}"#.utf8)
    }

    func testAllTabsPreserveNotesAndSpeechSeparatelyAndFailuresKeepReadableCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = try MeetingGoogleMaterials.sync(candidate: candidate(), run: { args in
            if args.prefix(2) == ["docs", "raw"] {
                XCTAssertTrue(args.contains("--all-tabs")); return self.tabs
            }
            return Data(#"{"file":{"name":"Planning"}}"#.utf8)
        }, cacheDirectory: dir)
        XCTAssertEqual(snapshot.status, .available)
        XCTAssertEqual(snapshot.notes.count, 1)
        XCTAssertEqual(snapshot.segments.count, 2)
        XCTAssertEqual(snapshot.segments.first?.speakerName, "Speaker A")
        XCTAssertEqual(snapshot.segments.first?.capturedAt, 1_700_000_060)
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.sourceURL.contains("tab=transcript") })
        XCTAssertFalse(snapshot.segments.contains { $0.text.contains("参考") })
        let failed = try MeetingGoogleMaterials.sync(candidate: candidate(), run: { _ in
            throw NSError(domain: "network", code: 1)
        }, cacheDirectory: dir)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.notes, snapshot.notes)
        XCTAssertEqual(failed.segments, snapshot.segments)
    }

    func testSearchPermissionFailureIsNotNoMaterials() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let denied = try MeetingGoogleMaterials.sync(candidate: candidate(attachments: false), run: { _ in
            throw NSError(domain: "permission", code: 403)
        }, cacheDirectory: dir)
        XCTAssertEqual(denied.status, .permissionDenied)
    }

    func testSameTitleOnAnotherDayCannotBecomeEvidence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try MeetingGoogleMaterials.sync(candidate: candidate(attachments: false), run: { args in
            if args.prefix(2) == ["drive", "search"] {
                return Data(#"{"files":[{"id":"test-doc","name":"Planning","modifiedTime":"2023-11-15T00:00:00Z"}]}"#.utf8)
            }
            if args.prefix(2) == ["docs", "raw"] { return self.tabs }
            return Data(#"{"file":{"name":"Planning"}}"#.utf8)
        }, cacheDirectory: dir)
        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertTrue(result.segments.isEmpty)
    }
    func testDisabledDocsAPIIsNotMissingMaterial() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try MeetingGoogleMaterials.sync(candidate: candidate(), run: { _ in
            throw NSError(domain: "docs API disabled", code: 403)
        }, cacheDirectory: dir)
        XCTAssertEqual(result.status, .serviceUnavailable)
    }

    func testDisabledAPIRecoversOnRetryAndIsNotCachedForever() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let failed = try MeetingGoogleMaterials.sync(candidate: candidate(), run: { _ in
            throw NSError(domain: "docs API disabled", code: 403)
        }, cacheDirectory: dir, now: now)
        XCTAssertTrue(MeetingGoogleMaterials.shouldReuseFailure(failed, now: now.addingTimeInterval(100)))
        XCTAssertFalse(MeetingGoogleMaterials.shouldReuseFailure(failed, now: now.addingTimeInterval(1800)))
        XCTAssertFalse(MeetingGoogleMaterials.shouldReuseFailure(failed, force: true))
        let recovered = try MeetingGoogleMaterials.sync(candidate: candidate(), run: { args in
            if args.prefix(2) == ["docs", "raw"] { return self.tabs }
            return Data(#"{"file":{"name":"Planning"}}"#.utf8)
        }, cacheDirectory: dir)
        XCTAssertEqual(recovered.status, .available)
        XCTAssertEqual(recovered.segments.count, 2)
    }

}
