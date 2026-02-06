import Foundation

final class BridgeTokenManager {
    private let keychain: KeychainStore
    private let account = "bridge.token"

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func currentToken() -> String {
        if let token = try? keychain.load(account: account) {
            return token
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? keychain.save(account: account, value: generated)
        return generated
    }

    func regenerateToken() -> String {
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? keychain.save(account: account, value: generated)
        return generated
    }

    func validate(_ token: String?) -> Bool {
        guard let token else { return false }
        return token == currentToken()
    }

    func hasValidToken() -> Bool {
        (try? keychain.load(account: account)) != nil
    }
}
