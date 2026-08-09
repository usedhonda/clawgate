import XCTest
import AVFoundation
@testable import ClawGate

final class AmbientCaptureTimingTests: XCTestCase {
    enum CaptureError: Error {
        case writeFailed
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private let sampleRate = 16_000.0

    private lazy var floatFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }()

    private var fixturesURL: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AmbientCaptureTimingTests", isDirectory: true)
        return url
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: fixturesURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixturesURL)
        try super.tearDownWithError()
    }

    private func tempURL(_ name: String) -> URL {
        fixturesURL.appendingPathComponent(name)
    }

    private func buffer(frames: AVAudioFrameCount, sample: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        if sample != 0, let ch = buffer.floatChannelData {
            let n = Int(frames)
            for i in 0..<n { ch[0][i] = sample }
        }
        return buffer
    }

    private func makeManager(
        tapTimeToDate: @escaping (AVAudioTime) -> Date? = { _ in Date() },
        writeAudioFile: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> AVAudioFrameCount = { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
        }
    ) -> AmbientCaptureManager {
        AmbientCaptureManager(
            tapTimeToDate: tapTimeToDate,
            writeAudioFile: writeAudioFile,
            log: { _ in }
        )
    }

    func testDelayedFirstTapUsesFirstSampleTimeForStartedAt() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 1)
        let firstTapTime = date(1_700_000_012.5)

        state.markPrimeResult(0)
        state.markFirstLiveSample(at: firstTapTime)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-1.wav"), sampleRate: sampleRate)
        XCTAssertEqual(meta.startedAt, firstTapTime)
        XCTAssertFalse(meta.provenOverlap)
    }

    func testInitialOrZeroOverlapDoesNotSubtractOffset() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 2)
        let firstTap = date(1_700_000_100)

        state.markPrimeResult(0)
        state.markFirstLiveSample(at: firstTap)

        let meta = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-2.wav"), sampleRate: sampleRate)
        XCTAssertEqual(meta.startedAt, firstTap)
        XCTAssertEqual(meta.actualPrimedFrames, 0)
        XCTAssertFalse(meta.provenOverlap)
    }

    func testMissingTapTimePreservesChunkAndYieldsNilStartedAt() {
        let manager = makeManager()
        let url = tempURL("missing-tap.wav")
        _ = try! manager.testOpenChunk(at: url)
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: nil)

        let chunk = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(chunk)
        XCTAssertNil(chunk?.startedAt)
        XCTAssertEqual(chunk?.sequence, 1)
        XCTAssertEqual(chunk?.url, url)
    }

    func testInvalidTapTimeMappingIsPerInstanceAndDoesNotClobberOtherManager() {
        let fixedA = date(1_600_000_100)
        let fixedB = date(1_700_000_200)
        let managerA = makeManager(tapTimeToDate: { _ in fixedA })
        let managerB = makeManager(tapTimeToDate: { _ in fixedB })
        let tapTime = AVAudioTime(hostTime: 123, sampleTime: 0, atRate: sampleRate)

        XCTAssertEqual(managerA.testFirstLiveSampleDate(from: tapTime), fixedA)
        XCTAssertEqual(managerB.testFirstLiveSampleDate(from: tapTime), fixedB)
    }

    func testPrimeOverlapFullPartialZeroAndThrowUseActualWrittenFrames() {
        struct Case {
            let label: String
            let returnedFrames: Result<AVAudioFrameCount, Error>
            let expectedPrimed: AVAudioFrameCount
            let expectProven: Bool
            let expectedStartedAtOffset: AVAudioFrameCount?
        }

        let firstTap = date(1_700_000_450)
        let overlapFrames = AVAudioFrameCount(4_800)
        let overlap = Array(repeating: Float(0.2), count: Int(overlapFrames))

        let cases: [Case] = [
            .init(label: "full", returnedFrames: .success(overlapFrames), expectedPrimed: overlapFrames, expectProven: true,
                  expectedStartedAtOffset: overlapFrames),
            .init(label: "partial", returnedFrames: .success(1_234), expectedPrimed: 1_234, expectProven: true,
                  expectedStartedAtOffset: 1_234),
            .init(label: "zero", returnedFrames: .success(0), expectedPrimed: 0, expectProven: false,
                  expectedStartedAtOffset: nil),
            .init(label: "throw", returnedFrames: .failure(CaptureError.writeFailed), expectedPrimed: 0, expectProven: false,
                  expectedStartedAtOffset: nil)
        ]

        for c in cases {
            let manager = makeManager(writeAudioFile: { _, _ in
                switch c.returnedFrames {
                case .success(let frames):
                    return min(frames, overlapFrames)
                case .failure(let err):
                    throw err
                }
            })
            _ = try! manager.testOpenChunk(at: tempURL("prime-" + c.label + ".wav"))
            manager.testSetOverlapTail(overlap)
            manager.testMarkCurrentChunkFirstLiveSample(firstTap)
            let primed = manager.testPrimeAndMark()

            let timing = manager.testCurrentChunkTiming()
            XCTAssertEqual(primed, c.expectedPrimed, "\(c.label) prime")
            XCTAssertEqual(timing.actualPrimedFrames, c.expectedPrimed, "\(c.label) prime")
            XCTAssertEqual(timing.provenOverlap, c.expectProven, "\(c.label) prime")

            let startedAt = manager.testStartedAtFromCurrentTiming(sampleRate: sampleRate)
            if let offset = c.expectedStartedAtOffset, let startedAt {
                XCTAssertEqual(
                    startedAt.timeIntervalSince1970,
                    firstTap.timeIntervalSince1970 - Double(offset) / sampleRate,
                    accuracy: 1e-9,
                    "\(c.label) prime")
            } else {
                XCTAssertEqual(startedAt, firstTap)
            }
            XCTAssertNil(manager.testCurrentChunkTiming().startedAt(sampleRate: .nan))
        }
    }

    func testFirstWriteFailureThenSuccessStampsOnlyFirstSuccessfulTime() {
        var attempt = 0
        let firstSuccessful = date(1_700_000_600)
        let manager = makeManager(writeAudioFile: { _, _ in
            attempt += 1
            if attempt == 1 { throw CaptureError.writeFailed }
            return 2_000
        })

        _ = try! manager.testOpenChunk(at: tempURL("write-fail-success.wav"))
        manager.testWriteBuffer(buffer(frames: 2_000), firstLiveSampleDate: date(1_700_000_400))
        XCTAssertNil(manager.testStartedAtFromCurrentTiming(sampleRate: sampleRate))

        manager.testWriteBuffer(buffer(frames: 2_000), firstLiveSampleDate: firstSuccessful)
        XCTAssertEqual(manager.testStartedAtFromCurrentTiming(sampleRate: sampleRate), firstSuccessful)
    }

    func testOpenFinalizeSequenceIsMonotonicAndNoDuplicateCallbackPerURL() {
        let expectation = expectation(description: "chunk callback")
        expectation.expectedFulfillmentCount = 2

        var delivered: [AmbientCaptureManager.CompletedChunk] = []
        let manager = makeManager(writeAudioFile: { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
        })
        manager.onChunkReady = { chunk in
            delivered.append(chunk)
            expectation.fulfill()
        }

        _ = try! manager.testOpenChunk(at: tempURL("seq-1.wav"))
        manager.testMarkCurrentChunkFirstLiveSample(date(1_700_000_700))
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: date(1_700_000_700))
        let first = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(first)
        XCTAssertNil(manager.testFinalizeCurrentChunk())

        _ = try! manager.testOpenChunk(at: tempURL("seq-2.wav"))
        manager.testMarkCurrentChunkFirstLiveSample(date(1_700_000_900))
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: date(1_700_000_900))
        let second = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(second)

        waitForExpectations(timeout: 1)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.map(\.sequence), [1, 2])
        XCTAssertEqual(Set(delivered.map(\.url)).count, 2)
        XCTAssertEqual(delivered[0].url.lastPathComponent, "seq-1.wav")
        XCTAssertEqual(delivered[1].url.lastPathComponent, "seq-2.wav")
    }

    func testInvalidSampleRateDoesNotProduceTimestampWhenOverlapNeedsSubtraction() {
        var state = AmbientCaptureManager.ChunkTimingState(sequence: 88)
        let firstTap = date(1_700_001_000)
        state.markPrimeResult(1_000)
        state.markFirstLiveSample(at: firstTap)

        let metaNonFinite = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-invalid.wav"), sampleRate: .nan)
        XCTAssertNil(metaNonFinite.startedAt)
        XCTAssertFalse(metaNonFinite.provenOverlap)

        let metaZero = state.completedChunk(url: URL(fileURLWithPath: "/tmp/ambient-zero.wav"), sampleRate: 0)
        XCTAssertNil(metaZero.startedAt)
        XCTAssertFalse(metaZero.provenOverlap)
    }

    func testOriginalChunkTimingSequenceAndMonotonicity() {
        let first = date(1_700_000_800)
        let second = date(1_700_000_840)

        var delivered: [AmbientCaptureManager.ChunkTimingState] = []

        for (idx, startDate) in [first, second].enumerated() {
            var state = AmbientCaptureManager.ChunkTimingState(sequence: idx + 1)
            state.markFirstLiveSample(at: startDate)
            delivered.append(state)
        }

        XCTAssertEqual(delivered.map(\.sequence), [1, 2])
        XCTAssertEqual(delivered.map { $0.firstLiveSampleAt?.timeIntervalSince1970 }, [first.timeIntervalSince1970, second.timeIntervalSince1970])
    }
}
