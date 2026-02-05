import Foundation

protocol AdapterProtocol {
    var name: String { get }
    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog])
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
