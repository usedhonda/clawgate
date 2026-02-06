import AppKit
import Foundation
import NIOHTTP1

final class BridgeCore {
    let eventBus: EventBus

    private let tokenManager: BridgeTokenManager
    private let pairingManager: PairingCodeManager
    private let registry: AdapterRegistry
    private let logger: AppLogger
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(eventBus: EventBus, tokenManager: BridgeTokenManager, pairingManager: PairingCodeManager, registry: AdapterRegistry, logger: AppLogger) {
        self.eventBus = eventBus
        self.tokenManager = tokenManager
        self.pairingManager = pairingManager
        self.registry = registry
        self.logger = logger
        self.jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
    }

    func isAuthorized(headers: HTTPHeaders) -> Bool {
        tokenManager.validate(headers.first(name: "X-Bridge-Token"))
    }

    func health() -> HTTPResult {
        let body = encode(HealthResponse(ok: true, version: "0.1.0"))
        return jsonResponse(status: .ok, body: body)
    }

    func send(body: Data) -> HTTPResult {
        do {
            let request = try jsonDecoder.decode(SendRequest.self, from: body)
            guard request.action == "send_message" else {
                throw BridgeRuntimeError(
                    code: "unsupported_action",
                    message: "actionはsend_messageのみ対応です",
                    retriable: false,
                    failedStep: "validate_request",
                    details: request.action
                )
            }
            guard !request.payload.conversationHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeRuntimeError(
                    code: "invalid_conversation_hint",
                    message: "conversation_hintは必須です",
                    retriable: false,
                    failedStep: "validate_request",
                    details: nil
                )
            }
            guard !request.payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeRuntimeError(
                    code: "invalid_text",
                    message: "textは必須です",
                    retriable: false,
                    failedStep: "validate_request",
                    details: nil
                )
            }

            guard let adapter = registry.adapter(for: request.adapter) else {
                throw BridgeRuntimeError(
                    code: "adapter_not_found",
                    message: "指定adapterは未登録です",
                    retriable: false,
                    failedStep: "resolve_adapter",
                    details: request.adapter
                )
            }

            let (result, steps) = try adapter.sendMessage(payload: request.payload)
            logger.log(.info, "send_message completed with \(steps.count) steps")

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
                message: "リクエストJSONを解釈できません",
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
                    message: "指定adapterは未登録です",
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
                message: "コンテキスト取得中にエラーが発生しました",
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
                    message: "指定adapterは未登録です",
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
                message: "メッセージ取得中にエラーが発生しました",
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
                    message: "指定adapterは未登録です",
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
                message: "会話リスト取得中にエラーが発生しました",
                retriable: false,
                failedStep: "get_conversations",
                details: String(describing: error)
            )
            return jsonResponse(status: .internalServerError, body: encode(APIResponse<ConversationList>(ok: false, result: nil, error: payload)))
        }
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
                    message: "指定adapterは未登録です",
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
                message: "AXDumpの取得に失敗しました",
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
            message: axTrusted ? "Accessibility権限が許可されています" : "Accessibility権限が未付与です",
            details: axTrusted ? nil : "System Settings > Privacy & Security > Accessibility"
        ))

        // Check 2: Token configured
        let hasToken = tokenManager.hasValidToken()
        checks.append(DoctorCheck(
            name: "token_configured",
            status: hasToken ? "ok" : "warning",
            message: hasToken ? "認証トークンが設定されています" : "認証トークンが未設定です",
            details: hasToken ? nil : "初回起動時に自動生成されます"
        ))

        // Check 3: LINE running
        let lineRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first != nil
        checks.append(DoctorCheck(
            name: "line_running",
            status: lineRunning ? "ok" : "warning",
            message: lineRunning ? "LINEが起動しています" : "LINEが起動していません",
            details: lineRunning ? nil : "LINEを起動してください"
        ))

        // Check 4: LINE window accessible (only if LINE is running and AX is trusted)
        if axTrusted && lineRunning {
            let windowCheck = checkLINEWindowAccessible()
            checks.append(windowCheck)
        } else {
            checks.append(DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "LINEウィンドウのチェックをスキップしました",
                details: !axTrusted ? "Accessibility権限が必要です" : "LINEが起動していません"
            ))
        }

        // Check 5: Port 8765 (we're already listening, so this is informational)
        checks.append(DoctorCheck(
            name: "server_port",
            status: "ok",
            message: "サーバーがポート8765でリッスン中です",
            details: "127.0.0.1:8765"
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
                message: "LINEが起動していません",
                details: nil
            )
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "LINEウィンドウが取得できません（前面に表示してください）",
                details: "Qt制約: バックグラウンドではAXツリーが取得できません"
            )
        }

        guard let _ = AXQuery.copyFrameAttribute(window) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "ウィンドウフレーム情報が取得できません",
                details: nil
            )
        }

        let nodes = AXQuery.descendants(of: window)
        let hasInput = nodes.contains { $0.role == "AXTextArea" }

        if hasInput {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "LINEウィンドウにアクセス可能です（入力欄あり）",
                details: "ノード数: \(nodes.count)"
            )
        } else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "LINEウィンドウにアクセス可能です（サイドバー表示中）",
                details: "ノード数: \(nodes.count)、チャット画面を開くと入力欄が表示されます"
            )
        }
    }

    // MARK: - Pairing

    func pair(body: Data, headers: HTTPHeaders) -> HTTPResult {
        // Reject browser-origin requests (CSRF protection)
        if let origin = headers.first(name: "Origin"), !origin.isEmpty {
            let payload = ErrorPayload(
                code: "browser_origin_rejected",
                message: "ブラウザからのリクエストは拒否されます",
                retriable: false,
                failedStep: "origin_check",
                details: "Origin header detected: \(origin)"
            )
            return jsonResponse(
                status: .forbidden,
                body: encode(APIResponse<PairResult>(ok: false, result: nil, error: payload))
            )
        }

        do {
            let request = try jsonDecoder.decode(PairRequest.self, from: body)

            guard pairingManager.validateAndConsume(request.code) else {
                let payload = ErrorPayload(
                    code: "invalid_pairing_code",
                    message: "ペアリングコードが無効または期限切れです",
                    retriable: true,
                    failedStep: "validate_code",
                    details: nil
                )
                return jsonResponse(
                    status: .unauthorized,
                    body: encode(APIResponse<PairResult>(ok: false, result: nil, error: payload))
                )
            }

            // Generate new token for this pairing
            let token = tokenManager.regenerateToken()
            logger.log(.info, "Pairing successful for client: \(request.clientName ?? "unknown")")

            let result = PairResult(token: token, expiresAt: nil)
            return jsonResponse(status: .ok, body: encode(APIResponse(ok: true, result: result, error: nil)))

        } catch {
            let payload = ErrorPayload(
                code: "invalid_json",
                message: "リクエストJSONを解釈できません",
                retriable: false,
                failedStep: "decode_request",
                details: String(describing: error)
            )
            return jsonResponse(
                status: .badRequest,
                body: encode(APIResponse<PairResult>(ok: false, result: nil, error: payload))
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
