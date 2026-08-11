import XCTest
@testable import ClawGate

final class PetModelFloatingGoalC2TeardownTests: XCTestCase {
    func testCleanupTwiceReleasesSharedOwner() {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        model.claimSharedSummonForTesting(source: "ask")

        model.cleanup()
        model.cleanup()

        XCTAssertFalse(model.isSummonBusy)
        XCTAssertNil(model.summonWatchdogTokenForTesting)
    }

    func testApplicationTerminationAndQuitShareTeardownPath() throws {
        let source = try source("ClawGate/UI/MenuBarApp.swift")
        XCTAssertTrue(source.contains("func applicationWillTerminate"))
        XCTAssertTrue(source.contains("performTeardown()"))
        XCTAssertTrue(source.contains("petWindowController?.teardown()"))
        XCTAssertTrue(source.contains("petModel.cleanup()"))
    }

    func testAskLifecycleOwnsOutsideClickAndFocusLossMonitor() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let askBody = try functionBody(
            from: source,
            functionName: "showAskInput",
            nextFunctionHeader: "@objc private func summonDraftPR(_ sender: NSMenuItem) {")
        let detachBody = try functionBody(
            from: source,
            functionName: "detachAskWindow",
            nextFunctionHeader: "/// Brings the full chat window")
        XCTAssertTrue(source.contains("askDismissMonitor"))
        XCTAssertTrue(source.contains("windowDidResignKey"))
        XCTAssertTrue(source.contains("func teardown()"))
        XCTAssertTrue(askBody.contains("bw.delegate = self"),
                      "Ask must wire the actual child window delegate")
        XCTAssertTrue(askBody.contains("installAskDismissMonitor()"),
                      "Ask must install its dedicated outside-click monitor")
        XCTAssertTrue(detachBody.contains("removeAskDismissMonitor()"),
                      "Ask detach must release both monitors")
        XCTAssertTrue(detachBody.contains("aw.delegate = nil"),
                      "Ask detach must clear the child delegate")
    }

    private func source(_ relative: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
            .path
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func functionBody(
        from source: String,
        functionName: String,
        nextFunctionHeader: String
    ) throws -> String {
        guard let start = source.range(of: "func \(functionName)(", options: .literal),
              let bodyStart = source[start.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "PetModelFloatingGoalC2TeardownTests", code: 1)
        }
        let afterStart = source.index(after: bodyStart)
        guard let nextStart = source[afterStart...].range(
            of: "\n    \(nextFunctionHeader)", options: .literal
        ) else {
            throw NSError(domain: "PetModelFloatingGoalC2TeardownTests", code: 2)
        }
        return String(source[afterStart..<nextStart.lowerBound])
    }
}
