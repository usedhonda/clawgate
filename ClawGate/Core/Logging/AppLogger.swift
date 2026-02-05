import Foundation

final class AppLogger {
    enum Level: String {
        case debug
        case info
        case warning
        case error
    }

    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func log(_ level: Level, _ message: String) {
        if level == .debug && !configStore.load().debugLogging {
            return
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] [\(level.rawValue.uppercased())] \(message)")
    }
}
