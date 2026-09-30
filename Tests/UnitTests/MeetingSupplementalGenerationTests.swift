import XCTest
@testable import ClawGate

final class MeetingSupplementalGenerationTests: XCTestCase {
    private var record: MeetingRecord {
        MeetingRecord(id: "mtg-test", source: "meet", startedAt: 1, endedAt: 2,
            timeZone: "UTC", title: "Test", conferenceCode: nil, participants: [], minutesState: "none", minutesError: nil)
    }
    private func material(_ text: String) -> MeetingSupplementalMaterial {
        .init(id: "file", name: "notes.txt", note: "会議中に配布", included: true, status: .ready, error: nil,
            sections: [.init(id: "mat-file-0", locator: "text", text: text)], addedAt: Date(timeIntervalSince1970: 0), originalRelativePath: nil)
    }
    func testMaterialCitationLinksIncludeMaterialOnlyAndMixedClaims() {
        let evidence = [MeetingEvidence(claim: "【資料補足】背景", segmentIds: [], materialIds: ["mat-file-0"]),
                        MeetingEvidence(claim: "正式表記を資料で確認した", segmentIds: ["seg-1"], materialIds: ["mat-file-1"])]
        let supplement = WorkspaceFormat.cited("【資料補足】背景", allowed: [], evidence: evidence)
        XCTAssertTrue(supplement.runs.contains { $0.link?.absoluteString == "clawgate-material://mat-file-0" })
        let mixed = WorkspaceFormat.cited("正式表記を資料で確認した", allowed: ["seg-1"], evidence: evidence)
        XCTAssertTrue(mixed.runs.contains { $0.link?.absoluteString == "clawgate-material://mat-file-1" })
        XCTAssertTrue(mixed.runs.contains { $0.link?.scheme == "clawgate-segment" })
    }

    func testMaterialsAreBudgetedSeparatelyFrozenAndChangeFingerprint() throws {
        var envelope = MeetingMinutesEnvelope.build(record: record, segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Proposal discussed")])
        let original = MeetingMinutesJob.fingerprint(envelope)
        envelope.supplementalMaterials = [material(String(repeating: "Reference ", count: 2500))]
        XCTAssertNotEqual(original, MeetingMinutesJob.fingerprint(envelope))
        let chunks = MeetingMinutes.chunked(envelope)
        XCTAssertGreaterThan(chunks.count, 2)
        let fragments = chunks.flatMap { $0.supplementalMaterials ?? [] }.flatMap(\.sections)
        XCTAssertEqual(fragments.map(\.text).joined(), envelope.supplementalMaterials!.first!.sections.first!.text)
        XCTAssertEqual(Set(fragments.map(\.id)).count, fragments.count)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: chunks, completed: [], supplementalSnapshot: envelope.supplementalMaterials)
        XCTAssertEqual(job.allSupplementalMaterials, envelope.supplementalMaterials)
        var edited = envelope; edited.supplementalMaterials![0].note = "用語の確認用"
        XCTAssertNotEqual(MeetingMinutesJob.fingerprint(edited), job.fingerprint)
        XCTAssertEqual(job.allSupplementalMaterials?.first?.note, "会議中に配布")
    }

    func testUpdatingMaterialsReusesOnlyIdenticalCompletedPrefix() throws {
        var speech = MeetingMinutesEnvelope.build(record: record, segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Proposal discussed")])
        let previous = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(speech),
            envelopes: MeetingMinutes.chunked(speech), completed: [nil])
        // nil is a validated silent part, not an unfinished checkpoint.
        speech.supplementalMaterials = [material("Reference")]
        let updated = MeetingMinutesJob.updating(speech, previous: previous)
        XCTAssertEqual(updated.completed.count, 1)
        XCTAssertEqual(updated.envelopes.count, 2)
        XCTAssertNotNil(updated.next?.supplementalMaterials)
        XCTAssertEqual(updated.allSupplementalMaterials, speech.supplementalMaterials)
        XCTAssertEqual(updated.frozenEnvelope?.segments, speech.segments,
                       "material context must not duplicate speech in the frozen input")
        XCTAssertEqual(updated.frozenEnvelope?.supplementalMaterials, speech.supplementalMaterials)

        var changedRecord = record
        changedRecord.title = "Different meeting title"
        var changedMetadata = MeetingMinutesEnvelope.build(record: changedRecord, segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Proposal discussed")])
        changedMetadata.supplementalMaterials = speech.supplementalMaterials
        XCTAssertEqual(MeetingMinutesJob.updating(changedMetadata, previous: previous).completed.count, 0)
        let sameInput = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(speech),
            envelopes: updated.envelopes, completed: [nil, nil])
        XCTAssertEqual(MeetingMinutesJob.updating(speech, previous: sameInput).completed.count, 0,
                       "explicit regenerate of identical input must not be a no-op")
    }
    func testMaterialOnlyDecisionIsRejectedButLabelledSupplementIsAccepted() throws {
        func reply(_ decisions: [String], _ points: [String], _ ids: [String]) throws -> String {
            let claims = decisions + points
            let payload: [String: Any] = ["outcome": "answer", "contextDecision": ["policyVersion": MeetingMinutesPrompt.policyVersion],
                "minutes": ["summary": "", "topics": [["heading": "補足", "points": points]], "decisions": decisions,
                    "actionItems": [], "openQuestions": [], "evidence": claims.map { ["claim": $0, "segmentIds": [], "materialIds": ids] }]]
            return String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        }
        XCTAssertThrowsError(try MeetingMinutesParser.parse(reply(["Approved"], [], ["mat-file-0"]), validSegmentIds: [], validMaterialIds: ["mat-file-0"]))
        XCTAssertThrowsError(try MeetingMinutesParser.parse(reply([], ["Unlabelled claim"], ["mat-file-0"]), validSegmentIds: [], validMaterialIds: ["mat-file-0"]))
        XCTAssertNotNil(try MeetingMinutesParser.parse(reply([], ["【資料補足】Background"], ["mat-file-0"]), validSegmentIds: [], validMaterialIds: ["mat-file-0"]))
        XCTAssertThrowsError(try MeetingMinutesParser.parse(reply([], ["【資料補足】Background"], ["other"]), validSegmentIds: [], validMaterialIds: ["mat-file-0"]))
    }
}
