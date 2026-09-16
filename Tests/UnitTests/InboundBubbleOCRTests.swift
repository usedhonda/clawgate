import XCTest
import AppKit
import CoreText
@testable import ClawGate

final class InboundBubbleOCRTests: XCTestCase {
    override func setUp() { InboundBubbleOCR.clearCache() }
    override func tearDown() { InboundBubbleOCR.clearCache() }

    private func image(y: CGFloat = 80, repeatBubble: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        for top in repeatBubble ? [y, y + 130] : [y] {
            let rect = CGRect(x: 80, y: 600 - top - 70, width: 210, height: 70)
            context.setFillColor(CGColor(gray: 239.0 / 255, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            context.textPosition = CGPoint(x: 100, y: rect.minY + 23)
            let text = NSAttributedString(string: "0:04", attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()!
    }

    func testVerifiedTimeOnlyBodySurvivesAndCacheKeepsSeparateOccurrences() throws {
        let first = try XCTUnwrap(InboundBubbleOCR.recognize(image(), scope: "test", config: .default))
        XCTAssertEqual(first.bubbleCount, 1)
        XCTAssertEqual(first.observations.map(\.text), ["0:04"])
        XCTAssertGreaterThan(first.recognizedPixels, 0)
        let shifted = try XCTUnwrap(InboundBubbleOCR.recognize(image(y: 160, repeatBubble: true), scope: "test", config: .default))
        XCTAssertEqual(shifted.observations.map(\.text), ["0:04", "0:04"])
        XCTAssertEqual(shifted.cacheHits, 2)
        XCTAssertEqual(shifted.recognizedPixels, 0)
        XCTAssertGreaterThan(first.observations[0].boundingBox.maxY, shifted.observations[0].boundingBox.maxY)
        let otherConversation = try XCTUnwrap(InboundBubbleOCR.recognize(image(), scope: "other", config: .default))
        XCTAssertEqual(otherConversation.cacheHits, 0)
        XCTAssertEqual(LineTextSanitizer.bubbleBody("0:04\n今日\nOK"), "0:04\n今日\nOK")
        XCTAssertEqual(LinePixelContinuity.appendedTail(previous: "hello", current: "hello\n0:04"), "0:04")
    }

    func testAtlasCoordinatesReturnToSourceAndRetinaScreen() {
        let box = InboundBubbleOCR.originalBox(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
            crop: CGRect(x: 100, y: 600, width: 800, height: 100), imageSize: CGSize(width: 1600, height: 1200))
        XCTAssertEqual(box.minX, 180.0 / 1600, accuracy: 0.0001)
        XCTAssertEqual(VisionOCR.globalTopDownY(for: box, in: CGRect(x: 0, y: 120, width: 800, height: 600)), 445, accuracy: 0.0001)
    }

    /// Private captured conversations never become repository fixtures.
    func testPrivateCapturedFrameWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["INBOUND_BUBBLE_FIXTURE"] else {
            throw XCTSkip("Set INBOUND_BUBBLE_FIXTURE for the private captured frame")
        }
        let image = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let start = CFAbsoluteTimeGetCurrent()
        let result = try XCTUnwrap(InboundBubbleOCR.recognize(image, scope: "fixture", config: .default))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(result.bubbleCount, 2)
        let text = result.observations.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("カレンダー"))
        XCTAssertTrue(text.contains("何の話"))
        XCTAssertFalse(text.contains("午前"))
        XCTAssertFalse(text.contains("今日"))
        XCTAssertFalse(text.contains("未読"))
        XCTAssertFalse(text.contains("了解"))
        print("bubble-fixture pixels=\(result.recognizedPixels)/\(image.width * image.height) elapsed_ms=\(elapsed)")
        let cached = try XCTUnwrap(InboundBubbleOCR.recognize(image, scope: "fixture", config: .default))
        XCTAssertEqual(cached.cacheHits, 2)
        XCTAssertEqual(cached.recognizedPixels, 0)
    }
}
