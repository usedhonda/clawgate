import XCTest
import AppKit
@testable import ClawGate

final class MainPanelTimelineLoaderTests: XCTestCase {
    func testBurstCoalescesAndUnchangedReadsDoNotPublish() {
        let started = expectation(description: "background read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var reads = 0
        let loader = MainPanelTimelineLoader {
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            if reads == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return [MainPanelLogLine(text: "latest", color: .systemGreen, event: "ready")]
            }
            return nil
        }
        defer { loader.stop() }
        var publications = 0
        let apply: ([MainPanelLogLine]) -> Void = { lines in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(lines.map(\.text), ["latest"])
            publications += 1
        }
        let drained = expectation(description: "one running and one pending read")
        drained.expectedFulfillmentCount = 2
        loader.didFinishForTesting = { drained.fulfill() }
        loader.refresh(apply: apply)
        wait(for: [started], timeout: 3)
        for _ in 0..<20 { loader.refresh(apply: apply) }
        release.signal()
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(publications, 1)
        let unchanged = expectation(description: "unchanged timer tick")
        loader.didFinishForTesting = { unchanged.fulfill() }
        loader.refresh(apply: apply)
        wait(for: [unchanged], timeout: 3)
        XCTAssertEqual(publications, 1)
    }

    func testDisplayTailDetectsSameSizeRewriteAndSkipsUnchangedDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpsLogStore(logDirectory: root)
        XCTAssertEqual(store.recentDisplayIfChanged(limit: 30)?.count, 0)
        XCTAssertNil(store.recentDisplayIfChanged(limit: 30))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        let path = root.appendingPathComponent("\(formatter.string(from: Date()))-ops.log")
        let entry = OpsLogEntry(ts: "2026-01-01T00:00:00Z", level: "info", event: "ready",
                                role: "client", host: "example-host", script: "test", message: "first")
        var data = try JSONEncoder().encode(entry)
        data.append(10)
        try data.write(to: path)
        XCTAssertEqual(store.recentDisplayIfChanged(limit: 30)?.map(\.message), ["first"])
        XCTAssertNil(store.recentDisplayIfChanged(limit: 30))
        let rewritten = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "first", with: "other")
        try Data(rewritten.utf8).write(to: path)
        XCTAssertEqual(store.recentDisplayIfChanged(limit: 30)?.map(\.message), ["other"])
        XCTAssertNil(store.recentDisplayIfChanged(limit: 30))
    }

    func testStoppedLoaderCannotPublishAnInFlightSnapshot() {
        let started = expectation(description: "read started")
        let finished = expectation(description: "cancelled result returned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = MainPanelTimelineLoader {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [MainPanelLogLine(text: "old", color: .systemRed, event: "old")]
        }
        loader.didFinishForTesting = { finished.fulfill() }
        loader.refresh { _ in XCTFail("teardown must reject old results") }
        wait(for: [started], timeout: 3)
        loader.stop()
        release.signal()
        wait(for: [finished], timeout: 3)
    }

    func testTimelinePreservesNewestOrderRunCompressionAndColors() {
        func entry(_ event: String, level: String = "info") -> OpsLogEntry {
            OpsLogEntry(ts: "2026-01-01T00:00:00Z", level: level, event: event,
                        role: "client", host: "example-host", script: "test", message: "fixture")
        }
        let lines = MenuBarAppDelegate.timelineLines([
            entry("line_send_ok"), entry("line_send_ok"), entry("send_failed", level: "error")
        ])
        XCTAssertEqual(lines.map(\.event), ["line_send_ok", "send_failed"])
        XCTAssertTrue(lines[0].text.hasSuffix("×2"))
        XCTAssertTrue(lines[0].color.isEqual(NSColor.systemGreen))
        XCTAssertTrue(lines[1].color.isEqual(NSColor.systemRed))
        XCTAssertTrue(MenuBarAppDelegate.timelineLines([])[0].text.hasSuffix("No recent logs"))
    }
}
