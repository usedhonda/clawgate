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

    func testFinalizeCallbackPreservesTimingStateAndIsExactlyOnce() throws {
        let expectation = expectation(description: "chunk callback")
        expectation.expectedFulfillmentCount = 3
        let primedFrames: AVAudioFrameCount = 2_400

        var delivered: [AmbientCaptureManager.CompletedChunk] = []
        let lock = NSLock()
        let manager = makeManager(writeAudioFile: { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
        })
        manager.onChunkReady = { chunk in
            lock.lock()
            delivered.append(chunk)
            lock.unlock()
            expectation.fulfill()
        }

        _ = try! manager.testOpenChunk(at: tempURL("seq-1.wav"))
        XCTAssertEqual(manager.testCurrentChunkSequence(), 1)
        let firstTap = date(1_700_000_700)
        manager.testMarkCurrentChunkFirstLiveSample(firstTap)
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: firstTap)
        let first = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(first)
        XCTAssertNil(manager.testFinalizeCurrentChunk())

        _ = try! manager.testOpenChunk(at: tempURL("seq-2.wav"))
        XCTAssertEqual(manager.testCurrentChunkSequence(), 2)
        let secondTap = date(1_700_000_900)
        manager.testMarkCurrentChunkFirstLiveSample(secondTap)
        manager.testSetOverlapTail(Array(repeating: 0.2, count: Int(primedFrames)))
        let primed = manager.testPrimeAndMark()
        XCTAssertEqual(primed, primedFrames)
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: secondTap)
        let second = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(second)
        XCTAssertNil(manager.testFinalizeCurrentChunk())

        _ = try! manager.testOpenChunk(at: tempURL("seq-3.wav"))
        XCTAssertEqual(manager.testCurrentChunkSequence(), 3)
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: nil)
        let third = manager.testFinalizeCurrentChunk()
        XCTAssertNotNil(third)
        XCTAssertNil(manager.testFinalizeCurrentChunk())

        waitForExpectations(timeout: 1)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(delivered.count, 3)
        let ordered = delivered.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(Set(ordered.map(\.url)).count, 3)
        XCTAssertEqual(ordered.map { $0.url.lastPathComponent }, ["seq-1.wav", "seq-2.wav", "seq-3.wav"])
        XCTAssertEqual(ordered[0].startedAt, firstTap)
        XCTAssertEqual(ordered[0].actualPrimedFrames, 0)
        XCTAssertFalse(ordered[0].provenOverlap)
        let expectedSecondStart = secondTap.timeIntervalSince1970 - Double(primedFrames) / sampleRate
        let secondStartedAt = try XCTUnwrap(ordered[1].startedAt)
        XCTAssertEqual(
            secondStartedAt.timeIntervalSince1970,
            expectedSecondStart,
            accuracy: 1e-9
        )
        XCTAssertEqual(ordered[1].actualPrimedFrames, primedFrames)
        XCTAssertTrue(ordered[1].provenOverlap)
        XCTAssertNil(ordered[2].startedAt)
        XCTAssertEqual(ordered[2].actualPrimedFrames, 0)
        XCTAssertFalse(ordered[2].provenOverlap)
    }

    func testShortChunkFinalizeResetsTimingStateBeforeNextOpen() {
        let validChunkExpectation = expectation(description: "short-2.wav callback is emitted")
        let shortChunkExpectation = expectation(description: "short-1.wav callback is not emitted")
        shortChunkExpectation.isInverted = true
        var callbackURLs: [URL] = []
        let callbackLock = NSLock()
        let manager = makeManager(writeAudioFile: { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
        })
        manager.onChunkReady = { chunk in
            callbackLock.lock()
            callbackURLs.append(chunk.url)
            callbackLock.unlock()

            if chunk.url.lastPathComponent == "short-2.wav" {
                validChunkExpectation.fulfill()
            } else {
                shortChunkExpectation.fulfill()
            }
        }

        _ = try! manager.testOpenChunk(at: tempURL("short-1.wav"))
        manager.testSetOverlapTail([0.1, 0.2, 0.3, 0.4])
        manager.testMarkCurrentChunkFirstLiveSample(date(1_700_000_800))
        _ = manager.testPrimeAndMark()
        manager.testWriteBuffer(buffer(frames: 10_000), firstLiveSampleDate: date(1_700_000_800))

        let short = manager.testFinalizeCurrentChunk()
        XCTAssertNil(short)
        XCTAssertNil(manager.testCurrentChunkTiming().firstLiveSampleAt)
        XCTAssertEqual(manager.testCurrentChunkTiming().actualPrimedFrames, 0)
        XCTAssertFalse(manager.testCurrentChunkTiming().provenOverlap)

        _ = try! manager.testOpenChunk(at: tempURL("short-2.wav"))
        let nextTap = date(1_700_001_000)
        manager.testMarkCurrentChunkFirstLiveSample(nextTap)
        manager.testWriteBuffer(buffer(frames: 17_001), firstLiveSampleDate: nextTap)

        let nextChunk = manager.testFinalizeCurrentChunk()
        waitForExpectations(timeout: 1)
        XCTAssertNotNil(nextChunk)
        callbackLock.lock()
        let urls = callbackURLs
        callbackLock.unlock()

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["short-2.wav"])

        if let nextChunk {
            XCTAssertEqual(nextChunk.actualPrimedFrames, 0)
            XCTAssertFalse(nextChunk.provenOverlap)
            XCTAssertEqual(nextChunk.startedAt, nextTap)
        }
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

    func testNilCurrentChunkCannotMarkPrimeSuccess() {
        var wrotePrime = false
        let manager = makeManager(writeAudioFile: { _, _ in
            wrotePrime = true
            throw CaptureError.writeFailed
        })
        manager.testSetOverlapTail([0.1, 0.2, 0.3, 0.4])

        let primed = manager.testPrimeAndMark()
        let timing = manager.testCurrentChunkTiming()

        XCTAssertEqual(primed, 0)
        XCTAssertFalse(wrotePrime)
        XCTAssertEqual(timing.actualPrimedFrames, 0)
        XCTAssertFalse(timing.provenOverlap)
        XCTAssertEqual(timing.sequence, 0)
        XCTAssertNil(manager.testFinalizeCurrentChunk())
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
