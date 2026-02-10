import AppKit
import Foundation
import NIOHTTP1

final class BridgeCore {
    let eventBus: EventBus
    let statsCollector: StatsCollector

    private let registry: AdapterRegistry
    private let logger: AppLogger
    private let configStore: ConfigStore
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(eventBus: EventBus, registry: AdapterRegistry, logger: AppLogger, configStore: ConfigStore, statsCollector: StatsCollector) {
        self.eventBus = eventBus
        self.registry = registry
        self.logger = logger
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
                sessionModes: cfg.tmuxSessionModes
            )
        )
        let body = encode(APIResponse(ok: true, result: result, error: nil))
        return jsonResponse(status: .ok, body: body)
    }

    func send(body: Data) -> HTTPResult {
        do {
            let request = try jsonDecoder.decode(SendRequest.self, from: body)
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

            guard let adapter = registry.adapter(for: request.adapter) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "Specified adapter is not registered",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: request.adapter
                )
            }

            let (result, steps) = try adapter.sendMessage(payload: request.payload)
            logger.log(.info, "send_message completed with \(steps.count) steps")
            statsCollector.increment("sent", adapter: request.adapter)
            eventBus.append(type: "outbound_message", adapter: request.adapter, payload: [
                "text": String(request.payload.text.prefix(100)),
                "conversation": request.payload.conversationHint,
            ])

            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content))
        } catch let err as BridgeRuntimeError {
            return jsonResponse(
                status: err.retriable ? .serviceUnavailable : .badRequest,
                body: encode(APIResponse<SendResult>(ok: false, result: nil, error: err.asPayload()))
            )
        } catch {
            let payload = ErrorPayload(
                code: "invalid_json",
                message: "Could not parse request JSON",
                retriable: false,
                failedStep: "decode_request",
                details: String(describing: error)
            )
            return jsonResponse(status: .badRequest, body: encode(APIResponse<SendResult>(ok: false, result: nil, error: payload)))
        }
    }

    func context(adapter adapterName: String) -> HTTPResult {
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
            let result = try adapter.getMessages(limit: limit)
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
            let result = try adapter.getConversations(limit: limit)
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
        let response = PollResponse(ok: true, events: data.events, nextCursor: data.nextCursor)
        return jsonResponse(status: .ok, body: encode(response))
    }

    func axdump(adapter adapterName: String) -> HTTPResult {
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

        // Check 1: Accessibility permission
        let axTrusted = AXIsProcessTrusted()
        checks.append(DoctorCheck(
            name: "accessibility_permission",
            status: axTrusted ? "ok" : "error",
            message: axTrusted ? "Accessibility permission is granted" : "Accessibility permission is not granted",
            details: axTrusted ? nil : "System Settings > Privacy & Security > Accessibility"
        ))

        // Check 2: LINE running
        let lineRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first != nil
        checks.append(DoctorCheck(
            name: "line_running",
            status: lineRunning ? "ok" : "warning",
            message: lineRunning ? "LINE is running" : "LINE is not running",
            details: lineRunning ? nil : "Please launch LINE"
        ))

        // Check 3: LINE window accessible (only if LINE is running and AX is trusted)
        if axTrusted && lineRunning {
            let windowCheck = checkLINEWindowAccessible()
            checks.append(windowCheck)
        } else {
            checks.append(DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "LINE window check skipped",
                details: !axTrusted ? "Accessibility permission required" : "LINE is not running"
            ))
        }

        // Check 4: Port 8765 (we're already listening, so this is informational)
        checks.append(DoctorCheck(
            name: "server_port",
            status: "ok",
            message: "Server is listening on port 8765",
            details: "127.0.0.1:8765"
        ))

        // Check 5: Screen Recording permission (for Vision OCR)
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

    private func encode<T: Codable>(_ value: T) -> Data {
        (try? jsonEncoder.encode(value)) ?? Data("{\"ok\":false}".utf8)
    }

    private func jsonResponse(status: HTTPResponseStatus, body: Data) -> HTTPResult {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.count)")
        return HTTPResult(status: status, headers: headers, body: body)
    }
}
