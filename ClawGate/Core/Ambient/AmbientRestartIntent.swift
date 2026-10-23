import Foundation

/// Body-free user-control fence for canonical restart recovery.
/// A pending or newer control must never be mistaken for permission to reopen a mic.
final class AmbientRestartIntent {
    struct Record: Codable, Equatable {
        var revision: String
        var settled: Bool
        var captureState: String?
        var streaming: Bool?
    }

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func begin() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let revision = UUID().uuidString
        do {
            try write(Record(revision: revision, settled: false))
        } catch {
            // A privacy stop still proceeds if storage fails. Invalidate an old
            // restart fence rather than leave its permission apparently current.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return revision
    }

    func settle(_ revision: String?, captureState: String, streaming: Bool) throws {
        guard let revision else { return }
        lock.lock(); defer { lock.unlock() }
        let current = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard current.revision == revision else { return }
        try write(Record(revision: revision, settled: true,
                         captureState: captureState, streaming: streaming))
    }

    private func write(_ record: Record) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
