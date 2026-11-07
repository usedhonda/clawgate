import XCTest
@testable import ClawGate

final class TmuxShellTests: XCTestCase {
    func testProcessEnvironmentPreservesBaseAndSetsLCAll() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/test"]
        let result = TmuxShell.processEnvironment(base: base)

        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["LC_ALL"], "en_US.UTF-8")
    }

    func testProcessEnvironmentOverridesExistingLocale() {
        let base = ["LC_ALL": "C", "LANG": "C"]
        let result = TmuxShell.processEnvironment(base: base)

        XCTAssertEqual(result["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(result["LANG"], "C")
    }

    func testLargeStdoutAndStderrDrainWithoutDeadlock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = [#"BEGIN { for (i=0; i<262144; i++) printf "o"; for (i=0; i<262144; i++) printf "e" > "/dev/stderr"; }"#]
        // Bound a regression to five seconds instead of hanging the test worker.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        let output = try TmuxShell.captureOutput(of: process)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.utf8.count, 262_144)
        XCTAssertEqual(output.stderr.utf8.count, 262_144)
    }

    func testProcessSnapshotPreservesDepthOrderAndUnicodeArguments() {
        let snapshot = TmuxShell.ProcessSnapshot(output: """
            10 1 /bin/zsh
            11 10 node /tmp/開発/claude-code
            12 10 /usr/bin/helper
            13 11 /usr/bin/worker
            14 13 /usr/bin/deep
            15 14 /usr/bin/too-deep
            10 13 /bin/zsh
            999999999999 10 invalid-pid
            invalid row
            """)
        XCTAssertEqual(snapshot.descendantArgs(rootPID: 10), [
            "node /tmp/開発/claude-code", "/usr/bin/helper", "/usr/bin/worker", "/usr/bin/deep"
        ])
        XCTAssertEqual(snapshot.descendantArgs(rootPID: 10, maxDepth: 1), [
            "node /tmp/開発/claude-code", "/usr/bin/helper"
        ])
        XCTAssertTrue(snapshot.descendantArgs(rootPID: 10, maxDepth: 0).isEmpty)
    }
}
