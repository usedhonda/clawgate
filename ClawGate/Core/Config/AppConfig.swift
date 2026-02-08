import Foundation

struct AppConfig: Codable {
    // General
    var debugLogging: Bool
    var includeMessageBodyInLogs: Bool

    // LINE
    var lineDefaultConversation: String
    var linePollIntervalSeconds: Int

    static let `default` = AppConfig(
        debugLogging: false,
        includeMessageBodyInLogs: false,
        lineDefaultConversation: "",
        linePollIntervalSeconds: 2
    )
}

final class ConfigStore {
    private enum Keys {
        static let debugLogging = "clawgate.debugLogging"
        static let includeMessageBodyInLogs = "clawgate.includeMessageBodyInLogs"
        static let lineDefaultConversation = "clawgate.lineDefaultConversation"
        static let linePollIntervalSeconds = "clawgate.linePollIntervalSeconds"
        // Legacy key for migration
        static let legacyPollIntervalSeconds = "clawgate.pollIntervalSeconds"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    func load() -> AppConfig {
        var cfg = AppConfig.default

        if defaults.object(forKey: Keys.debugLogging) != nil {
            cfg.debugLogging = defaults.bool(forKey: Keys.debugLogging)
        }

        if defaults.object(forKey: Keys.includeMessageBodyInLogs) != nil {
            cfg.includeMessageBodyInLogs = defaults.bool(forKey: Keys.includeMessageBodyInLogs)
        }

        if let conv = defaults.string(forKey: Keys.lineDefaultConversation) {
            cfg.lineDefaultConversation = conv
        }

        if defaults.object(forKey: Keys.linePollIntervalSeconds) != nil {
            cfg.linePollIntervalSeconds = max(1, defaults.integer(forKey: Keys.linePollIntervalSeconds))
        }

        return cfg
    }

    func save(_ cfg: AppConfig) {
        defaults.set(cfg.debugLogging, forKey: Keys.debugLogging)
        defaults.set(cfg.includeMessageBodyInLogs, forKey: Keys.includeMessageBodyInLogs)
        defaults.set(cfg.lineDefaultConversation, forKey: Keys.lineDefaultConversation)
        defaults.set(cfg.linePollIntervalSeconds, forKey: Keys.linePollIntervalSeconds)
    }

    /// Migrate legacy "pollIntervalSeconds" key to "linePollIntervalSeconds"
    private func migrateIfNeeded() {
        if defaults.object(forKey: Keys.legacyPollIntervalSeconds) != nil
            && defaults.object(forKey: Keys.linePollIntervalSeconds) == nil
        {
            let value = defaults.integer(forKey: Keys.legacyPollIntervalSeconds)
            defaults.set(value, forKey: Keys.linePollIntervalSeconds)
            defaults.removeObject(forKey: Keys.legacyPollIntervalSeconds)
        }
    }
}
