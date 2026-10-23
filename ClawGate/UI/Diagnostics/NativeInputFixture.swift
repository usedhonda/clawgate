#if DEBUG
import AppKit
import SwiftUI

/// Explicit DEBUG window in the normal app; no second runtime or shared lifecycle.
/// The PetModel is never started; only this object's timers/window/probe are owned.
final class NativeInputFixture: NSObject, ObservableObject, NSWindowDelegate {
    private static var active: NativeInputFixture?
    let model: PetModel
    @Published var streaming = false
    @Published var scope = "Chat"
    let workloads: NativeWorkloadFixture
    private let output: URL
    private var window: NSWindow?
    private var probe: NativeInputCommitProbe?
    private var timer: Timer?
    private var ticks = 0
    private var finished = false

    private init(output: URL) throws {
        let model = PetModel()
        model.persistenceDisabledForFixture = true
        self.model = model
        self.output = output
        workloads = try NativeWorkloadFixture(root: output.appendingPathComponent("workloads"), model: model)
        super.init()
        let text = String(repeating: "**Synthetic fixture**: input, links and `code` remain visible. ", count: 30)
        model.messages = (0..<60).map {
            OpenClawChatMessage(id: "fixture-\($0)", role: .assistant, text: text,
                               timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
        }
        model.requestTab("chat")
    }

    static func presentIfRequested() {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1] == "--native-input-probe", active == nil else { return }
        do {
            let fixture = try NativeInputFixture(output: URL(fileURLWithPath: CommandLine.arguments[2]))
            active = fixture
            try fixture.start()
        }
        catch {
            active?.stop()
            active = nil
            fputs("Native input fixture could not initialize.\n", stderr)
        }
    }

    private func start() throws {
        let view = NSHostingView(rootView: NativeInputFixtureView(fixture: self))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ClawGate Native Input Probe"
        window.contentView = view
        window.delegate = self
        self.window = window
        probe = NativeInputCommitProbe(host: view, input: { [weak self] in self?.model.inputText ?? "" },
                                      inputChanges: model.$inputText.eraseToAnyPublisher(),
                                      phase: { [weak self] in self?.streaming == true ? "stream" : "static" },
                                      onSample: { [weak self] in self?.flushReport() })
        workloads.beginAction = { [weak self] in self?.probe?.beginNativeAction($0) }
        workloads.completeAction = { [weak self] in self?.probe?.completeNativeAction($0) }
        probe?.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try write(["pid": ProcessInfo.processInfo.processIdentifier,
                   "windowNumber": window.windowNumber, "title": window.title,
                   "bundleID": Bundle.main.bundleIdentifier ?? "",
                   "historyCount": 60, "streamIntervalMs": 50], name: "ready.json")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            if self.streaming, let last = self.model.messages.indices.last {
                self.model.messages[last].text += " delta\(self.ticks)"
                self.model.messages[last].isStreaming = true
                self.model.streamingText = self.model.messages[last].text
            }

        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        flushReport()
        stop()
        window?.orderOut(nil)
        window = nil
        Self.active = nil
    }

    private func flushReport() {
        var result = probe?.report() ?? [:]
        result["workloadState"] = workloads.evidence()
        result["historyCount"] = 60
        result["streamIntervalMs"] = 50
        result["connected"] = model.connectionState == .connected
        result["backgroundCapture"] = "normal application lifecycle unchanged"
        do { try write(result, name: "report.json") }
        catch { fputs("Native input fixture report could not be saved.\n", stderr) }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func stop() {
        workloads.stop()
        timer?.invalidate()
        timer = nil
        probe?.stop()
        // Do not call model.cleanup(): an unstarted diagnostic model does not
        // own shared watcher lifecycle.
    }

    static func workspaceAction(model: PetModel, workload: String) {
        guard let fixture = active, fixture.model === model, fixture.scope == "Workloads" else { return }
        let id = fixture.probe?.beginNativeAction(workload)
        fixture.probe?.completeNativeAction(id)
    }

    private func write(_ value: [String: Any], name: String) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = output.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private struct NativeInputFixtureView: View {
    @ObservedObject var fixture: NativeInputFixture

    var body: some View {
        VStack {
            HStack {
                Button("Static") { fixture.streaming = false }
                Button("Stream") { fixture.streaming = true }
                Button("Finish fixture") { fixture.finish() }
                Text(fixture.streaming ? "stream" : "static")
            }
            Picker("Scope", selection: $fixture.scope) {
                Text("Chat").tag("Chat")
                Text("Workloads").tag("Workloads")
            }.pickerStyle(.segmented)
            if fixture.scope == "Chat" {
                PetChatContainerView(model: fixture.model)
            } else {
                NativeWorkloadFixtureView(fixture: fixture.workloads)
            }
        }
    }
}
#endif
