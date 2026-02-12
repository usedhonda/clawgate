import AppKit
import Foundation
import NIOHTTP1

final class BridgeCore {
    let eventBus: EventBus
    let statsCollector: StatsCollector

    private let registry: AdapterRegistry
    private let logger: AppLogger
    private let opsLogStore: OpsLogStore
    private let configStore: ConfigStore
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(eventBus: EventBus, registry: AdapterRegistry, logger: AppLogger, opsLogStore: OpsLogStore, configStore: ConfigStore, statsCollector: StatsCollector) {
        self.eventBus = eventBus
        self.registry = registry
        self.logger = logger
        self.opsLogStore = opsLogStore
        self.configStore = configStore
        self.statsCollector = statsCollector
        self.jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
    }

    /// CSRF protection: reject POST requests that carry an Origin header (browser-initiated).
    func checkOrigin(method: HTTPMethod, headers: HTTPHeaders) -> HTTPResult? {
        guard method == .POST else { return nil }
        guard let origin = headers.first(name: "Origin"), !origin.isEmpty else { return nil }
        let payload = ErrorPayload(
            code: "browser_origin_rejected",
            message: "Requests from browsers are rejected",
            retriable: false,
            failedStep: "origin_check",
            details: "Origin header detected: \(origin)"
        )
        return jsonResponse(
            status: .forbidden,
            body: encode(APIResponse<String>(ok: false, result: nil, error: payload))
        )
    }

    /// Optional Bearer auth for remote access mode.
    /// Localhost default mode keeps auth disabled for backward compatibility.
    func checkAuthorization(headers: HTTPHeaders) -> HTTPResult? {
        let cfg = configStore.load()
        guard cfg.remoteAccessEnabled else { return nil }
        let token = cfg.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        let authHeader = headers.first(name: "Authorization") ?? ""
        guard authHeader == "Bearer \(token)" else {
            let payload = ErrorPayload(
                code: "unauthorized",
                message: "Missing or invalid bearer token",
                retriable: false,
                failedStep: "auth",
                details: nil
            )
            return jsonResponse(
                status: .unauthorized,
                body: encode(APIResponse<String>(ok: false, result: nil, error: payload))
            )
        }
        return nil
    }

    func health() -> HTTPResult {
        let body = encode(HealthResponse(ok: true, version: "0.1.0"))
        return jsonResponse(status: .ok, body: body)
    }

    func config() -> HTTPResult {
        let cfg = configStore.load()
        let result = ConfigResult(
            version: "0.1.0",
            general: ConfigGeneralSection(
                debugLogging: cfg.debugLogging,
                includeMessageBodyInLogs: cfg.includeMessageBodyInLogs
            ),
            line: ConfigLineSection(
                enabled: cfg.lineEnabled && cfg.nodeRole != .client,
                defaultConversation: cfg.lineDefaultConversation,
                pollIntervalSeconds: cfg.linePollIntervalSeconds,
                detectionMode: cfg.lineDetectionMode,
                fusionThreshold: cfg.lineFusionThreshold,
                enablePixelSignal: cfg.lineEnablePixelSignal,
                enableProcessSignal: cfg.lineEnableProcessSignal,
                enableNotificationStoreSignal: cfg.lineEnableNotificationStoreSignal
            ),
            tmux: ConfigTmuxSection(
                enabled: cfg.tmuxEnabled,
                statusBarURL: cfg.tmuxStatusBarURL,
                sessionModes: cfg.tmuxSessionModes
            ),
            remote: ConfigRemoteSection(
                nodeRole: cfg.nodeRole.rawValue,
                accessEnabled: cfg.remoteAccessEnabled,
                federationEnabled: cfg.federationEnabled,
                federationURL: cfg.federationURL
            )
        )
        let body = encode(APIResponse(ok: true, result: result, error: nil))
        return jsonResponse(status: .ok, body: body)
    }

    func send(body: Data, traceID: String?) -> HTTPResult {
        let requestTrace = normalizedTraceID(traceID)
        let start = Date()
        writeOps(level: "info", event: "ingress_received", traceID: requestTrace, stage: "bridge_server", action: "send_message", status: "start", errorCode: nil, errorMessage: nil, latencyMs: nil)
        do {
            let request = try jsonDecoder.decode(SendRequest.self, from: body)
            let trace = normalizedTraceID(request.payload.traceID ?? requestTrace)
            writeOps(level: "info", event: "ingress_validated", traceID: trace, stage: "bridge_server", action: "send_message", status: "ok", errorCode: nil, errorMessage: nil, latencyMs: nil)
            guard request.action == "send_message" else {
                throw BridgeRuntimeError(
                    code: "unsupported_action",
                    message: "Only send_message action is supported",
                    retriable: false,
                    failedStep: "validate_request",
                    details: request.action
                )
            }
            guard !request.payload.conversationHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeRuntimeError(
                    code: "invalid_conversation_hint",
                    message: "conversation_hint is required",
                    retriable: false,
                    failedStep: "validate_request",
                    details: nil
                )
            }
            guard !request.payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeRuntimeError(
                    code: "invalid_text",
                    message: "text is required",
                    retriable: false,
                    failedStep: "validate_request",
                    details: nil
                )
            }
            if let denied = rejectLineOnClient(adapterName: request.adapter) {
                return denied
            }

            guard let adapter = registry.adapter(for: request.adapter) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: request.adapter
                )
            }

            let adapterAction = request.adapter == "line" ? "line_send" : "gateway_forward"
            writeOps(level: "info", event: "\(adapterAction)_start", traceID: trace, stage: "adapter", action: adapterAction, status: "start", errorCode: nil, errorMessage: nil, latencyMs: nil)
            let (result, steps) = try adapter.sendMessage(payload: request.payload)
            logger.log(.info, "send_message completed with \(steps.count) steps")
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            writeOps(level: "info", event: "\(adapterAction)_ok", traceID: trace, stage: "adapter", action: adapterAction, status: "ok", errorCode: nil, errorMessage: nil, latencyMs: latencyMs)
            statsCollector.increment("sent", adapter: request.adapter)
            eventBus.append(type: "outbound_message", adapter: request.adapter, payload: [
                "text": String(request.payload.text.prefix(100)),
                "conversation": request.payload.conversationHint,
                "trace_id": trace,
            ])

            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content), traceID: trace)
        } catch let err as BridgeRuntimeError {
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            writeOps(level: "error", event: "send_failed", traceID: requestTrace, stage: "bridge_server", action: "send_message", status: "failed", errorCode: err.code, errorMessage: err.message, latencyMs: latencyMs)
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<SendResult>(ok: false, result: nil, error: err.asPayload())),
                traceID: requestTrace
            )
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            writeOps(level: "error", event: "decode_failed", traceID: requestTrace, stage: "bridge_server", action: "send_message", status: "failed", errorCode: "invalid_json", errorMessage: String(describing: error), latencyMs: latencyMs)
            let payload = ErrorPayload(
                code: "invalid_json",
                message: "Could not parse request JSON",
                retriable: false,
                failedStep: "decode_request",
                details: String(describing: error)
            )
            return jsonResponse(status: .badRequest, body: encode(APIResponse<SendResult>(ok: false, result: nil, error: payload)), traceID: requestTrace)
        }
    }

    func debugInject(body: Data) -> HTTPResult {
        struct DebugInjectRequest: Codable {
            let type: String?
            let adapter: String?
            let text: String
            let conversation: String?
        }
        do {
            let req = try jsonDecoder.decode(DebugInjectRequest.self, from: body)
            let eventType = req.type ?? "inbound_message"
            let adapter = req.adapter ?? "line"
            var payload: [String: String] = ["text": req.text]
            if let conv = req.conversation {
                payload["conversation"] = conv
            }
            let event = eventBus.append(type: eventType, adapter: adapter, payload: payload)
            logger.log(.info, "debug/inject: type=\(eventType) adapter=\(adapter) eventID=\(event.id)")
            let result: [String: String] = [
                "event_id": "\(event.id)",
                "type": eventType,
                "adapter": adapter,
            ]
            return jsonResponse(status: .ok, body: encode(APIResponse(ok: true, result: result, error: nil)))
        } catch {
            let payload = ErrorPayload(
                code: "invalid_json",
                message: "Could not parse debug inject request",
                retriable: false,
                failedStep: "decode_request",
                details: String(describing: error)
            )
            return jsonResponse(status: .badRequest, body: encode(APIResponse<[String: String]>(ok: false, result: nil, error: payload)))
        }
    }

    func opsLogs(limit: Int, level: String?, traceID: String?) -> HTTPResult {
        let entries = opsLogStore.recent(limit: limit, levelFilter: level, traceFilter: traceID)
        let result = OpsLogsResult(entries: entries, count: entries.count)
        return jsonResponse(status: .ok, body: encode(APIResponse(ok: true, result: result, error: nil)))
    }

    func context(adapter adapterName: String) -> HTTPResult {
        if let denied = rejectLineOnClient(adapterName: adapterName) {
            return denied
        }
        do {
            guard let adapter = registry.adapter(for: adapterName) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: adapterName
                )
            }
            let result = try adapter.getContext()
            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content))
        } catch let err as BridgeRuntimeError {
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<ConversationContext>(ok: false, result: nil, error: err.asPayload()))
            )
        } catch {
            let payload = ErrorPayload(
                code: "internal_error",
                message: "Error while retrieving context",
                retriable: false,
                failedStep: "get_context",
                details: String(describing: error)
            )
            return jsonResponse(status: .internalServerError, body: encode(APIResponse<ConversationContext>(ok: false, result: nil, error: payload)))
        }
    }

    func messages(adapter adapterName: String, limit: Int) -> HTTPResult {
        if let denied = rejectLineOnClient(adapterName: adapterName) {
            return denied
        }
        do {
            guard let adapter = registry.adapter(for: adapterName) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: adapterName
                )
            }
            var result = try adapter.getMessages(limit: limit)
            if adapterName == "tmux", result.messages.isEmpty {
                result = buildTmuxMessageListFromEventBus(limit: limit)
            }
            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content))
        } catch let err as BridgeRuntimeError {
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<MessageList>(ok: false, result: nil, error: err.asPayload()))
            )
        } catch {
            let payload = ErrorPayload(
                code: "internal_error",
                message: "Error while retrieving messages",
                retriable: false,
                failedStep: "get_messages",
                details: String(describing: error)
            )
            return jsonResponse(status: .internalServerError, body: encode(APIResponse<MessageList>(ok: false, result: nil, error: payload)))
        }
    }

    func conversations(adapter adapterName: String, limit: Int) -> HTTPResult {
        if let denied = rejectLineOnClient(adapterName: adapterName) {
            return denied
        }
        do {
            guard let adapter = registry.adapter(for: adapterName) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: adapterName
                )
            }
            var result = try adapter.getConversations(limit: limit)
            if adapterName == "tmux", result.conversations.isEmpty {
                result = buildTmuxConversationListFromEventBus(limit: limit)
            }
            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content))
        } catch let err as BridgeRuntimeError {
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<ConversationList>(ok: false, result: nil, error: err.asPayload()))
            )
        } catch {
            let payload = ErrorPayload(
                code: "internal_error",
                message: "Error while retrieving conversations",
                retriable: false,
                failedStep: "get_conversations",
                details: String(describing: error)
            )
            return jsonResponse(status: .internalServerError, body: encode(APIResponse<ConversationList>(ok: false, result: nil, error: payload)))
        }
    }

    func stats(days: Int) -> HTTPResult {
        let todayStats = statsCollector.today()
        let historyEntries = statsCollector.history(count: days).map { (date, stats) in
            DayStatsEntry(date: date, stats: stats)
        }
        let result = StatsResult(
            today: todayStats,
            history: historyEntries,
            totalDaysTracked: historyEntries.count + 1
        )
        let content = APIResponse(ok: true, result: result, error: nil)
        return jsonResponse(status: .ok, body: encode(content))
    }

    func poll(since: Int64?) -> HTTPResult {
        let data = eventBus.poll(since: since)

        let deliveredTmux = data.events.filter { event in
            guard event.adapter == "tmux", event.type == "inbound_message" else { return false }
            let source = event.payload["source"] ?? ""
            return source == "completion" || source == "question" || source == "progress"
        }
        if !deliveredTmux.isEmpty {
            let trace = "poll-\(data.nextCursor)"
            writeOps(
                level: "info",
                event: "tmux_gateway_deliver",
                traceID: trace,
                stage: "gateway",
                action: "poll_delivery",
                status: "ok",
                errorCode: nil,
                errorMessage: nil,
                latencyMs: nil
            )
        }

        let response = PollResponse(ok: true, events: data.events, nextCursor: data.nextCursor)
        return jsonResponse(status: .ok, body: encode(response))
    }

    func axdump(adapter adapterName: String) -> HTTPResult {
        if let denied = rejectLineOnClient(adapterName: adapterName) {
            return denied
        }
        do {
            guard let adapter = registry.adapter(for: adapterName) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: adapterName
                )
            }
            let dump = try AXDump.dump(bundleIdentifier: adapter.bundleIdentifier)
            return jsonResponse(status: .ok, body: encode(dump))
        } catch let err as BridgeRuntimeError {
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<AXDumpNode>(ok: false, result: nil, error: err.asPayload()))
            )
        } catch {
            let payload = ErrorPayload(
                code: "axdump_failed",
                message: "Failed to retrieve AX dump",
                retriable: true,
                failedStep: "axdump",
                details: String(describing: error)
            )
            return jsonResponse(status: .serviceUnavailable, body: encode(APIResponse<AXDumpNode>(ok: false, result: nil, error: payload)))
        }
    }

    func doctor() -> HTTPResult {
        var checks: [DoctorCheck] = []
        let cfg = configStore.load()
        let lineEnabled = cfg.nodeRole != .client && cfg.lineEnabled

        // Check 1: App signature authority (avoid TCC re-prompt churn)
        checks.append(appSignatureCheck())

        // Check 2: Accessibility permission
        let axTrusted = AXIsProcessTrusted()
        checks.append(DoctorCheck(
            name: "accessibility_permission",
            status: axTrusted ? "ok" : "error",
            message: axTrusted ? "Accessibility permission is granted" : "Accessibility permission is not granted",
            details: axTrusted ? nil : "System Settings > Privacy & Security > Accessibility"
        ))

        // Check 3: LINE running
        let lineRunning = lineEnabled && (NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first != nil)
        checks.append(DoctorCheck(
            name: "line_running",
            status: lineEnabled ? (lineRunning ? "ok" : "warning") : "ok",
            message: lineEnabled ? (lineRunning ? "LINE is running" : "LINE is not running") : "LINE checks disabled (client role or LINE disabled)",
            details: lineEnabled ? (lineRunning ? nil : "Please launch LINE") : "Enable LINE in Settings when needed"
        ))

        // Check 4: LINE window accessible (only if LINE is running and AX is trusted)
        if lineEnabled && axTrusted && lineRunning {
            let windowCheck = checkLINEWindowAccessible()
            checks.append(windowCheck)
        } else {
            checks.append(DoctorCheck(
                name: "line_window_accessible",
                status: lineEnabled ? "warning" : "ok",
                message: "LINE window check skipped",
                details: lineEnabled ? (!axTrusted ? "Accessibility permission required" : "LINE is not running") : "nodeRole=client or lineEnabled=false"
            ))
        }

        // Check 5: Port 8765 (we're already listening, so this is informational)
        checks.append(DoctorCheck(
            name: "server_port",
            status: "ok",
            message: "Server is listening on port 8765",
            details: "127.0.0.1:8765"
        ))

        // Check 6: Screen Recording permission (for Vision OCR)
        let screenOk = CGPreflightScreenCaptureAccess()
        checks.append(DoctorCheck(
            name: "screen_recording_permission",
            status: screenOk ? "ok" : "warning",
            message: screenOk ? "Screen recording permission granted" : "Screen recording not granted (OCR disabled)",
            details: screenOk ? nil : "System Settings > Privacy > Screen Recording"
        ))

        // Calculate summary
        let passed = checks.filter { $0.status == "ok" }.count
        let warnings = checks.filter { $0.status == "warning" }.count
        let errors = checks.filter { $0.status == "error" }.count
        let allOk = errors == 0

        let report = DoctorReport(
            ok: allOk,
            version: "0.1.0",
            checks: checks,
            summary: DoctorSummary(
                total: checks.count,
                passed: passed,
                warnings: warnings,
                errors: errors
            ),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        return jsonResponse(status: allOk ? .ok : .serviceUnavailable, body: encode(report))
    }

    // MARK: - Federation command dispatch

    func handleFederationCommand(_ command: FederationCommandPayload) -> FederationResponsePayload {
        let components = URLComponents(string: "http://localhost\(command.path)")
        let path = components?.path ?? command.path
        let method = httpMethod(from: command.method)

        if path != "/v1/health" {
            var headerBag = HTTPHeaders()
            for (key, value) in command.headers {
                headerBag.add(name: key, value: value)
            }
            if let auth = checkAuthorization(headers: headerBag) {
                return federationResponse(id: command.id, result: auth)
            }
        }

        let result: HTTPResult
        switch (method, path) {
        case (.GET, "/v1/health"):
            result = health()
        case (.GET, "/v1/config"):
            result = config()
        case (.GET, "/v1/poll"):
            let since = components?.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int64.init)
            result = poll(since: since)
        case (.POST, "/v1/send"):
            let body = command.body?.data(using: .utf8) ?? Data()
            result = send(body: body, traceID: command.headers["X-Trace-ID"] ?? command.headers["x-trace-id"])
        case (.GET, "/v1/context"):
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            result = context(adapter: adapter)
        case (.GET, "/v1/messages"):
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limit = min(components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50, 200)
            result = messages(adapter: adapter, limit: limit)
        case (.GET, "/v1/conversations"):
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            let limit = min(components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50, 200)
            result = conversations(adapter: adapter, limit: limit)
        case (.GET, "/v1/axdump"):
            let adapter = components?.queryItems?.first(where: { $0.name == "adapter" })?.value ?? "line"
            result = axdump(adapter: adapter)
        case (.GET, "/v1/doctor"):
            result = doctor()
        default:
            let notFound = ErrorPayload(code: "not_found", message: "not found", retriable: false, failedStep: "routing", details: nil)
            result = jsonResponse(status: .notFound, body: encode(APIResponse<String>(ok: false, result: nil, error: notFound)))
        }

        return federationResponse(id: command.id, result: result)
    }

    private func checkLINEWindowAccessible() -> DoctorCheck {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "LINE is not running",
                details: nil
            )
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "LINE window not accessible (bring it to foreground)",
                details: "Qt limitation: AX tree unavailable in background"
            )
        }

        guard let _ = AXQuery.copyFrameAttribute(window) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Could not retrieve window frame",
                details: nil
            )
        }

        let nodes = AXQuery.descendants(of: window)
        let hasInput = nodes.contains { $0.role == "AXTextArea" }

        if hasInput {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "LINE window is accessible (input field present)",
                details: "Node count: \(nodes.count)"
            )
        } else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "LINE window is accessible (sidebar view)",
                details: "Node count: \(nodes.count), open a chat to see the input field"
            )
        }
    }

    private func appSignatureCheck() -> DoctorCheck {
        let appPath = Bundle.main.bundlePath
        guard let output = runProcess(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", appPath]) else {
            return DoctorCheck(
                name: "app_signature",
                status: "warning",
                message: "Could not verify app signature",
                details: "codesign output unavailable"
            )
        }

        let authorities = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let prefix = "Authority="
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }

        let isTrusted = authorities.contains("ClawGate Dev")
        if isTrusted {
            return DoctorCheck(
                name: "app_signature",
                status: "ok",
                message: "App signature authority is ClawGate Dev",
                details: nil
            )
        }

        let detail = authorities.first.map { "Current authority: \($0)" } ?? "No authority found in signature"
        return DoctorCheck(
            name: "app_signature",
            status: "error",
            message: "App is not signed with ClawGate Dev",
            details: detail
        )
    }

    private func runProcess(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = [out, err].joined(separator: "\n")
        return merged.isEmpty ? nil : merged
    }

    private func encode<T: Codable>(_ value: T) -> Data {
        (try? jsonEncoder.encode(value)) ?? Data("{\"ok\":false}".utf8)
    }

    private func jsonResponse(status: HTTPResponseStatus, body: Data, traceID: String? = nil) -> HTTPResult {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.count)")
        if let traceID, !traceID.isEmpty {
            headers.add(name: "X-Trace-ID", value: traceID)
        }
        return HTTPResult(status: status, headers: headers, body: body)
    }

    private func federationResponse(id: String, result: HTTPResult) -> FederationResponsePayload {
        var headers: [String: String] = [:]
        for header in result.headers {
            headers[header.name] = header.value
        }
        let body = String(data: result.body, encoding: .utf8) ?? "{}"
        return FederationResponsePayload(
            id: id,
            status: Int(result.status.code),
            headers: headers,
            body: body
        )
    }

    private func httpMethod(from value: String) -> HTTPMethod {
        switch value.uppercased() {
        case "POST": return .POST
        case "PUT": return .PUT
        case "DELETE": return .DELETE
        case "PATCH": return .PATCH
        case "HEAD": return .HEAD
        case "OPTIONS": return .OPTIONS
        default: return .GET
        }
    }

    private func rejectLineOnClient(adapterName: String) -> HTTPResult? {
        let cfg = configStore.load()
        guard cfg.nodeRole == .client, adapterName == "line" else { return nil }
        let payload = ErrorPayload(
            code: "line_disabled_on_client",
            message: "line adapter is disabled on client node role",
            retriable: false,
            failedStep: "role_gate",
            details: "nodeRole=client"
        )
        return jsonResponse(
            status: .forbidden,
            body: encode(APIResponse<String>(ok: false, result: nil, error: payload))
        )
    }

    private func normalizedTraceID(_ traceID: String?) -> String {
        let raw = (traceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        return "trace-\(UUID().uuidString)"
    }

    private func writeOps(
        level: String,
        event: String,
        traceID: String,
        stage: String,
        action: String,
        status: String,
        errorCode: String?,
        errorMessage: String?,
        latencyMs: Int?
    ) {
        let role = configStore.load().nodeRole.rawValue
        let parts: [String] = [
            "trace_id=\(traceID)",
            "stage=\(stage)",
            "action=\(action)",
            "status=\(status)",
            latencyMs.map { "latency_ms=\($0)" } ?? nil,
            errorCode.map { "error_code=\($0)" } ?? nil,
            errorMessage.map { "error_message=\($0)" } ?? nil,
        ].compactMap { $0 }
        opsLogStore.append(
            level: level,
            event: event,
            role: role,
            script: "clawgate.app",
            message: parts.joined(separator: " ")
        )
    }

    private func recentTmuxInboundEvents(limit: Int) -> [BridgeEvent] {
        let all = eventBus.poll(since: nil).events
        let relevant = all.filter { event in
            guard event.adapter == "tmux", event.type == "inbound_message" else { return false }
            return !(event.payload["text"] ?? "").isEmpty
        }
        return Array(relevant.suffix(max(1, min(limit, 200))))
    }

    private func buildTmuxMessageListFromEventBus(limit: Int) -> MessageList {
        let events = recentTmuxInboundEvents(limit: limit)
        let messages = events.enumerated().map { index, event in
            VisibleMessage(
                text: event.payload["text"] ?? "",
                sender: "other",
                yOrder: index
            )
        }
        let conversation = events.last?.payload["project"] ?? events.last?.payload["conversation"]
        return MessageList(
            adapter: "tmux",
            conversationName: conversation,
            messages: messages,
            messageCount: messages.count,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func buildTmuxConversationListFromEventBus(limit: Int) -> ConversationList {
        let events = recentTmuxInboundEvents(limit: limit * 4)
        var orderedProjects: [String] = []
        var seen = Set<String>()
        for event in events.reversed() {
            let project = (event.payload["project"] ?? event.payload["conversation"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !project.isEmpty else { continue }
            if !seen.contains(project) {
                seen.insert(project)
                orderedProjects.append(project)
            }
            if orderedProjects.count >= limit { break }
        }
        let entries = orderedProjects.enumerated().map { idx, project in
            ConversationEntry(name: project, yOrder: idx, hasUnread: false)
        }
        return ConversationList(
            adapter: "tmux",
            conversations: entries,
            count: entries.count,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
