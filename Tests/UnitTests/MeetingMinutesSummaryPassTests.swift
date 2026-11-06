import XCTest
@testable import ClawGate

final class MeetingMinutesSummaryPassTests: XCTestCase {
    private var record: MeetingRecord {
        MeetingRecord(id: "reconcile", source: "manual", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: "Planning", conferenceCode: nil, participants: [],
            minutesState: "pending", minutesError: nil)
    }

    private func minutes(_ text: String, id: String) -> MeetingMinutes {
        MeetingMinutes(title: "Planning", summary: text, topics: [], decisions: [text],
            actionItems: [], openQuestions: [], evidence: [.init(claim: text, segmentIds: [id])],
            attendance: nil, language: "en")
    }

    func testWholeMeetingCorrectionRequiresFullCoverageOriginalQuoteAndHistory() throws {
        let parts = [minutes("Budget is 23 million.", id: "seg-1"), minutes("Budget is 2 million.", id: "seg-2")]
        let base = try XCTUnwrap(MeetingMinutes.combining(parts))
        let sources = [MeetingMinutesSegment(sourceSegment: .init(id: "seg-1", source: "local", text: parts[0].summary)),
                       MeetingMinutesSegment(sourceSegment: .init(id: "seg-2", source: "local", text: "Correction: budget is 2 million, not 23 million."))]
        let input = MeetingMinutesSummaryPass.input(for: base, parts: parts, record: record, segments: sources)
        let history = "【訂正】Budget changed from 23 to 2 million."
        let result = MeetingMinutes(title: "Planning", summary: "Budget was corrected.",
            topics: [.init(heading: "History", points: [history])], decisions: ["Budget is 2 million."],
            actionItems: [], openQuestions: [],
            evidence: ["Budget was corrected.", history, "Budget is 2 million."].map { .init(claim: $0, segmentIds: ["seg-1", "seg-2"]) },
            attendance: nil, language: "en")
        func reply(ids: [String], quote: String) throws -> String {
            let value = MeetingMinutesSummaryPass.Reply(policyVersion: MeetingMinutesSummaryPass.policyVersion,
                minutes: result, resolutions: [.init(sourceClaimIds: ids, disposition: "corrected",
                    outputClaims: [result.summary, history] + result.decisions,
                    quotes: [.init(segmentId: "seg-2", text: quote)])])
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        let all = input.claims.map(\.id)
        let parsed = try MeetingMinutesSummaryPass.parse(reply(ids: all, quote: sources[1].text), input: input)
        let accepted = MeetingMinutesSummaryPass.apply(parsed, to: base, parts: parts)
        XCTAssertEqual(accepted.decisions, ["Budget is 2 million."])
        XCTAssertEqual(accepted.topics.first?.points, [history])
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(ids: Array(all.dropLast()), quote: sources[1].text), input: input))
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(ids: all, quote: "A later timestamp proves this correct"), input: input))
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(ids: all, quote: ""), input: input))
        let secondarySources = sources.map { MeetingMinutesSegment(sourceSegment:
            .init(id: $0.id, source: "existing-minutes", text: $0.text)) }
        let secondaryInput = MeetingMinutesSummaryPass.input(for: base, parts: parts, record: record, segments: secondarySources)
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(ids: all, quote: sources[1].text), input: secondaryInput))

    }

    func testExplicitEvidenceCorrectionIsBoundedToAnswerValidation() {
        XCTAssertTrue(MeetingMinutesSummaryPass.permitsEvidenceCorrection(
            MeetingMinutesError.invalidEvidence(claim: nil, reason: "訂正・撤回の経緯と両方の引用がありません")))
        XCTAssertTrue(MeetingMinutesSummaryPass.permitsEvidenceCorrection(
            MeetingMinutesError.invalidEvidence(claim: nil, reason: "統合で元の引用が失われています")))
        XCTAssertFalse(MeetingMinutesSummaryPass.permitsEvidenceCorrection(URLError(.timedOut)))
    }

    func testUnresolvedConflictMustRemainInQuestionsAndUnknownCitationsFail() throws {
        let part = minutes("Budget is uncertain.", id: "seg-1")
        let input = MeetingMinutesSummaryPass.input(for: part, parts: [part], record: record)
        func reply(question: Bool, id: String, definite: Bool = false) throws -> String {
            let value = MeetingMinutes(title: nil, summary: part.summary, topics: [], decisions: definite ? [part.summary] : [],
                actionItems: [], openQuestions: question ? [part.summary] : [],
                evidence: [.init(claim: part.summary, segmentIds: [id])], attendance: nil, language: nil)
            let result = MeetingMinutesSummaryPass.Reply(policyVersion: MeetingMinutesSummaryPass.policyVersion,
                minutes: value, resolutions: [.init(sourceClaimIds: input.claims.map(\.id),
                    disposition: "unresolved", outputClaims: [part.summary], quotes: [])])
            return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        }
        XCTAssertNoThrow(try MeetingMinutesSummaryPass.parse(reply(question: true, id: "seg-1"), input: input))
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(question: true, id: "seg-1", definite: true), input: input))
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(question: false, id: "seg-1", definite: true), input: input))
        let normalized = try MeetingMinutesSummaryPass.parse(reply(question: false, id: "seg-1"), input: input)
        XCTAssertEqual(normalized.minutes.openQuestions, [part.summary])
        XCTAssertEqual(normalized.minutes.summary, part.summary)
        XCTAssertEqual(normalized.minutes.evidence, part.evidence)
        // A mistyped or invented ID is discarded; the mapped source claim's
        // frozen citation grounds the output instead.
        let mistyped = try MeetingMinutesSummaryPass.parse(reply(question: true, id: "seg-99"), input: input)
        XCTAssertEqual(mistyped.minutes.evidence, part.evidence)
    }

    func testProvenanceComesFromTheMappingButEveryOutputMustBeMapped() throws {
        let part = minutes("Ship on Friday.", id: "seg-1")
        let input = MeetingMinutesSummaryPass.input(for: part, parts: [part], record: record)
        func reply(extra: Bool) throws -> String {
            let value = MeetingMinutes(title: nil, summary: part.summary, topics: [],
                decisions: [part.summary] + (extra ? ["Hire two engineers."] : []),
                actionItems: [], openQuestions: [], evidence: [], attendance: nil, language: nil)
            let result = MeetingMinutesSummaryPass.Reply(policyVersion: MeetingMinutesSummaryPass.policyVersion,
                minutes: value, resolutions: [.init(sourceClaimIds: input.claims.map(\.id),
                    disposition: "merged", outputClaims: [part.summary], quotes: [])])
            return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        }
        let parsed = try MeetingMinutesSummaryPass.parse(reply(extra: false), input: input)
        XCTAssertEqual(parsed.minutes.evidence, part.evidence)
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse(reply(extra: true), input: input))
    }
}
