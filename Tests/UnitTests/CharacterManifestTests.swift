import AppKit
import XCTest
@testable import ClawGate

final class CharacterManifestTests: XCTestCase {
    private let fileManager = FileManager.default

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

    func testChangingIdentityComponentsInvalidatesFrameCacheExactlyOnce() throws {
        let root = makeTempRoot()
        defer { try? fileManager.removeItem(at: root) }
        let alphaPath = root.appendingPathComponent("alpha")

        try makeBundle(
            at: alphaPath,
            manifest: makeManifest(name: "alpha", states: [
                makeState(name: "idle", frames: ["idle@1x-0.png", "idle@1x-1.png"]),
                makeState(name: "speak", frames: ["speak@1x-0.png"]),
            ]),
            frameColors: [
                "idle@1x-0.png": .systemBlue,
                "idle@1x-1.png": .systemBlue,
                "speak@1x-0.png": .systemRed,
                "idle@1x-2.png": .systemGreen,
                "idle@2x-0.png": .systemPurple,
            ]
        )
        try makeBundle(
            at: root.appendingPathComponent("beta"),
            manifest: makeManifest(name: "beta", states: [
                makeState(name: "idle", frames: ["idle@1x-0.png"]),
            ]),
            frameColors: ["idle@1x-0.png": .systemBlue]
        )

        let manager = CharacterManager(searchPaths: [root])
        manager.selectedName = "alpha"
        manager.scan()

        guard let alpha = manager.current() else {
            return XCTFail("alpha should load")
        }

        _ = alpha.frames(for: "idle")
        XCTAssertEqual(alpha.decodedFrameCount, 2)
        _ = alpha.frames(for: "idle")
        XCTAssertEqual(alpha.decodedFrameCount, 2)
        _ = alpha.frames(for: "speak")
        XCTAssertEqual(alpha.decodedFrameCount, 3)
        _ = alpha.frames(for: "idle")
        XCTAssertEqual(alpha.decodedFrameCount, 3)

        try encodeManifest(
            makeManifest(name: "alpha", states: [
                makeState(name: "idle", frames: ["idle@1x-2.png"]),
            ]),
            to: alphaPath.appendingPathComponent("manifest.json")
        )
        manager.scan()
        guard let alphaAfterFrameIndexChange = manager.current() else {
            return XCTFail("alpha should load after frame index change")
        }
        _ = alphaAfterFrameIndexChange.frames(for: "idle")
        XCTAssertEqual(alphaAfterFrameIndexChange.decodedFrameCount, 1)
        _ = alphaAfterFrameIndexChange.frames(for: "idle")
        XCTAssertEqual(alphaAfterFrameIndexChange.decodedFrameCount, 1)

        try encodeManifest(
            makeManifest(name: "alpha", states: [
                makeState(name: "idle", frames: ["idle@2x-0.png"]),
            ]),
            to: alphaPath.appendingPathComponent("manifest.json")
        )
        manager.scan()
        guard let alphaAfterScaleChange = manager.current() else {
            return XCTFail("alpha should load after scale variant change")
        }
        _ = alphaAfterScaleChange.frames(for: "idle")
        XCTAssertEqual(alphaAfterScaleChange.decodedFrameCount, 1)
        _ = alphaAfterScaleChange.frames(for: "idle")
        XCTAssertEqual(alphaAfterScaleChange.decodedFrameCount, 1)

        manager.selectedName = "beta"
        guard let beta = manager.current() else {
            return XCTFail("beta should load")
        }
        _ = beta.frames(for: "idle")
        XCTAssertEqual(beta.decodedFrameCount, 1)
        XCTAssertEqual(alphaAfterScaleChange.decodedFrameCount, 1)
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

    private func makeState(name: String, frames: [String]) -> CharacterManifest.StateInfo {
        CharacterManifest.StateInfo(
            name: name,
            frames: frames,
            fps: nil,
            loop: nil,
            sheetColumns: nil,
            sheetRows: nil
        )
    }

    private func makeBundle(at path: URL, manifest: CharacterManifest, frameColors: [String: NSColor]) throws {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        try encodeManifest(manifest, to: path.appendingPathComponent("manifest.json"))

        for (filename, color) in frameColors {
            try writePNG(at: path.appendingPathComponent(filename), color: color)
        }
    }

    private func encodeManifest(_ manifest: CharacterManifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url)
    }

    private func writePNG(at url: URL, color: NSColor) throws {
        let imageSize = CGSize(width: 16, height: 16)
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

    private func diagCount(_ code: String, _ diagnostics: [CharacterManagerScanDiagnostic]) -> Int {
        diagnostics.first(where: { $0.code == code })?.count ?? 0
    }
}
