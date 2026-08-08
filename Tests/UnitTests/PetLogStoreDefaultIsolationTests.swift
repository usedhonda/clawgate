import XCTest
@testable import ClawGate

/// D37: test isolation must be safe-by-construction, not convention-dependent.
/// This class deliberately does NOT redirect `PetLogStore.dir` in setUp — it
/// proves that even a case which forgets the per-test override can never resolve
/// to (or write into) the real `~/.clawgate/logs` (2026-07-14 incident class).
final class PetLogStoreDefaultIsolationTests: XCTestCase {
    func testDefaultDirIsNeverProductionUnderXCTest() {
        let def = PetLogStore.defaultDir()
        XCTAssertTrue(def.hasPrefix(NSTemporaryDirectory()),
                      "under XCTest the default store dir must live under the temp root, got \(def)")
        XCTAssertFalse(def.contains(".clawgate/logs"),
                       "the production path must be structurally unreachable under XCTest")

        let production = NSString("~/.clawgate/logs").expandingTildeInPath
        XCTAssertNotEqual(def, production)
    }

    /// A bare save (no per-case override) lands outside production. Hold the
    /// shared semaphore so a parallel class's override can't race `dir`.
    func testBareSaveLandsOutsideProduction() throws {
        PetLogStore.testIsolationSemaphore.wait()
        let saved = PetLogStore.dir
        PetLogStore.dir = PetLogStore.defaultDir()  // what a forgetful class inherits
        defer {
            try? FileManager.default.removeItem(atPath: PetLogStore.dir)
            PetLogStore.dir = saved
            PetLogStore.testIsolationSemaphore.signal()
        }
        let entry = NotificationEntry(id: "d", text: "x", source: "log", timestamp: Date())
        XCTAssertTrue(PetLogStore.save([entry], file: "log.json"))
        let written = (PetLogStore.dir as NSString).appendingPathComponent("log.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written))
        XCTAssertFalse(written.contains(".clawgate/logs"),
                       "a bare save must never target the production directory")
    }

    /// AUXILIARY lint (the PRIMARY guard is the runtime block in
    /// PetLogStore.productionAccessBlocked, tested below). Allowlist-style: every
    /// `PetLogStore.dir = …` assignment must use a recognized safe seam
    /// (temp root / default / a saved-original restore var / /dev/null), or
    /// carry an explicit `// petlog-test-dir-ok` opt-out comment for a
    /// deliberate case. A variable-indirected production assignment that slips
    /// past this is still caught at runtime.
    func testNoTestAssignsStoreDirToProduction() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: testsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let allowedRHS = ["NSTemporaryDirectory", "defaultDir(", "original", "saved", "/dev/null"]
        let optOut = "petlog-test-dir-ok"
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                // Skip comment/doc lines — only real code assignments matter.
                if trimmedLine.hasPrefix("//") || trimmedLine.hasPrefix("*") { continue }
                guard let range = line.range(of: "PetLogStore.dir") else { continue }
                let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // Only assignments (`=`, not `==` comparisons).
                guard after.hasPrefix("=") && !after.hasPrefix("==") else { continue }
                let safe = allowedRHS.contains { line.contains($0) } || line.contains(optOut)
                XCTAssertTrue(safe,
                              "\(file.lastPathComponent):\(n + 1) assigns PetLogStore.dir without an allowlisted seam (add // \(optOut) if intentional): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// PRIMARY D37 guard: even a variable-indirected assignment of the store dir
    /// to the real production path is refused at the I/O entry points under
    /// XCTest — save and load both no-op, and no bytes are written.
    func testRuntimeBlocksProductionDirEvenViaVariable() throws {
        PetLogStore.testIsolationSemaphore.wait()
        let saved = PetLogStore.dir
        let production = NSString("~/.clawgate/logs").expandingTildeInPath
        defer {
            PetLogStore.dir = saved  // petlog-test-dir-ok
            PetLogStore.testIsolationSemaphore.signal()
        }
        // Snapshot real files (if any) so we can prove they're untouched.
        let realLog = (production as NSString).appendingPathComponent("log.json")
        let before = try? Data(contentsOf: URL(fileURLWithPath: realLog))

        let productionVar = production  // indirection the source scan can't resolve
        PetLogStore.dir = productionVar  // petlog-test-dir-ok

        let entry = NotificationEntry(id: "x", text: "must not be written", source: "log", timestamp: Date())
        XCTAssertFalse(PetLogStore.save([entry], file: "log.json"),
                       "save to production must be refused under XCTest")
        if case .missing = PetLogStore.loadOutcome(file: "log.json") {} else {
            XCTFail("load from production must be refused (reported missing) under XCTest")
        }

        let after = try? Data(contentsOf: URL(fileURLWithPath: realLog))
        XCTAssertEqual(before, after, "real production bytes must be untouched")
    }

    /// D97: the runtime guard compares RESOLVED targets, so a trailing slash, a
    /// `..` segment, or a symlink alias that all point at the production dir are
    /// each refused for save / load / chmod, with real bytes untouched.
    func testRuntimeBlocksProductionDirPathVariants() throws {
        PetLogStore.testIsolationSemaphore.wait()
        let saved = PetLogStore.dir
        let production = NSString("~/.clawgate/logs").expandingTildeInPath
        let symlink = NSTemporaryDirectory() + "clawgate-prod-alias-\(UUID().uuidString)"
        try? FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: production)
        defer {
            try? FileManager.default.removeItem(atPath: symlink)
            PetLogStore.dir = saved  // petlog-test-dir-ok
            PetLogStore.testIsolationSemaphore.signal()
        }
        let realLog = (production as NSString).appendingPathComponent("log.json")
        let before = try? Data(contentsOf: URL(fileURLWithPath: realLog))

        let variants: [(String, String)] = [
            ("trailing slash", production + "/"),
            ("dot-dot", production + "/../logs"),
            ("symlink alias", symlink),
        ]
        for (label, variant) in variants {
            PetLogStore.dir = variant  // petlog-test-dir-ok
            XCTAssertFalse(PetLogStore.save([NotificationEntry(id: "x", text: "no", source: "log", timestamp: Date())], file: "log.json"),
                           "\(label): save must be refused")
            if case .missing = PetLogStore.loadOutcome(file: "log.json") {} else {
                XCTFail("\(label): load must be refused (missing)")
            }
            XCTAssertTrue(PetLogStore.convergePermissionsOnLoad(file: "log.json"),
                          "\(label): chmod convergence must be a blocked no-op")
            let after = try? Data(contentsOf: URL(fileURLWithPath: realLog))
            XCTAssertEqual(before, after, "\(label): real production bytes must be untouched")
        }
    }
}
