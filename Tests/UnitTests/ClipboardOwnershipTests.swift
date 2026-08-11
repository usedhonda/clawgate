import XCTest
import AppKit
@testable import ClawGate

final class ClipboardOwnershipTests: XCTestCase {
    private let watcher = ClipboardWatcher.shared
    private let pasteboard = NSPasteboard.general

    override func setUp() {
        super.setUp()
        watcher.stop()
        watcher.onOffer = nil
        pasteboard.clearContents()
    }

    override func tearDown() {
        watcher.stop()
        watcher.onOffer = nil
        pasteboard.clearContents()
        super.tearDown()
    }

    func testOwnedTemporaryWriteAndRestoreEmitNoClipboardOffer() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        pasteboard.setString("https://example.com/original", forType: .string)
        let saved = pasteboard.string(forType: .string)

        watcher.start()
        let ownedChangeCount = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/temporary",
            pasteboard: pasteboard
        )
        watcher.checkForTesting()
        _ = AXActions.restoreClipboardIfUnchangedForTesting(
            savedText: saved,
            expectedChangeCount: ownedChangeCount,
            pasteboard: pasteboard
        )
        watcher.checkForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), saved)
        XCTAssertEqual(offers, 0)
    }

    func testUserCopyBeforeRestoreIsPreservedAndOfferedOnce() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        pasteboard.setString("https://example.com/original", forType: .string)
        let saved = pasteboard.string(forType: .string)

        watcher.start()
        let ownedChangeCount = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/temporary",
            pasteboard: pasteboard
        )
        watcher.checkForTesting()

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/user-copy", forType: .string)
        watcher.checkForTesting()
        XCTAssertFalse(AXActions.restoreClipboardIfUnchangedForTesting(
            savedText: saved,
            expectedChangeCount: ownedChangeCount,
            pasteboard: pasteboard
        ))
        watcher.checkForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/user-copy")
        XCTAssertEqual(offers, 1)
    }

    func testStopAndStartClearOwnedStateBeforeNextUserCopy() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        watcher.start()
        _ = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/stale-owned",
            pasteboard: pasteboard
        )
        watcher.stop()
        watcher.start()

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/user-copy", forType: .string)
        watcher.checkForTesting()
        watcher.checkForTesting()

        XCTAssertEqual(offers, 1)
    }
}
