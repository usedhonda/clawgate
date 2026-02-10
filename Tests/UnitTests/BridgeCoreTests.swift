import Foundation
import NIOHTTP1
import XCTest
@testable import ClawGate

private final class FakeAdapter: AdapterProtocol {
    let name = "line"
    let bundleIdentifier = "jp.naver.line.mac"

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        let result = SendResult(adapter: "line", action: "send_message", messageID: "local-test", timestamp: "2026-02-05T00:00:00Z")
        return (result, [])
    }

    func getContext() throws -> ConversationContext {
        ConversationContext(
            adapter: "line",
            conversationName: "TestUser",
            hasInputField: true,
            windowTitle: "TestUser",
            timestamp: "2026-02-06T00:00:00Z"
        )
    }

    func getMessages(limit: Int) throws -> MessageList {
        MessageList(
            adapter: "line",
            conversationName: "TestUser",
            messages: [
                VisibleMessage(text: "Hello", sender: "other", yOrder: 0),
                VisibleMessage(text: "Hi there", sender: "self", yOrder: 1),
            ],
            messageCount: 2,
            timestamp: "2026-02-06T00:00:00Z"
        )
    }

    func getConversations(limit: Int) throws -> ConversationList {
        ConversationList(
            adapter: "line",
            conversations: [
                ConversationEntry(name: "TestUser", yOrder: 0, hasUnread: false),
                ConversationEntry(name: "WorkGroup", yOrder: 1, hasUnread: true),
            ],
            count: 2,
            timestamp: "2026-02-06T00:00:00Z"
        )
    }
}

private final class FailingAdapter: AdapterProtocol {
    let name = "failing"
    let bundleIdentifier = "com.example.failing"

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

    // MARK: - Read API tests

    func testContextReturnsOk() {
        let core = makeCore()
        let response = core.context(adapter: "line")
        XCTAssertEqual(response.status, .ok)
        let parsed = try! JSONDecoder().decode(APIResponse<ConversationContext>.self, from: response.body)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.result?.conversationName, "TestUser")
        XCTAssertEqual(parsed.result?.hasInputField, true)
    }

    func testMessagesReturnsOk() {
        let core = makeCore()
        let response = core.messages(adapter: "line", limit: 50)
        XCTAssertEqual(response.status, .ok)
        let parsed = try! JSONDecoder().decode(APIResponse<MessageList>.self, from: response.body)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.result?.messageCount, 2)
        XCTAssertEqual(parsed.result?.messages.first?.sender, "other")
    }

    func testConversationsReturnsOk() {
        let core = makeCore()
        let response = core.conversations(adapter: "line", limit: 50)
        XCTAssertEqual(response.status, .ok)
        let parsed = try! JSONDecoder().decode(APIResponse<ConversationList>.self, from: response.body)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.result?.count, 2)
        XCTAssertEqual(parsed.result?.conversations.last?.hasUnread, true)
    }

    func testContextUnsupportedAdapterReturnsError() {
        let core = makeCore()
        let response = core.context(adapter: "slack")
        XCTAssertEqual(response.status, .badRequest)
        let parsed = try! JSONDecoder().decode(APIResponse<ConversationContext>.self, from: response.body)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.error?.code, "adapter_not_found")
    }

    // MARK: - Origin check tests

    func testOriginCheckRejectsPostWithOrigin() {
        let core = makeCore()
        var headers = HTTPHeaders()
        headers.add(name: "Origin", value: "http://evil.com")
        let result = core.checkOrigin(method: .POST, headers: headers)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .forbidden)

        let parsed = try! JSONDecoder().decode(APIResponse<String>.self, from: result!.body)
        XCTAssertEqual(parsed.error?.code, "browser_origin_rejected")
    }

    func testOriginCheckAllowsPostWithoutOrigin() {
        let core = makeCore()
        let headers = HTTPHeaders()
        let result = core.checkOrigin(method: .POST, headers: headers)
        XCTAssertNil(result)
    }

    func testOriginCheckAllowsGetWithOrigin() {
        let core = makeCore()
        var headers = HTTPHeaders()
        headers.add(name: "Origin", value: "http://evil.com")
        let result = core.checkOrigin(method: .GET, headers: headers)
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func makeCore() -> BridgeCore {
        let defaults = UserDefaults(suiteName: "clawgate.tests.core")!
        defaults.removePersistentDomain(forName: "clawgate.tests.core")
        let cfg = ConfigStore(defaults: defaults)

        let statsFile = NSTemporaryDirectory() + "clawgate-stats-test-\(UUID().uuidString).json"
        return BridgeCore(
            eventBus: EventBus(),
            registry: AdapterRegistry(adapters: [FakeAdapter()]),
            logger: AppLogger(configStore: cfg),
            configStore: cfg,
            statsCollector: StatsCollector(filePath: statsFile)
        )
    }

    private func makeCoreWithFailingAdapter() -> BridgeCore {
        let defaults = UserDefaults(suiteName: "clawgate.tests.failing")!
        defaults.removePersistentDomain(forName: "clawgate.tests.failing")
        let cfg = ConfigStore(defaults: defaults)

        let statsFile = NSTemporaryDirectory() + "clawgate-stats-test-\(UUID().uuidString).json"
        return BridgeCore(
            eventBus: EventBus(),
            registry: AdapterRegistry(adapters: [FakeAdapter(), FailingAdapter()]),
            logger: AppLogger(configStore: cfg),
            configStore: cfg,
            statsCollector: StatsCollector(filePath: statsFile)
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
