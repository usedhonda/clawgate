import Foundation

enum NodeRole: String, Codable, CaseIterable {
    case server
    case client
}

struct AppConfig: Codable {
    // Node role
    var nodeRole: NodeRole

    // General
    var debugLogging: Bool
    var includeMessageBodyInLogs: Bool

    // LINE
    var lineEnabled: Bool
    var lineDefaultConversation: String
    var linePollIntervalSeconds: Int
    var lineDetectionMode: String
    var lineFusionThreshold: Int
    var lineEnablePixelSignal: Bool
    var lineEnableProcessSignal: Bool
    var lineEnableNotificationStoreSignal: Bool

    // Tmux
    var tmuxEnabled: Bool
    var tmuxStatusBarURL: String
    var tmuxSessionModes: [String: String]  // project -> "observe" | "auto" | "autonomous"; absent = ignore

    // Remote / Federation
    var remoteAccessEnabled: Bool
    var remoteAccessToken: String
    var federationEnabled: Bool
    var federationURL: String
    var federationToken: String
    var federationReconnectMaxSeconds: Int

    static let `default` = AppConfig(
        nodeRole: .server,
        debugLogging: false,
        includeMessageBodyInLogs: false,
        lineEnabled: true,
        lineDefaultConversation: "",
        linePollIntervalSeconds: 2,
        lineDetectionMode: "hybrid",
        lineFusionThreshold: 60,
        lineEnablePixelSignal: true,
        lineEnableProcessSignal: false,
        lineEnableNotificationStoreSignal: false,
        tmuxEnabled: false,
        tmuxStatusBarURL: "ws://localhost:8080/ws/sessions",
        tmuxSessionModes: [:],
        remoteAccessEnabled: false,
        remoteAccessToken: "",
        federationEnabled: false,
        federationURL: "",
        federationToken: "",
        federationReconnectMaxSeconds: 60
    )
}

final class ConfigStore {
    private enum Keys {
        static let debugLogging = "clawgate.debugLogging"
        static let nodeRole = "clawgate.nodeRole"
        static let includeMessageBodyInLogs = "clawgate.includeMessageBodyInLogs"
        static let lineEnabled = "clawgate.lineEnabled"
        static let lineDefaultConversation = "clawgate.lineDefaultConversation"
        static let linePollIntervalSeconds = "clawgate.linePollIntervalSeconds"
        static let lineDetectionMode = "clawgate.lineDetectionMode"
        static let lineFusionThreshold = "clawgate.lineFusionThreshold"
        static let lineEnablePixelSignal = "clawgate.lineEnablePixelSignal"
        static let lineEnableProcessSignal = "clawgate.lineEnableProcessSignal"
        static let lineEnableNotificationStoreSignal = "clawgate.lineEnableNotificationStoreSignal"
        // Tmux
        static let tmuxEnabled = "clawgate.tmuxEnabled"
        static let tmuxStatusBarURL = "clawgate.tmuxStatusBarUrl"
        static let tmuxSessionModes = "clawgate.tmuxSessionModes"
        // Remote / Federation
        static let remoteAccessEnabled = "clawgate.remoteAccessEnabled"
        static let remoteAccessToken = "clawgate.remoteAccessToken"
        static let federationEnabled = "clawgate.federationEnabled"
        static let federationURL = "clawgate.federationURL"
        static let federationToken = "clawgate.federationToken"
        static let federationReconnectMaxSeconds = "clawgate.federationReconnectMaxSeconds"
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
        if let roleRaw = defaults.string(forKey: Keys.nodeRole),
           let role = NodeRole(rawValue: roleRaw) {
            cfg.nodeRole = role
        }

        if defaults.object(forKey: Keys.includeMessageBodyInLogs) != nil {
            cfg.includeMessageBodyInLogs = defaults.bool(forKey: Keys.includeMessageBodyInLogs)
        }

        if defaults.object(forKey: Keys.lineEnabled) != nil {
            cfg.lineEnabled = defaults.bool(forKey: Keys.lineEnabled)
        }

        if let conv = defaults.string(forKey: Keys.lineDefaultConversation) {
            cfg.lineDefaultConversation = conv
        }

        if defaults.object(forKey: Keys.linePollIntervalSeconds) != nil {
            cfg.linePollIntervalSeconds = max(1, defaults.integer(forKey: Keys.linePollIntervalSeconds))
        }
        if let mode = defaults.string(forKey: Keys.lineDetectionMode), !mode.isEmpty {
            cfg.lineDetectionMode = mode
        }
        if defaults.object(forKey: Keys.lineFusionThreshold) != nil {
            cfg.lineFusionThreshold = min(100, max(1, defaults.integer(forKey: Keys.lineFusionThreshold)))
        }
        if defaults.object(forKey: Keys.lineEnablePixelSignal) != nil {
            cfg.lineEnablePixelSignal = defaults.bool(forKey: Keys.lineEnablePixelSignal)
        }
        if defaults.object(forKey: Keys.lineEnableProcessSignal) != nil {
            cfg.lineEnableProcessSignal = defaults.bool(forKey: Keys.lineEnableProcessSignal)
        }
        if defaults.object(forKey: Keys.lineEnableNotificationStoreSignal) != nil {
            cfg.lineEnableNotificationStoreSignal = defaults.bool(forKey: Keys.lineEnableNotificationStoreSignal)
        }

        // Tmux
        if defaults.object(forKey: Keys.tmuxEnabled) != nil {
            cfg.tmuxEnabled = defaults.bool(forKey: Keys.tmuxEnabled)
        }
        if let statusBarURL = defaults.string(forKey: Keys.tmuxStatusBarURL), !statusBarURL.isEmpty {
            cfg.tmuxStatusBarURL = statusBarURL
        }
        if let json = defaults.string(forKey: Keys.tmuxSessionModes),
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cfg.tmuxSessionModes = dict
        }

        // Remote / Federation
        if defaults.object(forKey: Keys.remoteAccessEnabled) != nil {
            cfg.remoteAccessEnabled = defaults.bool(forKey: Keys.remoteAccessEnabled)
        }
        if let token = defaults.string(forKey: Keys.remoteAccessToken) {
            cfg.remoteAccessToken = token
        }
        if defaults.object(forKey: Keys.federationEnabled) != nil {
            cfg.federationEnabled = defaults.bool(forKey: Keys.federationEnabled)
        }
        if let url = defaults.string(forKey: Keys.federationURL) {
            cfg.federationURL = url
        }
        if let token = defaults.string(forKey: Keys.federationToken) {
            cfg.federationToken = token
        }
        if defaults.object(forKey: Keys.federationReconnectMaxSeconds) != nil {
            cfg.federationReconnectMaxSeconds = min(300, max(5, defaults.integer(forKey: Keys.federationReconnectMaxSeconds)))
        }

        // Backward-compat: when federation token is unset, reuse remote access token.
        if cfg.federationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cfg.federationToken = cfg.remoteAccessToken
        }

        return cfg
    }

    func save(_ cfg: AppConfig) {
        defaults.set(cfg.debugLogging, forKey: Keys.debugLogging)
        defaults.set(cfg.nodeRole.rawValue, forKey: Keys.nodeRole)
        defaults.set(cfg.includeMessageBodyInLogs, forKey: Keys.includeMessageBodyInLogs)
        defaults.set(cfg.lineEnabled, forKey: Keys.lineEnabled)
        defaults.set(cfg.lineDefaultConversation, forKey: Keys.lineDefaultConversation)
        defaults.set(cfg.linePollIntervalSeconds, forKey: Keys.linePollIntervalSeconds)
        defaults.set(cfg.lineDetectionMode, forKey: Keys.lineDetectionMode)
        defaults.set(cfg.lineFusionThreshold, forKey: Keys.lineFusionThreshold)
        defaults.set(cfg.lineEnablePixelSignal, forKey: Keys.lineEnablePixelSignal)
        defaults.set(cfg.lineEnableProcessSignal, forKey: Keys.lineEnableProcessSignal)
        defaults.set(cfg.lineEnableNotificationStoreSignal, forKey: Keys.lineEnableNotificationStoreSignal)
        // Tmux
        defaults.set(cfg.tmuxEnabled, forKey: Keys.tmuxEnabled)
        defaults.set(cfg.tmuxStatusBarURL, forKey: Keys.tmuxStatusBarURL)
        if let json = try? JSONEncoder().encode(cfg.tmuxSessionModes),
           let str = String(data: json, encoding: .utf8) {
            defaults.set(str, forKey: Keys.tmuxSessionModes)
        }
        // Remote / Federation
        defaults.set(cfg.remoteAccessEnabled, forKey: Keys.remoteAccessEnabled)
        defaults.set(cfg.remoteAccessToken, forKey: Keys.remoteAccessToken)
        defaults.set(cfg.federationEnabled, forKey: Keys.federationEnabled)
        defaults.set(cfg.federationURL, forKey: Keys.federationURL)
        defaults.set(cfg.federationToken, forKey: Keys.federationToken)
        defaults.set(cfg.federationReconnectMaxSeconds, forKey: Keys.federationReconnectMaxSeconds)
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
