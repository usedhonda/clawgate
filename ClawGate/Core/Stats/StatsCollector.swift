import Foundation

struct RecentEvent {
    let timestamp: Date
    let icon: String      // "←", "→", "⚡", "?", "~"
    let label: String     // "received", "sent", "completion", "question", "echo"
    let textPreview: String
    let adapter: String
}

struct DayStats: Codable {
    var lineSent: Int = 0
    var lineReceived: Int = 0
    var lineEcho: Int = 0
    var tmuxSent: Int = 0
    var tmuxCompletion: Int = 0
    var tmuxQuestion: Int = 0
    var apiRequests: Int = 0
    var firstEventAt: String?
    var lastEventAt: String?

    enum CodingKeys: String, CodingKey {
        case lineSent = "line_sent"
        case lineReceived = "line_received"
        case lineEcho = "line_echo"
        case tmuxSent = "tmux_sent"
        case tmuxCompletion = "tmux_completion"
        case tmuxQuestion = "tmux_question"
        case apiRequests = "api_requests"
        case firstEventAt = "first_event_at"
        case lastEventAt = "last_event_at"
    }
}

final class StatsCollector {
    private let lock = NSLock()
    private var days: [String: DayStats] = [:]
    private let filePath: String
    private let maxDays = 90
    private var recentEventBuffer: [RecentEvent] = []
    private let maxRecentEvents = 10

    private static let iso = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    init(filePath: String? = nil) {
        if let filePath {
            self.filePath = filePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("ClawGate")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.filePath = dir.appendingPathComponent("stats.json").path
        }
        load()
    }

    func increment(_ metric: String, adapter: String) {
        lock.lock()
        defer { lock.unlock() }

        let key = todayKey()
        var stats = days[key] ?? DayStats()
        let now = Self.iso.string(from: Date())

        if stats.firstEventAt == nil { stats.firstEventAt = now }
        stats.lastEventAt = now

        switch (metric, adapter) {
        case ("sent", "line"):       stats.lineSent += 1
        case ("sent", "tmux"):       stats.tmuxSent += 1
        case ("received", "line"):   stats.lineReceived += 1
        case ("received", "tmux"):   break // handled by source below
        case ("echo", "line"):       stats.lineEcho += 1
        case ("completion", "tmux"): stats.tmuxCompletion += 1
        case ("question", "tmux"):   stats.tmuxQuestion += 1
        case ("api_requests", _):    stats.apiRequests += 1
        default: break
        }

        days[key] = stats
        saveUnlocked()
    }

    func today() -> DayStats {
        lock.lock()
        defer { lock.unlock() }
        return days[todayKey()] ?? DayStats()
    }

    func history(count: Int) -> [(String, DayStats)] {
        lock.lock()
        defer { lock.unlock() }

        let todayStr = todayKey()
        return days
            .filter { $0.key != todayStr }
            .sorted { $0.key > $1.key }
            .prefix(min(count, maxDays))
            .map { ($0.key, $0.value) }
    }

    func handleEvent(_ event: BridgeEvent) {
        switch event.type {
        case "inbound_message":
            let source = event.payload["source"] ?? ""
            let rawText = event.payload["text"] ?? ""
            let sender = event.payload["sender"] ?? ""
            if event.adapter == "line" {
                increment("received", adapter: "line")
                let displayText = Self.extractLastMessage(from: rawText, source: source)
                let label = sender.isEmpty ? "received" : sender
                appendRecentEvent(icon: "\u{2190}", label: label, text: displayText, adapter: "line")
            } else if event.adapter == "tmux" {
                if source == "completion" {
                    increment("completion", adapter: "tmux")
                    let project = event.payload["project"] ?? "tmux"
                    let displayText = rawText.isEmpty ? "(completion)" : rawText
                    appendRecentEvent(icon: "\u{26A1}", label: "completion:\(project)", text: displayText, adapter: "tmux")
                } else if source == "question" {
                    increment("question", adapter: "tmux")
                    let project = event.payload["project"] ?? "tmux"
                    let questionText = event.payload["question_text"] ?? rawText
                    let displayText = questionText.isEmpty ? "(question)" : questionText
                    appendRecentEvent(icon: "?", label: "question:\(project)", text: displayText, adapter: "tmux")
                }
                // progress events are excluded (noise)
            }
        case "outbound_message":
            let text = event.payload["text"] ?? ""
            appendRecentEvent(icon: "\u{2192}", label: "sent", text: text, adapter: event.adapter)
        case "echo_message":
            if event.adapter == "line" {
                increment("echo", adapter: "line")
                // echo = our sent message detected back; skip timeline (already shown as → sent)
            }
        default:
            break
        }
    }

    /// Extract the last meaningful message line from a chat dump.
    /// notification_banner source already has clean text; hybrid_fusion has the entire visible chat.
    private static func extractLastMessage(from text: String, source: String) -> String {
        // Banner text is already a single message
        if source == "notification_banner" { return text }

        // For hybrid_fusion / legacy: text is the entire visible chat area.
        // Extract the last non-trivial line.
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                && line != "\u{65E2}\u{8AAD}"  // 既読
                && !Self.isTimestampLine(line)
            }
        return lines.last ?? String(text.prefix(50))
    }

    private static func isTimestampLine(_ line: String) -> Bool {
        // "午前 HH:MM" or "午後 HH:MM"
        if line.hasPrefix("\u{5348}\u{524D} ") || line.hasPrefix("\u{5348}\u{5F8C} ") {
            return true
        }
        // Pure time like "10:37"
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped.count <= 5, stripped.contains(":"),
           stripped.allSatisfy({ $0.isNumber || $0 == ":" }) {
            return true
        }
        return false
    }

    func recentTimeline(count: Int) -> [RecentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentEventBuffer.suffix(count).reversed())
    }

    private func appendRecentEvent(icon: String, label: String, text: String, adapter: String) {
        lock.lock()
        defer { lock.unlock() }
        let event = RecentEvent(
            timestamp: Date(),
            icon: icon,
            label: label,
            textPreview: text,
            adapter: adapter
        )
        recentEventBuffer.append(event)
        if recentEventBuffer.count > maxRecentEvents {
            recentEventBuffer.removeFirst(recentEventBuffer.count - maxRecentEvents)
        }
    }

    // MARK: - Persistence

    private func todayKey() -> String {
        Self.dayFormatter.string(from: Date())
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }

        guard let data = FileManager.default.contents(atPath: filePath),
              let container = try? JSONDecoder().decode(StatsFile.self, from: data) else {
            days = [:]
            return
        }
        days = container.days
        pruneOldUnlocked()
    }

    private func saveUnlocked() {
        let container = StatsFile(days: days)
        guard let data = try? JSONEncoder().encode(container) else { return }
        FileManager.default.createFile(atPath: filePath, contents: data)
    }

    private func pruneOldUnlocked() {
        guard days.count > maxDays else { return }
        let sorted = days.keys.sorted()
        let toRemove = sorted.prefix(days.count - maxDays)
        for key in toRemove {
            days.removeValue(forKey: key)
        }
    }
}

private struct StatsFile: Codable {
    let days: [String: DayStats]
}
