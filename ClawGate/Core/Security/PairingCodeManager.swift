import Foundation

/// Manages one-time pairing codes for secure token exchange
/// - Generates 6-digit codes with 120-second TTL
/// - Each code can only be used once
final class PairingCodeManager {
    private struct PairingCode {
        let code: String
        let expiresAt: Date
        var used: Bool = false
    }

    private var currentCode: PairingCode?
    private let ttlSeconds: TimeInterval = 120
    private let lock = NSLock()

    /// Generate a new 6-digit pairing code
    /// Invalidates any existing code
    func generateCode() -> String {
        lock.lock()
        defer { lock.unlock() }

        let code = String(format: "%06d", Int.random(in: 0..<1000000))
        currentCode = PairingCode(
            code: code,
            expiresAt: Date().addingTimeInterval(ttlSeconds)
        )
        return code
    }

    /// Get the current code if valid (not expired, not used)
    func currentValidCode() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let code = currentCode else { return nil }
        guard !code.used else { return nil }
        guard Date() < code.expiresAt else {
            currentCode = nil
            return nil
        }
        return code.code
    }

    /// Remaining seconds until current code expires
    func remainingSeconds() -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard let code = currentCode, !code.used else { return 0 }
        let remaining = code.expiresAt.timeIntervalSinceNow
        return max(0, Int(remaining))
    }

    /// Validate a code and mark it as used if valid
    /// Returns true only once per code
    func validateAndConsume(_ inputCode: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let code = currentCode else { return false }
        guard !code.used else { return false }
        guard Date() < code.expiresAt else {
            currentCode = nil
            return false
        }
        guard code.code == inputCode else { return false }

        // Mark as used
        currentCode?.used = true
        return true
    }

    /// Check if a code is valid without consuming it
    func isValid(_ inputCode: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let code = currentCode else { return false }
        guard !code.used else { return false }
        guard Date() < code.expiresAt else { return false }
        return code.code == inputCode
    }

    /// Clear any existing code
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        currentCode = nil
    }
}
