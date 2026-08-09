import AppKit
import XCTest
@testable import ClawGate

final class CharacterManifestTests: XCTestCase {
    private let fileManager = FileManager.default
    private let defaultFrameSize = CGSize(width: 16, height: 16)

    // MARK: - JSON Decoding

    func testDecodeMinimalManifest() throws {
        let json = """
        {
          "name": "test",
          "states": [
            {"name": "idle", "frames": ["idle.png"]}
          ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: json)
        XCTAssertEqual(manifest.name, "test")
        XCTAssertNil(manifest.displayName)
        XCTAssertNil(manifest.author)
        XCTAssertEqual(manifest.states.count, 1)
        XCTAssertEqual(manifest.states[0].name, "idle")
        XCTAssertEqual(manifest.states[0].frames, ["idle.png"])
    }

    func testDecodeFullManifest() throws {
        let json = """
        {
          "name": "chi",
          "displayName": "Chi",
          "author": "ClawGate",
          "version": "1.0.0",
          "description": "A test character",
          "states": [
            {"name": "idle", "frames": ["idle-01.png", "idle-02.png"], "fps": 3, "loop": true},
            {"name": "blink", "frames": ["blink-sheet.png"], "sheetColumns": 5, "sheetRows": 1, "fps": 8, "loop": false}
          ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: json)
        XCTAssertEqual(manifest.name, "chi")
        XCTAssertEqual(manifest.displayName, "Chi")
        XCTAssertEqual(manifest.author, "ClawGate")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.states.count, 2)
    }

    // MARK: - Chi Manifest fixture integration

    func testChiManifestLoadsFromBundleFixture() throws {
        let moduleBundle = Bundle(for: CharacterManager.self)
        let candidatePaths = [
            "Characters/chi",
            "Characters/chi-claw",
            "chi",
            "chi-claw",
        ]

        let manifestURL = candidatePaths.compactMap {
            moduleBundle.url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: $0
            )
        }.first { FileManager.default.fileExists(atPath: $0.path) }

        let enumeratedManifestURL = moduleBundle.resourceURL.flatMap { resourceURL in
            let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
            return enumerator?.compactMap { ($0 as? URL) }.first(where: {
                $0.lastPathComponent == "manifest.json" &&
                ($0.path.contains("/chi/") || $0.path.contains("/chi-claw/"))
            })
        }

        let sourceManifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClawGate/Resources/Characters/chi/manifest.json")
        let sourceBundleManifestURL = FileManager.default.fileExists(atPath: sourceManifestURL.path) ? sourceManifestURL : nil

        let fallbackURL = moduleBundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: "Characters"
        )?.first(where: {
            $0.lastPathComponent == "manifest.json" && $0.path.contains("/chi/")
        })

        guard let manifestURL = manifestURL ?? enumeratedManifestURL ?? fallbackURL ?? sourceBundleManifestURL else {
            XCTFail("Expected chi manifest fixture in Bundle.module")
            return
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: data)
        XCTAssertEqual(manifest.name, "chi")
        XCTAssertTrue(manifest.states.contains(where: { $0.name == "idle" }))
        XCTAssertTrue(manifest.states.contains(where: { $0.name == "speak" }))
    }

    // MARK: - State Info

    func testStateInfoIndividualFrames() throws {
        let json = """
        {"name": "walk", "frames": ["w1.png", "w2.png", "w3.png"], "fps": 6, "loop": true}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(CharacterManifest.StateInfo.self, from: json)
        XCTAssertEqual(state.name, "walk")
        XCTAssertEqual(state.frames.count, 3)
        XCTAssertFalse(state.isSheet)
        XCTAssertTrue(state.shouldLoop)
        XCTAssertEqual(state.fps, 6)
    }

    func testStateInfoSpriteSheet() throws {
        let json = """
        {"name": "react", "frames": ["react.png"], "sheetColumns": 3, "sheetRows": 2, "fps": 2, "loop": false}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(CharacterManifest.StateInfo.self, from: json)
        XCTAssertEqual(state.name, "react")
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertTrue(state.isSheet)
        XCTAssertFalse(state.shouldLoop)
        XCTAssertEqual(state.sheetColumns, 3)
        XCTAssertEqual(state.sheetRows, 2)
    }

    func testDefaultValues() throws {
        let json = """
        {"name": "idle", "frames": ["idle.png"]}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(CharacterManifest.StateInfo.self, from: json)
        XCTAssertNil(state.fps)
        XCTAssertNil(state.loop)
        XCTAssertTrue(state.shouldLoop)
        XCTAssertFalse(state.isSheet)
    }

    // MARK: - Character Manager

    func testScanEmptyDirectory() {
        let manager = CharacterManager(searchPaths: [nonExistentRoot()])
        manager.scan()
    }

    func testScanDeduplicatesCharactersByCanonicalOrder() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("bundle-a"),
            manifest: makeManifest(name: "dupe", states: [
                makeState(name: "idle", frames: ["first-idle.png"]),
            ]),
            frameColors: ["first-idle.png": .systemRed]
        )
        try makeBundle(
            at: root.appendingPathComponent("bundle-b"),
            manifest: makeManifest(name: "dupe", states: [
                makeState(name: "idle", frames: ["second-idle.png"]),
            ]),
            frameColors: ["second-idle.png": .systemBlue]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters.map { $0.name }, ["dupe"])
        XCTAssertEqual(diagCount(CharacterManager.duplicateBundleNameCode, manager.lastScanDiagnostics), 1)
    }

    func testScanReplacesSnapshotAndDoesNotAppendStaleEntries() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        let staleRoot = root.appendingPathComponent("stale")
        try makeBundle(
            at: staleRoot,
            manifest: makeManifest(name: "stale", states: [makeState(name: "idle", frames: ["stale.png"])]),
            frameColors: ["stale.png": .systemBlue]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "stale"
        manager.scan()
        XCTAssertEqual(manager.characters.map { $0.name }, ["stale"])
        XCTAssertEqual(manager.selectedName, "stale")

        try fileManager.removeItem(at: staleRoot)
        try makeBundle(
            at: root.appendingPathComponent("fresh"),
            manifest: makeManifest(name: "fresh", states: [makeState(name: "idle", frames: ["fresh.png"])]),
            frameColors: ["fresh.png": .systemGreen]
        )

        manager.scan()
        XCTAssertEqual(manager.characters.map { $0.name }, ["fresh"])
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 0)
        XCTAssertEqual(manager.selectedName, "fresh")
    }

    func testSelectedNameReconcilesWhenCurrentSelectionVanishes() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("first"),
            manifest: makeManifest(name: "first", states: [makeState(name: "idle", frames: ["first.png"])]),
            frameColors: ["first.png": .systemOrange]
        )
        try makeBundle(
            at: root.appendingPathComponent("second"),
            manifest: makeManifest(name: "second", states: [makeState(name: "idle", frames: ["second.png"])]),
            frameColors: ["second.png": .systemPink]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "missing"
        manager.scan()
        XCTAssertEqual(manager.selectedName, "first")
    }

    func testSelectedNameFallsBackDeterministicallyOnEmptyScan() {
        let manager = CharacterManager(searchPaths: [nonExistentRoot()])
        manager.selectedName = "previous-name"
        manager.scan()

        XCTAssertEqual(manager.selectedName, "")
        XCTAssertNil(manager.current())
        XCTAssertEqual(manager.characters, [])
    }

    func testScanRefreshUpdatesPreviewWhenBundleMovesWithSameCharacterName() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        let firstPath = root.appendingPathComponent("first")
        try makeBundle(
            at: firstPath,
            manifest: makeManifest(name: "same-name", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemBlue],
            previewColor: .systemRed,
            previewSize: CGSize(width: 12, height: 12)
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "same-name"
        manager.scan()

        guard let first = manager.current() else {
            return XCTFail("bundle should load")
        }
        XCTAssertEqual(first.preview?.size.width, 12)
        XCTAssertEqual(first.preview?.size.height, 12)
        let firstPreviewColor = pixelTuple(from: first.preview)
        guard let firstPreviewColor else {
            return XCTFail("preview should decode")
        }

        try fileManager.removeItem(at: firstPath)
        let secondPath = root.appendingPathComponent("second")
        try makeBundle(
            at: secondPath,
            manifest: makeManifest(name: "same-name", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemBlue],
            previewColor: .systemBlue,
            previewSize: CGSize(width: 20, height: 20)
        )

        manager.scan()
        guard let second = manager.current() else {
            return XCTFail("bundle should reload after move")
        }
        XCTAssertEqual(second.preview?.size.width, 20)
        XCTAssertEqual(second.preview?.size.height, 20)
        let secondPreviewColor = pixelTuple(from: second.preview)
        guard let secondPreviewColor else {
            return XCTFail("preview should decode after move")
        }

        if pixelTuplesEqual(firstPreviewColor, secondPreviewColor) {
            return XCTFail("preview assets should differ after rescan")
        }
    }

    func testScanRefreshUpdatesPreviewWhenOnlyPreviewChanges() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        let bundlePath = root.appendingPathComponent("same-path-preview")
        try makeBundle(
            at: bundlePath,
            manifest: makeManifest(name: "same-name", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemBlue],
            previewColor: .systemRed,
            previewSize: CGSize(width: 12, height: 12)
        )

        var readCounts: [String: Int] = [:]
        let manager = CharacterManager(
            searchPaths: [root],
            frameAssetReader: { url in
                readCounts[url.lastPathComponent, default: 0] += 1
                return try Data(contentsOf: url)
            }
        )
        manager.selectedName = "same-name"
        manager.scan()

        guard let before = manager.current() else {
            return XCTFail("bundle should load")
        }
        let beforeColor = pixelTuple(from: before.preview)
        guard let beforeColor else {
            return XCTFail("preview should decode")
        }
        XCTAssertEqual(readCounts["preview.png"], 1)

        try writePNG(at: bundlePath.appendingPathComponent("preview.png"), color: .systemBlue)
        manager.scan()

        guard let after = manager.current() else {
            return XCTFail("bundle should reload after preview rewrite")
        }
        let afterColor = pixelTuple(from: after.preview)
        guard let afterColor else {
            return XCTFail("preview should decode after rewrite")
        }
        XCTAssertEqual(readCounts["preview.png"], 2)

        if pixelTuplesEqual(beforeColor, afterColor) {
            return XCTFail("preview rewrite should invalidate refresh path and update preview")
        }
    }

    func testFrameAssetReaderInstanceDependencyDoesNotCrossManagers() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("multi-manager"),
            manifest: makeManifest(name: "multi-manager", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemBlue]
        )

        var managerAReads = 0
        var managerBReads = 0
        let managerA = CharacterManager(
            searchPaths: [root],
            frameAssetReader: { url in
                managerAReads += 1
                return try Data(contentsOf: url)
            }
        )

        let managerB = CharacterManager(
            searchPaths: [root],
            frameAssetReader: { url in
                managerBReads += 1
                return try Data(contentsOf: url)
            }
        )

        // Ensure a previous manager's injected reader is still used after another manager is created.
        managerB.scan()
        managerA.scan()

        XCTAssertEqual(managerAReads, 1)
        XCTAssertEqual(managerBReads, 1)
    }

    func testFramesUseScannedImageCacheWithoutAdditionalReaderReads() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("scan-read-count"),
            manifest: makeManifest(name: "scan-read-count", states: [
                makeState(name: "idle", frames: ["shared-idle.png", "shared-idle.png"]),
                CharacterManifest.StateInfo(
                    name: "sheet",
                    frames: ["shared-idle.png"],
                    fps: nil,
                    loop: nil,
                    sheetColumns: 2,
                    sheetRows: 1
                ),
            ]),
            frameColors: [
                "shared-idle.png": .systemBlue,
            ],
            imageSize: CGSize(width: 12, height: 6)
        )

        var readCounts: [String: Int] = [:]
        let reader: (URL) throws -> Data = { url in
            readCounts[url.lastPathComponent, default: 0] += 1
            return try Data(contentsOf: url)
        }

        let manager = CharacterManager(searchPaths: [root], frameAssetReader: reader)
        manager.scan()

        XCTAssertEqual(readCounts["shared-idle.png"], 1)
        manager.selectedName = "scan-read-count"

        guard let character = manager.current() else {
            return XCTFail("character cache should be present")
        }
        _ = character.frames(for: "idle")
        _ = character.frames(for: "sheet")
        _ = character.frames(for: "idle")
        _ = character.frames(for: "sheet")
        XCTAssertEqual(readCounts["shared-idle.png"], 1)
    }

    func testSharedFramePathReusedAcrossStatesStillValidatesEachSheetGrid() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("shared-sheet"),
            manifest: CharacterManifest(
                name: "shared-sheet",
                displayName: nil,
                author: nil,
                version: nil,
                description: nil,
                states: [
                    CharacterManifest.StateInfo(
                        name: "sheetA",
                        frames: ["sprite.png"],
                        fps: nil,
                        loop: nil,
                        sheetColumns: 2,
                        sheetRows: 1
                    ),
                    CharacterManifest.StateInfo(
                        name: "sheetB",
                        frames: ["sprite.png"],
                        fps: nil,
                        loop: nil,
                        sheetColumns: 3,
                        sheetRows: 1
                    ),
                ]
            ),
            frameColors: ["sprite.png": .systemBlue],
            imageSize: CGSize(width: 4, height: 2)
        )

        var readCounts: [String: Int] = [:]
        let manager = CharacterManager(
            searchPaths: [root],
            frameAssetReader: { url in
                readCounts[url.lastPathComponent, default: 0] += 1
                return try Data(contentsOf: url)
            }
        )

        manager.scan()

        XCTAssertEqual(readCounts["sprite.png"], 1)
        XCTAssertEqual(manager.characters, [])
        XCTAssertEqual(diagCount(CharacterManager.invalidSpriteConfigCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testCorruptPreviewFileKeepsBundleValidWithNilPreview() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root.appendingPathComponent("corrupt-preview"), withIntermediateDirectories: true)
        let bundlePath = root.appendingPathComponent("corrupt-preview")
        try encodeManifest(
            makeManifest(name: "corrupt-preview", states: [makeState(name: "idle", frames: ["idle.png"])]),
            to: bundlePath.appendingPathComponent("manifest.json")
        )
        try writePNG(at: bundlePath.appendingPathComponent("idle.png"), color: .systemBlue)
        try Data("not an image".utf8).write(to: bundlePath.appendingPathComponent("preview.png"))

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "corrupt-preview"
        manager.scan()

        XCTAssertEqual(manager.characters.map { $0.name }, ["corrupt-preview"])
        XCTAssertNotNil(manager.current())
        XCTAssertNil(manager.current()?.preview)
        XCTAssertEqual(diagCount(CharacterManager.invalidPreviewFileCode, manager.lastScanDiagnostics), 1)
    }

    func testMissingPreviewDoesNotEmitPreviewDiagnostic() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("no-preview"),
            manifest: makeManifest(name: "no-preview", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemBlue]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "no-preview"
        manager.scan()

        XCTAssertEqual(manager.characters.map { $0.name }, ["no-preview"])
        XCTAssertNil(manager.current()?.preview)
        XCTAssertEqual(diagCount(CharacterManager.invalidPreviewFileCode, manager.lastScanDiagnostics), 0)
    }

    func testMalformedManifestAndFrameDoNotPublishInvalidBundle() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("valid"),
            manifest: makeManifest(name: "valid", states: [makeState(name: "idle", frames: ["valid.png"])]),
            frameColors: ["valid.png": .systemBlue]
        )
        let badPath = root.appendingPathComponent("bad")
        try fileManager.createDirectory(at: badPath, withIntermediateDirectories: true)
        let missingFrameManifest = makeManifest(name: "bad", states: [makeState(name: "idle", frames: ["missing.png"])])
        try encodeManifest(missingFrameManifest, to: badPath.appendingPathComponent("manifest.json"))

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters.map { $0.name }, ["valid"])
        XCTAssertEqual(diagCount(CharacterManager.missingFrameFileCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testInvalidImageFrameIsRejected() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        let badPath = root.appendingPathComponent("invalid-image")
        try fileManager.createDirectory(at: badPath, withIntermediateDirectories: true)
        let manifest = makeManifest(name: "invalid-image", states: [makeState(name: "idle", frames: ["broken.png"])])
        try encodeManifest(manifest, to: badPath.appendingPathComponent("manifest.json"))
        try Data("not an image".utf8).write(to: badPath.appendingPathComponent("broken.png"))

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters, [])
        XCTAssertEqual(diagCount(CharacterManager.invalidImageFileCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testInvalidSpriteGridIsRejectedBeforePublishing() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("bad-grid"),
            manifest: CharacterManifest(
                name: "bad-grid",
                displayName: nil,
                author: nil,
                version: nil,
                description: nil,
                states: [
                    CharacterManifest.StateInfo(
                        name: "walk",
                        frames: ["walk.png"],
                        fps: nil,
                        loop: nil,
                        sheetColumns: 4,
                        sheetRows: 3
                    )
                ]
            ),
            frameColors: ["walk.png": .systemYellow],
            imageSize: CGSize(width: 10, height: 10)
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters, [])
        XCTAssertEqual(diagCount(CharacterManager.invalidSpriteConfigCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testSpriteCellOverflowIsRejectedWithoutCrash() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("overflow"),
            manifest: CharacterManifest(
                name: "overflow",
                displayName: nil,
                author: nil,
                version: nil,
                description: nil,
                states: [
                    CharacterManifest.StateInfo(
                        name: "idle",
                        frames: ["idle.png"],
                        fps: nil,
                        loop: nil,
                        sheetColumns: Int.max,
                        sheetRows: 2
                    )
                ]
            ),
            frameColors: ["idle.png": .systemOrange],
            imageSize: CGSize(width: 32, height: 32)
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters, [])
        XCTAssertEqual(diagCount(CharacterManager.invalidSpriteConfigCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testDuplicateStateNamesAreRejected() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("dupe"),
            manifest: CharacterManifest(
                name: "dupe",
                displayName: nil,
                author: nil,
                version: nil,
                description: nil,
                states: [
                    makeState(name: "idle", frames: ["idle-1.png"]),
                    makeState(name: "idle", frames: ["idle-2.png"]),
                ]
            ),
            frameColors: ["idle-1.png": .systemBlue, "idle-2.png": .systemGreen]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.scan()

        XCTAssertEqual(manager.characters, [])
        XCTAssertEqual(diagCount(CharacterManager.duplicateStateNameCode, manager.lastScanDiagnostics), 1)
        XCTAssertEqual(manager.lastScanDroppedBundleCount, 1)
    }

    func testRepeatedStateLookupUsesCachedFramesAndSkipsDiskAfterFirstDecode() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: root.appendingPathComponent("cache"),
            manifest: makeManifest(name: "cache", states: [
                makeState(name: "idle", frames: ["idle-cache.png", "idle-cache-2.png"]),
                makeState(name: "blink", frames: ["blink-cache.png"]),
            ]),
            frameColors: [
                "idle-cache.png": .systemPurple,
                "idle-cache-2.png": .systemPurple,
                "blink-cache.png": .systemPurple,
            ]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "cache"
        manager.scan()

        guard let character = manager.current() else {
            return XCTFail("character cache should be present")
        }

        let idleFirst = character.frames(for: "idle")
        XCTAssertEqual(idleFirst.count, 2)
        XCTAssertEqual(character.decodedFrameCount, 2)

        let idleSecond = character.frames(for: "idle")
        XCTAssertEqual(idleSecond.count, 2)
        XCTAssertEqual(character.decodedFrameCount, 2)

        let blink = character.frames(for: "blink")
        XCTAssertEqual(blink.count, 1)
        XCTAssertEqual(character.decodedFrameCount, 3)
    }

    func testSamePathImageRewriteRefreshesAssetFingerprintAndReloadsFrame() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }
        let path = root.appendingPathComponent("rewrite")

        try makeBundle(
            at: path,
            manifest: makeManifest(name: "rewrite", states: [
                makeState(name: "idle", frames: ["idle.png"]),
            ]),
            frameColors: ["idle.png": .systemRed]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "rewrite"
        manager.scan()

        guard let before = manager.current() else {
            return XCTFail("bundle should load")
        }
        let beforeFrame = before.frames(for: "idle").first
        let beforeColor = pixelTuple(from: beforeFrame)
        XCTAssertEqual(before.decodedFrameCount, 1)

        try writePNG(at: path.appendingPathComponent("idle.png"), color: .systemGreen)
        manager.scan()

        guard let after = manager.current() else {
            return XCTFail("bundle should reload after rewrite")
        }
        let afterFrame = after.frames(for: "idle").first
        let afterColor = pixelTuple(from: afterFrame)
        XCTAssertEqual(after.decodedFrameCount, 1)
        if pixelTuplesEqual(beforeColor, afterColor) {
            return XCTFail("frame asset should refresh when rewritten at same path")
        }
    }

    func testFrameCacheIdentityIncludesRenderKeyComponents() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }

        let alphaPath = root.appendingPathComponent("alpha")
        try makeBundle(
            at: alphaPath,
            manifest: makeManifest(name: "alpha", states: [
                makeState(name: "idle", frames: ["idle-1.png", "idle-1.png"]),
                makeState(name: "sheet", frames: ["sheet.png"], sheetColumns: 1, sheetRows: 2),
            ]),
            frameColors: [
                "idle-1.png": .systemBlue,
                "sheet.png": .systemBlue,
            ],
            imageSizes: [
                "sheet.png": CGSize(width: 20, height: 10),
            ]
        )
        try makeBundle(
            at: root.appendingPathComponent("beta"),
            manifest: makeManifest(name: "beta", states: [
                makeState(name: "idle", frames: ["beta.png"]),
            ]),
            frameColors: ["beta.png": .systemRed]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "alpha"
        manager.scan()

        guard let alpha = manager.current() else {
            return XCTFail("alpha should load")
        }

        let framesByIndex = alpha.frames(for: "idle")
        XCTAssertEqual(framesByIndex.count, 2)
        XCTAssertTrue(framesByIndex[0] === framesByIndex[1])
        XCTAssertEqual(alpha.decodedFrameCount, 2)

        let sheetFrames = alpha.frames(for: "sheet")
        XCTAssertEqual(sheetFrames.count, 2)
        XCTAssertEqual(alpha.decodedFrameCount, 3)

        manager.selectedName = "beta"
        guard let beta = manager.current() else {
            return XCTFail("beta should load")
        }
        let betaFrames = beta.frames(for: "idle")
        XCTAssertEqual(betaFrames.count, 1)
        XCTAssertEqual(beta.decodedFrameCount, 1)

        manager.selectedName = "alpha"
        try encodeManifest(
            makeManifest(name: "alpha", states: [
                makeState(name: "idle", frames: ["idle-2.png", "idle-1.png"]),
                makeState(name: "sheet", frames: ["sheet.png"], sheetColumns: 2, sheetRows: 1),
            ]),
            to: alphaPath.appendingPathComponent("manifest.json")
        )
        try writePNG(at: alphaPath.appendingPathComponent("idle-2.png"), color: .systemGreen)
        manager.scan()

        guard let alphaAfter = manager.current() else {
            return XCTFail("alpha should load after identity update")
        }
        _ = alphaAfter.frames(for: "idle")
        XCTAssertEqual(alphaAfter.decodedFrameCount, 2)
        _ = alphaAfter.frames(for: "sheet")
        XCTAssertEqual(alphaAfter.decodedFrameCount, 3)
    }

    // MARK: - Helpers

    private func nonExistentRoot() -> URL {
        return fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTempRoot() -> URL {
        let path = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func makeManifest(name: String, states: [CharacterManifest.StateInfo]) -> CharacterManifest {
        CharacterManifest(
            name: name,
            displayName: nil,
            author: nil,
            version: nil,
            description: nil,
            states: states
        )
    }

    private func makeState(
        name: String,
        frames: [String],
        sheetColumns: Int? = nil,
        sheetRows: Int? = nil
    ) -> CharacterManifest.StateInfo {
        CharacterManifest.StateInfo(
            name: name,
            frames: frames,
            fps: nil,
            loop: nil,
            sheetColumns: sheetColumns,
            sheetRows: sheetRows
        )
    }

    private func makeBundle(
        at path: URL,
        manifest: CharacterManifest,
        frameColors: [String: NSColor],
        previewColor: NSColor? = nil,
        previewSize: CGSize = CGSize(width: 16, height: 16),
        imageSize: CGSize? = nil,
        imageSizes: [String: CGSize] = [:]
    ) throws {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        try encodeManifest(manifest, to: path.appendingPathComponent("manifest.json"))

        if let previewColor {
            try writePNG(at: path.appendingPathComponent("preview.png"), color: previewColor, size: previewSize)
        }

        for (filename, color) in frameColors {
            let size = imageSizes[filename] ?? imageSize ?? defaultFrameSize
            try writePNG(at: path.appendingPathComponent(filename), color: color, size: size)
        }
    }

    private func encodeManifest(_ manifest: CharacterManifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url)
    }

    private func writePNG(
        at url: URL,
        color: NSColor,
        size: CGSize = CGSize(width: 16, height: 16)
    ) throws {
        let imageSize = size
        let image = NSImage(size: imageSize)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CharacterManifestTests", code: 1)
        }

        try png.write(to: url)
    }

    private func pixelTuple(from image: NSImage?) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard let image,
              let imageData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: imageData),
              let color = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return nil
        }

        return (
            UInt8((color.redComponent * 255).rounded()),
            UInt8((color.greenComponent * 255).rounded()),
            UInt8((color.blueComponent * 255).rounded()),
            UInt8((color.alphaComponent * 255).rounded())
        )
    }

    private func pixelTuplesEqual(_ lhs: (UInt8, UInt8, UInt8, UInt8)?, _ rhs: (UInt8, UInt8, UInt8, UInt8)?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.some(left), .some(right)):
            return left.0 == right.0 && left.1 == right.1 && left.2 == right.2 && left.3 == right.3
        default:
            return false
        }
    }

    private func diagCount(_ code: String, _ diagnostics: [CharacterManagerScanDiagnostic]) -> Int {
        diagnostics.first(where: { $0.code == code })?.count ?? 0
    }
}
