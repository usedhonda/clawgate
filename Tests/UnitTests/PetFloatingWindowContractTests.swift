import XCTest
import AppKit
@testable import ClawGate

final class PetFloatingWindowContractTests: XCTestCase {

    private func repoPath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
            .path
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: repoPath(relativePath), encoding: .utf8)
    }

    private func functionBody(
        from source: String,
        functionName: String,
        nextFunctionHeader: String
    ) throws -> String {
        guard let start = source.range(of: "func \(functionName)(", options: .literal) else {
            throw NSError(domain: "PetFloatingWindowContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing function \(functionName)"])
        }
        guard let bodyStart = source[start.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "PetFloatingWindowContractTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing body for \(functionName)"])
        }

        let afterStart = source.index(after: bodyStart)
        let nextStart = source[afterStart...].range(of: "\n    \(nextFunctionHeader)", options: .literal)
            ?? source[afterStart...].range(of: "\n\(nextFunctionHeader)", options: .literal)
        guard let nextStart = nextStart else {
            throw NSError(domain: "PetFloatingWindowContractTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Missing next marker \(nextFunctionHeader)"])
        }

        return String(source[afterStart..<nextStart.lowerBound])
    }

    func testFullChatPolicyCapturesWindowModeAndCloseSemantics() {
        let mask = PetChatWindowPolicy.chatWindowStyleMask

        XCTAssertTrue(mask.contains(.titled))
        XCTAssertTrue(mask.contains(.closable))
        XCTAssertTrue(mask.contains(.resizable))
        XCTAssertTrue(mask.contains(.fullSizeContentView))
        XCTAssertFalse(mask.contains(.nonactivatingPanel))

        XCTAssertEqual(PetChatWindowPolicy.chatWindowCollectionBehavior, [.managed, .moveToActiveSpace])
    }

    func testFullChatRevealRequiresVisibleAndUnminimized() {
        XCTAssertFalse(PetChatWindowPolicy.shouldRevealChatWindow(isVisible: false, isMiniaturized: false))
        XCTAssertFalse(PetChatWindowPolicy.shouldRevealChatWindow(isVisible: true, isMiniaturized: true))
        XCTAssertTrue(PetChatWindowPolicy.shouldRevealChatWindow(isVisible: true, isMiniaturized: false))
    }

    func testFullChatWindowCloseRoutesThroughCleanup() {
        var closed = 0
        XCTAssertFalse(PetChatWindowPolicy.routeClose { closed += 1 })
        XCTAssertEqual(closed, 1)
    }

    func testMenuBarLeftClickRoutingPreservesRevealPathAndRightClickPath() throws {
        let source = try source("ClawGate/UI/MenuBarApp.swift")
        let body = try functionBody(from: source, functionName: "toggleMainPanel", nextFunctionHeader: "private func prepareExpandedPanelForOpen(_ panel: NSPanel) {")

        XCTAssertTrue(body.contains("event.type == .rightMouseUp"),
                      "right-click path must stay intact")
        XCTAssertTrue(body.contains("showStatusItemMenu()"),
                      "right-click must continue opening the status menu")
        XCTAssertTrue(body.contains("panel.isVisible"),
                      "left-click close path must stay intact")
        XCTAssertTrue(body.contains("petWindowController?.bringChatToFrontIfVisible()"),
                      "settings-open path should route to conditional chat reveal")
        XCTAssertFalse(body.contains("showFullChat()"),
                       "menu toggles should not create chat directly")
    }

    func testMainMenuContainsStandardCloseShortcut() throws {
        let source = try source("ClawGate/main.swift")
        let body = try functionBody(from: source, functionName: "installMainMenu", nextFunctionHeader: "let app = NSApplication.shared")

        XCTAssertTrue(body.contains("let fileMenu = NSMenu(title: \"File\")"),
                      "main menu should configure a Close menu command path")
        XCTAssertTrue(body.contains("addItem(withTitle: \"Close\""),
                      "main menu should expose a standard Close command")
        XCTAssertTrue(body.contains("performClose"),
                      "main menu close command should route through first-responder performClose(_:)")
        XCTAssertTrue(body.contains("keyEquivalent: \"w\""),
                      "main menu should include Cmd+W binding")
        XCTAssertTrue(body.contains("mainMenu.addItem(fileMenuItem)"),
                      "main menu should wire File menu into app menu bar")
    }

    func testPolicyRoutingIsDelegatedFromContentWindow() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let body = try functionBody(from: source, functionName: "showFullChat", nextFunctionHeader: "private func setLogThreadPaneOpen(_ open: Bool) {")

        XCTAssertTrue(body.contains("bw.delegate = self"),
                      "full-chat window should route close and other window events through this content delegate")
        XCTAssertTrue(source.contains("func windowShouldClose(_ sender: NSWindow) -> Bool"),
                      "full-chat close path should be delegated through windowShouldClose")
        XCTAssertTrue(source.contains("guard sender === chatWindow else { return true }"),
                      "windowShouldClose should not intercept non-chat windows")
        XCTAssertTrue(source.contains("PetChatWindowPolicy.routeClose"),
                      "chat windows should still route close through cleanup policy path")
    }

    func testFloatingWindowContractSpecContainsActivationRevealAndKeyboardGuards() throws {
        let spec = try source("docs/pet-floating-window-spec.md")
        XCTAssertTrue(spec.contains("## Normative (shipped)"), "spec must define a shipped contract section")
        XCTAssertTrue(spec.contains("z-order"), "spec must document z-order")
        XCTAssertTrue(spec.contains("Activation"), "spec must document activation")
        XCTAssertTrue(spec.contains("PetChatWindowPolicy.chatWindowCollectionBehavior"), "spec must document active-space collection behavior")
        XCTAssertTrue(spec.contains("NSApp.activate(ignoringOtherApps: true)"), "spec must document forced activation on explicit reveal")
        XCTAssertTrue(spec.contains("close (⌘W)"), "spec must capture close shortcut expectation")
        XCTAssertTrue(spec.contains("copy (⌘C)"), "spec must capture copy shortcut expectation")
        XCTAssertTrue(spec.contains("select-all (⌘A)"), "spec must capture select-all expectation")
        XCTAssertFalse(spec.contains(".ts.net"), "spec must stay public-safe")
        XCTAssertFalse(spec.contains("showStatusItemMenu()"),
                       "spec must describe behavior not implementation details")
    }
}
