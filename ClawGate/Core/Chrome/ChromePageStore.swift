import Foundation

/// Lightweight index entry for a captured page (stored in index.json).
struct CapturedPageMeta: Codable {
    let id: UUID
    let url: String
    let title: String
    let capturedAt: Date
    let snippetID: String
}

/// Full page entry returned by the /v1/chrome/recent-pages API.
struct CapturedPageFull: Codable {
    let id: String
    let url: String
    let title: String
    let capturedAt: String
    let excerpt: String?
}

/// Persists captured web pages to Application Support.
///
/// Layout:
///   ~/Library/Application Support/ClawGate/chrome-pages/
///     index.json         — CapturedPageMeta array (lightweight, max 20)
///     excerpts/<id>.txt  — raw text content per page
///
/// UserDefaults is deliberately NOT used here: page text can be 5-50 KB,
/// multiplied by 20 entries is too large for UserDefaults.
final class ChromePageStore {
    private let maxEntries = 20
    private let pagesDir: URL
    private let excerptDir: URL
    private let indexURL: URL
    private let lock = NSLock()
    private let iso = ISO8601DateFormatter()
    private var cache: [CapturedPageMeta] = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        pagesDir = support.appendingPathComponent("ClawGate/chrome-pages", isDirectory: true)
        excerptDir = pagesDir.appendingPathComponent("excerpts", isDirectory: true)
        indexURL = pagesDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: excerptDir, withIntermediateDirectories: true)
        cache = loadIndex()
    }

    /// Add a captured page. Oldest entry is purged once max is exceeded.
    func add(url: String, title: String, content: String) {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID()
        let excerpt = String(content.prefix(3000))
        let excerptURL = excerptDir.appendingPathComponent("\(id.uuidString).txt")
        try? excerpt.write(to: excerptURL, atomically: true, encoding: .utf8)

        let meta = CapturedPageMeta(id: id, url: url, title: title, capturedAt: Date(), snippetID: id.uuidString)
        cache.insert(meta, at: 0)

        if cache.count > maxEntries {
            let excess = cache.dropFirst(maxEntries)
            for old in excess {
                try? FileManager.default.removeItem(at: excerptDir.appendingPathComponent("\(old.snippetID).txt"))
            }
            cache = Array(cache.prefix(maxEntries))
        }
        saveIndex()
    }

    /// Returns recent pages for the API response.
    /// Index (title+url+timestamp) for all 20, excerpt only for the most recent one.
    func recentForAPI() -> [CapturedPageFull] {
        lock.lock()
        defer { lock.unlock() }
        return cache.enumerated().map { idx, meta in
            let excerpt: String? = idx == 0
                ? (try? String(contentsOf: excerptDir.appendingPathComponent("\(meta.snippetID).txt"), encoding: .utf8))
                : nil
            return CapturedPageFull(
                id: meta.id.uuidString,
                url: meta.url,
                title: meta.title,
                capturedAt: iso.string(from: meta.capturedAt),
                excerpt: excerpt
            )
        }
    }

    private func loadIndex() -> [CapturedPageMeta] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CapturedPageMeta].self, from: data) else {
            return []
        }
        return list
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
