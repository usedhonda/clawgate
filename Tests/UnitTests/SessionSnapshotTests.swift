import XCTest
@testable import ClawGate

final class SessionSnapshotTests: XCTestCase {

    // MARK: - Logical Key

    func testLogicalKeyNormalization() {
        let key1 = SessionSnapshot.makeLogicalKey(
            sessionType: "claude_code",
            project: "MyProject"
        )
        let key2 = SessionSnapshot.makeLogicalKey(
            sessionType: "CLAUDE_CODE",
            project: "myproject"
        )
        XCTAssertEqual(key1, key2, "Case should be normalized")
    }

    func testLogicalKeyWhitespaceNormalization() {
        let key1 = SessionSnapshot.makeLogicalKey(
            sessionType: "codex",
            project: "  tproj  "
        )
        let key2 = SessionSnapshot.makeLogicalKey(
            sessionType: "codex",
            project: "tproj"
        )
        XCTAssertEqual(key1, key2, "Whitespace should be trimmed")
    }

    func testLogicalKeyWithRootHint() {
        let key = SessionSnapshot.makeLogicalKey(
            sessionType: "claude_code",
            project: "clawgate",
            rootHint: "clawgate"
        )
        XCTAssertEqual(key, "claude_code|clawgate|clawgate")
    }

    func testLogicalKeyFormat() {
        let key = SessionSnapshot.makeLogicalKey(
            sessionType: "claude_code",
            project: "tproj"
        )
        XCTAssertEqual(key, "claude_code|tproj|")
    }

    func testLogicalKeyDistinguishesSessionType() {
        let ccKey = SessionSnapshot.makeLogicalKey(
            sessionType: "claude_code",
            project: "shared"
        )
        let codexKey = SessionSnapshot.makeLogicalKey(
            sessionType: "codex",
            project: "shared"
        )
        XCTAssertNotEqual(ccKey, codexKey,
            "Same project with different session types should have different keys")
    }

    // MARK: - Computed Properties

    func testTmuxTargetFormat() {
        let snap = SessionSnapshot(
            id: "main:1.0",
            sourceID: "main:1.0",
            logicalKey: "claude_code|test|",
            project: "test",
            sessionType: "claude_code",
            tmuxSession: "main",
            tmuxWindow: "1",
            tmuxPane: "0",
            status: "running",
            waitingReason: nil,
            attentionLevel: 0,
            questionText: nil,
            questionOptions: nil,
            questionSelected: nil,
            paneCapture: nil,
            captureSource: nil,
            isAttached: false
        )
        XCTAssertEqual(snap.tmuxTarget, "main:1.0")
    }

    func testReadyForSendRequiresWaitingInput() {
        let snap = makeSnapshot(status: "running")
        XCTAssertFalse(snap.readyForSend)

        let waiting = makeSnapshot(status: "waiting_input")
        XCTAssertTrue(waiting.readyForSend)
    }

    func testHasQuestionDataFromStructured() {
        let snap = SessionSnapshot(
            id: "x",
            sourceID: "x",
            logicalKey: "k",
            project: "p",
            sessionType: "claude_code",
            tmuxSession: "s",
            tmuxWindow: "0",
            tmuxPane: "0",
            status: "waiting_input",
            waitingReason: "askUserQuestion",
            attentionLevel: 1,
            questionText: "Continue?",
            questionOptions: ["yes", "no"],
            questionSelected: 0,
            paneCapture: nil,
            captureSource: nil,
            isAttached: false
        )
        XCTAssertTrue(snap.hasQuestionData)
    }

    func testHasQuestionDataFromPaneCapture() {
        let snap = SessionSnapshot(
            id: "x",
            sourceID: "x",
            logicalKey: "k",
            project: "p",
            sessionType: "claude_code",
            tmuxSession: "s",
            tmuxWindow: "0",
            tmuxPane: "0",
            status: "waiting_input",
            waitingReason: nil,
            attentionLevel: 1,
            questionText: nil,
            questionOptions: nil,
            questionSelected: nil,
            paneCapture: "some content",
            captureSource: .tmuxDirect,
            isAttached: false
        )
        XCTAssertTrue(snap.hasQuestionData)
    }

    // MARK: - Helpers

    private func makeSnapshot(status: String) -> SessionSnapshot {
        SessionSnapshot(
            id: "main:1.0",
            sourceID: "main:1.0",
            logicalKey: "claude_code|test|",
            project: "test",
            sessionType: "claude_code",
            tmuxSession: "main",
            tmuxWindow: "1",
            tmuxPane: "0",
            status: status,
            waitingReason: nil,
            attentionLevel: 0,
            questionText: nil,
            questionOptions: nil,
            questionSelected: nil,
            paneCapture: nil,
            captureSource: nil,
            isAttached: false
        )
    }
}
