import XCTest
import AVFoundation
@testable import ClawGate

final class AmbientCaptureTimingTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private let sampleRate = 16_000.0

    func testDelayedFirstTapUsesFirstSampleTimeForStartedAt() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 1)
        let firstTapTime = date(1_700_000_012.5)

        state.markPrimeResult(0)
        state.markFirstLiveSample(at: firstTapTime)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-1.wav"), sampleRate: sampleRate)
        XCTAssertEqual(meta?.startedAt, firstTapTime)
        XCTAssertFalse(meta?.provenOverlap ?? true)
    }

    func testInitialOrZeroOverlapDoesNotSubtractOffset() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 2)
        let firstTap = date(1_700_000_100)

        state.markPrimeResult(0)
        state.markFirstLiveSample(at: firstTap)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-2.wav"), sampleRate: sampleRate)
        XCTAssertEqual(meta?.startedAt, firstTap)
        XCTAssertEqual(meta?.actualPrimedFrames, 0)
        XCTAssertFalse(meta?.provenOverlap ?? true)
    }

    func testSuccessfulFullOverlapSubtractsActualPrimeFrames() {
        let firstTap = date(1_700_000_200)
        let primedFrames: AVAudioFrameCount = 4_800

        var state = AmbientCaptureManager.ChunkTimingState(sequence: 3)
        state.markPrimeResult(primedFrames)
        state.markFirstLiveSample(at: firstTap)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-3.wav"), sampleRate: sampleRate)
        let startedAt = try! XCTUnwrap(meta?.startedAt)
        XCTAssertEqual(
            startedAt.timeIntervalSince1970,
            firstTap.timeIntervalSince1970 - Double(primedFrames) / sampleRate,
            accuracy: 1e-9
        )
        XCTAssertEqual(meta?.actualPrimedFrames, primedFrames)
        XCTAssertTrue(meta?.provenOverlap ?? false)
    }

    func testPartialOverlapSubtractsActualPrimeFramesOnly() {
        let firstTap = date(1_700_000_260)
        let primedFrames: AVAudioFrameCount = 1_234

        var state = AmbientCaptureManager.ChunkTimingState(sequence: 4)
        state.markPrimeResult(primedFrames)
        state.markFirstLiveSample(at: firstTap)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-4.wav"), sampleRate: sampleRate)
        let startedAt = try! XCTUnwrap(meta?.startedAt)
        XCTAssertEqual(
            startedAt.timeIntervalSince1970,
            firstTap.timeIntervalSince1970 - Double(primedFrames) / sampleRate,
            accuracy: 1e-9
        )
        XCTAssertEqual(meta?.actualPrimedFrames, primedFrames)
        XCTAssertTrue(meta?.provenOverlap ?? false)
    }

    func testPrimeFailureWritesNoSubtractedOffsetAndNoProvenOverlap() {
        let firstTap = date(1_700_000_300)

        var state = AmbientCaptureManager.ChunkTimingState(sequence: 5)
        state.markPrimeResult(0)
        state.markFirstLiveSample(at: firstTap)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-5.wav"), sampleRate: sampleRate)
        XCTAssertEqual(meta?.startedAt, firstTap)
        XCTAssertEqual(meta?.actualPrimedFrames, 0)
        XCTAssertFalse(meta?.provenOverlap ?? true)
    }

    func testFirstWriteFailureThenSuccessUsesFirstSuccessfulWriteTime() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 6)
        let successfulWrite = date(1_700_000_405)

        state.markFirstLiveSample(at: nil)
        let fromFailureOnly = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-6.wav"), sampleRate: sampleRate)
        XCTAssertNil(fromFailureOnly)

        state.markFirstLiveSample(at: successfulWrite)
        let fromSuccess = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-6b.wav"), sampleRate: sampleRate)
        XCTAssertEqual(fromSuccess?.startedAt, successfulWrite)
    }

    func testChunkSequenceMonotonicAndOneMetadataPerCompletion() {
        let first = date(1_700_000_500)
        let second = date(1_700_000_560)

        var delivered: [AmbientCaptureManager.CompletedChunk] = []

        for idx in [7, 8] {
            var state = AmbientCaptureManager.ChunkTimingState(sequence: idx)
            state.markFirstLiveSample(at: idx == 7 ? first : second)
            if let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-\(idx).wav"), sampleRate: sampleRate) {
                delivered.append(meta)
            }
        }

        XCTAssertEqual(delivered.map(\.sequence), [7, 8])
        XCTAssertEqual(Set(delivered.map(\.sequence)).count, 2)
        XCTAssertEqual(delivered.count, 2)
    }
}
