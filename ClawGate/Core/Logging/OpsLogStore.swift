import Foundation

struct OpsLogEntry: Codable {
    let ts: String
    let level: String
    let event: String
    let role: String
    let host: String
    let script: String
    let message: String

    var date: Date {
        OpsLogStore.iso.date(from: ts) ?? Date.distantPast
    }
}

final class OpsLogStore {
    static let iso = ISO8601DateFormatter()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logDirectory: URL

    init() {
        self.logDirectory = OpsLogStore.resolveLogDirectory()
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    func append(
        level: String,
        event: String,
        role: String,
        script: String,
        message: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        let entry = OpsLogEntry(
            ts: Self.iso.string(from: Date()),
            level: level,
            event: event,
            role: role,
            host: Self.hostName(),
            script: script,
            message: message
        )

        guard let data = try? encoder.encode(entry), var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        let lineData = Data(line.utf8)

        let fileURL = Self.currentLogFileURL(in: logDirectory)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } catch {
            return
        }
    }

    func recent(limit: Int, levelFilter: String? = nil, traceFilter: String? = nil) -> [OpsLogEntry] {
        let capped = max(1, min(limit, 200))
        let fileURL = Self.currentLogFileURL(in: logDirectory)
        guard let data = fileManager.contents(atPath: fileURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let rows = text.split(separator: "\n")
        var entries: [OpsLogEntry] = []
        entries.reserveCapacity(min(capped, rows.count))

        for row in rows.reversed() {
            guard let rowData = row.data(using: .utf8),
                  let entry = try? decoder.decode(OpsLogEntry.self, from: rowData) else {
                continue
            }
            if let levelFilter, !levelFilter.isEmpty, entry.level.lowercased() != levelFilter.lowercased() {
                continue
            }
            if let traceFilter, !traceFilter.isEmpty,
               !entry.message.contains(traceFilter), !entry.event.contains(traceFilter) {
                continue
            }
            entries.append(entry)
            if entries.count >= capped { break }
        }
        return entries
    }

    private static func resolveLogDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment["CLAWGATE_PROJECT_PATH"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("docs/log/ops", isDirectory: true)
        }

        let fixed = URL(fileURLWithPath: "/Users/usedhonda/projects/ios/clawgate/docs/log/ops", isDirectory: true)
        if FileManager.default.fileExists(atPath: "/Users/usedhonda/projects/ios/clawgate") {
            return fixed
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let cwdProject = cwd.appendingPathComponent("docs/log/ops", isDirectory: true)
        if FileManager.default.fileExists(atPath: cwdProject.deletingLastPathComponent().deletingLastPathComponent().path) {
            return cwdProject
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClawGate/ops", isDirectory: true)
    }

    private static func currentLogFileURL(in dir: URL) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .current
        let day = f.string(from: Date())
        return dir.appendingPathComponent("\(day)-ops.log")
    }

    private static func hostName() -> String {
        ProcessInfo.processInfo.hostName
    }
}
