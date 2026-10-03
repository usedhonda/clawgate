import Foundation
import Darwin

/// A private, explicitly requested, one-shot diagnostic snapshot.
///
/// This helper deliberately has no network or debug-API surface.  A caller must
/// create `audit-request.json` in the private observation directory first.
enum LineObservationAuditStatus: String, Equatable {
    case noRequest = "no_request"
    case invalidRequest = "invalid_request"
    case expiredRequest = "expired_request"
    case rejected = "rejected"
    case auditWriteFailed = "audit_write_failed"
    case success = "success"

    /// Stable machine-only value suitable for existing diagnostics fields.
    var diagnosticStatus: String { rawValue }
}

enum LineObservationAudit {
    static let requestName = "audit-request.json"
    static let resultName = "audit-result.json"
    private static let maxRequestBytes = 1024
    private static let maxAge: TimeInterval = 5 * 60

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawgate/line-observation", isDirectory: true)
    }

    /// Consume one valid request and atomically write private observation content.
    /// No directory or request is created by this function.
    @discardableResult
    static func consumeIfRequested(
        snapshots: [[String: Any]],
        capturedAt: String,
        root: URL = defaultRoot,
        now: Date = Date()
    ) -> LineObservationAuditStatus {
        let fm = FileManager.default
        guard let rootStat = stat(root) else { return .noRequest }
        guard rootStat.isDirectory, rootStat.owner == getuid(), rootStat.permissions == 0o700 else { return .rejected }

        let requestURL = root.appendingPathComponent(requestName, isDirectory: false)
        guard let requestStat = lstat(requestURL) else { return .noRequest }
        guard requestStat.isRegular, requestStat.owner == getuid(), requestStat.permissions == 0o600 else {
            return .rejected
        }
        guard requestStat.size <= maxRequestBytes,
              let data = try? Data(contentsOf: requestURL), data.count <= maxRequestBytes else {
            return .invalidRequest
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any],
              let version = request["version"] as? Int, version == 1,
              let requestID = request["requestId"] as? String, UUID(uuidString: requestID) != nil,
              let expiresAtString = request["expiresAt"] as? String,
              let expiresAt = ISO8601DateFormatter().date(from: expiresAtString) else {
            return .invalidRequest
        }

        let age = now.timeIntervalSince(requestStat.modified)
        guard age >= 0, age <= maxAge else { return .expiredRequest }
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= maxAge else { return .expiredRequest }

        let outputURL = root.appendingPathComponent(resultName, isDirectory: false)
        if let existing = lstat(outputURL),
           (!existing.isRegular || existing.owner != getuid() || existing.permissions != 0o600) {
            return .rejected
        }

        // Consume before writing: a failed write must never be retried implicitly.
        guard unlink(requestURL.path) == 0 else { return .rejected }

        let payload: [String: Any] = [
            "requestId": requestID,
            "capturedAt": capturedAt,
            "snapshots": snapshots
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let outputData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .auditWriteFailed
        }
        let tempURL = root.appendingPathComponent(".audit-result-\(UUID().uuidString).tmp", isDirectory: false)
        guard writeExclusive(outputData, to: tempURL) else { return .auditWriteFailed }
        guard rename(tempURL.path, outputURL.path) == 0 else {
            try? fm.removeItem(at: tempURL)
            return .auditWriteFailed
        }
        return .success
    }

    private struct Entry {
        let isRegular: Bool
        let isDirectory: Bool
        let owner: uid_t
        let permissions: Int
        let size: Int64
        let modified: Date
    }

    private static func lstat(_ url: URL) -> Entry? {
        var value = Darwin.stat()
        guard Darwin.lstat(url.path, &value) == 0 else { return nil }
        return Entry(isRegular: (value.st_mode & S_IFMT) == S_IFREG,
                     isDirectory: (value.st_mode & S_IFMT) == S_IFDIR,
                     owner: value.st_uid,
                     permissions: Int(value.st_mode & 0o7777),
                     size: Int64(value.st_size),
                     modified: Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec) +
                                    TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    private static func stat(_ url: URL) -> Entry? { lstat(url) }

    private static func writeExclusive(_ data: Data, to url: URL) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }
}
