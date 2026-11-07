import XCTest
@testable import ClawGate

final class TmuxDirectPollerTests: XCTestCase {
    private func pane(pid: Int32, title: String = "shell", command: String = "zsh") -> TmuxShell.PaneDescriptor {
        .init(session: "test", window: "0", pane: String(pid), currentCommand: command,
              title: title, currentPath: "/tmp/project", tty: "/dev/ttys000",
              isAttached: true, panePID: pid)
    }

    func testManyUnresolvedPanesShareOneFreshSnapshotPerPoll() {
        let panes = (1...20).map { pane(pid: Int32($0 * 10)) }
        var loads = 0
        let first = TmuxDirectPoller.sessionTypes(for: panes) {
            loads += 1
            return .init(output: (1...20).map { "\($0 * 10 + 1) \($0 * 10) node /tmp/@openai/codex/bin/codex.js" }.joined(separator: "\n"))
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(first, Array(repeating: "codex", count: 20))

        let second = TmuxDirectPoller.sessionTypes(for: panes) {
            loads += 1
            return .init(output: "")
        }
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(second.allSatisfy { $0 == nil }, "Do not retain exited processes across polls")
    }

    func testKnownPaneMetadataAvoidsProcessScanAndKeepsPrecedence() {
        let panes = [pane(pid: 10, title: "app.cdx", command: "claude"),
                     pane(pid: 20, title: "app.cc", command: "codex"),
                     pane(pid: 30, command: "claude"), pane(pid: 40, command: "codex"),
                     pane(pid: 0)]
        let types = TmuxDirectPoller.sessionTypes(for: panes) {
            XCTFail("Metadata-only classification must not launch ps")
            return .init(output: "")
        }
        XCTAssertEqual(types, ["codex", "claude_code", "claude_code", "codex", nil])
    }
}
