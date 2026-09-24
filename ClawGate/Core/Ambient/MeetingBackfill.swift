import AVFoundation
import AudioToolbox
import Foundation

/// Re-runs recognition from retained audio. Live ambient text is only a hint;
/// this result is the meeting's own reproducible transcript revision.
final class MeetingBackfill {
    enum Failure: Error {
        case noAudio
        case incompleteAudio
    }

    private let archive: MeetingAudioArchive
    private let transcriber: AmbientTranscriber
    private let store: MeetingStore

    init(archive: MeetingAudioArchive = MeetingAudioArchive(),
         transcriber: AmbientTranscriber = AmbientTranscriber(),
         store: MeetingStore = MeetingStore()) {
        self.archive = archive
        self.transcriber = transcriber
        self.store = store
    }

    func createMeeting(start: Date, end: Date, title: String? = nil,
                       candidate: MeetingCandidate? = nil) throws -> MeetingRecord {
        guard start < end else { throw Failure.noAudio }
        let existing = candidate?.matchedMeetingID.flatMap { store.load(id: $0) }
        var record = existing ?? MeetingRecord(
            id: MeetingRecorder.makeID(at: start) + "-" + UUID().uuidString.prefix(8),
            source: "manual", startedAt: start.timeIntervalSince1970,
            endedAt: end.timeIntervalSince1970, timeZone: TimeZone.current.identifier,
            title: title, conferenceCode: nil, participants: [],
            minutesState: "none", minutesError: nil)
        record.startedAt = start.timeIntervalSince1970
        record.endedAt = end.timeIntervalSince1970
        if let title { record.title = title }
        record.calendarEventID = candidate?.calendarEventID
        record.calendarID = candidate?.calendarID
        record.calendarEventStart = candidate?.start.timeIntervalSince1970
        record.calendarEventEnd = candidate?.end.timeIntervalSince1970
        record.boundaryEvidence = candidate?.boundaryEvidence
        do {
            try pinAudio(for: record)
            let segments = try process(record)
            guard !segments.isEmpty else { throw Failure.noAudio }
            store.save(record)
            return record
        } catch {
            if existing == nil { try? FileManager.default.removeItem(at: store.directory(for: record.id)) }
            throw error
        }
    }

    func process(_ record: MeetingRecord) throws -> [TranscriptSegment] {
        guard let end = record.endedAt, record.startedAt < end else { throw Failure.noAudio }
        let pinned = pinnedAudio(for: record)
        let chunks = pinned?.chunks ?? archive.chunks(start: record.startedAt, end: end)
        guard !chunks.isEmpty else { throw Failure.noAudio }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var results: [TranscriptSegment] = []
        for source in ["mic", "system"] {
            var coveredTo = record.startedAt
            for chunk in chunks where chunk.source == source {
                let begin = max(record.startedAt, chunk.startedAt, coveredTo)
                let finish = min(end, chunk.endedAt)
                guard begin < finish else { continue }
                let wav = scratch.appendingPathComponent(UUID().uuidString + ".wav")
                let audio = pinned.map { $0.directory.appendingPathComponent(chunk.fileName) }
                    ?? archive.audioURL(for: chunk)
                try exportWAV(from: audio, to: wav,
                              offset: begin - chunk.startedAt, duration: finish - begin)
                let recognized = try transcriber.transcribe(chunk: wav, engineOverride: "whisper")
                for var seg in recognized.kept {
                    seg.capturedAt = begin + seg.startSeconds
                    seg.stream = source
                    if source == "system", record.source == "meet" { seg.speaker = "other" }
                    results.append(seg)
                }
                coveredTo = finish
            }
        }
        results.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        let live = AmbientStorage.segmentsInRange(start: record.startedAt, end: end)
        results = Self.carryLiveSpeakerLabels(results, from: live, meetingSource: record.source)
        try store.saveBackfill(results, for: record)
        return results
    }

    static func carryLiveSpeakerLabels(_ backfill: [TranscriptSegment], from live: [TranscriptSegment],
                                       meetingSource: String) -> [TranscriptSegment] {
        backfill.map { segment in
            guard let at = segment.capturedAt, let stream = segment.stream else { return segment }
            let duration = max(0.3, segment.endSeconds - segment.startSeconds)
            let matches = live.compactMap { earlier -> (TranscriptSegment, Double)? in
                guard earlier.stream == stream, let liveAt = earlier.capturedAt else { return nil }
                let liveEnd = liveAt + max(0.3, earlier.endSeconds - earlier.startSeconds)
                let overlap = min(at + duration, liveEnd) - max(at, liveAt)
                return overlap > 0 ? (earlier, overlap) : nil
            }
            func unambiguous(_ label: (TranscriptSegment) -> String?) -> String? {
                var overlap: [String: Double] = [:]
                for (earlier, seconds) in matches {
                    if let value = label(earlier), !value.isEmpty { overlap[value, default: 0] += seconds }
                }
                let ranked = overlap.sorted { $0.value > $1.value }
                guard let top = ranked.first, top.value >= duration * 0.5,
                      ranked.dropFirst().allSatisfy({ $0.value < duration * 0.2 }) else { return nil }
                return top.key
            }
            var result = segment
            if let name = unambiguous({ $0.speakerName }) { result.speakerName = name }
            if meetingSource == "manual" {
                if let speaker = unambiguous({ $0.speaker }) { result.speaker = speaker }
            }
            return result
        }
    }

    func pinAudio(for record: MeetingRecord) throws {
        let chunks = archive.chunks(start: record.startedAt, end: record.endedAt ?? record.startedAt)
        guard !chunks.isEmpty else { throw Failure.noAudio }
        let directory = store.directory(for: record.id).appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pinned: [MeetingAudioArchive.Chunk] = []
        for chunk in chunks {
            let begin = max(record.startedAt, chunk.startedAt)
            let finish = min(record.endedAt ?? record.startedAt, chunk.endedAt)
            guard begin < finish else { continue }
            let destination = directory.appendingPathComponent(chunk.fileName)
            let temporary = directory.appendingPathComponent(chunk.id + ".wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try exportWAV(from: archive.audioURL(for: chunk), to: temporary,
                          offset: begin - chunk.startedAt, duration: finish - begin)
            let input = try AVAudioFile(forReading: temporary)
            do {
                let output = try AVAudioFile(forWriting: destination, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                ])
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000)!
                while input.framePosition < input.length {
                    try input.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw Failure.incompleteAudio }
                    try output.write(from: buffer)
                }
                if #available(macOS 15.0, *) { output.close() }
            }
            pinned.append(.init(id: chunk.id, source: chunk.source, startedAt: begin,
                                endedAt: finish, fileName: chunk.fileName))
        }
        try JSONEncoder().encode(pinned).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func pinnedAudio(for record: MeetingRecord) -> (chunks: [MeetingAudioArchive.Chunk], directory: URL)? {
        let directory = store.directory(for: record.id).appendingPathComponent("audio", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let chunks = try? JSONDecoder().decode([MeetingAudioArchive.Chunk].self, from: data) else {
            return nil
        }
        return (chunks, directory)
    }

    private func exportWAV(from source: URL, to destination: URL,
                           offset: Double, duration: Double) throws {
        let input = try AVAudioFile(forReading: source)
        let rate = input.fileFormat.sampleRate
        input.framePosition = min(input.length, AVAudioFramePosition(max(0, offset) * rate))
        let wanted = AVAudioFramePosition(max(0, duration) * rate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000)!
        var remaining = wanted
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw Failure.incompleteAudio }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        if #available(macOS 15.0, *) { output.close() }
    }
}
