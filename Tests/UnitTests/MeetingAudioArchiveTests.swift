import AVFoundation
import AudioToolbox
import XCTest
@testable import ClawGate

final class MeetingAudioArchiveTests: XCTestCase {
    func testArchiveIsIndexedAndSelectedMeetingPinsOnlyItsRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let input = try AVAudioFile(forWriting: source, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        samples.frameLength = 16_000
        for i in 0..<16_000 {
            samples.floatChannelData![0][i] = sin(Float(i) * 0.04) * 0.2
        }
        try input.write(from: samples)
        if #available(macOS 15.0, *) { input.close() }

        let archive = MeetingAudioArchive(root: root.appendingPathComponent("archive"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let chunk = AmbientCaptureManager.CompletedChunk(
            url: source, sequence: 1, rms: 0.1, startedAt: start,
            actualPrimedFrames: 0, sampleRate: 16_000, provenOverlap: false,
            source: .mic)
        try archive.archive(chunk)
        let indexed = try XCTUnwrap(archive.chunks(start: start.timeIntervalSince1970,
                                                  end: start.timeIntervalSince1970 + 2).first)
        XCTAssertEqual(indexed.source, "mic")
        XCTAssertEqual(indexed.startedAt, start.timeIntervalSince1970)
        XCTAssertEqual(indexed.endedAt - indexed.startedAt, 1, accuracy: 0.01)
        XCTAssertTrue(archive.audioURL(for: indexed).pathExtension == "m4a")
        XCTAssertGreaterThan(try AVAudioFile(forReading: archive.audioURL(for: indexed)).length, 0)
        XCTAssertTrue(archive.chunks(start: start.timeIntervalSince1970 + 2,
                                     end: start.timeIntervalSince1970 + 3).isEmpty)

        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let selected = MeetingRecord(
            id: "mtg-test", source: "manual", startedAt: start.timeIntervalSince1970 + 0.2,
            endedAt: start.timeIntervalSince1970 + 0.8, timeZone: "UTC",
            title: nil, conferenceCode: nil, participants: [],
            minutesState: "none", minutesError: nil)
        try MeetingBackfill(archive: archive, store: store).pinAudio(for: selected)
        let pinnedFile = store.directory(for: selected.id).appendingPathComponent("audio")
            .appendingPathComponent(indexed.fileName)
        let pinned = try AVAudioFile(forReading: pinnedFile)
        XCTAssertEqual(Double(pinned.length) / pinned.fileFormat.sampleRate, 0.6, accuracy: 0.03)
        var utterance = TranscriptSegment(startSeconds: 0, endSeconds: 0.2, text: "test")
        utterance.capturedAt = start.timeIntervalSince1970 + 0.5
        utterance.stream = "mic"
        let clip = try XCTUnwrap(store.audioClip(id: selected.id, segment: utterance))
        XCTAssertEqual(clip.url, pinnedFile)
        XCTAssertEqual(clip.offset, 0.3, accuracy: 0.01)
    }
}
