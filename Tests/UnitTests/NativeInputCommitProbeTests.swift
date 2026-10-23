#if DEBUG
import AppKit
import Combine
import XCTest
@testable import ClawGate

final class NativeInputCommitProbeTests: XCTestCase {
    func testOverlappingEventsJoinOldestAndCannotProduceOptimisticLatency() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        window.contentView = host
        let input = CurrentValueSubject<String, Never>("")
        let completed = expectation(description: "joined transaction")
        var acceptsSample = true
        let probe = NativeInputCommitProbe(host: host, input: { input.value },
                                          inputChanges: input.eraseToAnyPublisher(), phase: { "static" },
                                          onSample: { if acceptsSample { acceptsSample = false; completed.fulfill() } })
        defer { probe.stop(); window.close() }
        // Construct event values only: no sendEvent, input synthesis or shown window.
        for _ in 0..<2 {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            probe.observe(event)
        }
        input.send("a")
        wait(for: [completed], timeout: 1)
        let report = probe.report()
        let samples = try XCTUnwrap(report["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?["operation"] as? Int, 1)
        XCTAssertEqual(report["pendingCount"] as? Int, 1)
        XCTAssertEqual(report["excludedOverlapCount"] as? Int, 1)
        XCTAssertTrue((report["workloads"] as? [String: Any])?.isEmpty == true)
    }
}
#endif
