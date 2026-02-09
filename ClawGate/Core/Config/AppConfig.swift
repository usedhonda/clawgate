import Foundation

struct AppConfig: Codable {
    // General
    var debugLogging: Bool
    var includeMessageBodyInLogs: Bool

    // LINE
    var lineDefaultConversation: String
    var linePollIntervalSeconds: Int

    // Tmux
    var tmuxEnabled: Bool
    var tmuxStatusBarUrl: String
    var tmuxSessionModes: [String: String]  // project -> "observe" | "auto" | "autonomous"; absent = ignore

    static let `default` = AppConfig(
        debugLogging: false,
        includeMessageBodyInLogs: false,
        lineDefaultConversation: "",
        linePollIntervalSeconds: 2,
        tmuxEnabled: false,
        tmuxStatusBarUrl: "ws://localhost:8080/ws/sessions",
        tmuxSessionModes: [:]
    )
}

final class ConfigStore {
    private enum Keys {
        static let debugLogging = "clawgate.debugLogging"
        static let includeMessageBodyInLogs = "clawgate.includeMessageBodyInLogs"
        static let lineDefaultConversation = "clawgate.lineDefaultConversation"
        static let linePollIntervalSeconds = "clawgate.linePollIntervalSeconds"
        // Tmux
        static let tmuxEnabled = "clawgate.tmuxEnabled"
        static let tmuxStatusBarUrl = "clawgate.tmuxStatusBarUrl"
        static let tmuxSessionModes = "clawgate.tmuxSessionModes"
        // Legacy keys for migration
        static let legacyPollIntervalSeconds = "clawgate.pollIntervalSeconds"
        static let legacyTmuxAllowedSessions = "clawgate.tmuxAllowedSessions"
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

        // Tmux
        if defaults.object(forKey: Keys.tmuxEnabled) != nil {
            cfg.tmuxEnabled = defaults.bool(forKey: Keys.tmuxEnabled)
        }
        if let url = defaults.string(forKey: Keys.tmuxStatusBarUrl), !url.isEmpty {
            cfg.tmuxStatusBarUrl = url
        }
        if let json = defaults.string(forKey: Keys.tmuxSessionModes),
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cfg.tmuxSessionModes = dict
        }

        return cfg
    }

    func save(_ cfg: AppConfig) {
        defaults.set(cfg.debugLogging, forKey: Keys.debugLogging)
        defaults.set(cfg.includeMessageBodyInLogs, forKey: Keys.includeMessageBodyInLogs)
        defaults.set(cfg.lineDefaultConversation, forKey: Keys.lineDefaultConversation)
        defaults.set(cfg.linePollIntervalSeconds, forKey: Keys.linePollIntervalSeconds)
        // Tmux
        defaults.set(cfg.tmuxEnabled, forKey: Keys.tmuxEnabled)
        defaults.set(cfg.tmuxStatusBarUrl, forKey: Keys.tmuxStatusBarUrl)
        if let json = try? JSONEncoder().encode(cfg.tmuxSessionModes),
           let str = String(data: json, encoding: .utf8) {
            defaults.set(str, forKey: Keys.tmuxSessionModes)
        }
    }

    private func migrateIfNeeded() {
        // Migrate legacy "pollIntervalSeconds" key to "linePollIntervalSeconds"
        if defaults.object(forKey: Keys.legacyPollIntervalSeconds) != nil
            && defaults.object(forKey: Keys.linePollIntervalSeconds) == nil
        {
            let value = defaults.integer(forKey: Keys.legacyPollIntervalSeconds)
            defaults.set(value, forKey: Keys.linePollIntervalSeconds)
            defaults.removeObject(forKey: Keys.legacyPollIntervalSeconds)
        }

        // Migrate legacy "tmuxAllowedSessions" [String] to "tmuxSessionModes" [String: String]
        if defaults.object(forKey: Keys.legacyTmuxAllowedSessions) != nil
            && defaults.object(forKey: Keys.tmuxSessionModes) == nil
        {
            if let json = defaults.string(forKey: Keys.legacyTmuxAllowedSessions),
               let data = json.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                var modes: [String: String] = [:]
                for project in arr {
                    modes[project] = "autonomous"
                }
                if let encoded = try? JSONEncoder().encode(modes),
                   let str = String(data: encoded, encoding: .utf8) {
                    defaults.set(str, forKey: Keys.tmuxSessionModes)
                }
            }
            defaults.removeObject(forKey: Keys.legacyTmuxAllowedSessions)
        }
    }
}
