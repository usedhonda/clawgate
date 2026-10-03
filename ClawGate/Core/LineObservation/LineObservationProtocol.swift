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
                    result["axObservations"] = [] as [[String: Any]]
                }
            } else if result["bodyCandidates"] == nil {
                result["bodyCandidates"] = [] as [[String: Any]]
            }
            return result
        }
    }

    /// Preserve the legacy admission ceilings even on the generic Hub route.
    /// Over-limit content is not truncated into a misleading partial success.
    static func boundedV3Observation(_ observation: [String: Any]) throws -> (data: Data, limited: Bool) {
        var value = observation
        guard value["schemaVersion"] as? Int == 3,
              let snapshots = value["snapshots"] as? [[String: Any]],
              let id = value["observationId"] as? String else { throw HubProducerProvision.Failure.invalidObservation }
        var limited = false
        if snapshots.count > 32 {
            value["snapshots"] = [unavailableV3Snapshot()]
            limited = true
        } else {
            value["snapshots"] = snapshots.map { snapshot in
                guard v3SnapshotWithinBounds(snapshot) else {
                    limited = true
                    return unavailableV3Snapshot(scope: snapshot["scope"] as? String ?? "state")
                }
                return snapshot
            }
        }
        func encoded() throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        var data = try encoded()
        if try hubEnvelope(observation: data, observationID: id).count > 2 * 1024 * 1024 {
            limited = true
            value["snapshots"] = [unavailableV3Snapshot()]
        }
        if limited {
            var state = value["state"] as? [String: Any] ?? [:]
            state["captureStatus"] = "observation_limits_exceeded"
            value["state"] = state
            data = try encoded()
        }
        guard try hubEnvelope(observation: data, observationID: id).count <= 2 * 1024 * 1024 else {
            throw HubProducerProvision.Failure.invalidObservation
        }
        return (data, limited)
    }

    private static func unavailableV3Snapshot(scope: String = "state") -> [String: Any] {
        ["scope": scope, "coverage": "unavailable", "reason": "observation_limits_exceeded",
         "conversationKey": NSNull(), "identityConfidence": "unknown", "tailCoverage": false,
         "ocrSpans": [], "bodyCandidates": [], "annotations": [], "axObservations": [],
         "conversationLabel": NSNull(), "conversationLabelEvidence": NSNull()]
    }

    private static func v3SnapshotWithinBounds(_ snapshot: [String: Any]) -> Bool {
        guard let spans = snapshot["ocrSpans"] as? [[String: Any]], spans.count <= 500,
              let bodies = snapshot["bodyCandidates"] as? [[String: Any]], bodies.count <= 500,
              let annotations = snapshot["annotations"] as? [[String: Any]], annotations.count <= 500,
              let ax = snapshot["axObservations"] as? [[String: Any]], ax.count <= 1 else { return false }
        let indices = Set(spans.indices)
        for (ordinal, span) in spans.enumerated() {
            guard span["ordinal"] as? Int == ordinal, let text = span["text"] as? String,
                  text.utf16.count <= 4000 else { return false }
        }
        var used = Set<Int>()
        for item in bodies + annotations {
            guard let text = item["text"] as? String, !text.isEmpty, text.utf16.count <= 4000,
                  let refs = item["spanOrdinals"] as? [Int], !refs.isEmpty, refs.count <= 500,
                  Set(refs).count == refs.count, Set(refs).isSubset(of: indices), used.isDisjoint(with: refs) else { return false }
            used.formUnion(refs)
        }
        let isConversation = snapshot["scope"] as? String == "selected_thread_visible_window" && snapshot["coverage"] as? String == "available"
        if isConversation {
            guard used == indices else { return false }
        } else if !bodies.isEmpty || !annotations.isEmpty || !ax.isEmpty { return false }
        if let label = snapshot["conversationLabel"] as? String {
            guard isConversation, !label.isEmpty, label.utf8.count <= 512, ax.count == 1,
                  let evidence = snapshot["conversationLabelEvidence"] as? [String: Any],
                  evidence["method"] as? String == "ax_window_title", evidence["axObservationOrdinal"] as? Int == 0,
                  ax[0]["ordinal"] as? Int == 0, ax[0]["attribute"] as? String == "AXTitle",
                  ax[0]["value"] as? String == label, ax[0]["corroboratedBy"] as? String == "SCWindow.title",
                  let windowID = snapshot["windowId"] as? String, ax[0]["windowId"] as? String == windowID else { return false }
        } else if !(snapshot["conversationLabel"] is NSNull) || !(snapshot["conversationLabelEvidence"] is NSNull) || !ax.isEmpty { return false }
        return true
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
