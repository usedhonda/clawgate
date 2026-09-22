import AVFoundation
import CoreAudio
import Foundation

/// Reads a calendar reminder aloud on this Mac, with VOICEVOX running locally.
///
/// The Gateway decides which device speaks: it marks a reminder `speakOn: "mac"`
/// and this Mac obeys that field alone, reading no setting of its own, so there
/// is exactly one place that decides. The phone's own readout is unrelated and
/// both sounding is intended (御大 ruling 2026-09-18).
///
/// Every reminder that was addressed here reports back what happened, because a
/// readout that silently never sounds — asleep, lid closed, muted — is
/// invisible otherwise. Contract: oc-general
/// `plans/260918-calendar-imminent-reminder.md` §2.3 / §2.3b / §2.4.

/// The fields the Gateway adds to a reminder's chat payload.
struct ReminderPayload: Equatable {
    var kind: String?
    var speech: String?
    var speakOn: String?
    var reminderId: String?
    var startUtc: String?
    var expiresAt: String?

    static let calendarImminent = "calendar_imminent"
}

/// What to do with a reminder, and what to report.
enum ReminderDecision: Equatable {
    /// Not addressed to this Mac: say nothing, report nothing.
    case ignore
    /// Addressed here and worth speaking.
    case speak(reminderId: String, speech: String)
    /// Addressed here but not spoken, with the reason to report.
    case skip(reminderId: String, outcome: String)
}

enum ReminderReadoutDecider {
    /// Pure: everything decidable from the payload alone.
    ///
    /// A reminder without a `reminderId` is dropped rather than skipped —
    /// there is nothing to report it under, and a receipt with no id would just
    /// be noise in the Gateway's log.
    static func decide(_ payload: ReminderPayload, now: Date, seen: Set<String>) -> ReminderDecision {
        guard payload.kind == ReminderPayload.calendarImminent else { return .ignore }
        guard payload.speakOn == "mac" else { return .ignore }
        guard let id = payload.reminderId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return .ignore }

        // The display text is never a fallback: an empty script means the
        // Gateway had nothing to say, and inventing one would read out a
        // message written for the eye.
        let speech = payload.speech?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !speech.isEmpty else { return .skip(reminderId: id, outcome: "skipped:speech_empty") }

        // A reminder that arrives after the event has begun is noise. This is
        // what a resend or a wake from sleep produces.
        if let expiresAt = payload.expiresAt, let expiry = parseISO8601(expiresAt), now > expiry {
            return .skip(reminderId: id, outcome: "skipped:expired")
        }
        guard !seen.contains(id) else { return .skip(reminderId: id, outcome: "skipped:duplicate") }
        return .speak(reminderId: id, speech: speech)
    }

    static func parseISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// The Mac's output state, as far as a readout cares.
enum ReminderAudioOutput {
    /// nil when there is something to play through, otherwise the outcome to
    /// report instead of playing.
    static func blockingOutcome() -> String? {
        guard let device = SystemAudioTap.defaultOutputDevice() else { return "skipped:no_output_device" }
        if isMuted(device) { return "skipped:volume_zero" }
        if let volume = mainVolume(device), volume <= 0.0001 { return "skipped:volume_zero" }
        return nil
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    private static func mainVolume(_ device: AudioObjectID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }
}

/// Local VOICEVOX synthesis. The voice settings are the ones agreed with
/// oc-general on 2026-09-18 so this Mac and Host A sound the same.
struct VoicevoxSynthesizer {
    struct Voice {
        var speaker = 4
        var speed = 1.3
        var pitch = 0.0
        var intonation = 1.0
        var volume = 1.5
        var pause = 1.0
    }

    var endpoint = URL(string: "http://127.0.0.1:50021")!
    var voice = Voice()
    var timeout: TimeInterval = 20

    enum SynthesisError: Error, Equatable {
        case queryFailed(Int)
        case synthesisFailed(Int)
        case badResponse
    }

    /// Text in, a 16-bit PCM WAV out, normalized so a reminder is never much
    /// quieter or louder than the last one.
    func synthesize(_ text: String) throws -> Data {
        var query = try audioQuery(text)
        query["speedScale"] = voice.speed
        query["pitchScale"] = voice.pitch
        query["intonationScale"] = voice.intonation
        query["volumeScale"] = voice.volume
        query["pauseLengthScale"] = voice.pause
        let wav = try synthesis(query)
        return WavPeakNormalizer.normalized(wav, toDBFS: -1) ?? wav
    }

    private func audioQuery(_ text: String) throws -> [String: Any] {
        var components = URLComponents(url: endpoint.appendingPathComponent("audio_query"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "speaker", value: String(voice.speaker)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, status) = try send(request)
        guard status == 200 else { throw SynthesisError.queryFailed(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynthesisError.badResponse
        }
        return json
    }

    private func synthesis(_ query: [String: Any]) throws -> Data {
        var components = URLComponents(url: endpoint.appendingPathComponent("synthesis"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "speaker", value: String(voice.speaker))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: query)
        let (data, status) = try send(request)
        guard status == 200 else { throw SynthesisError.synthesisFailed(status) }
        guard !data.isEmpty else { throw SynthesisError.badResponse }
        return data
    }

    private func send(_ request: URLRequest) throws -> (Data, Int) {
        var outcome: Result<(Data, Int), Error> = .failure(SynthesisError.badResponse)
        let done = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                outcome = .success((data ?? Data(), status))
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 5) == .success else {
            throw SynthesisError.badResponse
        }
        return try outcome.get()
    }
}

/// Peak normalization for 16-bit PCM WAV data.
enum WavPeakNormalizer {
    /// Scales the samples so the loudest one sits at `toDBFS`, quieting a clip
    /// as readily as lifting one — one-directional scaling would leave loud
    /// reminders louder than quiet ones, which is the whole thing this prevents.
    /// Returns nil when the data is not a 16-bit PCM WAV or is silent, so the
    /// caller can fall back to the original rather than emit something wrong.
    static func normalized(_ wav: Data, toDBFS: Double) -> Data? {
        guard let range = dataChunkRange(wav), range.count >= 2 else { return nil }
        var samples = [Int16](repeating: 0, count: range.count / 2)
        _ = samples.withUnsafeMutableBytes { wav.copyBytes(to: $0, from: range) }

        let peak = samples.reduce(Int32(0)) { max($0, Int32(abs(Int32($1)))) }
        guard peak > 0 else { return nil }
        let target = pow(10, toDBFS / 20) * Double(Int16.max)
        let gain = target / Double(peak)
        for i in samples.indices {
            samples[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), (Double(samples[i]) * gain).rounded())))
        }
        var out = wav
        samples.withUnsafeBytes { out.replaceSubrange(range, with: $0) }
        return out
    }

    /// The byte range of the `data` chunk's payload, walking the RIFF chunks
    /// rather than assuming the canonical 44-byte header (VOICEVOX is not the
    /// only thing that may produce these).
    static func dataChunkRange(_ wav: Data) -> Range<Int>? {
        guard wav.count > 12,
              wav[wav.startIndex..<wav.startIndex + 4].elementsEqual(Array("RIFF".utf8)),
              wav[wav.startIndex + 8..<wav.startIndex + 12].elementsEqual(Array("WAVE".utf8)) else { return nil }
        var offset = wav.startIndex + 12
        while offset + 8 <= wav.endIndex {
            let id = wav[offset..<offset + 4]
            let size = Int(wav.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: offset - wav.startIndex + 4, as: UInt32.self)
            }.littleEndian)
            let body = offset + 8
            guard size >= 0, body + size <= wav.endIndex else { return nil }
            if id.elementsEqual(Array("data".utf8)) { return body..<(body + size) }
            offset = body + size + (size % 2)   // chunks are word-aligned
        }
        return nil
    }
}
