import AppKit
import SwiftUI
import XCTest
@testable import ClawGate

final class ChatResponsivenessFixtureTests: XCTestCase {
    func testIsolatedNativeStreamFixture() throws {
        guard ProcessInfo.processInfo.environment["CLAWGATE_CHAT_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in native measurement fixture")
        }
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared
        let fixture = ChatResponsivenessFixture()
        let finished = expectation(description: "native fixture completed")
        fixture.finish = { finished.fulfill() }
        let view = NSHostingView(rootView: ChatResponsivenessFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ClawGate isolated responsiveness fixture"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        fixture.start()
        defer {
            fixture.stop()
            window.close()
        }
        wait(for: [finished], timeout: 30)
        let report = fixture.report()
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CHAT_FIXTURE " + String(decoding: encoded, as: UTF8.self))
    }
}

private final class ChatResponsivenessFixture: ObservableObject {
    let model = PetModel()
    @Published var streaming = false
    var finish: (() -> Void)?
    private var timer: Timer?
    private var previous = ProcessInfo.processInfo.systemUptime
    private var samples: [String: [Double]] = [:]
    private var ticks = 0

    init() {
        let text = String(repeating: "**Synthetic fixture**: input, links and `code` remain visible. ", count: 30)
        model.messages = (0..<60).map { index in
            OpenClawChatMessage(id: "fixture-\(index)", role: .assistant, text: text,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        model.requestTab("chat")
    }

    func start() {
        previous = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.samples[self.streaming ? "stream" : "static", default: []].append(max(0, now - self.previous - 0.05) * 1000)
            self.previous = now
            self.ticks += 1
            if self.ticks == 120 { self.streaming = true }
            if self.ticks.isMultiple(of: 10) { self.model.inputText = "synthetic input \(self.ticks)" }
            if self.ticks.isMultiple(of: 40) { self.model.requestTab("summon") }
            if self.ticks % 40 == 1 { self.model.requestTab("chat") }
            if self.streaming, let last = self.model.messages.indices.last {
                self.model.messages[last].text += " delta\(self.ticks)"
                self.model.messages[last].isStreaming = true
                self.model.streamingText = self.model.messages[last].text
            }
            if self.ticks == 240 {
                self.timer?.invalidate()
                self.finish?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model.cleanup()
    }

    func report() -> [String: Any] {
        var result: [String: Any] = ["metric": "main-runloop-timer-lateness-ms-not-input-to-display",
            "historyCount": 60, "streamIntervalMs": 50]
        for (phase, values) in samples {
            let sorted = values.sorted()
            result[phase] = ["count": sorted.count,
                "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "max": sorted.last ?? 0]
        }
        return result
    }
}

private struct ChatResponsivenessFixtureView: View {
    @ObservedObject var fixture: ChatResponsivenessFixture

    var body: some View {
        VStack {
            HStack {
                Button("Static") { fixture.streaming = false }
                Button("Stream") { fixture.streaming = true }
                Button("Finish fixture") { fixture.finish?() }
                Text(fixture.streaming ? "stream" : "static")
            }
            PetChatContainerView(model: fixture.model)
        }
    }
}
