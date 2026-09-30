import AVFoundation
import CoreMedia
import XCTest
@testable import ClawGate

final class AmbientCaptureBackendTests: XCTestCase {
    func testPCMBufferCopiesPlanarMultichannelSamples() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        guard let formatDescription else { return XCTFail("missing format description") }

        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [-1, -2, -3, -4]
        var bytes = Data()
        left.withUnsafeBytes { bytes.append(contentsOf: $0) }
        right.withUnsafeBytes { bytes.append(contentsOf: $0) }
        let blockBuffer = try makeBlockBuffer(bytes)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: left.count,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        guard let sampleBuffer else { return XCTFail("missing sample buffer") }

        guard let (pcm, _) = AmbientCaptureBackend.pcmBuffer(from: sampleBuffer),
              let channels = pcm.floatChannelData else {
            return XCTFail("expected planar PCM")
        }
        XCTAssertEqual(pcm.format.channelCount, 2)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[0], count: left.count)), left)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[1], count: right.count)), right)
    }

    private func makeBlockBuffer(_ bytes: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
        bytes.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pointer,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            pointer.deallocate()
            throw NSError(domain: "AmbientCaptureBackendTests", code: Int(status))
        }
        return blockBuffer
    }
}
