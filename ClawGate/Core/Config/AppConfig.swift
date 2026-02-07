import Foundation

struct AppConfig: Codable {
    var pollIntervalSeconds: Int
    var debugLogging: Bool
    var includeMessageBodyInLogs: Bool

    static let `default` = AppConfig(
        pollIntervalSeconds: 2,
        debugLogging: false,
        includeMessageBodyInLogs: false
    )
}

final class ConfigStore {
    private enum Keys {
        static let pollIntervalSeconds = "clawgate.pollIntervalSeconds"
        static let debugLogging = "clawgate.debugLogging"
        static let includeMessageBodyInLogs = "clawgate.includeMessageBodyInLogs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppConfig {
        var cfg = AppConfig.default

        if defaults.object(forKey: Keys.pollIntervalSeconds) != nil {
            cfg.pollIntervalSeconds = max(1, defaults.integer(forKey: Keys.pollIntervalSeconds))
        }

        if defaults.object(forKey: Keys.debugLogging) != nil {
            cfg.debugLogging = defaults.bool(forKey: Keys.debugLogging)
        }

        if defaults.object(forKey: Keys.includeMessageBodyInLogs) != nil {
            cfg.includeMessageBodyInLogs = defaults.bool(forKey: Keys.includeMessageBodyInLogs)
        }

        return cfg
    }

    func save(_ cfg: AppConfig) {
        defaults.set(cfg.pollIntervalSeconds, forKey: Keys.pollIntervalSeconds)
        defaults.set(cfg.debugLogging, forKey: Keys.debugLogging)
        defaults.set(cfg.includeMessageBodyInLogs, forKey: Keys.includeMessageBodyInLogs)
    }
}
