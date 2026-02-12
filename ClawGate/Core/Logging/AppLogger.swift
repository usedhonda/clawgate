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

    var isDebugEnabled: Bool {
        configStore.load().debugLogging
    }

    func log(_ level: Level, _ message: String) {
        if level == .debug && !isDebugEnabled {
            return
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] [\(level.rawValue.uppercased())] \(message)")
    }
}
