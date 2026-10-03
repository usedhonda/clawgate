import Foundation
import Darwin

/// Bounded, stateless reader for one session's append-only raw transcript.
///
/// This helper deliberately does not scan sessions, persist a cursor, parse JSON,
/// or enqueue anything.  The caller supplies both the path root and all bounds.
struct AudioHubRawTranscriptReader {
    struct Snapshot: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let length: UInt64
    }

    struct Checkpoint: Codable, Equatable {
        let offset: UInt64
        let physicalLine: UInt64
        let snapshot: Snapshot?

        init(offset: UInt64 = 0, physicalLine: UInt64 = 0, snapshot: Snapshot? = nil) {
            self.offset = offset
            self.physicalLine = physicalLine
            self.snapshot = snapshot
        }
    }

    struct ReadResult: Codable, Equatable {
        let rawLine: Data
        let physicalLine: UInt64
        let nextOffset: UInt64
        let nextPhysicalLine: UInt64
        let snapshot: Snapshot
    }

    enum Outcome: Equatable {
        case line(ReadResult)
        case incompleteTail
        case endOfFile
    }

    enum Error: Swift.Error, Equatable {
        case invalidBounds
        case invalidSessionID
        case unsafePath
        case staleCursor
        case truncatedCursor
        case readLimitExceeded
        case lineLimitExceeded
        case readFailed
    }

    /// Reads at most one complete physical line. A final unterminated line is
    /// reported as `incompleteTail` without advancing the cursor.
    /// Device/inode and shrink checks detect replacement and truncation; they do
    /// not prove that a writer did not rewrite bytes in place on the same inode.
    static func read(sessionsRoot: URL, sessionID: String, checkpoint: Checkpoint,
                     maxReadBytes: Int, maxLineBytes: Int) throws -> Outcome {
        guard maxReadBytes > 0, maxLineBytes > 0,
              checkpoint.offset <= UInt64(Int64.max), checkpoint.physicalLine < UInt64(Int.max)
        else { throw Error.invalidBounds }
        guard checkpoint.offset != 0 || checkpoint.physicalLine == 0 else { throw Error.staleCursor }
        guard checkpoint.offset == 0 || (checkpoint.physicalLine > 0 && checkpoint.physicalLine <= checkpoint.offset) else {
            throw Error.staleCursor
        }
        guard validSessionID(sessionID) else { throw Error.invalidSessionID }

        let root = openDirectory(sessionsRoot.path)
        guard root >= 0 else { throw Error.unsafePath }
        guard isOwnedDirectory(root) else { close(root); throw Error.unsafePath }
        let session = openat(root, sessionID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        close(root)
        guard session >= 0 else { throw Error.unsafePath }
        guard isOwnedDirectory(session) else { close(session); throw Error.unsafePath }
        let transcripts = openat(session, "transcripts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        close(session)
        guard transcripts >= 0 else { throw Error.unsafePath }
        guard isOwnedDirectory(transcripts) else { close(transcripts); throw Error.unsafePath }
        let raw = openat(transcripts, "raw.jsonl", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        close(transcripts)
        guard raw >= 0 else { throw Error.unsafePath }
        defer { close(raw) }

        var info = stat()
        guard fstat(raw, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0 else { throw Error.unsafePath }
        let snapshot = Snapshot(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                                length: UInt64(info.st_size))
        if checkpoint.offset > 0 && checkpoint.snapshot == nil { throw Error.staleCursor }
        if let expected = checkpoint.snapshot {
            guard expected.device == snapshot.device, expected.inode == snapshot.inode else {
                throw Error.staleCursor
            }
            guard snapshot.length >= expected.length, snapshot.length >= checkpoint.offset else {
                throw Error.truncatedCursor
            }
        } else if checkpoint.offset > snapshot.length {
            throw Error.truncatedCursor
        }
        guard checkpoint.offset <= snapshot.length else { throw Error.truncatedCursor }

        // A nonzero cursor must be a physical line boundary. This check is
        // deliberately byte-based; JSON validity is a separate concern.
        if checkpoint.offset > 0 {
            var previous: UInt8 = 0
            let n = pread(raw, &previous, 1, off_t(checkpoint.offset - 1))
            guard n == 1, previous == 0x0A else { throw Error.staleCursor }
        }
        if checkpoint.offset == snapshot.length { return .endOfFile }

        let available = snapshot.length - checkpoint.offset
        guard maxLineBytes < Int.max else { throw Error.invalidBounds }
        let boundedRequest = min(maxReadBytes, maxLineBytes + 1)
        let request = min(UInt64(boundedRequest), available)
        guard request > 0, request <= UInt64(Int.max) else { throw Error.invalidBounds }
        var bytes = Data(count: Int(request))
        let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return pread(raw, base, Int(request), off_t(checkpoint.offset))
        }
        guard count >= 0 else { throw Error.readFailed }
        guard count > 0 else { throw Error.readFailed }
        guard count == Int(request) else { throw Error.readFailed }
        var afterRead = stat()
        guard fstat(raw, &afterRead) == 0,
              afterRead.st_size >= info.st_size else { throw Error.truncatedCursor }
        bytes.removeSubrange(count..<bytes.count)

        if let newline = bytes.firstIndex(of: 0x0A) {
            let lineLength = newline + 1
            guard lineLength <= maxLineBytes else { throw Error.lineLimitExceeded }
            let line = bytes.prefix(lineLength)
            return .line(ReadResult(rawLine: Data(line), physicalLine: checkpoint.physicalLine + 1,
                                    nextOffset: checkpoint.offset + UInt64(lineLength),
                                    nextPhysicalLine: checkpoint.physicalLine + 1, snapshot: snapshot))
        }
        guard bytes.count <= maxLineBytes else { throw Error.lineLimitExceeded }
        if UInt64(bytes.count) < available { throw Error.readLimitExceeded }
        // No LF before EOF: hold the torn tail and do not advance.
        return .incompleteTail
    }

    private static func openDirectory(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
    }

    private static func isOwnedDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
        !value.unicodeScalars.contains(where: {
            $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0)
        })
    }
}
