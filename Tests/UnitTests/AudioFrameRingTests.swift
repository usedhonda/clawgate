import XCTest
@testable import ClawGate

final class AudioFrameRingTests: XCTestCase {
    private func write(_ ring: AudioFrameRing, _ values: [UInt8]) {
        values.withUnsafeBytes { ring.write($0.baseAddress, byteCount: $0.count, bufferCount: 1) }
    }

    private func read(_ ring: AudioFrameRing, max: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max)
        let n = out.withUnsafeMutableBytes { ring.read(into: $0.baseAddress!, maxBytes: max) }
        return Array(out.prefix(n))
    }

    func testWrapsWithoutLosingOrder() {
        let ring = AudioFrameRing(capacityBytes: 8, bytesPerFrame: 2)
        write(ring, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(read(ring, max: 4), [1, 2, 3, 4])
        write(ring, [7, 8, 9, 10])
        XCTAssertEqual(read(ring, max: 8), [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.snapshot.framesIn, 5)
    }

    /// A full ring keeps what it has and counts what was lost.
    func testFullRingDropsNewAudioAndCountsIt() {
        let ring = AudioFrameRing(capacityBytes: 4, bytesPerFrame: 2)
        write(ring, [1, 2, 3, 4])
        write(ring, [5, 6])
        XCTAssertEqual(ring.snapshot.droppedBytes, 2)
        XCTAssertEqual(read(ring, max: 8), [1, 2, 3, 4])
    }

    func testReadsWholeFramesOnly() {
        let ring = AudioFrameRing(capacityBytes: 8, bytesPerFrame: 4)
        write(ring, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(read(ring, max: 6), [1, 2, 3, 4])
    }
}
