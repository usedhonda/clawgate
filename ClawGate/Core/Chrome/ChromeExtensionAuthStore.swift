import Foundation
import Security

/// Manages the pairing token between ClawGate and the Chrome extension.
/// Token is stored in UserDefaults (small key, fine for UserDefaults).
final class ChromeExtensionAuthStore {
    private static let defaultsKey = "clawgate.chromeExtensionPairingToken"

    /// Always reads fresh from UserDefaults so any instance sees the latest token.
    var currentToken: String {
        UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
    }

    /// Generate a new 32-byte random hex token and persist it.
    @discardableResult
    func generateNewToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.defaultsKey)
        return token
    }

    func clearToken() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
