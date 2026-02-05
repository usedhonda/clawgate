import Foundation
import NIOHTTP1
import XCTest
@testable import ClawGate

private final class FakeAdapter: AdapterProtocol {
    let name = "line"

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        let result = SendResult(adapter: "line", action: "send_message", messageID: "local-test", timestamp: "2026-02-05T00:00:00Z")
        return (result, [])
    }
}

private final class FailingAdapter: AdapterProtocol {
    let name = "failing"

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        throw BridgeRuntimeError(
            code: "ax_timeout",
            message: "AX query timed out",
            retriable: true,
            failedStep: "scan_ui_tree",
            details: nil
        )
    }
}

final class BridgeCoreTests: XCTestCase {
    func testHealthIsOk() {
        let core = makeCore()
        let response = core.health()
        XCTAssertEqual(response.status, .ok)
    }

    func testSendRejectsInvalidPayload() {
        let core = makeCore()
        let response = core.send(body: Data("{}".utf8))
        XCTAssertEqual(response.status, .badRequest)
    }

    func testAuthValidationWorks() {
        let tokenManager = BridgeTokenManager(keychain: KeychainStore(service: "com.clawgate.test.auth"))
        let token = tokenManager.regenerateToken()

        var headers = HTTPHeaders()
        headers.add(name: "X-Bridge-Token", value: token)

        let core = BridgeCore(
            eventBus: EventBus(),
            tokenManager: tokenManager,
            registry: AdapterRegistry(adapters: [FakeAdapter()]),
            logger: AppLogger(configStore: ConfigStore(defaults: UserDefaults(suiteName: "clawgate.tests")!))
        )

        XCTAssertTrue(core.isAuthorized(headers: headers))
    }

    // MARK: - Error code tests

    func testSendReturnsAdapterNotFound() {
        let core = makeCore()
        let json = """
        {"adapter":"slack","action":"send_message","payload":{"conversation_hint":"test","text":"hello","enter_to_send":true}}
        """
        let response = core.send(body: Data(json.utf8))
        XCTAssertEqual(response.status, .badRequest)
        assertErrorCode(response, expected: "adapter_not_found")
    }

    func testSendReturnsUnsupportedAction() {
        let core = makeCore()
        let json = """
        {"adapter":"line","action":"delete_message","payload":{"conversation_hint":"test","text":"hello","enter_to_send":true}}
        """
        let response = core.send(body: Data(json.utf8))
        XCTAssertEqual(response.status, .badRequest)
        assertErrorCode(response, expected: "unsupported_action")
    }

    func testSendReturnsInvalidConversationHint() {
        let core = makeCore()
        let json = """
        {"adapter":"line","action":"send_message","payload":{"conversation_hint":"  ","text":"hello","enter_to_send":true}}
        """
        let response = core.send(body: Data(json.utf8))
        XCTAssertEqual(response.status, .badRequest)
        assertErrorCode(response, expected: "invalid_conversation_hint")
    }

    func testSendReturnsInvalidText() {
        let core = makeCore()
        let json = """
        {"adapter":"line","action":"send_message","payload":{"conversation_hint":"test","text":" ","enter_to_send":true}}
        """
        let response = core.send(body: Data(json.utf8))
        XCTAssertEqual(response.status, .badRequest)
        assertErrorCode(response, expected: "invalid_text")
    }

    func testSendReturnsInvalidJson() {
        let core = makeCore()
        let response = core.send(body: Data("not json at all".utf8))
        XCTAssertEqual(response.status, .badRequest)
        assertErrorCode(response, expected: "invalid_json")
    }

    func testSendReturnsRetriableError() {
        let core = makeCoreWithFailingAdapter()
        let json = """
        {"adapter":"failing","action":"send_message","payload":{"conversation_hint":"test","text":"hello","enter_to_send":true}}
        """
        let response = core.send(body: Data(json.utf8))
        XCTAssertEqual(response.status, .serviceUnavailable)
    }

    // MARK: - Token tests

    func testTokenRegenerationInvalidatesOldToken() {
        let tokenManager = BridgeTokenManager(keychain: KeychainStore(service: "com.clawgate.test.regen"))
        let oldToken = tokenManager.currentToken()
        let newToken = tokenManager.regenerateToken()

        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertFalse(tokenManager.validate(oldToken))
        XCTAssertTrue(tokenManager.validate(newToken))
    }

    func testTokenValidateRejectsNil() {
        let tokenManager = BridgeTokenManager(keychain: KeychainStore(service: "com.clawgate.test.nil"))
        XCTAssertFalse(tokenManager.validate(nil))
    }

    func testUnauthorizedRequestIsRejected() {
        let core = makeCore()
        var headers = HTTPHeaders()
        headers.add(name: "X-Bridge-Token", value: "invalid-token-value")
        XCTAssertFalse(core.isAuthorized(headers: headers))
    }

    func testMissingTokenIsRejected() {
        let core = makeCore()
        let headers = HTTPHeaders()
        XCTAssertFalse(core.isAuthorized(headers: headers))
    }

    // MARK: - Helpers

    private func makeCore() -> BridgeCore {
        let defaults = UserDefaults(suiteName: "clawgate.tests.core")!
        defaults.removePersistentDomain(forName: "clawgate.tests.core")
        let cfg = ConfigStore(defaults: defaults)
        let tokenManager = BridgeTokenManager(keychain: KeychainStore(service: "com.clawgate.test.core"))

        return BridgeCore(
            eventBus: EventBus(),
            tokenManager: tokenManager,
            registry: AdapterRegistry(adapters: [FakeAdapter()]),
            logger: AppLogger(configStore: cfg)
        )
    }

    private func makeCoreWithFailingAdapter() -> BridgeCore {
        let defaults = UserDefaults(suiteName: "clawgate.tests.failing")!
        defaults.removePersistentDomain(forName: "clawgate.tests.failing")
        let cfg = ConfigStore(defaults: defaults)
        let tokenManager = BridgeTokenManager(keychain: KeychainStore(service: "com.clawgate.test.failing"))

        return BridgeCore(
            eventBus: EventBus(),
            tokenManager: tokenManager,
            registry: AdapterRegistry(adapters: [FakeAdapter(), FailingAdapter()]),
            logger: AppLogger(configStore: cfg)
        )
    }

    private func assertErrorCode(_ response: HTTPResult, expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let parsed = try? JSONDecoder().decode(APIResponse<SendResult>.self, from: response.body) else {
            XCTFail("Failed to decode response body", file: file, line: line)
            return
        }
        XCTAssertFalse(parsed.ok, file: file, line: line)
        XCTAssertEqual(parsed.error?.code, expected, file: file, line: line)
    }
}
