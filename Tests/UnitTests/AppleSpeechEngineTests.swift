import XCTest
@testable import ClawGate

/// Grouping Apple's per-character timings into speaker-true segments.
final class AppleSpeechEngineTests: XCTestCase {
    private func pieces(_ text: String, from start: Double, step: Double = 0.1) -> [AppleSpeechEngine.Piece] {
        text.enumerated().map { i, ch in
            AppleSpeechEngine.Piece(text: String(ch), start: start + Double(i) * step, end: start + Double(i + 1) * step)
        }
    }

    func testSplitsWhereTheSpeakerChanges() {
        let input = pieces("そうだね", from: 0) + pieces("いやちがう", from: 0.4)
        let turns = [SpeakerTurn(start: 0, end: 0.4, speaker: "other", score: 1),
                     SpeakerTurn(start: 0.4, end: 1.0, speaker: "self", score: 1)]
        let out = AppleSpeechEngine.group(input, turns: turns)
        XCTAssertEqual(out.map(\.text), ["そうだね", "いやちがう"])
        XCTAssertEqual(out.map(\.speaker), ["other", "self"])
        XCTAssertEqual(out[1].startSeconds, 0.4, accuracy: 0.001)
    }

    func testSplitsAtSentenceMarksAndPauses() {
        let input = pieces("はい。", from: 0) + pieces("それで", from: 0.3) + pieces("次", from: 2.0)
        let out = AppleSpeechEngine.group(input, turns: nil)
        XCTAssertEqual(out.map(\.text), ["はい。", "それで", "次"])
        XCTAssertTrue(out.allSatisfy { $0.speaker == nil })
    }

    func testPieceOutsideEveryTurnKeepsTheCurrentSpeaker() {
        let input = pieces("ながいぶん", from: 0)   // 0.0-0.5, turn covers only 0-0.2
        let turns = [SpeakerTurn(start: 0, end: 0.2, speaker: "self", score: 1)]
        let out = AppleSpeechEngine.group(input, turns: turns)
        XCTAssertEqual(out.map(\.text), ["ながいぶん"])
        XCTAssertEqual(out.first?.speaker, "self")
    }

    // MARK: - Detecting speech the Japanese model cannot handle

    func testEnglishSpeechThroughTheJapaneseModelIsDetected() {
        // Real lines from the 2026-09-21 English meeting's raw.jsonl.
        XCTAssertTrue(AppleSpeechEngine.looksNonPrimary(
            "Bene ofe thstoo theactoill o understand th Manatnaseone tinone Soeteatnat tis"))
        XCTAssertTrue(AppleSpeechEngine.looksNonPrimary(
            "So that is down wod you kings Iink wo was beasons byery reomingin prorteay was youre tenit"))
        // The lowest-latin segment of that meeting (0.600), short and mixed.
        XCTAssertTrue(AppleSpeechEngine.looksNonPrimary("Arennos Soapsファーストアクセ"))
    }

    func testJapaneseIsNeverDetectedAsAnotherLanguage() {
        XCTAssertFalse(AppleSpeechEngine.looksNonPrimary(
            "基本的にはちゃんと見れば、この子は昔やってたけど、今はそんなことないじゃん。"))
        // The most latin-heavy real Japanese segment measured (0.370).
        XCTAssertFalse(AppleSpeechEngine.looksNonPrimary(
            "I tal yo Iil let younoとか言いたくなるけど、そういうのはダメって言われたらチャット GPT強すぎます。"))
    }

    func testShortRepliesStayBelowTheLengthFloor() {
        XCTAssertFalse(AppleSpeechEngine.looksNonPrimary("OK, thanks"))
        XCTAssertFalse(AppleSpeechEngine.looksNonPrimary(""))
    }
}
