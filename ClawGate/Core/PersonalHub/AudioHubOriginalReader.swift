import CryptoKit
import Darwin
import Foundation

/// Bounded reader for one explicitly referenced selected-meeting original.
/// It never copies, retains, deletes, or extends the source file's lifetime.
final class AudioHubOriginalReader {
    enum Error: Swift.Error, Equatable {
        case missingOriginal
        case unsafePath
        case contentMismatch
        case sourceChanged
        case invalidRange
        case readFailed
    }

    private struct Snapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let length: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private let root: URL
    private let reference: AudioHubOutbox.OriginalReference
    private let snapshot: Snapshot

    init(root: URL, reference: AudioHubOutbox.OriginalReference) throws {
        guard Self.validReference(reference.sourceRelativePath) else { throw Error.unsafePath }
        self.root = root
        self.reference = reference
        let descriptor = try Self.open(root: root, relativePath: reference.sourceRelativePath)
        defer { close(descriptor) }
        let initial = try Self.snapshot(descriptor)
        guard initial.length > 0, initial.length == reference.byteLength else { throw Error.contentMismatch }
        let digest = try Self.hash(descriptor, length: initial.length)
        guard digest == reference.sha256.lowercased() else { throw Error.contentMismatch }
        guard try Self.snapshot(descriptor) == initial else { throw Error.sourceChanged }
        let proof = try Self.open(root: root, relativePath: reference.sourceRelativePath)
        defer { close(proof) }
        guard try Self.snapshot(proof) == initial else { throw Error.sourceChanged }
        self.snapshot = initial
    }

    /// Inspect one explicitly named selected-meeting asset without copying it.
    /// The returned reference freezes the bytes observed across the same
    /// ownership, snapshot, hash, and reopen checks used by the reader.
    static func inspect(root: URL, relativePath: String) throws -> AudioHubOutbox.OriginalReference {
        guard validReference(relativePath) else { throw Error.unsafePath }
        let descriptor = try open(root: root, relativePath: relativePath)
        defer { close(descriptor) }
        let initial = try snapshot(descriptor)
        guard initial.length > 0 else { throw Error.contentMismatch }
        let digest = try hash(descriptor, length: initial.length)
        guard try snapshot(descriptor) == initial else { throw Error.sourceChanged }
        let proof = try open(root: root, relativePath: relativePath)
        defer { close(proof) }
        guard try snapshot(proof) == initial else { throw Error.sourceChanged }
        do {
            return try AudioHubOutbox.OriginalReference(sourceRelativePath: relativePath,
                                                        sha256: digest,
                                                        byteLength: initial.length)
        } catch {
            throw Error.readFailed
        }
    }

    func readChunk(offset: Int64, limit: Int) throws -> Data {
        guard limit > 0, limit <= 4 * 1024 * 1024, offset >= 0 else { throw Error.invalidRange }
        let descriptor = try Self.open(root: root, relativePath: reference.sourceRelativePath)
        defer { close(descriptor) }
        let before = try Self.snapshot(descriptor)
        guard before == snapshot else { throw Error.sourceChanged }
        guard offset <= before.length else { throw Error.invalidRange }
        let amount = min(Int64(limit), before.length - offset)
        if amount == 0 { return Data() }
        var data = Data(count: Int(amount))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return pread(descriptor, base, Int(amount), off_t(offset))
        }
        guard count == Int(amount) else { throw Error.readFailed }
        guard try Self.snapshot(descriptor) == snapshot else { throw Error.sourceChanged }
        let proof = try Self.open(root: root, relativePath: reference.sourceRelativePath)
        defer { close(proof) }
        guard try Self.snapshot(proof) == snapshot else { throw Error.sourceChanged }
        return data
    }

    private static func validReference(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "meetings", parts[2] == "audio" else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." &&
            !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }

    private static func open(root: URL, relativePath: String) throws -> Int32 {
        guard validReference(relativePath) else { throw Error.unsafePath }
        let parts = relativePath.split(separator: "/").map(String.init)
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        let rootError = errno
        guard rootFD >= 0 else { throw mapOpenError(rootError) }
        guard tryOwnedDirectory(rootFD) else { close(rootFD); throw Error.unsafePath }
        var directory = rootFD
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            let nextError = errno
            if directory != rootFD { close(directory) }
            guard next >= 0 else { close(rootFD); throw mapOpenError(nextError) }
            guard tryOwnedDirectory(next) else { close(next); close(rootFD); throw Error.unsafePath }
            directory = next
        }
        let descriptor = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        let descriptorError = errno
        if directory != rootFD { close(directory) }
        close(rootFD)
        guard descriptor >= 0 else { throw mapOpenError(descriptorError) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else { close(descriptor); throw Error.unsafePath }
        return descriptor
    }

    private static func tryOwnedDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private static func mapOpenError(_ value: Int32) -> Error {
        if value == ENOENT { return .missingOriginal }
        if value == ELOOP || value == ENOTDIR { return .unsafePath }
        return .readFailed
    }

    private static func snapshot(_ descriptor: Int32) throws -> Snapshot {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { throw Error.readFailed }
        return Snapshot(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: info.st_size,
                        modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                        changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func hash(_ descriptor: Int32, length: Int64) throws -> String {
        var hasher = SHA256()
        var offset: Int64 = 0
        let bufferSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while offset < length {
            let amount = min(bufferSize, Int(length - offset))
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, amount, off_t(offset)) }
            guard count == amount else { throw Error.readFailed }
            hasher.update(data: Data(buffer[0..<amount]))
            offset += Int64(amount)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
