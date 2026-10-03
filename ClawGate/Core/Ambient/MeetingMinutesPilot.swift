import Foundation
import CryptoKit

/// A local, exact-revision deployment checkpoint, not a Gateway capability.
/// Absent by default. Set only after the deployed owner reports readiness.
/// It admits one new part total, including across process restarts, and never
/// enables all meetings or the later max-two rollout implicitly.
struct MeetingMinutesPilot {
    static let defaultsKey = "clawgate.minutes.singleRunAcceptance"
    enum Mode { case singlePart, boundedMeeting }
    let mode: Mode
    let meetingID: String
    let jobSHA256: String

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let values = defaults.dictionary(forKey: defaultsKey),
              let version = values["version"] as? Int,
              (version == 1 && Set(values.keys) == ["version", "meetingID", "jobSHA256"] ||
               version == 2 && Set(values.keys) == ["version", "meetingID", "jobSHA256", "mode"] &&
               values["mode"] as? String == "boundedMeeting"),
              let id = values["meetingID"] as? String, !id.isEmpty,
              let revision = values["jobSHA256"] as? String,
              revision.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return Self(mode: version == 1 ? .singlePart : .boundedMeeting, meetingID: id, jobSHA256: revision)
    }

    func matches(store: MeetingStore, id: String, job: MeetingMinutesJob) -> Bool {
        guard id == meetingID else { return false }
        guard let bytes = try? Data(contentsOf: store.directory(for: id).appendingPathComponent("minutes-job.json")),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == jobSHA256,
              let stored = try? JSONDecoder().decode(MeetingMinutesJob.self, from: bytes),
              stored.fingerprint == job.fingerprint else { return false }
        return (try? stored.envelopes.map(MeetingMinutesExecutionState.hash)) ==
               (try? job.envelopes.map(MeetingMinutesExecutionState.hash))
    }
}
