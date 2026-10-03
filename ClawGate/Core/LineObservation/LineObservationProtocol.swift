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
