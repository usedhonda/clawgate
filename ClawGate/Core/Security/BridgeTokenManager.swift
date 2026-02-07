import Foundation

final class BridgeTokenManager {
    private let keychain: KeychainStore
    private let account = "bridge.token"
    private var cachedToken: String?
    private let lock = NSLock()

    init(keychain: KeychainStore) {
        self.keychain = keychain
        // Keychain load is deferred — ad-hoc signed apps may trigger a blocking
        // dialog on SecItemCopyMatching. Token is generated fresh on first access
        // or set via regenerateToken() during pairing.
    }

    func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let token = cachedToken {
            return token
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        cachedToken = generated
        let ks = keychain
        let acct = account
        DispatchQueue.global(qos: .utility).async {
            try? ks.save(account: acct, value: generated)
        }
        return generated
    }

    func regenerateToken() -> String {
        lock.lock()
        defer { lock.unlock() }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        cachedToken = generated
        let ks = keychain
        let acct = account
        DispatchQueue.global(qos: .utility).async {
            try? ks.save(account: acct, value: generated)
        }
        return generated
    }

    func validate(_ token: String?) -> Bool {
        guard let token else { return false }
        return token == currentToken()
    }

    func hasValidToken() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedToken != nil
    }
}
