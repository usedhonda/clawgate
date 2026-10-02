import Foundation

/// Failed or legacy capability responses never justify posting unsupported v2.
enum LineObservationProtocol {
    static func supportedVersion(capabilityData: Data) -> Int {
        guard let value = try? JSONSerialization.jsonObject(with: capabilityData) as? [String: Any],
              value["ok"] as? Bool == true,
              value["bodyCandidateFormat"] as? String == "line-body-candidate-v1",
              let versions = value["supportedSchemaVersions"] as? [Int], versions.contains(2) else { return 1 }
        return 2
    }
}
