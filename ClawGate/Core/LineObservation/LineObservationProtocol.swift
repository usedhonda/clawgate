import Foundation

/// Failed or legacy capability responses never justify posting unsupported v2.
enum LineObservationProtocol {
    /// Same fixed adapter used by the legacy server bridge. Original bytes stay
    /// in the source outbox; the caller persists these derived bytes once.
    static func hubEnvelope(observation: Data, observationID: String) throws -> Data {
        guard let value = try JSONSerialization.jsonObject(with: observation) as? [String: Any],
              value["observationId"] as? String == observationID,
              value["platform"] as? String == "line",
              value["source"] as? String == "clawgate-line-passive-ocr",
              let capturedAt = value["capturedAt"] as? String, !capturedAt.isEmpty else {
            throw HubProducerProvision.Failure.invalidObservation
        }
        return try JSONSerialization.data(withJSONObject: [
            "source": "line", "domain": "line", "kind": "passive-observation",
            "occurred_at": capturedAt, "external_id": observationID,
            "identity": NSNull(), "metadata": value
        ], options: [.sortedKeys])
    }

    /// Current producer has no confirmed identity, including unavailable surfaces.
    /// Keep legacy observations unchanged; queued payloads never pass through here.
    static func snapshotsForWire(_ snapshots: [[String: Any]], schemaVersion: Int) -> [[String: Any]] {
        guard schemaVersion == 2 || schemaVersion == 3 else { return snapshots }
        return snapshots.map { snapshot in
            var result = snapshot
            result["conversationKey"] = NSNull()
            result["identityConfidence"] = "unknown"
            result["tailCoverage"] = false
            if snapshot["scope"] as? String != "selected_thread_visible_window" ||
                snapshot["coverage"] as? String != "available" {
                result["bodyCandidates"] = [] as [[String: Any]]
                if schemaVersion == 3 {
                    result["annotations"] = [] as [[String: Any]]
                    result["conversationLabel"] = NSNull()
                    result["conversationLabelEvidence"] = NSNull()
                }
            } else if result["bodyCandidates"] == nil {
                result["bodyCandidates"] = [] as [[String: Any]]
            }
            return result
        }
    }

    /// Version alone is not semantic compatibility. Never upgrade existing queued bytes.
    static func supportedHubVersion(capabilityData: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: capabilityData) as? [String: Any],
              let versions = object["line_observation_schema_versions"] as? [Int] else { return nil }
        if versions.contains(3), object["line_observation_semantic_format"] as? String == "line-visible-content-v1" { return 3 }
        if versions.contains(2) { return 2 }
        return versions.contains(1) ? 1 : nil
    }

    static func supportedVersion(capabilityData: Data) -> Int {
        guard let value = try? JSONSerialization.jsonObject(with: capabilityData) as? [String: Any],
              value["ok"] as? Bool == true,
              value["bodyCandidateFormat"] as? String == "line-body-candidate-v1",
              let versions = value["supportedSchemaVersions"] as? [Int], versions.contains(2) else { return 1 }
        return 2
    }
}
