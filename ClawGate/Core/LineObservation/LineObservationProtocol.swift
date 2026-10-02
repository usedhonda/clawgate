import Foundation

/// Failed or legacy capability responses never justify posting unsupported v2.
enum LineObservationProtocol {
    /// Current producer has no confirmed identity, including unavailable surfaces.
    /// Keep legacy observations unchanged; queued payloads never pass through here.
    static func snapshotsForWire(_ snapshots: [[String: Any]], schemaVersion: Int) -> [[String: Any]] {
        guard schemaVersion == 2 else { return snapshots }
        return snapshots.map { snapshot in
            var result = snapshot
            result["conversationKey"] = NSNull()
            result["identityConfidence"] = "unknown"
            result["tailCoverage"] = false
            if snapshot["scope"] as? String != "selected_thread_visible_window" ||
                snapshot["coverage"] as? String != "available" {
                result["bodyCandidates"] = [] as [[String: Any]]
            } else if result["bodyCandidates"] == nil {
                result["bodyCandidates"] = [] as [[String: Any]]
            }
            return result
        }
    }

    static func supportedVersion(capabilityData: Data) -> Int {
        guard let value = try? JSONSerialization.jsonObject(with: capabilityData) as? [String: Any],
              value["ok"] as? Bool == true,
              value["bodyCandidateFormat"] as? String == "line-body-candidate-v1",
              let versions = value["supportedSchemaVersions"] as? [Int], versions.contains(2) else { return 1 }
        return 2
    }
}
