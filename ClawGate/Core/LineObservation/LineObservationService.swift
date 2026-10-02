import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// Machine-only diagnostics; never contains window titles, OCR text or credentials.
final class LineObservationDiagnostics: @unchecked Sendable {
    static let shared = LineObservationDiagnostics()
    private let lock = NSLock()
    private var value: [String: Any] = ["captureStatus": "starting", "deliveryStatus": "idle"]
    func update(_ values: [String: Any]) { lock.lock(); defer { lock.unlock() }; value.merge(values) { _, new in new } }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return value }
}

/// No redirected request may carry observation data or the configured credential.
private final class LineObservationSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class LineObservationService {
    static let shared = LineObservationService()
    static let enabledKey = "clawgate.lineObservationEnabled"
    private let configStore = ConfigStore()
    private var capture: LinePassiveCapture?
    private var loop: Task<Void, Never>?
    private var outbox: LineObservationOutbox?
    private var deviceID = ""
    private var lastSignature: String?
    private var lastChanged = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var retryAt = Date.distantPast
    private var capacityPausedAt: String?
    private var retryDelay: TimeInterval = 2
    private let session = URLSession(configuration: .ephemeral, delegate: LineObservationSessionDelegate(), delegateQueue: nil)
    private let diagnostics = LineObservationDiagnostics.shared

    func start() {
        guard loop == nil else { return }
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawgate/line-observation", isDirectory: true)
            outbox = try LineObservationOutbox(directory: root.appendingPathComponent("outbox", isDirectory: true))
            let deviceURL = root.appendingPathComponent("device-id")
            if FileManager.default.fileExists(atPath: deviceURL.path) {
                deviceID = try String(contentsOf: deviceURL).trimmingCharacters(in: .whitespacesAndNewlines)
                guard UUID(uuidString: deviceID) != nil else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                deviceID = UUID().uuidString.lowercased()
                try Data(deviceID.utf8).write(to: deviceURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deviceURL.path)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            diagnostics.update(["captureStatus": "storage_unavailable", "deliveryStatus": "blocked"])
            return
        }
        if #available(macOS 12.3, *) { capture = LinePassiveCapture() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval: TimeInterval = Date().timeIntervalSince(self.lastChanged) >= 30 ? 10 : 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func tick() async {
        let config = configStore.load()
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil || UserDefaults.standard.bool(forKey: Self.enabledKey)
        guard config.isClientRole, enabled else {
            diagnostics.update(["captureStatus": config.isClientRole ? "disabled" : "server_role", "deliveryStatus": "idle"])
            return
        }
        guard let outbox else { return }
        let now = Date()
        if outbox.queuedBytes >= 256 * 1024 * 1024 - 1024 * 1024 || capacityPausedAt != nil {
            if capacityPausedAt == nil { capacityPausedAt = Self.iso(now) }
            diagnostics.update(["captureStatus": "outbox_full", "deliveryStatus": "backpressure",
                                "gapStartedAt": capacityPausedAt!, "queueCount": outbox.queuedCount, "queueBytes": outbox.queuedBytes])
            await deliver(config: config)
            if outbox.queuedBytes < 256 * 1024 * 1024 - 1024 * 1024 {
                capacityPausedAt = nil
                diagnostics.update(["gapEndedAt": Self.iso(Date())])
            }
            return
        }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        var snapshots: [[String: Any]] = []
        var status = "unavailable"
        if locked {
            status = "screen_locked"
            snapshots = [Self.unavailableSnapshot(reason: status)]
        } else if #available(macOS 12.3, *), let capture {
            let windows = await capture.capture()
            if Task.isCancelled { return }
            status = windows.contains { $0.state == .captured } ? "observing" : (windows.first?.state.rawValue ?? "unavailable")
            snapshots = windows.map(Self.snapshot)
            diagnostics.update(["windows": windows.map { ["windowId": $0.windowID.map(String.init) as Any? ?? NSNull(),
                                                         "kind": $0.kind.rawValue, "state": $0.state.rawValue,
                                                         "width": $0.width, "height": $0.height, "spanCount": $0.rows.count] as [String: Any] }])
            let notifications = Self.notificationSnapshots()
            snapshots.append(contentsOf: notifications.isEmpty ? [["scope": "notification_visible_window", "coverage": "unavailable", "reason": "no_verified_line_banner", "ocrSpans": []]] : notifications)
            diagnostics.update(["windowCount": windows.filter { $0.windowID != nil }.count,
                                "availableWindowCount": windows.filter { $0.state == .captured }.count,
                                "ocrSpanCount": windows.reduce(0) { $0 + $1.rows.count }])
        } else {
            status = "unsupported_os"
            snapshots = [Self.unavailableSnapshot(reason: status)]
        }
        for requiredScope in ["sidebar_visible_window", "selected_thread_visible_window", "notification_visible_window"] {
            if !snapshots.contains(where: { $0["scope"] as? String == requiredScope }) {
                snapshots.append(["scope": requiredScope, "coverage": "unavailable",
                                  "reason": status == "observing" ? "no_identified_window" : status, "ocrSpans": []])
            }
        }
        diagnostics.update(["captureStatus": status, "lastObservedAt": Self.iso(now),
                            "queueCount": outbox.queuedCount, "queueBytes": outbox.queuedBytes])
        do {
            let signatureData = try JSONSerialization.data(withJSONObject: snapshots, options: [.sortedKeys])
            let signature = SHA256.hash(data: signatureData).map { String(format: "%02x", $0) }.joined()
            let changed = signature != lastSignature
            if changed || now.timeIntervalSince(lastHeartbeat) >= 60 {
                // A full outbox is observable and never evicts unacknowledged data.
                guard outbox.queuedBytes + signatureData.count + 2048 <= 256 * 1024 * 1024 else {
                    capacityPausedAt = Self.iso(now)
                    diagnostics.update(["captureStatus": "outbox_full", "deliveryStatus": "backpressure"])
                    await deliver(config: config)
                    return
                }
                let allocation = try outbox.allocateID()
                let observation: [String: Any] = [
                    "schemaVersion": 1, "observationId": allocation.id,
                    "producerInstance": outbox.producerInstance, "deviceId": deviceID, "seq": allocation.seq,
                    "platform": "line", "source": "clawgate-line-passive-ocr", "capturedAt": Self.iso(now),
                    "snapshots": snapshots,
                    "state": ["captureStatus": status, "queueCount": outbox.queuedCount, "queueBytes": outbox.queuedBytes]
                ]
                let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
                try outbox.enqueue(data, observationID: allocation.id)
                lastSignature = signature
                lastHeartbeat = now
                if changed { lastChanged = now }
            }
        } catch {
            diagnostics.update(["captureStatus": "outbox_write_failed", "deliveryStatus": "blocked"])
        }
        await deliver(config: config)
        diagnostics.update(["queueCount": outbox.queuedCount, "queueBytes": outbox.queuedBytes, "rejectedCount": outbox.rejectedCount])
    }

    private func deliver(config: AppConfig) async {
        guard let outbox, Date() >= retryAt else { return }
        do {
            let records = try outbox.pending(limit: 5)
            guard !records.isEmpty else { diagnostics.update(["deliveryStatus": "caught_up"]); return }
            guard let gateway = OpenClawGatewayInfo.load(), !gateway.token.isEmpty else {
                diagnostics.update(["deliveryStatus": "auth_unavailable"]); backoff(); return
            }
            var url = URLComponents()
            url.scheme = "http"
            url.host = config.openclawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            url.port = config.openclawPort
            url.path = "/api/line-observation"
            guard let endpoint = url.url else { diagnostics.update(["deliveryStatus": "invalid_endpoint"]); backoff(); return }
            let objects = try records.map { try JSONSerialization.jsonObject(with: $0.data) }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["observations": objects], options: [.sortedKeys])
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                diagnostics.update(["deliveryStatus": "http_\((response as? HTTPURLResponse)?.statusCode ?? 0)"])
                backoff(); return
            }
            let sentIDs = Set(records.map(\.id))
            guard let receipt = LineObservationAcknowledgement.parse(data: data, sentIDs: sentIDs) else {
                diagnostics.update(["deliveryStatus": "invalid_commit_ack"]); backoff(); return
            }
            let acked = receipt.acked
            for rejected in receipt.permanentRejected {
                try outbox.markRejected([rejected.id], code: rejected.code)
            }
            guard !acked.isEmpty else {
                diagnostics.update(["deliveryStatus": receipt.permanentRejected.isEmpty ? "no_commit_ack" : "permanent_rejection",
                                    "rejectedCount": outbox.rejectedCount]); backoff(); return
            }
            try outbox.acknowledge(acked)
            diagnostics.update(["deliveryStatus": acked.count == records.count ? "committed" : "partial_ack",
                                "lastAcknowledgedAt": Self.iso(Date())])
            retryDelay = 2
            retryAt = acked.count == records.count ? .distantPast : Date().addingTimeInterval(60)
        } catch {
            diagnostics.update(["deliveryStatus": "transport_or_store_failed"])
            backoff()
        }
    }

    private func backoff() { retryAt = Date().addingTimeInterval(retryDelay); retryDelay = min(60, retryDelay * 2) }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func unavailableSnapshot(reason: String) -> [String: Any] {
        ["scope": "state", "coverage": "unavailable", "reason": reason, "ocrSpans": []]
    }
    private static func snapshot(_ window: LineWindowObservation) -> [String: Any] {
        let scope = window.kind == .sidebar ? "sidebar_visible_window" : window.kind == .conversation ? "selected_thread_visible_window" : "state"
        return ["scope": scope, "coverage": window.state == .captured ? "available" : "unavailable",
                "reason": window.state == .captured ? NSNull() : window.state.rawValue as Any,
                "windowId": window.windowID.map { String($0) } as Any? ?? NSNull(),
                "windowWidth": window.width, "windowHeight": window.height,
                "coordinateSystem": "normalized_bottom_left", "conversationKey": NSNull(),
                "identityConfidence": "unknown", "tailCoverage": false,
                "ocrSpans": window.rows.enumerated().map { index, row in
                    ["ordinal": index, "text": row.text, "x": row.box.x, "y": row.box.y,
                     "width": row.box.width, "height": row.box.height, "confidence": row.confidence as Any? ?? NSNull(),
                     "fromSelf": NSNull(), "sender": NSNull(), "sentAt": NSNull(), "sentAtPrecision": "unknown"] as [String: Any]
                }]
    }

    /// Only already-displayed Notification Center windows; no click or open.
    private static func notificationSnapshots() -> [[String: Any]] {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let visible = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
        guard !visible.isEmpty else { return [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        return AXQuery.windows(appElement: ax).compactMap { window in
            guard let frame = AXQuery.descendants(of: window, maxDepth: 0, maxNodes: 1).first?.frame, visible.contains(where: { info in
                guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return abs(rect.minX-frame.minX) < 2 && abs(rect.minY-frame.minY) < 2 && abs(rect.width-frame.width) < 2 && abs(rect.height-frame.height) < 2
            }) else { return nil }
            let nodes = AXQuery.descendants(of: window, maxDepth: 8, maxNodes: 50).filter { $0.role == "AXStaticText" }
            guard let appLabel = nodes.first, (appLabel.value ?? appLabel.title) == "LINE",
                  let labelFrame = appLabel.frame, labelFrame.minY >= frame.minY,
                  labelFrame.maxY <= frame.minY + min(48, frame.height * 0.35) else { return nil }
            let texts = nodes.dropFirst().compactMap { $0.value ?? $0.title }
            return ["scope": "notification_visible_window", "coverage": "available", "reason": NSNull(),
                    "conversationKey": NSNull(), "identityConfidence": "unknown", "tailCoverage": false,
                    "notificationSpans": texts.map { ["text": $0] }, "ocrSpans": []]
        }
    }
}

/// Reject unknown IDs and malformed ACKs before mutating the durable queue.
struct LineObservationAcknowledgement {
    let acked: [String]
    let permanentRejected: [(id: String, code: String)]
    static func parse(data: Data, sentIDs: Set<String>) -> LineObservationAcknowledgement? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["ok"] as? Bool == true, let acked = body["ackedObservationIds"] as? [String],
              Set(acked).isSubset(of: sentIDs), Set(acked).count == acked.count else { return nil }
        var rejected: [(id: String, code: String)] = []
        if let raw = body["rejected"] {
            guard let rows = raw as? [[String: Any]] else { return nil }
            for row in rows {
                guard let id = row["observationId"] as? String, sentIDs.contains(id), !acked.contains(id),
                      let code = row["code"] as? String, let permanent = row["permanent"] as? Bool else { return nil }
                if permanent { rejected.append((id, code)) }
            }
        }
        return LineObservationAcknowledgement(acked: acked, permanentRejected: rejected)
    }
}
