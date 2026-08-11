import Foundation
import XCTest
import AppKit
@testable import ClawGate

final class ScreenshotWatcherTests: XCTestCase {
    func testScreenshotFileClassifierMatchesCommonScreenshotNames() {
        XCTAssertTrue(
            ScreenshotFileClassifier.looksLikeScreenshot(
                filename: "Screen Shot 2026-04-09 at 12.00.00.png",
                directoryName: "Desktop"
            )
        )
        XCTAssertTrue(
            ScreenshotFileClassifier.looksLikeScreenshot(
                filename: "スクリーンショット 2026-04-09 12.00.00.png",
                directoryName: "Desktop"
            )
        )
    }

    func testScreenshotFileClassifierMatchesScreenshotFolderNames() {
        XCTAssertTrue(
            ScreenshotFileClassifier.looksLikeScreenshot(
                filename: "capture.png",
                directoryName: "Screenshots"
            )
        )
        XCTAssertTrue(
            ScreenshotFileClassifier.looksLikeScreenshot(
                filename: "capture.png",
                directoryName: "スクリーンショット"
            )
        )
    }

    func testScreenshotFileClassifierRejectsNonScreenshotNamesOutsideHintFolder() {
        XCTAssertFalse(
            ScreenshotFileClassifier.looksLikeScreenshot(
                filename: "holiday-photo.png",
                directoryName: "Desktop"
            )
        )
    }

    func testScreenshotTempStoreCreatesClawgatePngPath() {
        let url = ScreenshotTempStore.makeTempURL(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("chi-shot-"))
        XCTAssertTrue(url.path.hasPrefix("/tmp/"))
    }

    func testOwnedSafePasteAndDelayedRestoreDoNotReemitPreexistingClipboardImage() async {
        let pasteboard = NSPasteboard.general
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: NSSize(width: 120, height: 120)).fill()
        image.unlockFocus()

        let watcher = ScreenshotWatcher.shared
        watcher.stop()
        watcher.onScreenshot = nil
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        var offers = 0
        watcher.onScreenshot = { _ in offers += 1 }
        watcher.start()

        AXActions.safePaste("temporary text")
        watcher.checkClipboardForTesting()
        try? await Task.sleep(nanoseconds: 700_000_000)
        watcher.checkClipboardForTesting()

        XCTAssertNotNil(NSImage(pasteboard: pasteboard), "the original image should be restored")
        XCTAssertEqual(offers, 0, "owned temporary write and restore must not emit clipboard_image")

        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        watcher.checkClipboardForTesting()
        XCTAssertEqual(offers, 1, "an external image clipboard mutation must still emit")

        watcher.stop()
        watcher.onScreenshot = nil
        pasteboard.clearContents()
    }
}
