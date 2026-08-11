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

    /// Z-order and close-control regression guard: these properties are set in
    /// `showFullChat`, not in the shared style/collection policy.
    func testFullChatWindowIsNormalLevelWithVisibleCloseButton() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let body = try functionBody(from: source, functionName: "showFullChat", nextFunctionHeader: "private func setLogThreadPaneOpen(_ open: Bool) {")

        XCTAssertTrue(body.contains("bw.level = .normal"),
                      "full chat must use normal level so it backgrounds behind other apps")
        XCTAssertFalse(body.contains("bw.level = .floating"),
                       "full chat must not be pinned above other apps")
        XCTAssertTrue(body.contains("bw.standardWindowButton(.closeButton)?.isHidden = false"),
                      "the standard close button must remain visible")
    }

    func testVisualLifecycleUsesSingleDetachCoordinator() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let hideBody = try functionBody(from: source, functionName: "hide", nextFunctionHeader: "/// Forwards to the full chat window")
        let detachBody = try functionBody(from: source, functionName: "detachForLifecycle", nextFunctionHeader: "private func hideChatWindow() {")

        XCTAssertTrue(hideBody.contains("detachForLifecycle(preserveChatState: true)"),
                      "hide must use the shared visual-window lifecycle coordinator")
        XCTAssertTrue(detachBody.contains("removePetPanelDismissMonitor()"),
                      "teardown coordinator must remove local/global click-out monitors")
        XCTAssertTrue(detachBody.contains("detachChatWindow(preserveState: preserveChatState)"),
                      "teardown coordinator must close full chat through shared path")
        XCTAssertTrue(detachBody.contains("detachAskWindow()"),
                      "teardown coordinator must dispose Ask window")
        XCTAssertTrue(detachBody.contains("dismissSummonMenu()"),
                      "teardown coordinator must dispose summon menu")
        XCTAssertTrue(detachBody.contains("hideWhisper()"),
                      "teardown coordinator must dispose whisper window")
        XCTAssertTrue(source.contains("func detachForLifecycle(preserveChatState: Bool)"),
                      "PetContentView must expose a single visual lifecycle detachment helper")
        XCTAssertTrue(source.contains("private func detachAskWindow()"),
                      "Ask dispose helper should exist for child-window teardown symmetry")
    }

    func testCloseVsHideDistinguishChatStatePreservationInTeardown() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let detachBody = try functionBody(from: source, functionName: "detachChatWindow", nextFunctionHeader: "private func chatWindowFrameForSave(from cw: NSWindow) -> NSRect {")
        let hideBody = try functionBody(from: source, functionName: "hideChatWindow", nextFunctionHeader: "private func detachChatWindow(preserveState: Bool) {")

        XCTAssertTrue(detachBody.contains("if !preserveState"),
                      "pane state reset should be conditional on detach mode")
        XCTAssertTrue(hideBody.contains("detachChatWindow(preserveState: false)"),
                      "close path must use non-preserving chat teardown")
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

    func testGeometryContractSelectsParentScreenThenIntersectsThenMain() throws {
        let parentScreen = NSRect(x: 1200, y: 120, width: 300, height: 300)
        let secondaryScreen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let mainScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let withParentScreen = PetWindowGeometryContract.visibleFrameForWindow(
            parentWindowFrame: NSRect(x: 1300, y: 130, width: 100, height: 100),
            parentWindowScreenFrame: parentScreen,
            screenVisibleFrames: [secondaryScreen, mainScreen],
            mainScreenVisibleFrame: mainScreen
        )
        XCTAssertEqual(withParentScreen, parentScreen)

        let withIntersectingScreen = PetWindowGeometryContract.visibleFrameForWindow(
            parentWindowFrame: NSRect(x: -1880, y: 20, width: 120, height: 80),
            parentWindowScreenFrame: nil,
            screenVisibleFrames: [secondaryScreen, mainScreen],
            mainScreenVisibleFrame: mainScreen
        )
        XCTAssertEqual(withIntersectingScreen, secondaryScreen)

        let withMainFallback = PetWindowGeometryContract.visibleFrameForWindow(
            parentWindowFrame: NSRect(x: 2500, y: 20, width: 120, height: 80),
            parentWindowScreenFrame: nil,
            screenVisibleFrames: [secondaryScreen, mainScreen],
            mainScreenVisibleFrame: mainScreen
        )
        XCTAssertEqual(withMainFallback, mainScreen)

        let withNoScreensOrMain = PetWindowGeometryContract.visibleFrameForWindow(
            parentWindowFrame: nil,
            parentWindowScreenFrame: nil,
            screenVisibleFrames: [],
            mainScreenVisibleFrame: nil
        )
        XCTAssertNil(withNoScreensOrMain)
    }

    func testGeometryContractNoScreenGuardDoesNotCrashAndPreservesNoClampFrame() {
        let sourceFrame = NSRect(x: 120, y: 80, width: 200, height: 160)
        let clamped = PetWindowGeometryContract.clampWindowFrame(sourceFrame, to: nil)
        XCTAssertEqual(clamped, sourceFrame)
    }

    func testNoScreenCallsitesSkipCreationOrUseLocalResizeFallback() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let showBody = try functionBody(from: source, functionName: "show", nextFunctionHeader: "func hide()")

        XCTAssertTrue(showBody.contains("guard let screenFrame = screenFrame else { return }"),
                      "character creation must skip when no screen target exists")
        XCTAssertTrue(source.contains("resizedFrame = NSRect(origin: w.frame.origin, size: winSize)"),
                      "character resize must keep an explicit local fallback when no screen target exists")
    }

    func testGeometryContractClampsOversizeWindowsAndPreservesResizeAnchor() {
        let visible = NSRect(x: 20, y: 30, width: 420, height: 300)
        let original = NSRect(x: 80, y: 90, width: 180, height: 100)
        let clamped = PetWindowGeometryContract.clampWindowFrame(original, to: visible)
        XCTAssertEqual(clamped, original)

        let anchorPreserved = PetWindowGeometryContract.clampFrameForResize(
            from: original,
            resizedTo: NSSize(width: 600, height: 420),
            to: visible,
            minimumSize: NSSize(width: 120, height: 120),
            anchorPoint: NSPoint(x: original.midX, y: original.midY)
        )
        XCTAssertEqual(anchorPreserved.size.width, visible.width)
        XCTAssertEqual(anchorPreserved.size.height, visible.height)
        XCTAssertEqual(anchorPreserved.origin.x, visible.origin.x)
        XCTAssertEqual(anchorPreserved.origin.y, visible.origin.y)
        XCTAssertEqual(anchorPreserved.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(anchorPreserved.maxY, visible.maxY, accuracy: 0.001)
    }

    func testCharacterContentSizePreservesSquareGeometryOnTinyScreens() {
        let portrait = NSRect(x: 0, y: 0, width: 120, height: 260)
        let landscape = NSRect(x: 0, y: 0, width: 260, height: 120)

        let portraitSize = PetWindowGeometryContract.characterWindowContentSize(
            requested: 200,
            visibleFrame: portrait
        )
        let landscapeSize = PetWindowGeometryContract.characterWindowContentSize(
            requested: 200,
            visibleFrame: landscape
        )

        XCTAssertEqual(portraitSize, 100)
        XCTAssertEqual(landscapeSize, 100)

        let portraitWindow = PetWindowGeometryContract.clampWindowFrame(
            NSRect(x: 10, y: 20, width: portraitSize + 20, height: portraitSize + 20),
            to: portrait
        )
        XCTAssertEqual(portraitWindow.width, portraitWindow.height)
        XCTAssertEqual(portraitWindow.width, portrait.width)

        let landscapeWindow = PetWindowGeometryContract.clampWindowFrame(
            NSRect(x: 10, y: 20, width: landscapeSize + 20, height: landscapeSize + 20),
            to: landscape
        )
        XCTAssertEqual(landscapeWindow.width, landscapeWindow.height)
        XCTAssertLessThanOrEqual(landscapeWindow.width, landscape.width)
    }

    func testChatMinimumSizeIsClampedToVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 180, height: 120)
        let min = PetWindowGeometryContract.clampedMinimumSize(
            requested: PetChatWindowPolicy.minimumChatWindowSize,
            visibleFrame: visible
        )

        XCTAssertEqual(min.width, visible.width)
        XCTAssertEqual(min.height, visible.height)
    }

    func testNotificationResizePathShrinksAndRestoresWithinVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 200, height: 100)
        let initial = NSRect(x: 60, y: 30, width: 80, height: 40)

        let small = PetWindowGeometryContract.clampFrameForResize(
            from: initial,
            resizedTo: initial.size,
            to: visible
        )
        XCTAssertEqual(small, initial)

        let large = PetWindowGeometryContract.clampFrameForResize(
            from: small,
            resizedTo: NSSize(width: 320, height: 220),
            to: visible,
            minimumSize: .zero,
            anchorPoint: NSPoint(x: small.midX, y: small.midY)
        )
        XCTAssertLessThanOrEqual(large.width, visible.width)
        XCTAssertLessThanOrEqual(large.height, visible.height)
        XCTAssertLessThanOrEqual(abs(large.maxX - visible.maxX), 0.001)
        XCTAssertLessThanOrEqual(abs(large.maxY - visible.maxY), 0.001)

        let restored = PetWindowGeometryContract.clampFrameForResize(
            from: large,
            resizedTo: initial.size,
            to: visible,
            minimumSize: .zero,
            anchorPoint: NSPoint(x: large.midX, y: large.midY)
        )
        XCTAssertLessThanOrEqual(restored.width, visible.width)
        XCTAssertLessThanOrEqual(restored.height, visible.height)
        XCTAssertEqual(restored.width, initial.width)
        XCTAssertEqual(restored.height, initial.height)
        XCTAssertGreaterThanOrEqual(restored.minX, visible.minX)
        XCTAssertLessThanOrEqual(restored.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(restored.minY, visible.minY)
        XCTAssertLessThanOrEqual(restored.maxY, visible.maxY)
    }

    func testGeometryContractPreservesCenterForResizeWithinVisibleFrame() {
        let visible = NSRect(x: 10, y: 10, width: 1000, height: 800)
        let sourceFrame = NSRect(x: 220, y: 200, width: 360, height: 420)
        let resized = PetWindowGeometryContract.clampFrameForResize(
            from: sourceFrame,
            resizedTo: NSSize(width: 700, height: 500),
            to: visible,
            minimumSize: NSSize(width: 360, height: 420)
        )
        XCTAssertEqual(resized.midX, sourceFrame.midX, accuracy: 0.001)
        XCTAssertEqual(resized.midY, sourceFrame.midY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(resized.minX, visible.minX)
        XCTAssertLessThanOrEqual(resized.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(resized.minY, visible.minY)
        XCTAssertLessThanOrEqual(resized.maxY, visible.maxY)
        XCTAssertEqual(resized.width, 700)
        XCTAssertEqual(resized.height, 500)
    }

    func testPostResizeClampKeepsOversizedFrameInsideVisibleFrame() {
        let visible = NSRect(x: 100, y: 50, width: 500, height: 300)
        let sourceFrame = NSRect(x: 450, y: 260, width: 200, height: 100)
        let resized = PetWindowGeometryContract.clampFrameForResize(
            from: sourceFrame,
            resizedTo: NSSize(width: 900, height: 700),
            to: visible,
            minimumSize: NSSize(width: 150, height: 150)
        )

        XCTAssertEqual(resized.width, visible.width)
        XCTAssertEqual(resized.height, visible.height)
        XCTAssertEqual(resized.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(resized.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(resized.minY, visible.minY, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, visible.maxY, accuracy: 0.001)
    }

    func testSavedFrameRestoreAndCloseClearChatReference() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let showBody = try functionBody(
            from: source,
            functionName: "showFullChat",
            nextFunctionHeader: "private func setLogThreadPaneOpen(_ open: Bool) {"
        )
        let detachBody = try functionBody(
            from: source,
            functionName: "detachChatWindow",
            nextFunctionHeader: "private func chatWindowFrameForSave(from cw: NSWindow) -> NSRect {"
        )

        XCTAssertTrue(showBody.contains("UserDefaults.standard.string(forKey: petChatWindowFrameKey)"),
                      "chat open must inspect the saved frame")
        XCTAssertTrue(showBody.contains("NSRectFromString(savedFrameString)"),
                      "chat open must restore a persisted frame")
        XCTAssertTrue(detachBody.contains("UserDefaults.standard.set(NSStringFromRect(frameToSave), forKey: petChatWindowFrameKey)"),
                      "chat close must save the effective frame")
        XCTAssertTrue(detachBody.contains("chatWindow = nil"),
                      "chat close must clear the owned window reference")
    }

    func testGeometryCallsitesRouteThroughContractHelpers() throws {
        let source = try source("ClawGate/UI/Pet/PetWindow.swift")
        let showBody = try functionBody(
            from: source,
            functionName: "show",
            nextFunctionHeader: "func hide()"
        )
        XCTAssertTrue(showBody.contains("PetWindowGeometryContract.visibleFrameForWindow"),
                      "initial pet show should resolve visible frame via shared contract")
        XCTAssertTrue(showBody.contains("PetWindowGeometryContract.clampWindowFrame("),
                      "initial pet show should clamp via shared contract")
        XCTAssertTrue(showBody.contains("sprite.frame = NSRect(origin: .zero, size: contentSize)"),
                      "initial pet show should size sprite from clamped frame")

        let askBody = try functionBody(
            from: source,
            functionName: "showAskInput",
            nextFunctionHeader: "@objc private func summonDraftPR(_ sender: NSMenuItem)"
        )
        XCTAssertTrue(askBody.contains("clampFrame(rawFrame, parentWindow: parentWindow)"),
                      "ask window should route initial placement through shared clamp")

        let notificationBody = try functionBody(
            from: source,
            functionName: "showNotification",
            nextFunctionHeader: "private func showFullChat()"
        )
        XCTAssertTrue(notificationBody.contains("if let nw = notificationWindow, nw.parent === parentWindow"),
                      "notification should use owned-window update path before recreate")
        XCTAssertTrue(notificationBody.contains("if let oldWindow = notificationWindow"),
                      "notification should detach stale notification when ownership changes")
        XCTAssertTrue(notificationBody.contains("oldWindow.parent?.removeChildWindow(oldWindow)"),
                      "notification stale child should be removed from prior owner")
        XCTAssertTrue(notificationBody.contains("clampFrameForResize("),
                      "notification update path should remeasure and reclamp")
        XCTAssertTrue(notificationBody.contains("nw.contentView = hosting"),
                      "notification update should refresh content")

        let summonBody = try functionBody(
            from: source,
            functionName: "rightMouseDown",
            nextFunctionHeader: "private func dismissSummonMenu()"
        )
        XCTAssertTrue(summonBody.contains("clampFrame("),
                      "summon menu initial frame should use shared clamp helper")

        let chatBody = try functionBody(
            from: source,
            functionName: "showFullChat",
            nextFunctionHeader: "private func setLogThreadPaneOpen(_ open: Bool) {"
        )
        XCTAssertTrue(chatBody.contains("clampFrame("),
                      "full-chat initial placement should use shared clamp helper")
        XCTAssertTrue(chatBody.contains("let effectiveMinimumSize = chatWindowEffectiveMinimumSize(for: parentWindow)"),
                      "full-chat should use visible-frame-compatible minimum size")
        XCTAssertTrue(chatBody.contains("minimumSize: effectiveMinimumSize"),
                      "full-chat should clamp with effective minimum size")

        let paneBody = try functionBody(
            from: source,
            functionName: "setLogThreadPaneOpen",
            nextFunctionHeader: "private func refreshPetPanelDismissMonitor()"
        )
        XCTAssertTrue(paneBody.contains("clampFrameForResize("),
                      "chat pane resize path should use resize-specific shared clamp")
        XCTAssertTrue(paneBody.contains("let effectiveMinimumSize = chatWindowEffectiveMinimumSize(for: parentWindow)"),
                      "chat pane resize should recalculate effective minimum")
        XCTAssertTrue(paneBody.contains("cw.minSize = effectiveMinimumSize"),
                      "chat pane resize should apply visible-frame-compatible minimum")

        let whisperBody = try functionBody(
            from: source,
            functionName: "showWhisper",
            nextFunctionHeader: "private func hideWhisper()"
        )
        XCTAssertTrue(whisperBody.contains("clampFrame("),
                      "whisper placement should use shared clamp helper")
    }
}
