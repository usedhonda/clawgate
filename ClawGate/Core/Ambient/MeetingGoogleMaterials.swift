import CryptoKit
import Foundation

/// Read-only Google Docs material discovered for a calendar meeting. The cache
/// is deliberately kept in Application Support, never in the repository.
struct MeetingGoogleMaterials {
    enum MaterialStatus: String, Codable { case checking, available, none, permissionDenied, serviceUnavailable, failed, ambiguous }

    struct SourceSegment: Codable, Equatable, Identifiable {
        let id: String
        let sourceURL: String
        let locator: String?
        let text: String
        let isTranscript: Bool
        let capturedAt: Double?
        let speakerName: String?
    }

    struct GeneratedNote: Codable, Equatable, Identifiable {
        let id: String
        let sourceURL: String
        let locator: String?
        let text: String
    }

    struct Source: Codable, Equatable, Identifiable {
        let id: String
        let url: String
        let documentID: String
        let tabID: String?
        let modifiedTime: Date?
        let contentHash: String?
        let status: MaterialStatus
        let title: String?
        let isTranscript: Bool
    }

    struct Snapshot: Codable, Equatable {
        let candidateID: String
        let status: MaterialStatus
        let sources: [Source]
        let segments: [SourceSegment]
        let notes: [GeneratedNote]
        let transcriptHash: String?
        let updatedAt: Date
    }

    typealias Runner = ([String]) throws -> Data

    static func shouldReuseFailure(_ snapshot: Snapshot, now: Date = Date(), force: Bool = false) -> Bool {
        guard !force else { return false }
        return snapshot.status == .permissionDenied ||
            (snapshot.status == .serviceUnavailable && now.timeIntervalSince(snapshot.updatedAt) < 1800)
    }

    static func authorizationArguments(email: String) -> [String] {
        ["auth", "add", email, "--services=calendar,drive,docs", "--readonly"]
    }

    static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawGate/meeting-materials", isDirectory: true)
    }

    static func load(candidateID: String, cacheDirectory: URL = defaultCacheDirectory()) -> Snapshot? {
        let safe = SHA256.hash(data: Data(candidateID.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(safe + ".json")) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func sync(candidate: MeetingCandidate, cacheDirectory: URL = defaultCacheDirectory(), now: Date = Date()) throws -> Snapshot {
        let auth = try liveRunner(["auth", "list", "--json"])
        if let object = try JSONSerialization.jsonObject(with: auth) as? [String: Any],
           let accounts = object["accounts"] as? [[String: Any]],
           let account = accounts.first(where: { $0["email"] as? String == candidate.calendarAccount }) {
            let services = account["services"] as? [String] ?? []
            if !services.contains("drive") || !services.contains("docs") {
                let old = load(candidateID: candidate.id, cacheDirectory: cacheDirectory)
                let snapshot = Snapshot(candidateID: candidate.id, status: .permissionDenied,
                    sources: old?.sources ?? [], segments: old?.segments ?? [], notes: old?.notes ?? [],
                    transcriptHash: old?.transcriptHash, updatedAt: now)
                try save(snapshot, cacheDirectory: cacheDirectory)
                return snapshot
            }
        }
        return try sync(candidate: candidate, run: liveRunner, cacheDirectory: cacheDirectory, now: now)
    }

    @discardableResult
    static func sync(candidate: MeetingCandidate, run: Runner,
                     cacheDirectory: URL = defaultCacheDirectory(), now: Date = Date()) throws -> Snapshot {
        let account = candidate.calendarAccount
        let previous = load(candidateID: candidate.id, cacheDirectory: cacheDirectory)
        var found = Set<String>()
        var documents: [Document] = []
        for url in candidate.attachmentURLs {
            if let id = documentID(from: url), found.insert(id).inserted { documents.append(Document(id: id, url: url, title: nil, modifiedTime: nil)) }
        }
        var discoveryFailure: MaterialStatus?
        if documents.isEmpty, let account, !account.isEmpty {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                do {
                    let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    let lower = ISO8601DateFormatter().string(from: candidate.start.addingTimeInterval(-86400))
                    let query = "trashed = false and mimeType = 'application/vnd.google-apps.document' and name contains '\(escaped)' and modifiedTime >= '\(lower)'"
                    var page: String?
                    var seenPages = Set<String>()
                    repeat {
                        let data = try run(["drive", "search", query, "--raw-query", "--account=" + account, "--max=100", "--json"] + (page.map { ["--page=" + $0] } ?? []))
                        guard let files = parseFiles(data) else { throw NSError(domain: "invalid Drive response", code: 1) }
                        documents += files.filter { found.insert($0.id).inserted }.map {
                            Document(id: $0.id, url: $0.url, title: $0.title, modifiedTime: $0.modifiedTime)
                        }
                        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        page = payload?["nextPageToken"] as? String
                        if let next = page, !next.isEmpty {
                            guard seenPages.insert(next).inserted, seenPages.count < 20 else {
                                discoveryFailure = .ambiguous; break
                            }
                        } else { page = nil }
                    } while page != nil
                } catch { discoveryFailure = String(describing: error).lowercased().contains("permission") ? .permissionDenied : .failed }
            }
        }

        var sources: [Source] = []
        var segments: [SourceSegment] = []
        var notes: [GeneratedNote] = []
        for doc in documents {
            do {
                let infoData = try run(["drive", "get", doc.id, "--account=" + (account ?? ""), "--json"])
                let info = parseInfo(infoData)
                let modified = info.modifiedTime ?? doc.modifiedTime
                if let modified, let old = previous, old.sources.contains(where: {
                    $0.documentID == doc.id && $0.modifiedTime == modified && $0.status == .available
                }) {
                    sources += old.sources.filter { $0.documentID == doc.id }
                    segments += old.segments.filter { $0.id.hasPrefix(doc.id + ":") }
                    notes += old.notes.filter { $0.id.hasPrefix(doc.id + ":") }
                    continue
                }
                let data = try run(["docs", "raw", doc.id, "--all-tabs", "--account=" + (account ?? ""), "--json"])
                let tabs = try parseRawTabs(data)
                let text = normalize(tabs.map(\.text).joined(separator: "\n\n"))
                let matchingText = (doc.title ?? info.title ?? "") + "\n" + text
                guard !text.isEmpty else { continue }
                let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                let url = doc.url
                let titleMatch = candidate.title.split(whereSeparator: { $0.isWhitespace }).contains { text.localizedCaseInsensitiveContains(String($0)) }
                let day = ISO8601DateFormatter().string(from: candidate.start).prefix(10)
                let grounded = candidate.conferenceCode.map { text.localizedCaseInsensitiveContains($0) } ?? false
                let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy年M月d日"; dayFormatter.timeZone = .current
                let dateGrounded = matchingText.contains(day) || matchingText.contains(day.replacingOccurrences(of: "-", with: "/")) || matchingText.contains(dayFormatter.string(from: candidate.start))
                let clock = DateFormatter(); clock.dateFormat = "HH:mm"; clock.timeZone = .current
                let timeGrounded = matchingText.contains(clock.string(from: candidate.start))
                guard candidate.attachmentURLs.contains(doc.url) || (dateGrounded && (grounded || (titleMatch && timeGrounded))) else {
                    sources.append(Source(id: doc.id, url: doc.url, documentID: doc.id, tabID: info.tabID, modifiedTime: doc.modifiedTime ?? info.modifiedTime, contentHash: hash, status: .ambiguous, title: doc.title ?? info.title, isTranscript: false)); continue
                }
                for tab in tabs {
                    let tabTranscript = looksLikeTranscript(tab.text, title: tab.title)
                    let tabURL = "https://docs.google.com/document/d/\(doc.id)/edit?tab=\(tab.id)"
                    sources.append(Source(id: doc.id + ":" + tab.id, url: tabURL, documentID: doc.id, tabID: tab.id,
                        modifiedTime: modified, contentHash: hash, status: .available,
                        title: tab.title ?? doc.title ?? info.title, isTranscript: tabTranscript))
                    if tabTranscript {
                        segments += transcriptEntries(tab.text, documentID: doc.id, tabID: tab.id,
                            url: tabURL, meetingStart: candidate.start)
                    } else if ["メモ", "議事録", "notes", "minutes"].contains(where: {
                        (tab.title ?? doc.title ?? info.title ?? "").localizedCaseInsensitiveContains($0)
                    }) {
                        for (index, part) in splitSections(tab.text).enumerated() {
                            notes.append(GeneratedNote(id: "\(doc.id):\(tab.id):\(index)", sourceURL: tabURL,
                                locator: tab.id, text: part))
                        }
                    }
                }
            } catch {
                sources.append(Source(id: doc.id, url: doc.url, documentID: doc.id, tabID: nil,
                                      modifiedTime: doc.modifiedTime, contentHash: nil,
                                      status: String(describing: error).contains("docs API disabled") ? .serviceUnavailable :
                                        (String(describing: error).lowercased().contains("permission") ? .permissionDenied : .failed),
                                      title: doc.title, isTranscript: false))
            }
        }
        let status: MaterialStatus = sources.contains(where: { $0.status == .serviceUnavailable }) ? .serviceUnavailable : discoveryFailure ?? (sources.isEmpty ? .none : (sources.contains { $0.status == .permissionDenied } ? .permissionDenied : (sources.contains { $0.status == .failed } ? .failed : (sources.contains { $0.status == .ambiguous } ? .ambiguous : .available))))
        let transcriptHash = transcriptDigest(segments)
        var snapshot = Snapshot(candidateID: candidate.id, status: status, sources: sources,
                                segments: segments, notes: notes, transcriptHash: transcriptHash, updatedAt: now)
        if (status == .failed || status == .permissionDenied || status == .serviceUnavailable), let old = previous {
            snapshot = Snapshot(candidateID: candidate.id, status: status, sources: sources.isEmpty ? old.sources : sources,
                segments: old.segments, notes: old.notes, transcriptHash: old.transcriptHash, updatedAt: now)
        }
        try save(snapshot, cacheDirectory: cacheDirectory)
        return snapshot
    }

    private static func save(_ snapshot: Snapshot, cacheDirectory: URL) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let safe = SHA256.hash(data: Data(snapshot.candidateID.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(snapshot).write(to: cacheDirectory.appendingPathComponent(safe + ".json"), options: .atomic)
    }

    static var executableURL: URL? {
        let paths = [Bundle.main.resourceURL?.appendingPathComponent("gog").path,
                     "/opt/homebrew/bin/gog", "/usr/local/bin/gog"].compactMap { $0 }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private static let liveRunner: Runner = { arguments in
        guard let binary = executableURL else { throw NSError(domain: "gog unavailable", code: 1) }
        let process = Process(); process.executableURL = binary
        process.arguments = arguments + ["--no-input"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        // Drain both pipes while the process runs; full transcripts exceed a pipe buffer.
        let group = DispatchGroup()
        var stderr = Data()
        group.enter()
        DispatchQueue.global().async { stderr = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); group.wait(); deadline.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?.lowercased() ?? ""
            if message.contains("docs api is not enabled") {
                throw NSError(domain: "docs API disabled", code: 403)
            }
            let denied = ["403", "insufficient", "permission", "scope", "unauthorized", "invalid_grant"].contains { message.contains($0) }
            // Never propagate stderr: it can contain account identifiers.
            throw NSError(domain: denied ? "permission" : "gog failed", code: Int(process.terminationStatus))
        }
        return data
    }

    private struct Document { let id: String; let url: String; let title: String?; let modifiedTime: Date? }
    private struct FileRecord: Decodable { let id: String; let name: String?; let title: String?; let modifiedTime: String?; let mimeType: String?; let webViewLink: String? }
    private struct Info { let title: String?; let modifiedTime: Date?; let tabID: String?; let tabCount: Int }
    private struct RawTab { let id: String; let title: String?; let text: String }

    private static func parseFiles(_ data: Data) -> [Document]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let raw: [[String: Any]] = (object as? [String: Any])?["files"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let title = (item["name"] as? String) ?? (item["title"] as? String)
            let modified = (item["modifiedTime"] as? String).flatMap(parseDate)
            let url = (item["webViewLink"] as? String) ?? "https://docs.google.com/document/d/\(id)"
            return Document(id: id, url: url, title: title, modifiedTime: modified)
        }
    }

    private static func parseInfo(_ data: Data) -> Info {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Info(title: nil, modifiedTime: nil, tabID: nil, tabCount: 0) }
        let metadata = (object["file"] as? [String: Any]) ?? object
        let tabs = metadata["tabs"] as? [[String: Any]]
        let tabID = tabs?.compactMap { ($0["tabId"] as? String) ?? ($0["id"] as? String) }.first
        return Info(title: (metadata["name"] as? String) ?? (metadata["title"] as? String), modifiedTime: (metadata["modifiedTime"] as? String).flatMap(parseDate), tabID: tabID, tabCount: tabs?.count ?? 0)
    }
    private static func parseRawTabs(_ data: Data) throws -> [RawTab] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "gog.raw", code: 1) }
        var out: [RawTab] = []
        func walk(_ value: Any, inherited: String? = nil) {
            guard let dict = value as? [String: Any] else { return }
            let props = dict["tabProperties"] as? [String: Any]
            let id = (props?["tabId"] as? String) ?? (dict["tabId"] as? String) ?? (dict["id"] as? String) ?? inherited
            let title = (props?["title"] as? String) ?? (dict["title"] as? String)
            var text = ""
            if let s = dict["text"] as? String { text += s + "\n" }
            if let tab = dict["documentTab"] as? [String: Any], let body = tab["body"] as? [String: Any], let content = body["content"] as? [[String: Any]] { for item in content { walkText(item, into: &text) } }
            if let content = dict["content"] as? [[String: Any]] { for item in content { walkText(item, into: &text) } }
            if let id, !text.isEmpty { out.append(RawTab(id: id, title: title, text: normalize(text))) }
            if let children = dict["childTabs"] as? [[String: Any]] { children.forEach { walk($0, inherited: id) } }
            for (key, child) in dict where key != "childTabs" { if let arr = child as? [[String: Any]], key == "tabs" { arr.forEach { walk($0, inherited: id) } } }
        }
        func walkText(_ item: [String: Any], into text: inout String) {
            if let paragraph = item["paragraph"] as? [String: Any], let els = paragraph["elements"] as? [[String: Any]] { els.forEach { walkText($0, into: &text) } }
            if let s = item["textRun"] as? [String: Any], let content = s["content"] as? String { text += content }
            if let s = item["content"] as? [[String: Any]] { s.forEach { walkText($0, into: &text) } }
            if let table = item["table"] as? [String: Any], let rows = table["tableRows"] as? [[String: Any]] {
                for row in rows { for cell in row["tableCells"] as? [[String: Any]] ?? [] { walkText(cell, into: &text) } }
            }
        }
        walk(object)
        guard !out.isEmpty else { throw NSError(domain: "gog.raw", code: 2) }
        return out
    }
    private static func parseDate(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func documentID(from url: String) -> String? {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "docs.google.com",
              let marker = url.range(of: "/document/d/") else { return nil }
        let tail = url[marker.upperBound...]
        let id = tail.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init)
        return id?.isEmpty == false ? id : nil
    }
    /// Meet transcript elapsed markers are anchored to the selected calendar
    /// interval only as an alignment hint, never proof of exact capture time.
    static func transcriptEntries(_ text: String, documentID: String, tabID: String,
                                  url: String, meetingStart: Date) -> [SourceSegment] {
        let stamp = try! NSRegularExpression(pattern: #"^\s*(\d{2}):(\d{2}):(\d{2})\s*$"#)
        let speakerLine = try! NSRegularExpression(pattern: #"^([^:：\n]{1,80})[:：]\s*(.*)$"#)
        var elapsed: Double?
        var name: String?
        var body = ""
        var result: [SourceSegment] = []
        func flush() {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let suffix = String(result.count)
            result.append(SourceSegment(id: documentID + ":" + tabID + ":" + suffix,
                sourceURL: url, locator: tabID + (elapsed.map { ";calendar-relative=\($0)s" } ?? ""),
                text: t, isTranscript: true, capturedAt: elapsed.map { meetingStart.timeIntervalSince1970 + $0 }, speakerName: name))
            body = ""
        }
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = stamp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush(); name = nil
                elapsed = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 3600 +
                    (Double(ns.substring(with: m.range(at: 2))) ?? 0) * 60 +
                    (Double(ns.substring(with: m.range(at: 3))) ?? 0)
            } else if let m = speakerLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush(); name = ns.substring(with: m.range(at: 1)); body = ns.substring(with: m.range(at: 2))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !body.isEmpty { body += "\n" }; body += line
            }
        }
        flush(); return result
    }

    private static func normalize(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func splitSections(_ text: String) -> [String] { text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private static func looksLikeTranscript(_ text: String, title: String?) -> Bool { let s = (title ?? "").lowercased(); return s.contains("transcript") || s.contains("文字起こし") }
    private static func transcriptDigest(_ segments: [SourceSegment]) -> String? { guard !segments.isEmpty else { return nil }; return SHA256.hash(data: Data(segments.map { "\($0.id)|\($0.capturedAt.map { String($0) } ?? "")|\($0.text)" }.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() }
}
