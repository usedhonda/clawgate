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

        // Extract EVERY `pet-log-context-vN` token in the Normative section via
        // regex (not a fixed v0..v3 list, which silently misses a future vN).
        // The current version must appear exactly once and no other version at all.
        let regex = try NSRegularExpression(pattern: "pet-log-context-v[0-9]+")
        let ns = normative as NSString
        let matches = regex.matches(in: normative, range: NSRange(location: 0, length: ns.length))
        let versions = matches.map { ns.substring(with: $0.range) }
        XCTAssertEqual(versions.filter { $0 == current }.count, 1,
                       "the current policyVersion must appear exactly once in the Normative section")
        let stale = versions.filter { $0 != current }
        XCTAssertTrue(stale.isEmpty,
                      "no stale policyVersion may appear in the Normative section, found: \(Set(stale))")
    }

    /// Public-repo safety: the spec must not leak obvious PII/infra markers.
    func testSpecIsPublicSafe() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        for marker in [".ts.net", "100.", "ssh ", "Bearer "] {
            XCTAssertFalse(spec.contains(marker), "spec must not contain infra/PII marker: \(marker)")
        }
    }

    func testSpecDefinesActionResultPaneAndTopicSummary() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        let normative = normativeSection(spec)
        XCTAssertTrue(normative.contains("action result surface"))
        XCTAssertTrue(normative.contains("not a conversation thread"))
        XCTAssertTrue(normative.contains("topic spaces"))
        XCTAssertTrue(normative.contains("fixed 3–5 one-line"))
    }
}
