import Foundation
import FluidAudio

// clawgate-diarizer — speaker diarization helper for the Ambient Context
// Stream. Self/other binary labeling against an enrolled "self" voiceprint.
//
//   warmup
//       Download/caches the CoreML models, then exits. Used by provisioning.
//   enroll --wav-dir <dir> --out <self.json>
//       Average speaker embeddings over all *.wav in dir → voiceprint JSON.
//   diarize --wav <16k-mono.wav> --known <self.json> --out <out.json>
//       → {"turns":[{"start":1.2,"end":4.5,"speaker":"self"|"other","score":0.83}]}
//
// Exit codes: 0 ok, 1 usage, 2 runtime failure.

struct VoicePrint: Codable {
    let label: String
    let embedding: [Float]
    let sampleCount: Int
    let model: String
}

struct Turn: Codable {
    let start: Double
    let end: Double
    let speaker: String
    let score: Float
}

struct TurnsOut: Codable {
    let turns: [Turn]
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("clawgate-diarizer: " + message + "\n").utf8))
    exit(code)
}

func argValue(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = (na.squareRoot() * nb.squareRoot())
    return denom > 0 ? dot / denom : 0
}

@main
struct Main {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fail("usage: clawgate-diarizer warmup | enroll --wav-dir <dir> --out <json> | diarize --wav <wav> --known <json> --out <json>", code: 1)
        }
        args.removeFirst()
        do {
            switch command {
            case "warmup":
                _ = try await DiarizerModels.downloadIfNeeded()
                print("models ready")
            case "enroll":
                try await enroll(args)
            case "diarize":
                try await diarize(args)
            case "--help", "help":
                print("clawgate-diarizer warmup | enroll --wav-dir <dir> --out <json> | diarize --wav <wav> --known <json> --out <json> [--threshold 0.6]")
            default:
                fail("unknown command: \(command)", code: 1)
            }
        } catch {
            fail("\(error)")
        }
    }

    static func makeDiarizer() async throws -> DiarizerManager {
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        return diarizer
    }

    static func enroll(_ args: [String]) async throws {
        guard let dir = argValue(args, "--wav-dir"), let out = argValue(args, "--out") else {
            fail("enroll requires --wav-dir and --out", code: 1)
        }
        let wavs = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".wav") }
            .sorted()
            .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        guard !wavs.isEmpty else { fail("no .wav files in \(dir)") }

        let diarizer = try await makeDiarizer()
        let converter = AudioConverter()
        var sum: [Float] = []
        var used = 0
        for url in wavs {
            let samples = try converter.resampleAudioFile(url)
            guard samples.count > 16_000 else { continue }  // skip < 1s clips
            let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
            if sum.isEmpty { sum = [Float](repeating: 0, count: embedding.count) }
            guard embedding.count == sum.count else { continue }
            for i in 0..<embedding.count { sum[i] += embedding[i] }
            used += 1
            FileHandle.standardError.write(Data("enrolled \(url.lastPathComponent)\n".utf8))
        }
        guard used > 0 else { fail("no usable clips (all too short or failed)") }
        var mean = sum.map { $0 / Float(used) }
        // L2-normalize the mean voiceprint.
        let norm = mean.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { mean = mean.map { $0 / norm } }

        let profile = VoicePrint(label: "self", embedding: mean, sampleCount: used, model: "wespeaker_v2")
        let data = try JSONEncoder().encode(profile)
        try data.write(to: URL(fileURLWithPath: out))
        FileHandle.standardError.write(Data("voiceprint written: \(out) (clips=\(used), dim=\(mean.count))\n".utf8))
    }

    static func diarize(_ args: [String]) async throws {
        guard let wav = argValue(args, "--wav"),
              let knownPath = argValue(args, "--known"),
              let out = argValue(args, "--out") else {
            fail("diarize requires --wav, --known, --out", code: 1)
        }
        let threshold = Float(argValue(args, "--threshold") ?? "") ?? 0.6

        let knownData = try Data(contentsOf: URL(fileURLWithPath: knownPath))
        let known = try JSONDecoder().decode(VoicePrint.self, from: knownData)

        let diarizer = try await makeDiarizer()
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(URL(fileURLWithPath: wav))
        let result = try diarizer.performCompleteDiarization(samples)

        // Self/other per segment: TimedSpeakerSegment carries its own
        // L2-normalized embedding — cosine against the enrolled voiceprint.
        let turns = result.segments.map { seg -> Turn in
            let score = cosineSimilarity(seg.embedding, known.embedding)
            return Turn(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speaker: score >= threshold ? "self" : "other",
                score: score
            )
        }
        let data = try JSONEncoder().encode(TurnsOut(turns: turns))
        try data.write(to: URL(fileURLWithPath: out))
    }
}
