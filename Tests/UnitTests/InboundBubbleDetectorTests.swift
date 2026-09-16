import AppKit
import XCTest
@testable import ClawGate

final class InboundBubbleDetectorTests: XCTestCase {
    func testRejectsRoundGrayAvatarAndColoredPhoto() {
        let image = makeImage(width: 800, height: 600) { context in
            fill(context, CGRect(x: 0, y: 100, width: 45, height: 45), color: (239, 239, 239), radius: 22)
            fill(context, CGRect(x: 55, y: 220, width: 200, height: 150), color: (90, 130, 210), radius: 12)
            fill(context, CGRect(x: 75, y: 250, width: 160, height: 70), color: (170, 80, 40))
        }
        XCTAssertEqual(InboundBubbleDetector.detect(in: image).status, .noBubbles)
        XCTAssertTrue(InboundBubbleDetector.detect(in: image).rects.isEmpty)
    }

    func testDetectsMultipleInboundBubblesAndExcludesOutgoing() {
        let image = makeImage(width: 800, height: 600) { context in
            bubble(context, CGRect(x: 50, y: 80, width: 610, height: 70))
            bubble(context, CGRect(x: 50, y: 250, width: 220, height: 48))
            fill(context, CGRect(x: 120, y: 400, width: 620, height: 70), color: (195, 246, 157))
        }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.rects.count, 2)
        XCTAssertEqual(result.rects[0], CGRect(x: 50, y: 80, width: 610, height: 70))
        XCTAssertEqual(result.rects[1], CGRect(x: 50, y: 250, width: 220, height: 48))
    }

    func testRejectsDayLabelSeparatorAvatarsAndClippedBubbles() {
        let image = makeImage(width: 800, height: 600) { context in
            fill(context, CGRect(x: 340, y: 150, width: 120, height: 28), color: (239, 239, 239))
            fill(context, CGRect(x: 0, y: 300, width: 800, height: 3), color: (239, 239, 239))
            fill(context, CGRect(x: 0, y: 375, width: 45, height: 45), color: (239, 239, 239))
            fill(context, CGRect(x: 0, y: 450, width: 55, height: 55), color: (180, 120, 80))
            bubble(context, CGRect(x: 50, y: 0, width: 300, height: 50))
        }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertTrue(result.rects.isEmpty)
        XCTAssertEqual(result.status, .uncertain)
    }

    func testPreservesTopDownCoordinatesAtTwoXScale() {
        let image = makeImage(width: 1600, height: 1200) { context in
            bubble(context, CGRect(x: 100, y: 200, width: 700, height: 100))
        }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertEqual(result.status, .ready)
        guard let rect = result.rects.first else {
            XCTFail("retina bubble should produce one rectangle")
            return
        }
        XCTAssertEqual(result.rects.count, 1)
        XCTAssertEqual(rect, CGRect(x: 100, y: 200, width: 700, height: 100))
    }

    func testCleanCanvasHasNoBubbles() {
        let image = makeImage(width: 300, height: 200) { _ in }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertEqual(result.status, .noBubbles)
        XCTAssertTrue(result.rects.isEmpty)
    }

    func testDarkUnsupportedCanvasIsUncertain() {
        let image = makeImage(width: 300, height: 200) { context in
            fill(context, CGRect(x: 0, y: 0, width: 300, height: 200), color: (24, 28, 31))
        }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertTrue(result.rects.isEmpty)
    }

    func testOptionalCapturedFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["INBOUND_BUBBLE_FIXTURE"] else {
            throw XCTSkip("INBOUND_BUBBLE_FIXTURE not set")
        }
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("fixture could not be loaded")
            return
        }
        let result = InboundBubbleDetector.detect(in: image)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.rects.count, 2, "captured fixture should contain exactly two inbound bubbles")
        XCTAssertEqual(result.rects.map(\.minY), [628, 1018])
    }

    private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        var bytes = Array(repeating: UInt8(255), count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        context.restoreGState()
        return context.makeImage()!
    }

    private func bubble(_ context: CGContext, _ rect: CGRect) {
        fill(context, rect, color: (239, 239, 239), radius: min(18, rect.height / 2))
        fill(context, CGRect(x: rect.minX + 22, y: rect.minY + rect.height / 2 - 5, width: min(130, rect.width - 40), height: 10), color: (31, 31, 31))
    }

    private func fill(_ context: CGContext, _ rect: CGRect, color: (Int, Int, Int), radius: CGFloat = 0) {
        context.setFillColor(CGColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
        if radius > 0 {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }
}
