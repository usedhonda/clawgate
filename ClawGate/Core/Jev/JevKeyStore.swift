import Foundation
import CryptoKit

/// On-disk storage for the TypeSafe (Jev) API key.
///
/// The key lives in its own 0o600 file rather than UserDefaults because
/// UserDefaults (`~/Library/Preferences/*.plist`) is readable by anything with
/// this user's account and shows up whole in backups, Spotlight-indexed
/// preference dumps, and `defaults read`; a dedicated file under
/// `~/.clawgate/secrets/` with owner-only permissions is the same treatment
/// the device identity key already gets (`OpenClawDeviceIdentity`), and keeps
/// every credential this app holds in one predictable, narrowly-permissioned
/// place instead of spread across the preference domain.
struct JevKeyStore {
    private struct Payload: Codable {
        var version: Int
        var apiKey: String
    }

    var path: String = NSString("~/.clawgate/secrets/typesafe.json").expandingTildeInPath

    var isConfigured: Bool {
        (try? load()) != nil
    }

    /// Trims whitespace before writing; an empty key is treated as "remove the
    /// key" rather than persisting a blank credential a caller would still
    /// have to special-case on load.
    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let payload = Payload(version: 1, apiKey: trimmed)
        let data = try JSONEncoder().encode(payload)
        guard FileManager.default.createFile(atPath: path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw JevError.keyUnreadable
        }
    }

    /// Reads fresh every call — no in-memory cache — so a key rotated on disk
    /// (or deleted) takes effect on the very next request rather than only
    /// after a restart.
    func load() throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw JevError.keyUnreadable
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw JevError.keyUnreadable
        }
        let key = payload.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw JevError.keyUnreadable }
        return key
    }

    func delete() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// An irreversible tag safe to put in a log line: the key text itself
    /// never appears, only a short hash prefix plus its byte length (the same
    /// idea `TransportLog.boundedTag` uses for wire-controlled strings).
    static func tag(of key: String) -> String {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "h\(hex.prefix(8))/\(key.utf8.count)"
    }
}
