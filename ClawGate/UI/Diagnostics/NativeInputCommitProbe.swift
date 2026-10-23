#if DEBUG
import AppKit
import Combine
import QuartzCore
import os

/// Observes only the opt-in synthetic window. Never synthesizes native input.
/// A sample ends at the semantic update's host transaction, not presentation.
final class NativeInputCommitProbe {
    private struct Pending {
        let id: Int
        let kind: String
        let workload: String
        let started: TimeInterval
        let beforeInput: String
        let editor: NSTextView?
        let beforeEditorText: String?
        let clip: NSClipView?
        let beforeOrigin: NSPoint?
        let responder: String
        let keyCode: UInt16
        let modifiers: UInt
        let signpost: OSSignpostID
        var overlapped: Bool
    }
    private weak var host: NSView?
    private let input: () -> String
    private let phase: () -> String
    private let onSample: () -> Void
    private var inputSubscription: AnyCancellable?
    private var boundsObserver: NSObjectProtocol?
    private var textObserver: NSObjectProtocol?
    private var monitor: Any?
    private var sequence = 0
    private var pending: [Int: Pending] = [:]
    private var samples: [[String: Any]] = []
    private var unmatched: [[String: Any]] = []
    private let log = OSLog(subsystem: "com.clawgate.fixture", category: "NativeInput")

    init(host: NSView, input: @escaping () -> String,
         inputChanges: AnyPublisher<String, Never>, phase: @escaping () -> String,
         onSample: @escaping () -> Void) {
        self.host = host
        self.input = input
        self.phase = phase
        self.onSample = onSample
        inputSubscription = inputChanges.dropFirst().sink { [weak self] value in
            guard let self, let operation = self.pending.values
                .filter({ $0.kind == "key" && $0.beforeInput != value })
                .min(by: { $0.id < $1.id }) else { return }
            self.semanticUpdate(operation.id, source: "input-publisher")
        }
    }

    func start() {
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let clip = notification.object as? NSClipView,
                  let operation = self.pending.values.filter({
                      $0.clip === clip && $0.beforeOrigin != clip.bounds.origin
                  }).min(by: { $0.id < $1.id }) else { return }
            self.semanticUpdate(operation.id, source: "target-clip-bounds")
        }
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let editor = notification.object as? NSTextView,
                  let operation = self.pending.values.filter({
                      $0.editor === editor && $0.beforeEditorText != editor.string
                  }).min(by: { $0.id < $1.id }) else { return }
            self.semanticUpdate(operation.id, source: "native-editor-notification")
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
        monitor = nil
        boundsObserver = nil
        inputSubscription = nil
        for id in Array(pending.keys) { expire(id, reason: "fixture closed") }
    }

    func observe(_ event: NSEvent) {
        guard let host, event.window === host.window else { return }
        let kind = event.type == .keyDown ? "key" : "scroll"
        if kind == "scroll" && event.scrollingDeltaY == 0 && event.scrollingDeltaX == 0 { return }
        var hit = host.hitTest(host.convert(event.locationInWindow, from: nil))
        var scroll: NSScrollView?
        while let view = hit {
            if let view = view as? NSScrollView { scroll = view; break }
            hit = view.superview
        }
        let clip = kind == "scroll" ? scroll?.contentView : nil
        clip?.postsBoundsChangedNotifications = true
        let editor = kind == "key" ? host.window?.firstResponder as? NSTextView : nil
        sequence += 1
        let signpost = OSSignpostID(log: log)
        let overlaps = pending.values.filter { $0.kind == kind }.map(\.id)
        for id in overlaps { pending[id]?.overlapped = true }
        let operation = Pending(id: sequence, kind: kind, workload: phase() + "-" + kind,
                                started: event.timestamp, beforeInput: input(),
                                editor: editor, beforeEditorText: editor?.string, clip: clip,
                                beforeOrigin: clip?.bounds.origin,
                                responder: host.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                                keyCode: kind == "key" ? event.keyCode : 0, modifiers: event.modifierFlags.rawValue,
                                signpost: signpost, overlapped: !overlaps.isEmpty)
        pending[operation.id] = operation
        os_signpost(.begin, log: log, name: "NativeInputCommit", signpostID: signpost,
                    "operation=%d", operation.id)
        // IME marked text updates the native editor before SwiftUI commits its
        // binding. Join the visible composition too, without changing input mode.
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, editor.string != operation.beforeEditorText else { return }
            self.semanticUpdate(operation.id, source: "native-editor-after-dispatch")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.expire(operation.id, reason: "no matching semantic update within 1 second")
        }
    }

    /// Native action activation -> verified state transition. AX-only actions
    /// without a recent event in this exact window are never latency samples.
    func beginNativeAction(_ workload: String) -> Int? {
        guard let host, let event = NSApp.currentEvent, event.window === host.window,
              [.leftMouseDown, .leftMouseUp, .keyDown].contains(event.type),
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25 else { return nil }
        sequence += 1
        let overlaps = pending.values.filter { $0.kind == "action" }.map(\.id)
        for id in overlaps { pending[id]?.overlapped = true }
        let signpost = OSSignpostID(log: log)
        pending[sequence] = Pending(id: sequence, kind: "action", workload: workload,
            started: event.timestamp, beforeInput: "", editor: nil, beforeEditorText: nil,
            clip: nil, beforeOrigin: nil, responder: "native action",
            keyCode: 0, modifiers: event.modifierFlags.rawValue, signpost: signpost,
            overlapped: !overlaps.isEmpty)
        let id = sequence
        os_signpost(.begin, log: log, name: "NativeInputCommit", signpostID: signpost,
                    "operation=%d", id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.expire(id, reason: "action semantic update not confirmed")
        }
        return id
    }

    func completeNativeAction(_ id: Int?) {
        if let id { semanticUpdate(id, source: "verified-native-action-state") }
    }

    private func semanticUpdate(_ id: Int, source: String) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        // @Published emits in willSet. Complete after its binding update returns,
        // and force layout/display only for the transaction joined to that update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, host.window != nil else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self else { return }
                let elapsed = (CACurrentMediaTime() - operation.started) * 1000
                self.samples.append(["operation": id, "workload": operation.workload,
                                     "milliseconds": elapsed, "semanticMatch": true,
                                     "firstResponder": operation.responder, "semanticSource": source,
                                     "keyCode": operation.keyCode, "overlapped": operation.overlapped])
                os_signpost(.end, log: self.log, name: "NativeInputCommit", signpostID: operation.signpost,
                            "semantic_match=1")
                self.onSample()
            }
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
            CATransaction.commit()
        }
    }

    private func expire(_ id: Int, reason: String) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        unmatched.append(["operation": id, "workload": operation.workload,
                          "firstResponder": operation.responder, "keyCode": operation.keyCode,
                          "modifiers": operation.modifiers, "scrollTargetFound": operation.clip != nil,
                          "reason": reason])
        os_signpost(.end, log: log, name: "NativeInputCommit", signpostID: operation.signpost,
                    "semantic_match=0")
        onSample()
    }

    func report() -> [String: Any] {
        var workloads: [String: Any] = [:]
        let eligible = samples.filter { $0["overlapped"] as? Bool != true }
        let groups = Dictionary(grouping: eligible) { $0["workload"] as! String }
        for (key, rows) in groups {
            let values = rows.compactMap { $0["milliseconds"] as? Double }.sorted()
            guard let maximum = values.last else { continue }
            let index = max(0, Int((Double(values.count) * 0.95).rounded(.up)) - 1)
            workloads[key] = ["count": values.count, "p95": values[index], "max": maximum,
                              "clockValid": values.allSatisfy { $0 >= 0 },
                              "withinTarget": values.allSatisfy { $0 >= 0 } &&
                                  values[index] <= 100 && maximum <= 250]
        }
        return ["metric": "native-event-to-semantic-host-transaction-commit-ms",
                "endpoint": "forced host transaction completion, not physical presentation",
                "semanticJoin": "native editor composition, input publisher or target clip bounds notification",
                "workloads": workloads, "samples": samples, "unmatched": unmatched,
                "pendingCount": pending.count, "excludedOverlapCount": samples.count - eligible.count,
                "requiredWorkloads": ["static-key", "static-scroll", "stream-key", "stream-scroll"]]
    }
}
#endif
