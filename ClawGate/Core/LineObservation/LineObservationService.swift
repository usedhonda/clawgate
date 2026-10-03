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
    private var schemaVersion = 1
    private var capabilityEndpoint: String?
    private var capabilityCheckedAt = Date.distantPast
    private var hubCapabilityReady = false
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
            clearSurfaceDiagnostics()
            return
        }
        guard let outbox else { return }
        let now = Date()
        await refreshCapabilities(config: config)
        if outbox.queuedBytes >= 256 * 1024 * 1024 - 1024 * 1024 || capacityPausedAt != nil {
            if capacityPausedAt == nil { capacityPausedAt = Self.iso(now) }
            diagnostics.update(["captureStatus": "outbox_full", "deliveryStatus": "backpressure",
                                "gapStartedAt": capacityPausedAt!, "queueCount": outbox.queuedCount, "queueBytes": outbox.queuedBytes])
            clearSurfaceDiagnostics()
            await deliver(config: config)
            if outbox.queuedBytes < 256 * 1024 * 1024 - 1024 * 1024 {
                capacityPausedAt = nil
                diagnostics.update(["gapEndedAt": Self.iso(Date())])
            }
            return
        }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        var snapshots: [[String: Any]] = []
        var auditSnapshots: [[String: Any]] = []
        var status = "unavailable"
        clearSurfaceDiagnostics()
        if locked {
            status = "screen_locked"
            snapshots = [Self.unavailableSnapshot(reason: status)]
        } else if #available(macOS 12.3, *), let capture {
            let windows = await capture.capture()
            if Task.isCancelled { return }
            if let metricsData = try? JSONEncoder().encode(capture.metrics),
               let performance = try? JSONSerialization.jsonObject(with: metricsData) {
                diagnostics.update(["capturePerformance": performance, "lastCaptureCompletedAt": Self.iso(Date())])
            }
            status = windows.contains { $0.state == .captured } ? "observing" : (windows.first?.state.rawValue ?? "unavailable")
            snapshots = windows.map { Self.snapshot($0, schemaVersion: schemaVersion) }
            auditSnapshots = windows.map { window in
                var audit = Self.snapshot(window, schemaVersion: 3)
                audit["localSchemaVersion"] = 3
                audit["deliverySchemaVersion"] = schemaVersion
                audit["historyRegions"] = window.historyRegions.map {
                    ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height]
                }
                return audit
            }
            diagnostics.update([
                "localBodyCandidateCount": auditSnapshots.reduce(0) { $0 + (($1["bodyCandidates"] as? [[String: Any]])?.count ?? 0) },
                "displayedTimeCount": auditSnapshots.reduce(0) { count, snapshot in
                    count + ((snapshot["annotations"] as? [[String: Any]])?.filter { $0["kind"] as? String == "displayed_time" }.count ?? 0)
                },
                "annotationCount": auditSnapshots.reduce(0) { $0 + (($1["annotations"] as? [[String: Any]])?.count ?? 0) },
                "observedLabelWindowCount": windows.filter { $0.observedLabel != nil }.count,
                "senderKnownCount": 0, "directionKnownCount": 0
            ])
            diagnostics.update(["windows": windows.map { ["windowId": $0.windowID.map(String.init) as Any? ?? NSNull(),
                                                         "kind": $0.kind.rawValue, "state": $0.state.rawValue,
                                                         "width": $0.width, "height": $0.height, "spanCount": $0.rows.count,
                                                         "bodyCandidateCount": $0.bodyCandidates.count,
                                                         "labelObserved": $0.observedLabel != nil] as [String: Any] }])
            let notifications = Self.notificationSnapshots()
            snapshots.append(contentsOf: notifications.isEmpty ? [["scope": "notification_visible_window", "coverage": "unavailable", "reason": "no_verified_line_banner", "ocrSpans": []]] : notifications)
            diagnostics.update(["windowCount": windows.filter { $0.windowID != nil }.count,
                                "availableWindowCount": windows.filter { $0.state == .captured }.count,
                                "ocrSpanCount": windows.reduce(0) { $0 + $1.rows.count },
                                "sidebarWindowCount": windows.filter { $0.kind == .sidebar && $0.state == .captured }.count,
                                "sidebarOCRSpanCount": windows.filter { $0.kind == .sidebar }.reduce(0) { $0 + $1.rows.count },
                                "conversationWindowCount": windows.filter { $0.kind == .conversation && $0.state == .captured }.count,
                                "conversationOCRSpanCount": windows.filter { $0.kind == .conversation }.reduce(0) { $0 + $1.rows.count },
                                "bodyCandidateCount": windows.reduce(0) { $0 + $1.bodyCandidates.count }])
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
        snapshots = LineObservationProtocol.snapshotsForWire(snapshots, schemaVersion: schemaVersion)
        let auditStatus = LineObservationAudit.consumeIfRequested(snapshots: auditSnapshots, capturedAt: Self.iso(now))
        if auditStatus != .noRequest { diagnostics.update(["auditStatus": auditStatus.diagnosticStatus]) }
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
                    "schemaVersion": schemaVersion, "observationId": allocation.id,
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

    private func clearSurfaceDiagnostics() {
        diagnostics.update(["windows": [] as [[String: Any]], "windowCount": 0, "availableWindowCount": 0,
                            "capturePerformance": NSNull(),
                            "ocrSpanCount": 0, "sidebarWindowCount": 0, "sidebarOCRSpanCount": 0,
                            "conversationWindowCount": 0, "conversationOCRSpanCount": 0, "bodyCandidateCount": 0,
                            "localBodyCandidateCount": 0, "displayedTimeCount": 0, "annotationCount": 0,
                            "observedLabelWindowCount": 0, "senderKnownCount": 0, "directionKnownCount": 0,
                            "schemaVersion": schemaVersion])
    }

    private func refreshCapabilities(config: AppConfig) async {
        do {
            if let provision = try HubProducerProvision.load(source: "line") {
                try outbox?.selectIndependentHub()
                let endpoint = provision.endpoint("v1/capabilities")
                let credentialRevision = SHA256.hash(data: Data(provision.bearer_token.utf8)).map { String(format: "%02x", $0) }.joined()
                let key = endpoint.absoluteString + credentialRevision
                if capabilityEndpoint == key, Date().timeIntervalSince(capabilityCheckedAt) < 300 { return }
                capabilityEndpoint = key
                capabilityCheckedAt = Date()
                hubCapabilityReady = false
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 3
                request.setValue("Bearer \(provision.bearer_token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await boundedHubResponse(request)
                if response.statusCode == 200, provision.acceptsCapabilities(data),
                   let supported = LineObservationProtocol.supportedHubVersion(capabilityData: data) {
                    hubCapabilityReady = true
                    // Generic Hub stores the unchanged current observation schema;
                    // it does not interpret OCR candidates as message facts.
                    schemaVersion = supported
                }
                return
            }
            if outbox?.independentHubSelected == true {
                hubCapabilityReady = false
                return
            }
        } catch {
            try? outbox?.selectIndependentHub()
            hubCapabilityReady = false
            return
        }
        var url = URLComponents()
        url.scheme = "http"
        url.host = config.openclawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        url.port = config.openclawPort
        url.path = "/api/line-observation/capabilities"
        guard let endpoint = url.url else { schemaVersion = 1; return }
        if capabilityEndpoint == endpoint.absoluteString, Date().timeIntervalSince(capabilityCheckedAt) < 300 { return }
        capabilityEndpoint = endpoint.absoluteString
        capabilityCheckedAt = Date()
        schemaVersion = 1
        guard let gateway = OpenClawGatewayInfo.load(), !gateway.token.isEmpty else { return }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3
        request.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                schemaVersion = LineObservationProtocol.supportedVersion(capabilityData: data)
            }
        } catch { /* Keep legacy capture/delivery when capabilities cannot be verified. */ }
    }

    private func deliver(config: AppConfig) async {
        guard let outbox, Date() >= retryAt else { return }
        do {
            let records = try outbox.pending(limit: 5)
            guard !records.isEmpty else { diagnostics.update(["deliveryStatus": "caught_up"]); return }
            if let provision = try HubProducerProvision.load(source: "line") {
                try outbox.selectIndependentHub()
                guard hubCapabilityReady else {
                    diagnostics.update(["deliveryStatus": "hub_capability_unavailable"]); backoff(); return
                }
                try await deliverToHub(records: records, outbox: outbox, provision: provision)
                return
            }
            guard !outbox.independentHubSelected else {
                diagnostics.update(["deliveryStatus": "hub_provision_unavailable"]); backoff(); return
            }
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

    private func boundedHubResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, http)
    }

    private func deliverToHub(records: [(id: String, data: Data)], outbox: LineObservationOutbox,
                              provision: HubProducerProvision) async throws {
        var acknowledged = 0
        for record in records {
            let envelope = try outbox.hubEnvelope(observationID: record.id) { original in
                try LineObservationProtocol.hubEnvelope(observation: original, observationID: record.id)
            }
            guard envelope.count <= 20 * 1024 * 1024 else {
                try outbox.markRejected([record.id], code: "hub_event_too_large")
                continue
            }
            var request = URLRequest(url: provision.endpoint("v1/events"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(provision.bearer_token)", forHTTPHeaderField: "Authorization")
            request.httpBody = envelope
            let (data, response) = try await boundedHubResponse(request)
            guard !Task.isCancelled else { return }
            if response.statusCode == 409 {
                try outbox.markRejected([record.id], code: "hub_content_conflict")
                continue
            }
            guard [200, 201].contains(response.statusCode) else {
                diagnostics.update(["deliveryStatus": "hub_http_\(response.statusCode)"]); backoff(); return
            }
            let receipt = try HubMetadataReceipt.validatedData(response: data, source: "line", externalID: record.id)
            try outbox.acknowledgeHub(record.id, receipt: receipt)
            acknowledged += 1
            diagnostics.update(["deliveryStatus": "hub_committed", "lastAcknowledgedAt": Self.iso(Date())])
        }
        if acknowledged > 0 { retryDelay = 2; retryAt = .distantPast }
        else { diagnostics.update(["deliveryStatus": "permanent_rejection"]); backoff() }
    }

    private func backoff() { retryAt = Date().addingTimeInterval(retryDelay); retryDelay = min(60, retryDelay * 2) }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func unavailableSnapshot(reason: String) -> [String: Any] {
        ["scope": "state", "coverage": "unavailable", "reason": reason, "ocrSpans": []]
    }
    static func snapshot(_ window: LineWindowObservation, schemaVersion: Int) -> [String: Any] {
        let scope = window.kind == .sidebar ? "sidebar_visible_window" : window.kind == .conversation ? "selected_thread_visible_window" : "state"
        var result: [String: Any] = ["scope": scope, "coverage": window.state == .captured ? "available" : "unavailable",
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
        let content = schemaVersion == 3 && window.kind == .conversation && window.state == .captured
            ? LineVisibleContentExtractor.extract(rows: window.rows, textBlockRegions: window.historyRegions, regionMethod: "ax_history_row")
            : nil
        if schemaVersion >= 2 {
            result["bodyCandidates"] = (content?.bodyCandidates ?? window.bodyCandidates).map { candidate in
                var body: [String: Any] = ["ordinal": candidate.ordinal, "text": candidate.text, "spanOrdinals": candidate.spanOrdinals,
                 "x": candidate.box.x, "y": candidate.box.y, "width": candidate.box.width, "height": candidate.box.height,
                 "extractionMethod": candidate.extractionMethod, "coverage": candidate.coverage,
                 "sender": NSNull(), "fromSelf": NSNull(), "sentAt": NSNull(), "sentAtPrecision": "unknown",
                 "displayedTimeText": NSNull()]
                if schemaVersion == 3 {
                    body["displayedTimeText"] = candidate.displayedTimeText as Any? ?? NSNull()
                    let time = content?.annotations.first { $0.kind == "displayed_time" && $0.relatedBodyOrdinal == candidate.ordinal }
                    body["displayedTimeEvidence"] = time.map { ["method": $0.evidence, "spanOrdinals": $0.spanOrdinals] as [String: Any] } as Any? ?? NSNull()
                }
                return body
            }
        }
        if schemaVersion == 3 {
            let label = content == nil ? nil : window.observedLabel
            result["conversationLabel"] = label as Any? ?? NSNull()
            result["conversationLabelEvidence"] = label == nil ? NSNull() : "ax_window_title" as Any
            result["annotations"] = (content?.annotations ?? []).map { annotation in
                ["ordinal": annotation.ordinal, "text": annotation.text, "spanOrdinals": annotation.spanOrdinals,
                 "x": annotation.box.x, "y": annotation.box.y, "width": annotation.box.width, "height": annotation.box.height,
                 "kind": annotation.kind, "evidence": annotation.evidence,
                 "relatedBodyOrdinal": annotation.relatedBodyOrdinal as Any? ?? NSNull()] as [String: Any]
            }
        }
        return result
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
