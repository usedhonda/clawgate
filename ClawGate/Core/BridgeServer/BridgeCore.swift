import Foundation
import NIOHTTP1

final class BridgeCore {
    let eventBus: EventBus

    private let tokenManager: BridgeTokenManager
    private let registry: AdapterRegistry
    private let logger: AppLogger
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(eventBus: EventBus, tokenManager: BridgeTokenManager, registry: AdapterRegistry, logger: AppLogger) {
        self.eventBus = eventBus
        self.tokenManager = tokenManager
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

    func poll(since: Int64?) -> HTTPResult {
        let data = eventBus.poll(since: since)
        let response = PollResponse(ok: true, events: data.events, nextCursor: data.nextCursor)
        return jsonResponse(status: .ok, body: encode(response))
    }

    func axdump() -> HTTPResult {
        do {
            let dump = try AXDump.dump(bundleIdentifier: "jp.naver.line.mac")
            return jsonResponse(status: .ok, body: encode(dump))
        } catch {
            let payload = ErrorPayload(
                code: "axdump_failed",
                message: "AXDumpの取得に失敗しました",
                retriable: true,
                failedStep: "axdump",
                details: String(describing: error)
            )
            return jsonResponse(status: .serviceUnavailable, body: encode(APIResponse<String>(ok: false, result: nil, error: payload)))
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
