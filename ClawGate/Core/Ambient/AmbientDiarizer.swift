import Foundation

/// One diarized speaker turn from the helper binary.
struct SpeakerTurn: Codable, Equatable {
    let start: Double
    let end: Double
    let speaker: String  // "self" | "other"
    let score: Float
}

/// Shells out to the `clawgate-diarizer` helper (separate macOS 14+/Apple
/// Silicon binary, provisioned like whisper-cli) to label a WAV chunk's
/// speech as self (ご主人様, matched against the enrolled voiceprint) vs
/// other. Fail-soft by design: when the helper or voiceprint is absent
/// (old/Intel Macs) or a run fails, callers proceed without speaker labels.
final class AmbientDiarizer {
    private struct TurnsOut: Codable { let turns: [SpeakerTurn] }

    let binary: URL
    let voiceprint: URL
    let log: (String) -> Void

    init(binary: URL = AmbientStorage.defaultDiarizerBinary,
         voiceprint: URL = AmbientStorage.defaultSelfVoiceprint,
         log: @escaping (String) -> Void = { _ in }) {
        self.binary = binary
        self.voiceprint = voiceprint
        self.log = log
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: voiceprint.path)
    }

    /// Diarize a chunk into self/other turns. Returns nil on any failure —
    /// transcription must never be blocked by diarization.
    func diarize(chunk: URL) -> [SpeakerTurn]? {
        guard isAvailable else { return nil }
        let outURL = chunk.deletingPathExtension().appendingPathExtension("turns.json")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "diarize",
            "--wav", chunk.path,
            "--known", voiceprint.path,
            "--out", outURL.path,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            log("ambient diarizer launch failed: \(error)")
            return nil
        }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            log("ambient diarizer exited \(proc.terminationStatus): \(String(err.suffix(300)))")
            return nil
        }
        guard let data = try? Data(contentsOf: outURL),
              let parsed = try? JSONDecoder().decode(TurnsOut.self, from: data) else {
            log("ambient diarizer produced unreadable output")
            return nil
        }
        return parsed.turns
    }

    /// Assign each transcript segment the speaker whose turns overlap it the
    /// most (by duration). Segments with no meaningful overlap stay unlabeled.
    static func label(segments: [TranscriptSegment], with turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            var overlapBySpeaker: [String: Double] = [:]
            for turn in turns {
                let overlap = min(seg.endSeconds, turn.end) - max(seg.startSeconds, turn.start)
                if overlap > 0 {
                    overlapBySpeaker[turn.speaker, default: 0] += overlap
                }
            }
            guard let best = overlapBySpeaker.max(by: { $0.value < $1.value }),
                  best.value > 0 else { return seg }
            var labeled = seg
            labeled.speaker = best.key
            return labeled
        }
    }
}
