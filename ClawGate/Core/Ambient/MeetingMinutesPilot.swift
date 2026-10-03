import Foundation

/// A local, exact-revision deployment checkpoint, not a Gateway capability.
/// Absent by default. Set only after the deployed owner reports readiness.
/// It admits one new part total, including across process restarts, and never
/// enables all meetings or the later max-two rollout implicitly.
struct MeetingMinutesPilot {
    static let defaultsKey = "clawgate.minutes.singleRunAcceptance"
    let meetingID: String
    let revisionFileName: String

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let values = defaults.dictionary(forKey: defaultsKey),
              Set(values.keys) == ["version", "meetingID", "revisionFileName"],
              let version = values["version"] as? Int, version == 1,
              let id = values["meetingID"] as? String, !id.isEmpty,
              let revision = values["revisionFileName"] as? String,
              revision.hasPrefix("minutes-execution-"), revision.hasSuffix(".json"),
              !revision.contains("/") else { return nil }
        return Self(meetingID: id, revisionFileName: revision)
    }

    func matches(store: MeetingStore, id: String, job: MeetingMinutesJob) -> Bool {
        guard id == meetingID else { return false }
        return (try? MeetingMinutesExecutionState.fileURL(store: store, id: id, job: job).lastPathComponent) == revisionFileName
    }
}
