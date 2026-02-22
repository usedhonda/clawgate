import AppKit
import Foundation
import NIOHTTP1

final class BridgeCore {
    let eventBus: EventBus
    let statsCollector: StatsCollector

    /// Set by main.swift when running as federation server
    var federationServer: FederationServer?

    /// Set by main.swift to enable /v1/debug/line-dedup endpoint
    var lineInboundWatcher: LINEInboundWatcher?

    private let registry: AdapterRegistry
    private let logger: AppLogger
    private let opsLogStore: OpsLogStore
    private let configStore: ConfigStore
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private let autonomousStatusLock = NSLock()
    private var reportedAutonomousStalledTraceIDs: Set<String> = []
    private let autonomousStallThresholdSeconds: TimeInterval = 120
    private var typingBusyStreakCount = 0

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

    func openclawInfo() -> HTTPResult {
        let configPath = NSString("~/.openclaw/openclaw.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String, !token.isEmpty else {
            let payload = ErrorPayload(
                code: "openclaw_not_configured",
                message: "OpenClaw config not found",
                retriable: false,
                failedStep: "read_openclaw_config",
                details: nil
            )
            return jsonResponse(status: .notFound, body: encode(APIResponse<String>(ok: false, result: nil, error: payload)))
        }
        let port = gateway["port"] as? Int ?? 18789
        let host = localTailscaleHostname() ?? "unknown"

        let result: [String: Any] = ["ok": true, "host": host, "token": token, "port": port]
        guard let body = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]) else {
            let payload = ErrorPayload(
                code: "encode_failed",
                message: "Failed to encode response",
                retriable: false,
                failedStep: "encode_openclaw_info",
                details: nil
            )
            return jsonResponse(status: .internalServerError, body: encode(APIResponse<String>(ok: false, result: nil, error: payload)))
        }
        return jsonResponse(status: .ok, body: body)
    }

    private func localTailscaleHostname() -> String? {
        let paths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let cli = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        guard let output = runProcess(executable: cli, arguments: ["status", "--json"]) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backendState = json["BackendState"] as? String,
              backendState == "Running",
              let selfInfo = json["Self"] as? [String: Any],
              let dnsName = selfInfo["DNSName"] as? String else {
            return nil
        }
        return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
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

    func tmuxSessionMode(sessionType: String, project: String) -> HTTPResult {
        let normalizedType = sessionType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedType == "claude_code" || normalizedType == "codex" else {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_session_type",
                            message: "session_type must be claude_code or codex",
                            retriable: false,
                            failedStep: "validate_request",
                            details: normalizedType
                        )
                    )
                )
            )
        }

        let normalizedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProject.isEmpty else {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_project",
                            message: "project is required",
                            retriable: false,
                            failedStep: "validate_request",
                            details: nil
                        )
                    )
                )
            )
        }

        let cfg = configStore.load()
        let key = AppConfig.modeKey(sessionType: normalizedType, project: normalizedProject)
        let configuredMode = cfg.tmuxSessionModes[key]
        let result = TmuxSessionModeResult(
            sessionType: normalizedType,
            project: normalizedProject,
            mode: configuredMode ?? "ignore",
            source: configuredMode == nil ? "default_ignore" : "config"
        )
        return jsonResponse(status: .ok, body: encode(APIResponse(ok: true, result: result, error: nil)))
    }

    func setTmuxSessionMode(body: Data) -> HTTPResult {
        let request: TmuxSessionModeUpdateRequest
        do {
            request = try jsonDecoder.decode(TmuxSessionModeUpdateRequest.self, from: body)
        } catch {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeUpdateResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_json",
                            message: "Could not parse request JSON",
                            retriable: false,
                            failedStep: "decode_request",
                            details: String(describing: error)
                        )
                    )
                )
            )
        }

        let normalizedType = request.sessionType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedType == "claude_code" || normalizedType == "codex" else {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeUpdateResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_session_type",
                            message: "session_type must be claude_code or codex",
                            retriable: false,
                            failedStep: "validate_request",
                            details: normalizedType
                        )
                    )
                )
            )
        }

        let normalizedProject = request.project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProject.isEmpty else {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeUpdateResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_project",
                            message: "project is required",
                            retriable: false,
                            failedStep: "validate_request",
                            details: nil
                        )
                    )
                )
            )
        }

        let normalizedMode = request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowedModes = ["ignore", "observe", "auto", "autonomous"]
        guard allowedModes.contains(normalizedMode) else {
            return jsonResponse(
                status: .badRequest,
                body: encode(
                    APIResponse<TmuxSessionModeUpdateResult>(
                        ok: false,
                        result: nil,
                        error: ErrorPayload(
                            code: "invalid_mode",
                            message: "mode must be one of ignore|observe|auto|autonomous",
                            retriable: false,
                            failedStep: "validate_request",
                            details: normalizedMode
                        )
                    )
                )
            )
        }

        var cfg = configStore.load()
        let key = AppConfig.modeKey(sessionType: normalizedType, project: normalizedProject)
        if normalizedMode == "ignore" {
            cfg.tmuxSessionModes.removeValue(forKey: key)
        } else {
            cfg.tmuxSessionModes[key] = normalizedMode
        }
        configStore.save(cfg)

        eventBus.append(
            type: "tmux.session_mode_updated",
            adapter: "tmux",
            payload: [
                "session_type": normalizedType,
                "project": normalizedProject,
                "mode": normalizedMode,
            ]
        )

        let result = TmuxSessionModeUpdateResult(
            sessionType: normalizedType,
            project: normalizedProject,
            mode: normalizedMode,
            updated: true
        )
        return jsonResponse(status: .ok, body: encode(APIResponse(ok: true, result: result, error: nil)))
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

            // Pre-flight: if tmux + federation connected + no local authoritative mode,
            // skip TmuxAdapter entirely and forward to federation client directly.
            // This avoids the throw-catch round-trip for sessions that live on the remote host.
            if request.adapter == "tmux",
               let fedServer = federationServer, fedServer.hasConnectedClient() {
                let project = request.payload.conversationHint
                let modes = configStore.load().tmuxSessionModes
                // Check both session types — a project may be CC-only, Codex-only, or both
                let ccMode = modes[AppConfig.modeKey(sessionType: "claude_code", project: project)]
                let codexMode = modes[AppConfig.modeKey(sessionType: "codex", project: project)]
                let hasLocalAuthoritative = [ccMode, codexMode].contains(where: { $0 == "autonomous" || $0 == "auto" })
                if !hasLocalAuthoritative {
                    do {
                        let fedResult = try forwardToFederationClient(body: body, traceID: trace, fedServer: fedServer)
                        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                        writeOps(level: "info", event: "federation_preflight_forward_ok", traceID: trace, stage: "federation", action: "forward_send", status: "ok", errorCode: nil, errorMessage: nil, latencyMs: latencyMs)
                        return fedResult
                    } catch {
                        logger.log(.warning, "Pre-flight federation forward failed: \(error), falling through to local adapter")
                    }
                }
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
            typingBusyStreakCount = 0
            statsCollector.increment("sent", adapter: request.adapter)
            eventBus.append(type: "outbound_message", adapter: request.adapter, payload: [
                "text": String(request.payload.text.prefix(100)),
                "conversation": request.payload.conversationHint,
                "trace_id": trace,
            ])

            let content = APIResponse(ok: true, result: result, error: nil)
            return jsonResponse(status: .ok, body: encode(content), traceID: trace)
        } catch let err as BridgeRuntimeError {
            // Federation fallback: if tmux session_not_found and we have a federation server with connected clients
            if err.code == "session_not_found" || err.code == "tmux_target_missing" {
                if let fedServer = federationServer, fedServer.hasConnectedClient() {
                    do {
                        let fedResult = try forwardToFederationClient(body: body, traceID: requestTrace, fedServer: fedServer)
                        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                        writeOps(level: "info", event: "federation_forward_ok", traceID: requestTrace, stage: "federation", action: "forward_send", status: "ok", errorCode: nil, errorMessage: nil, latencyMs: latencyMs)
                        return fedResult
                    } catch {
                        logger.log(.warning, "Federation forward failed: \(error)")
                        // Fall through to return original error
                    }
                }
            }

            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            writeOps(level: "error", event: "send_failed", traceID: requestTrace, stage: "bridge_server", action: "send_message", status: "failed", errorCode: err.code, errorMessage: err.message, latencyMs: latencyMs)
            if err.code == "session_typing_busy" {
                typingBusyStreakCount += 1
                logger.log(.debug, "BridgeCore: typing_busy streak=\(typingBusyStreakCount)")
            } else {
                typingBusyStreakCount = 0
            }
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

    func handleLineDedupDebug() -> HTTPResult {
        let snapshot = lineInboundWatcher?.dedupSnapshot() ?? LineInboundDedupSnapshot(
            seenConversations: [:],
            seenLinesTotal: 0,
            lastFingerprintHead: "",
            lastAcceptedAt: "never",
            fingerprintWindowSec: 0,
            pipelineHistory: [],
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        return jsonResponse(status: .ok, body: encode(snapshot))
    }

    func debugInject(body: Data) -> HTTPResult {
        struct DebugInjectRequest: Codable {
            let type: String?
            let adapter: String?
            let text: String
            let conversation: String?
            let extra: [String: String]?
        }
        do {
            let req = try jsonDecoder.decode(DebugInjectRequest.self, from: body)
            let eventType = req.type ?? "inbound_message"
            let adapter = req.adapter ?? "line"
            var payload: [String: String] = ["text": req.text]
            if let conv = req.conversation {
                payload["conversation"] = conv
            }
            if let extra = req.extra {
                for (key, value) in extra where payload[key] == nil {
                    payload[key] = value
                }
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

    func messages(adapter adapterName: String, limit: Int, conversation: String? = nil) -> HTTPResult {
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
            var result: MessageList
            if adapterName == "tmux",
               let conversation = conversation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !conversation.isEmpty,
               let tmux = adapter as? TmuxAdapter
            {
                result = try tmux.getMessages(limit: limit, forProject: conversation)
            } else {
                result = try adapter.getMessages(limit: limit)
            }
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

    func autonomousStatus() -> HTTPResult {
        let snapshot = autonomousStatusSnapshot()
        let role = configStore.load().nodeRole.rawValue
        opsLogStore.append(
            level: "info",
            event: "autonomous.status_snapshot",
            role: role,
            script: "clawgate.app",
            message: "project=\(snapshot.targetProject.isEmpty ? "-" : snapshot.targetProject) mode=\(snapshot.mode) review_done=\(snapshot.reviewDone) reason=\(snapshot.lastSuppressionReason)"
        )
        return jsonResponse(
            status: .ok,
            body: encode(APIResponse(ok: true, result: snapshot, error: nil))
        )
    }

    func autonomousStatusSnapshot() -> AutonomousStatusResult {
        let config = configStore.load()
        let localLineSendExpected = config.nodeRole != .client && config.lineEnabled
        let candidates = config.tmuxSessionModes
            .filter { (key, mode) in
                key.hasPrefix("codex:") && (mode == "autonomous" || mode == "auto")
            }
            .sorted { $0.key < $1.key }

        guard let target = candidates.first else {
            return AutonomousStatusResult(
                targetProject: "",
                mode: "ignore",
                reviewDone: false,
                lastCompletionAt: nil,
                lastTaskSentAt: nil,
                lastLineSendOKAt: nil,
                lastSuppressionReason: "no_target"
            )
        }

        let project = String(target.key.dropFirst("codex:".count))
        let mode = target.value
        let entries = opsLogStore.recent(limit: 400)

        var lastCompletionAt: String?
        var lastCompletionDate: Date?
        var lastCompletionTraceID: String?
        var lastTaskSentAt: String?
        var lastLineSendOKAt: String?

        for entry in entries {
            if lastCompletionAt == nil, entry.event == "tmux.completion" {
                let kv = parseKeyValueMessage(entry.message)
                if kv["project"] == project {
                    lastCompletionAt = entry.ts
                    lastCompletionDate = entry.date
                    lastCompletionTraceID = kv["trace_id"]
                }
            }
            if lastTaskSentAt == nil, entry.event == "tmux.forward" {
                let kv = parseKeyValueMessage(entry.message)
                if kv["project"] == project {
                    lastTaskSentAt = entry.ts
                }
            }
            if lastCompletionAt != nil && lastTaskSentAt != nil {
                break
            }
        }

        if let completionDate = lastCompletionDate {
            for entry in entries where entry.event == "line_send_ok" {
                if let traceID = lastCompletionTraceID, !traceID.isEmpty {
                    if entry.message.contains("trace_id=\(traceID)") {
                        logger.log(.debug, "BridgeCore: line_send_ok matched trace_id=\(traceID)")
                        lastLineSendOKAt = entry.ts
                        break
                    }
                    // Proximity fallback: accept line_send_ok within 5 minutes of completion
                    // even if trace_id doesn't match (e.g. gateway-side trace vs bridge-side trace)
                    let proximityWindow: TimeInterval = 300
                    if entry.date >= completionDate && entry.date.timeIntervalSince(completionDate) <= proximityWindow {
                        logger.log(.debug, "BridgeCore: line_send_ok fallback by timestamp (trace_id=\(traceID))")
                        lastLineSendOKAt = entry.ts
                        break
                    }
                } else if entry.date >= completionDate {
                    // Fallback: when trace_id is unavailable, use the latest line_send_ok
                    // after the most recent completion timestamp.
                    lastLineSendOKAt = entry.ts
                    break
                }
            }
            if lastLineSendOKAt == nil {
                logger.log(.debug, "BridgeCore: line_send_ok NOT found for trace_id=\(lastCompletionTraceID ?? "nil") -> stall risk")
            }
        }

        // Find the most recent send_failed error code after the last completion
        var lastSendFailedErrorCode: String? = nil
        if let completionDate = lastCompletionDate {
            for entry in entries where entry.event == "send_failed" {
                if entry.date >= completionDate {
                    let kv = parseKeyValueMessage(entry.message)
                    lastSendFailedErrorCode = kv["error_code"]
                    break
                }
            }
        }

        var suppressionReason = "none"
        var reviewDone = false
        if lastCompletionAt != nil && lastLineSendOKAt == nil {
            if !localLineSendExpected {
                suppressionReason = "line_send_not_local"
            } else if let completionDate = lastCompletionDate {
                let age = Date().timeIntervalSince(completionDate)
                if age >= autonomousStallThresholdSeconds {
                    if lastSendFailedErrorCode == "session_typing_busy" {
                        suppressionReason = "stalled_typing_busy"
                        // reviewDone remains false — typing_busy is transient, don't suppress notifications
                    } else {
                        suppressionReason = "stalled_no_line_send"
                        reviewDone = true
                        recordAutonomousStalledIfNeeded(project: project, traceID: lastCompletionTraceID, ageSeconds: Int(age))
                    }
                    logger.log(.debug, "BridgeCore: autonomous_stall_check age_s=\(Int(age)) threshold=\(Int(autonomousStallThresholdSeconds)) send_fail_code=\(lastSendFailedErrorCode ?? "none") -> \(suppressionReason)")
                } else {
                    suppressionReason = "pending_line_send"
                }
            } else {
                suppressionReason = "pending_line_send"
            }
        }

        return AutonomousStatusResult(
            targetProject: project,
            mode: mode,
            reviewDone: reviewDone,
            lastCompletionAt: lastCompletionAt,
            lastTaskSentAt: lastTaskSentAt,
            lastLineSendOKAt: lastLineSendOKAt,
            lastSuppressionReason: suppressionReason
        )
    }

    func poll(since: Int64?) -> HTTPResult {
        let data = eventBus.poll(since: since)

        let deliveredTmux = data.events.filter { event in
            guard event.adapter == "tmux", event.type == "inbound_message" else { return false }
            let source = event.payload["source"] ?? ""
            return source == "completion" || source == "question"
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

        // Check 3: Messenger (LINE adapter) running
        let lineRunning = lineEnabled && (NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first != nil)
        checks.append(DoctorCheck(
            name: "line_running",
            status: lineEnabled ? (lineRunning ? "ok" : "warning") : "ok",
            message: lineEnabled ? (lineRunning ? "Messenger app (LINE) is running" : "Messenger app (LINE) is not running") : "Messenger checks disabled (client role or messenger disabled)",
            details: lineEnabled ? (lineRunning ? nil : "Please launch LINE") : "Enable Messenger (LINE) in Settings when needed"
        ))

        // Check 4: LINE window accessible (only if LINE is running and AX is trusted)
        if lineEnabled && axTrusted && lineRunning {
            let windowCheck = checkLINEWindowAccessible()
            checks.append(windowCheck)
        } else {
            checks.append(DoctorCheck(
                name: "line_window_accessible",
                status: lineEnabled ? "warning" : "ok",
                message: "Messenger window check skipped (LINE adapter)",
                details: lineEnabled ? (!axTrusted ? "Accessibility permission required" : "LINE app is not running") : "nodeRole=client or lineEnabled=false"
            ))
        }

        // Check 5: Port 8765 (we're already listening, so this is informational)
        let portDetails = cfg.remoteAccessEnabled ? "0.0.0.0:8765 (remote access)" : "127.0.0.1:8765"
        let federationSuffix = (cfg.nodeRole == .server && cfg.federationEnabled) ? " + ws:/federation" : ""
        checks.append(DoctorCheck(
            name: "server_port",
            status: "ok",
            message: "Server is listening on port 8765",
            details: portDetails + federationSuffix
        ))

        // Check 6: Screen Recording permission (for Vision OCR)
        let screenOk = CGPreflightScreenCaptureAccess()
        checks.append(DoctorCheck(
            name: "screen_recording_permission",
            status: screenOk ? "ok" : "warning",
            message: screenOk ? "Screen recording permission granted" : "Screen recording not granted (OCR disabled)",
            details: screenOk ? nil : "System Settings > Privacy > Screen Recording"
        ))

        // Check 7: Federation status
        if cfg.nodeRole == .server && cfg.federationEnabled {
            let clientCount = federationServer?.clientCount() ?? 0
            checks.append(DoctorCheck(
                name: "federation",
                status: "ok",
                message: "Federation server active (\(clientCount) client\(clientCount == 1 ? "" : "s") connected)",
                details: "Accepting connections on /federation"
            ))
        } else if cfg.nodeRole == .client && cfg.federationEnabled {
            checks.append(DoctorCheck(
                name: "federation",
                status: "ok",
                message: "Federation client enabled",
                details: "Connecting to \(cfg.federationURL)"
            ))
        }

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
        case (.GET, "/v1/tmux/session-mode"):
            let sessionType = components?.queryItems?.first(where: { $0.name == "session_type" })?.value ?? ""
            let project = components?.queryItems?.first(where: { $0.name == "project" })?.value ?? ""
            result = tmuxSessionMode(sessionType: sessionType, project: project)
        case (.PUT, "/v1/tmux/session-mode"):
            let body = command.body?.data(using: .utf8) ?? Data()
            result = setTmuxSessionMode(body: body)
        case (.GET, "/v1/autonomous/status"):
            result = autonomousStatus()
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
        case (.GET, "/v1/openclaw-info"):
            result = openclawInfo()
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
                message: "Messenger app (LINE) is not running",
                details: nil
            )
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Messenger window (LINE) not accessible (bring it to foreground)",
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
                message: "Messenger window (LINE) is accessible (input field present)",
                details: "Node count: \(nodes.count)"
            )
        } else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "Messenger window (LINE) is accessible (sidebar view)",
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

    /// Forward a /v1/send request to a federation client when local tmux session is not found.
    /// Uses a 15-second timeout to prevent indefinite blocking when the client disconnects.
    private func forwardToFederationClient(body: Data, traceID: String, fedServer: FederationServer) throws -> HTTPResult {
        // Parse the request to find the project
        let request = try jsonDecoder.decode(SendRequest.self, from: body)
        let project = request.payload.conversationHint

        let command = FederationCommandPayload(
            id: UUID().uuidString,
            method: "POST",
            path: "/v1/send",
            headers: ["Content-Type": "application/json", "X-Trace-ID": traceID],
            body: String(data: body, encoding: .utf8)
        )

        logger.log(.info, "Forwarding /v1/send to federation client for project=\(project)")

        // Wait synchronously with timeout (we're on BlockingWork.queue, not NIO event loop)
        let semaphore = DispatchSemaphore(value: 0)
        var federationResult: Result<FederationResponsePayload, Error>?

        fedServer.sendCommand(forProject: project, command).whenComplete { result in
            federationResult = result
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + 15)
        guard timeoutResult == .success, let result = federationResult else {
            throw FederationServerError.commandTimeout
        }

        let response = try result.get()

        // Convert federation response back to HTTPResult
        var headers = HTTPHeaders()
        for (key, value) in response.headers {
            headers.add(name: key, value: value)
        }
        let responseBody = Data(response.body.utf8)
        let status = HTTPResponseStatus(statusCode: response.status)
        return HTTPResult(status: status, headers: headers, body: responseBody)
    }

    private func parseKeyValueMessage(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in message.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func recordAutonomousStalledIfNeeded(project: String, traceID: String?, ageSeconds: Int) {
        let normalizedTrace = (traceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dedupKey = normalizedTrace.isEmpty ? "project:\(project)" : normalizedTrace

        autonomousStatusLock.lock()
        if reportedAutonomousStalledTraceIDs.contains(dedupKey) {
            autonomousStatusLock.unlock()
            return
        }
        reportedAutonomousStalledTraceIDs.insert(dedupKey)
        if reportedAutonomousStalledTraceIDs.count > 512 {
            let keep = reportedAutonomousStalledTraceIDs.suffix(256)
            reportedAutonomousStalledTraceIDs = Set(keep)
        }
        autonomousStatusLock.unlock()

        let role = configStore.load().nodeRole.rawValue
        let traceField = normalizedTrace.isEmpty ? "trace_id=unknown" : "trace_id=\(normalizedTrace)"
        opsLogStore.append(
            level: "warning",
            event: "autonomous.stalled",
            role: role,
            script: "clawgate.app",
            message: "project=\(project) \(traceField) age_s=\(ageSeconds) reason=stalled_no_line_send"
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
