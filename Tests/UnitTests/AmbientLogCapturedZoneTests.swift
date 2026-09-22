import XCTest
@testable import ClawGate

/// The owner of this Mac travels constantly. Before `TranscriptSegment.timeZone`
/// existed, every past utterance re-rendered in whatever zone the Mac is in
/// right now, so a 09:00 meeting became 06:30 after landing. These tests pin
/// down that a segment stamped with its own captured zone keeps the wall-clock
/// time it actually had, regardless of the zone passed in for day grouping.
///
/// Pure-function tests against `AmbientLogGrouping` — no storage I/O, no
/// `AmbientLogModel`, nothing that could touch the owner's real ambient tree.
final class AmbientLogCapturedZoneTests: XCTestCase {
    // 1_700_007_000 == 2023-11-15 00:10:00 UTC == 09:10 JST == 05:40 IST
    // (Asia/Kolkata's Foundation abbreviation is "Kolkata", not "IST").
    private static let base = 1_700_007_000.0

    private static func seg(_ text: String, at epoch: Double, zone: String?) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        s.capturedAt = epoch
        s.timeZone = zone
        return s
    }

    /// Same UTC day, one segment captured in Tokyo, one in Kolkata — each
    /// block must show the HH:mm the owner actually saw at the time, not both
    /// forced into whatever zone is passed in for day grouping.
    func testSegmentsCapturedInDifferentZonesRenderEachInItsOwnZone() {
        let tokyoSeg = Self.seg("tokyo utterance", at: Self.base, zone: "Asia/Tokyo")
        // Push the Kolkata one past the 90s merge gap so it becomes its own block.
        let kolkataSeg = Self.seg("kolkata utterance", at: Self.base + 200, zone: "Asia/Kolkata")

        let blocks = AmbientLogGrouping.blocks(
            from: [tokyoSeg, kolkataSeg], timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].timeLabel, "09:10", "Tokyo segment matches the passed-in zone, no suffix")
        XCTAssertEqual(blocks[1].timeLabel, "05:43 Kolkata", "Kolkata segment renders in its own zone with the place named")
    }

    /// A scene's start/end each resolve in their own captured zone too.
    func testSceneStartAndEndEachRenderInTheirOwnCapturedZone() {
        let start = Self.base
        let end = Self.base + 600  // +10m
        let scenes = AmbientLogGrouping.scenes(
            from: [Self.seg("a", at: start, zone: "Asia/Tokyo"),
                   Self.seg("b", at: end, zone: "Asia/Kolkata")],
            timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].timeLabel, "09:10–05:50 Kolkata")
    }

    /// A scene that straddled the flight itself: the owner started talking in
    /// one place and finished in another, so each end names its own place.
    func testASceneThatStraddlesAZoneChangeNamesBothEnds() {
        let scenes = AmbientLogGrouping.scenes(
            from: [Self.seg("a", at: Self.base, zone: "Asia/Kolkata"),
                   Self.seg("b", at: Self.base + 600, zone: "Asia/Singapore")],
            timeZone: TimeZone(identifier: "Asia/Singapore")!)

        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].timeLabel, "05:40 Kolkata–08:20",
                       "the foreign end is named; the end matching the Mac's zone is not")
    }

    /// Legacy segments (written before `timeZone` existed) have no stamped
    /// zone at all — they must keep rendering in the passed-in zone, exactly
    /// as before this change.
    func testSegmentWithNoStampedZoneFallsBackToThePassedInZone() {
        let legacy = Self.seg("legacy utterance", at: Self.base, zone: nil)

        let blocks = AmbientLogGrouping.blocks(
            from: [legacy], timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].timeLabel, "09:10", "nil timeZone renders in the passed-in (fallback) zone")

        let scenes = AmbientLogGrouping.scenes(
            from: [legacy], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(scenes[0].timeLabel, "09:10–09:10")
    }

    /// When the segment's captured zone is the SAME as the passed-in (current)
    /// zone, no abbreviation should be appended — the label must stay exactly
    /// as it always has, unchanged by this feature.
    func testSegmentCapturedInTheCurrentZoneGetsNoAbbreviationSuffix() {
        let sameZone = Self.seg("same zone utterance", at: Self.base, zone: "Asia/Tokyo")

        let blocks = AmbientLogGrouping.blocks(
            from: [sameZone], timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].timeLabel, "09:10")
        XCTAssertFalse(blocks[0].timeLabel!.contains(" "), "no abbreviation suffix when zones match")

        let scenes = AmbientLogGrouping.scenes(
            from: [sameZone], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(scenes[0].timeLabel, "09:10–09:10")
    }
}
