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
        XCTAssertTrue(source.contains("askDismissMonitor"))
        XCTAssertTrue(source.contains("windowDidResignKey"))
        XCTAssertTrue(source.contains("func teardown()"))
        XCTAssertTrue(source.contains("detachAskWindow()"))
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
}
