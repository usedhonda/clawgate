import Foundation

protocol AdapterProtocol {
    var name: String { get }
    var bundleIdentifier: String { get }
    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog])
    func getContext() throws -> ConversationContext
    func getMessages(limit: Int) throws -> MessageList
    func getConversations(limit: Int) throws -> ConversationList
}

extension AdapterProtocol {
    func getContext() throws -> ConversationContext {
        throw BridgeRuntimeError(code: "not_supported", message: "このadapterはgetContextに未対応です",
                                 retriable: false, failedStep: nil, details: name)
    }
    func getMessages(limit: Int) throws -> MessageList {
        throw BridgeRuntimeError(code: "not_supported", message: "このadapterはgetMessagesに未対応です",
                                 retriable: false, failedStep: nil, details: name)
    }
    func getConversations(limit: Int) throws -> ConversationList {
        throw BridgeRuntimeError(code: "not_supported", message: "このadapterはgetConversationsに未対応です",
                                 retriable: false, failedStep: nil, details: name)
    }
}

struct AdapterRegistry {
    private let adapters: [String: AdapterProtocol]

    init(adapters: [AdapterProtocol]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.name, $0) })
    }

    func adapter(for name: String) -> AdapterProtocol? {
        adapters[name]
    }
}
