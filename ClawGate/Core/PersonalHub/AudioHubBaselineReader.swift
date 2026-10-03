import CryptoKit
import Darwin
import Foundation

/// Verify the frozen committed prefix at scanner start, not at current EOF.
enum AudioHubBaselineReader {
    static func verify(sessionsRoot: URL, entry: AudioHubActivationManifest.Session) throws {
        guard let expected = entry.initial.snapshot, entry.initial.offset <= expected.length else {
            throw AudioHubRuntime.Failure.invalidPath
        }
        let fd = try openRaw(root: sessionsRoot, sessionID: entry.sessionID)
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, UInt64(before.st_dev) == expected.device,
              UInt64(before.st_ino) == expected.inode, before.st_size >= 0,
              UInt64(before.st_size) >= expected.length else { throw AudioHubRuntime.Failure.invalidPath }
        var hasher = SHA256()
        var remaining = entry.initial.offset
        var lines: UInt64 = 0
        var last: UInt8?
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        while remaining > 0 {
            let amount = Int(min(UInt64(bytes.count), remaining))
            let count = Darwin.read(fd, &bytes, amount)
            guard count > 0 else { throw AudioHubRuntime.Failure.invalidPath }
            let block = Data(bytes.prefix(count))
            hasher.update(data: block)
            lines += UInt64(block.filter { $0 == 0x0A }.count)
            last = block.last
            remaining -= UInt64(count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == entry.prefixSHA256, lines == entry.initial.physicalLine,
              entry.initial.offset == 0 || last == 0x0A else { throw AudioHubRuntime.Failure.invalidPath }
        let proof = try openRaw(root: sessionsRoot, sessionID: entry.sessionID)
        defer { close(proof) }
        var after = stat()
        guard fstat(proof, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size >= before.st_size else { throw AudioHubRuntime.Failure.invalidPath }
    }

    private static func openRaw(root: URL, sessionID: String) throws -> Int32 {
        let parts = [sessionID, "transcripts", "raw.jsonl"]
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
            throw AudioHubRuntime.Failure.invalidPath
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw AudioHubRuntime.Failure.invalidPath }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw AudioHubRuntime.Failure.invalidPath }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else { throw AudioHubRuntime.Failure.invalidPath }
            close(directory); directory = next
            guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw AudioHubRuntime.Failure.invalidPath }
        }
        let file = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AudioHubRuntime.Failure.invalidPath }
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(file); throw AudioHubRuntime.Failure.invalidPath
        }
        return file
    }
}
