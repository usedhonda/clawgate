import XCTest
@testable import ClawGate

/// D34: the Pet Log window contract spec must exist and stay version-consistent
/// with the code — the policyVersion it quotes must equal the code constant, so
/// a version bump can't silently drift the spec.
final class PetLogWindowSpecTests: XCTestCase {
    private func specPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/pet-log-window-spec.md").path
    }

    /// Extracts the "## Normative (shipped)" section body (up to the next
    /// "## " heading) so version checks can't be satisfied by a Target-section
    /// mention (D144).
    private func normativeSection(_ spec: String) -> String {
        guard let start = spec.range(of: "## Normative") else { return "" }
        let rest = spec[start.upperBound...]
        if let next = rest.range(of: "\n## ") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    func testSpecExistsAndNormativeSectionMatchesPolicyVersion() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        XCTAssertTrue(spec.contains("Pet Log"), "spec must be the Pet Log window contract")
        XCTAssertTrue(spec.contains("Operating rule"), "spec must carry the same-commit update rule")

        // D144: the CURRENT policyVersion must appear in the NORMATIVE section
        // exactly once, and no older version string may appear there — a version
        // bump that leaves Normative on the old version must fail (a Target-section
        // mention can't rescue it).
        let normative = normativeSection(spec)
        let current = PetLogPromptBuilder.policyVersion
        let occurrences = normative.components(separatedBy: current).count - 1
        XCTAssertEqual(occurrences, 1,
                       "the current policyVersion must appear exactly once in the Normative section")
        // Any pet-log-context-vN other than the current must be absent from Normative.
        for old in ["pet-log-context-v0", "pet-log-context-v1", "pet-log-context-v2", "pet-log-context-v3"]
        where old != current {
            XCTAssertFalse(normative.contains(old),
                           "a stale version (\(old)) must not appear in the Normative section")
        }
    }

    /// Public-repo safety: the spec must not leak obvious PII/infra markers.
    func testSpecIsPublicSafe() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        for marker in [".ts.net", "100.", "ssh ", "Bearer "] {
            XCTAssertFalse(spec.contains(marker), "spec must not contain infra/PII marker: \(marker)")
        }
    }
}
