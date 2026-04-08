import Foundation
import XCTest
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
}
