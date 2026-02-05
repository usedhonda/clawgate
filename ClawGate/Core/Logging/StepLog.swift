import Foundation

struct StepLog: Codable {
    let step: String
    let success: Bool
    let durationMs: Int
    let details: String
    let timestamp: String

    init(step: String, success: Bool, durationMs: Int, details: String) {
        self.step = step
        self.success = success
        self.durationMs = durationMs
        self.details = details
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}

final class StepLogger {
    private var items: [StepLog] = []

    func record(step: String, start: Date, success: Bool, details: String) {
        let duration = Int(Date().timeIntervalSince(start) * 1000)
        items.append(StepLog(step: step, success: success, durationMs: duration, details: details))
    }

    func all() -> [StepLog] {
        items
    }
}
