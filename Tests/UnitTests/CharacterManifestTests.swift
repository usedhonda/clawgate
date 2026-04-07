import XCTest
@testable import ClawGate

final class CharacterManifestTests: XCTestCase {

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
        XCTAssertTrue(state.shouldLoop)  // default
        XCTAssertFalse(state.isSheet)    // no sheetColumns
    }

    // MARK: - Character Manager

    func testScanEmptyDirectory() {
        let manager = CharacterManager()
        // scan() should not crash even if directories don't exist
        manager.scan()
        // May or may not find characters depending on environment
    }

    // MARK: - Chi Manifest (integration)

    func testChiManifestLoadsFromDisk() throws {
        let chiPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawgate/characters/chi/manifest.json")

        guard FileManager.default.fileExists(atPath: chiPath.path) else {
            // Skip if chi character not installed
            return
        }

        let data = try Data(contentsOf: chiPath)
        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: data)
        XCTAssertEqual(manifest.name, "chi")
        XCTAssertTrue(manifest.states.count > 0, "Chi should have at least one state")

        // Verify required states exist
        let stateNames = manifest.states.map(\.name)
        XCTAssertTrue(stateNames.contains("idle"), "Chi must have idle state")
        XCTAssertTrue(stateNames.contains("speak"), "Chi must have speak state")
    }
}
