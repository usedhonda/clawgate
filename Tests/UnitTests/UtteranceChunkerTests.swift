import XCTest
@testable import ClawGate

/// Synthetic audio only; nothing here touches ambient storage.
final class UtteranceChunkerTests: XCTestCase {
    private let rate = 16_000

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(0.2 * sin(Double($0) * 0.3)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0.0005, count: Int(seconds * Double(rate)))
    }

    /// Feed in 10 ms buffers; return the stream offsets (seconds) where cuts happened.
    private func cuts(_ audio: [Float], chunker: inout UtteranceChunker) -> [(at: Double, overlap: Int)] {
        var result: [(Double, Int)] = []
        var fed = 0
        let step = 160
        while fed < audio.count {
            let end = min(fed + step, audio.count)
            let decision = audio[fed..<end].withUnsafeBufferPointer { chunker.consume($0) }
            fed = end
            if case .cut(let overlap) = decision {
                result.append((Double(fed) / Double(rate), overlap))
                chunker.didStartChunk(primed: overlap)
            }
        }
        return result
    }

    func testCutsInsideThePauseAfterAnUtterance() {
        var chunker = UtteranceChunker()
        let found = cuts(tone(6) + silence(1.5) + tone(4), chunker: &chunker)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].at, 6.8, accuracy: 0.1)
        XCTAssertEqual(found[0].overlap, 0)
    }

    func testDoesNotCutAShortUtterance() {
        var chunker = UtteranceChunker()
        XCTAssertTrue(cuts(tone(1.5) + silence(1) + tone(0.5), chunker: &chunker).isEmpty)
    }

    func testContinuousSpeechIsForcedAtTheCapWithOverlap() {
        var chunker = UtteranceChunker()
        let found = cuts(tone(31), chunker: &chunker)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].at, 30, accuracy: 0.1)
        XCTAssertEqual(found[0].overlap, 16_000)
    }

    func testSilenceRollsOverAtTheCapOnly() {
        var chunker = UtteranceChunker()
        let found = cuts(silence(65), chunker: &chunker)
        XCTAssertEqual(found.map { Int($0.at.rounded()) }, [30, 60])
        XCTAssertTrue(found.allSatisfy { $0.overlap == 0 })
    }
}
