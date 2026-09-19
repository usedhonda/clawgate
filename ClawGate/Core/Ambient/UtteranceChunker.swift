import Foundation

/// Decides where a 16 kHz mono stream should be cut into transcription chunks.
///
/// A fixed 30s grid cuts through words; the 3s overlap then transcribes the
/// boundary twice, and the two transcriptions do not always match, leaving
/// duplicated or truncated lines. This cuts inside a pause instead, so most
/// chunks need no overlap at all.
///
/// Speech-vs-pause here only chooses the cut point. Whether a chunk holds speech
/// is still decided by whisper's Silero VAD downstream.
struct UtteranceChunker {
    enum Decision: Equatable {
        case keep
        /// Close the chunk now. `overlapSamples` of the chunk's tail must lead
        /// the next chunk (non-zero only for a forced cut in continuous speech).
        case cut(overlapSamples: Int)
    }

    static let sampleRate = 16_000
    static let frameSamples = 480                 // 30 ms

    let minChunkSamples: Int                      // never cut before this (20 s: whisper needs context)
    let maxChunkSamples: Int                      // always cut by this (30 s)
    let pauseSamples: Int                         // pause long enough to cut in (0.8 s)
    let forcedOverlapSamples: Int                 // overlap after a forced cut (1 s)

    private(set) var chunkSamples = 0
    private var quietRun = 0
    private var sawSpeech = false
    private var loudSamples = 0
    private let minSpeechSamples = Int(0.5 * Double(UtteranceChunker.sampleRate))
    private var noiseFloor: Double = 0.003
    private var pending: [Float] = []

    init(minSeconds: Double = 20, maxSeconds: Double = 30, pauseSeconds: Double = 0.8, forcedOverlapSeconds: Double = 1) {
        minChunkSamples = Int(minSeconds * Double(Self.sampleRate))
        maxChunkSamples = Int(maxSeconds * Double(Self.sampleRate))
        pauseSamples = Int(pauseSeconds * Double(Self.sampleRate))
        forcedOverlapSamples = Int(forcedOverlapSeconds * Double(Self.sampleRate))
    }

    /// Feed samples that were just written to the current chunk. Returns `.cut`
    /// as soon as the chunk should close; the caller closes it, opens the next
    /// one, writes the requested overlap, and calls `didStartChunk(primed:)`.
    mutating func consume(_ samples: UnsafeBufferPointer<Float>) -> Decision {
        var decision = Decision.keep
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.frameSamples {
            var sum = 0.0
            for i in offset..<(offset + Self.frameSamples) { let v = Double(pending[i]); sum += v * v }
            offset += Self.frameSamples
            chunkSamples += Self.frameSamples
            observe(rms: (sum / Double(Self.frameSamples)).squareRoot())
            if decision == .keep {
                // A pause only ends an utterance if there was one: pure silence
                // rolls over at the 30s cap, as before, instead of every 3s.
                if sawSpeech, chunkSamples >= minChunkSamples, quietRun >= pauseSamples {
                    decision = .cut(overlapSamples: 0)
                } else if chunkSamples >= maxChunkSamples {
                    // Still inside a pause (silence or a lull): nothing to repeat.
                    decision = .cut(overlapSamples: quietRun >= Self.frameSamples * 3 ? 0 : forcedOverlapSamples)
                }
            }
        }
        pending.removeFirst(offset)
        return decision
    }

    /// A new chunk began with `primed` overlap samples already in it.
    mutating func didStartChunk(primed: Int) {
        chunkSamples = primed
        quietRun = 0
        loudSamples = 0
        sawSpeech = primed > 0
    }

    private mutating func observe(rms: Double) {
        // Speech is well above the room's floor. The floor follows quiet frames
        // quickly and loud frames slowly, so talking does not raise it.
        let quiet = rms < max(noiseFloor * 3, 0.004)
        if quiet {
            quietRun += Self.frameSamples
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        } else {
            quietRun = 0
            // A click or a cough is not an utterance: it takes ~0.5s of sound
            // before a following pause may end the chunk.
            loudSamples += Self.frameSamples
            if loudSamples >= minSpeechSamples { sawSpeech = true }
            // Minutes, not seconds: a long monologue must not become the floor,
            // but a fan switched on must eventually stop counting as speech.
            noiseFloor = noiseFloor * 0.9999 + rms * 0.0001
        }
    }
}
