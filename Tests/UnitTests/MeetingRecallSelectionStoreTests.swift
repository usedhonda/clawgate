import XCTest
@testable import ClawGate

final class MeetingRecallSelectionStoreTests: XCTestCase {
    func testSelectionPersistsOnlyReferencesAndRejectsStaleOverwriteOrCorruptFallback() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let record = MeetingRecord(id: "mtg-selection", source: "calendar", startedAt: 1, endedAt: 2,
            timeZone: "UTC", title: "Fixture", conferenceCode: nil, participants: [],
            minutesState: "ready", minutesError: nil)
        store.save(record)
        let selections = MeetingRecallSelectionStore(store: store)
        XCTAssertNil(try selections.load(meetingID: record.id).fingerprint)
        let event = "00000000-0000-4000-8000-000000000001"
        let derived = "00000000-0000-4000-8000-000000000002"
        let chosen = MeetingRecallSelectionStore.Item(eventID: event, resultEventID: derived)
        let saved = try selections.save(items: [chosen], record: record, expectedFingerprint: nil)
        XCTAssertEqual(try selections.load(meetingID: record.id).items, [chosen])
        XCTAssertEqual(try selections.save(items: [chosen], record: record,
            expectedFingerprint: saved.fingerprint).fingerprint, saved.fingerprint)
        XCTAssertThrowsError(try selections.save(items: [], record: record, expectedFingerprint: nil))
        XCTAssertEqual(try selections.load(meetingID: record.id).items, [chosen])
        XCTAssertThrowsError(try selections.save(items: [.init(eventID: event, resultEventID: event)],
            record: record, expectedFingerprint: saved.fingerprint))
        let file = store.directory(for: record.id).appendingPathComponent("recall-selection.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "meetingID", "items"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try selections.load(meetingID: record.id)) // never silently drop the owner's choices
    }
}
