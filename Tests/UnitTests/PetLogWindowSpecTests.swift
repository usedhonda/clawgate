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

    func testSpecExistsAndMatchesPolicyVersion() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        XCTAssertTrue(spec.contains("Pet Log"), "spec must be the Pet Log window contract")
        XCTAssertTrue(spec.contains("Operating rule"), "spec must carry the same-commit update rule")
        // The current code policyVersion must appear in the Normative section.
        XCTAssertTrue(spec.contains(PetLogPromptBuilder.policyVersion),
                      "spec must quote the current code policyVersion (\(PetLogPromptBuilder.policyVersion))")
    }

    /// Public-repo safety: the spec must not leak obvious PII/infra markers.
    func testSpecIsPublicSafe() throws {
        let spec = try String(contentsOfFile: specPath(), encoding: .utf8)
        for marker in [".ts.net", "100.", "ssh ", "Bearer "] {
            XCTAssertFalse(spec.contains(marker), "spec must not contain infra/PII marker: \(marker)")
        }
    }
}
