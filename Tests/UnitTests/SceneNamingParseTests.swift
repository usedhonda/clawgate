import XCTest
@testable import ClawGate

/// Loose parse of ちー's scene-naming reply: each line is "番号 区切り 名前".
/// Non-matching lines are ignored; names are trimmed; empty names dropped.
final class SceneNamingParseTests: XCTestCase {
    func testHalfWidthColon() {
        XCTAssertEqual(PetModel.parseSceneNaming("1: 朝会"), [1: "朝会"])
    }

    func testFullWidthColon() {
        XCTAssertEqual(PetModel.parseSceneNaming("2：デザイン定例"), [2: "デザイン定例"])
    }

    func testPeriodSeparator() {
        XCTAssertEqual(PetModel.parseSceneNaming("3. 打合せ"), [3: "打合せ"])
    }

    func testIgnoresDescriptionLines() {
        let text = "以下が各シーンの名前です。\n1: 朝会\nよろしくお願いします"
        XCTAssertEqual(PetModel.parseSceneNaming(text), [1: "朝会"])
    }

    func testEmptyInput() {
        XCTAssertEqual(PetModel.parseSceneNaming(""), [:])
    }

    func testMultipleLines() {
        let text = "1: 朝会\n2：デザイン定例\n3. 打合せ"
        XCTAssertEqual(PetModel.parseSceneNaming(text), [1: "朝会", 2: "デザイン定例", 3: "打合せ"])
    }

    func testEmptyNameDropped() {
        XCTAssertEqual(PetModel.parseSceneNaming("1: "), [:])
    }
}
