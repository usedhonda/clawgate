#if DEBUG
import XCTest
@testable import ClawGate

final class NativeWorkloadFixtureTests: XCTestCase {
    @MainActor
    func testSyntheticSourcesReachRealSidebarAndCoverThreeDistinctDays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PetModel()
        model.persistenceDisabledForFixture = true
        let fixture = try NativeWorkloadFixture(root: root, model: model)
        defer { fixture.stop() }
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let sidebar = try await MeetingWorkspaceLoader().sidebar(store: store, labels: [:])
        XCTAssertEqual(sidebar.meetings.count, 64, "The real consumer filters IDs, not the seed array count")
        XCTAssertEqual(sidebar.meetings.filter { $0.source == "local" }.count, 4)
        XCTAssertTrue(sidebar.meetings.allSatisfy { $0.materialCandidateID == nil })
        let raw = root.appendingPathComponent("sessions/ctx-fixture/transcripts/raw.jsonl")
        let lines = try String(contentsOf: raw).split(separator: "\n")
        let segments = try lines.map { try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8)) }
        let grouped = Dictionary(grouping: segments) { Int(($0.capturedAt ?? 0) / 86400) }
        XCTAssertEqual(grouped.count, 3)
        XCTAssertTrue(grouped.values.allSatisfy { $0.count == 120 })
        XCTAssertEqual(Set(grouped.values.compactMap { $0.first?.text }).count, 3,
                       "A day change must actually change the rendered synthetic content")
        XCTAssertNotEqual(model.connectionState, .connected)
    }
}
#endif
