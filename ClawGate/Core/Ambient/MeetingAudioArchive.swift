import AVFoundation
import AudioToolbox
import Foundation

/// A seven-day audio source independent of whether context streaming is enabled.
/// Each finalized capture chunk is compressed and indexed separately by stream.
final class MeetingAudioArchive {
    struct Chunk: Codable, Equatable {
        let id: String
        let source: String
        let startedAt: Double
        let endedAt: Double
        let fileName: String
    }

    static let retentionSeconds: TimeInterval = 7 * 24 * 3600

    private let root: URL
    private let queue = DispatchQueue(label: "ai.clawgate.meeting-audio-archive", qos: .utility)
    private let log: (String) -> Void
    private var lastMeetingPruneAt: Date = .distantPast

    init(root: URL = AmbientStorage.ambientRoot.appendingPathComponent("audio-archive", isDirectory: true),
         log: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.log = log
    }

    func enqueue(_ chunk: AmbientCaptureManager.CompletedChunk) {
        queue.async {
            do {
                try self.archive(chunk)
                let now = Date()
                self.prune(now: now)
                if now.timeIntervalSince(self.lastMeetingPruneAt) >= 24 * 3600 {
                    MeetingStore().pruneArchivedAudio(now: now)
                    self.lastMeetingPruneAt = now
                }
            } catch {
                self.log("meeting audio archive failed: \(error)")
            }
        }
    }

    /// Metadata only. A missing audio file never counts as a covered interval.
    func chunks(start: Double, end: Double) -> [Chunk] {
        guard start < end else { return [] }
        return allChunks().filter { $0.startedAt < end && $0.endedAt > start }
    }

    func coveredSeconds(start: Double, end: Double, source: String) -> Double {
        guard start < end else { return 0 }
        let intervals = chunks(start: start, end: end)
            .filter { $0.source == source }
            .map { (max(start, $0.startedAt), min(end, $0.endedAt)) }
            .sorted { $0.0 < $1.0 }
        var covered = 0.0
        var through = start
        for (begin, finish) in intervals {
            covered += max(0, finish - max(begin, through))
            through = max(through, finish)
        }
        return covered
    }

    func allChunks() -> [Chunk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Chunk? in
            guard let data = try? Data(contentsOf: url),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(chunk.fileName).path) else {
                return nil
            }
            return chunk
        }.sorted { $0.startedAt < $1.startedAt }
    }

    func audioURL(for chunk: Chunk) -> URL {
        root.appendingPathComponent(chunk.fileName)
    }

    func archive(_ chunk: AmbientCaptureManager.CompletedChunk) throws {
        guard let start = chunk.startedAt?.timeIntervalSince1970 else {
            throw ArchiveError.missingTimestamp
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: chunk.url)
        guard input.length > 0 else { throw ArchiveError.emptyAudio }
        let id = UUID().uuidString
        let finalName = id + ".m4a"
        let temporary = root.appendingPathComponent(id + ".partial.m4a")
        let final = root.appendingPathComponent(finalName)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000)!
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw ArchiveError.shortRead }
                try output.write(from: buffer)
            }
            if #available(macOS 15.0, *) { output.close() }
        }
        let duration = Double(input.length) / input.fileFormat.sampleRate
        // The writer has been released before the encoded file is published.
        try FileManager.default.moveItem(at: temporary, to: final)
        let entry = Chunk(id: id, source: chunk.source.rawValue, startedAt: start,
                          endedAt: start + duration, fileName: finalName)
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: root.appendingPathComponent(id + ".json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: final)
            throw error
        }
    }

    func prune(now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - Self.retentionSeconds
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for metadata in files where metadata.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metadata),
                  let entry = try? JSONDecoder().decode(Chunk.self, from: data),
                  entry.endedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.fileName))
            try? FileManager.default.removeItem(at: metadata)
        }
    }

    private enum ArchiveError: Error {
        case missingTimestamp, emptyAudio, shortRead
    }
}
