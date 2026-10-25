import Foundation

/// Explicit, one-line-at-a-time adapter. Constructing it never enumerates
/// sessions or starts a scan. No defaults select a historical start boundary.
final class AudioHubTranscriptScanner {
    enum Outcome: Equatable {
        case admitted(AudioHubControlStore.Checkpoint)
        case incompleteTail
        case endOfFile
    }

    private let sessionsRoot: URL
    private let sessionID: String
    private let control: AudioHubControlStore
    private let outbox: AudioHubOutbox
    private let maxReadBytes: Int
    private let maxLineBytes: Int
    private let legacyPrefixSHA256: String?
    private let lock = NSLock()

    init(sessionsRoot: URL, sessionID: String,
         initialCheckpoint: AudioHubRawTranscriptReader.Checkpoint,
         control: AudioHubControlStore, outbox: AudioHubOutbox,
         maxReadBytes: Int, maxLineBytes: Int, legacyPrefixSHA256: String? = nil) throws {
        guard maxReadBytes > 0, maxLineBytes > 0, maxLineBytes < Int.max else {
            throw AudioHubRawTranscriptReader.Error.invalidBounds
        }
        self.sessionsRoot = sessionsRoot; self.sessionID = sessionID
        self.control = control; self.outbox = outbox
        self.maxReadBytes = maxReadBytes; self.maxLineBytes = maxLineBytes
        self.legacyPrefixSHA256 = legacyPrefixSHA256
        try control.startScan(sessionID: sessionID, initial: initialCheckpoint)
    }

    /// Persist first-read bytes before anything can enqueue them. Exposed as a
    /// separate local phase so recovery never depends on rereading mutable input.
    func stageNext() throws -> AudioHubRawTranscriptReader.Outcome {
        lock.lock(); defer { lock.unlock() }
        return try stageUnlocked()
    }

    private func stageUnlocked() throws -> AudioHubRawTranscriptReader.Outcome {
        let scan = try control.scan(sessionID: sessionID)
        if let staged = scan.staged { return .line(staged) }
        var cursor = scan.cursor
        let needsProof = cursor.snapshot?.volumeUUID == nil
        let lastLine = needsProof ? try control.checkpoints().first {
            $0.sourceRecordRef == "clawgate:session:\(sessionID):raw:\(cursor.physicalLine)"
        }?.revisionRef : nil
        let prefix = cursor.offset == scan.initial.offset && cursor.physicalLine == scan.initial.physicalLine
            ? legacyPrefixSHA256 : nil
        let outcome = try AudioHubRawTranscriptReader.read(sessionsRoot: sessionsRoot,
            sessionID: sessionID, checkpoint: cursor,
            maxReadBytes: maxReadBytes, maxLineBytes: maxLineBytes,
            legacyLineSHA256: lastLine.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil },
            legacyPrefixSHA256: prefix, onReconciled: { replacement in
                try self.control.reconcileCursor(sessionID: self.sessionID, expected: cursor, replacement: replacement)
                cursor = replacement
            })
        if case .line(let line) = outcome {
            try control.stage(sessionID: sessionID, expected: cursor, line: line)
        }
        return outcome
    }

    /// Order: staged bytes -> queue/exclusion + journal -> cursor. An error at
    /// any stop point leaves the cursor unadvanced and replay uses the same ID.
    /// Invalid JSON/blank lines remain staged as an explicit failure, not skipped.
    func step() throws -> Outcome {
        lock.lock(); defer { lock.unlock() }
        switch try stageUnlocked() {
        case .endOfFile: return .endOfFile
        case .incompleteTail: return .incompleteTail
        case .line(let line):
            let prepared = try AudioHubTranscriptWire.prepare(raw: line.rawLine,
                sourceSessionID: sessionID, line: Int(line.physicalLine))
            let checkpoint = try control.admit(prepared, into: outbox)
            try control.advance(sessionID: sessionID, expectedLine: line, checkpoint: checkpoint)
            return .admitted(checkpoint)
        }
    }
}
