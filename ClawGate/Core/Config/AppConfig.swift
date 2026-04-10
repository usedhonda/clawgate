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
    var tmuxStatusBarURL: String
    var tmuxSessionModes: [String: String]  // project -> "observe" | "auto" | "autonomous"; absent = ignore

    // OCR
    var ocrConfidenceAccept: Double
    var ocrConfidenceFallback: Double
    var ocrRevision: Int
    var ocrUsesLanguageCorrection: Bool
    var ocrCandidateCount: Int

    // OpenClaw Gateway endpoint (the Gateway VibeTerm should connect to)
    var openclawHost: String
    var openclawPort: Int

    // Federation (vestigial — kept only for one-shot migration into openclawHost)
    var federationEnabled: Bool
    var federationURL: String
    var federationToken: String
    var federationReconnectMaxSeconds: Int

    /// Build a composite key for tmuxSessionModes: "cc:project" or "codex:project".
    static func modeKey(sessionType: String, project: String) -> String {
        let prefix = sessionType == "codex" ? "codex" : "cc"
        return "\(prefix):\(project)"
    }

    static let `default` = AppConfig(
        nodeRole: .client,
        debugLogging: false,
        includeMessageBodyInLogs: false,
        lineEnabled: true,
        lineDefaultConversation: "",
        linePollIntervalSeconds: 1,
        lineDetectionMode: "hybrid",
        lineFusionThreshold: 60,
        lineEnablePixelSignal: true,
        lineEnableProcessSignal: false,
        lineEnableNotificationStoreSignal: false,
        tmuxStatusBarURL: "ws://localhost:8080/ws/sessions",
        tmuxSessionModes: [:],
        ocrConfidenceAccept: 0.40,
        ocrConfidenceFallback: 0.25,
        ocrRevision: 0,
        ocrUsesLanguageCorrection: true,
        ocrCandidateCount: 3,
        openclawHost: "127.0.0.1",
        openclawPort: 18789,
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
        static let tmuxStatusBarURL = "clawgate.tmuxStatusBarUrl"
        static let tmuxSessionModes = "clawgate.tmuxSessionModes"
        // OCR
        static let ocrConfidenceAccept = "clawgate.ocrConfidenceAccept"
        static let ocrConfidenceFallback = "clawgate.ocrConfidenceFallback"
        static let ocrRevision = "clawgate.ocrRevision"
        static let ocrUsesLanguageCorrection = "clawgate.ocrUsesLanguageCorrection"
        static let ocrCandidateCount = "clawgate.ocrCandidateCount"
        // OpenClaw Gateway endpoint
        static let openclawHost = "clawgate.openclawHost"
        static let openclawPort = "clawgate.openclawPort"
        // Federation (vestigial, only read for migration)
        static let federationEnabled = "clawgate.federationEnabled"
        static let federationURL = "clawgate.federationURL"
        static let federationToken = "clawgate.federationToken"
        static let federationReconnectMaxSeconds = "clawgate.federationReconnectMaxSeconds"
        // Legacy: removed token field (still cleaned up on save)
        static let legacyRemoteAccessToken = "clawgate.remoteAccessToken"
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
        if let statusBarURL = defaults.string(forKey: Keys.tmuxStatusBarURL), !statusBarURL.isEmpty {
            cfg.tmuxStatusBarURL = statusBarURL
        }
        if let json = defaults.string(forKey: Keys.tmuxSessionModes),
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cfg.tmuxSessionModes = dict
        }

        // OCR
        if defaults.object(forKey: Keys.ocrConfidenceAccept) != nil {
            cfg.ocrConfidenceAccept = max(0.10, min(0.90, defaults.double(forKey: Keys.ocrConfidenceAccept)))
        }
        if defaults.object(forKey: Keys.ocrConfidenceFallback) != nil {
            cfg.ocrConfidenceFallback = max(0.05, min(0.50, defaults.double(forKey: Keys.ocrConfidenceFallback)))
        }
        if defaults.object(forKey: Keys.ocrRevision) != nil {
            cfg.ocrRevision = max(0, min(3, defaults.integer(forKey: Keys.ocrRevision)))
        }
        if defaults.object(forKey: Keys.ocrUsesLanguageCorrection) != nil {
            cfg.ocrUsesLanguageCorrection = defaults.bool(forKey: Keys.ocrUsesLanguageCorrection)
        }
        if defaults.object(forKey: Keys.ocrCandidateCount) != nil {
            cfg.ocrCandidateCount = max(1, min(10, defaults.integer(forKey: Keys.ocrCandidateCount)))
        }

        // OpenClaw Gateway endpoint
        if let host = defaults.string(forKey: Keys.openclawHost),
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cfg.openclawHost = host
        }
        if defaults.object(forKey: Keys.openclawPort) != nil {
            let port = defaults.integer(forKey: Keys.openclawPort)
            if port > 0 && port < 65536 {
                cfg.openclawPort = port
            }
        }

        // Federation (vestigial)
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

        return cfg
    }

    func save(_ cfg: AppConfig) {
        defaults.set(cfg.debugLogging, forKey: Keys.debugLogging)
        defaults.removeObject(forKey: Keys.nodeRole)
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
        defaults.removeObject(forKey: Keys.tmuxStatusBarURL)
        if let json = try? JSONEncoder().encode(cfg.tmuxSessionModes),
           let str = String(data: json, encoding: .utf8) {
            defaults.set(str, forKey: Keys.tmuxSessionModes)
        }
        // OCR
        defaults.set(cfg.ocrConfidenceAccept, forKey: Keys.ocrConfidenceAccept)
        defaults.set(cfg.ocrConfidenceFallback, forKey: Keys.ocrConfidenceFallback)
        defaults.set(cfg.ocrRevision, forKey: Keys.ocrRevision)
        defaults.set(cfg.ocrUsesLanguageCorrection, forKey: Keys.ocrUsesLanguageCorrection)
        defaults.set(cfg.ocrCandidateCount, forKey: Keys.ocrCandidateCount)
        // OpenClaw Gateway endpoint
        defaults.set(cfg.openclawHost, forKey: Keys.openclawHost)
        defaults.set(cfg.openclawPort, forKey: Keys.openclawPort)
        // Federation (vestigial — purge on save)
        defaults.removeObject(forKey: Keys.federationEnabled)
        defaults.removeObject(forKey: Keys.federationURL)
        defaults.removeObject(forKey: Keys.federationToken)
        defaults.removeObject(forKey: Keys.federationReconnectMaxSeconds)
        // Legacy token field — purge so it cannot resurface
        defaults.removeObject(forKey: Keys.legacyRemoteAccessToken)
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

        // Migrate bare project keys to "cc:project" composite keys
        if let json = defaults.string(forKey: Keys.tmuxSessionModes),
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            let needsMigration = dict.keys.contains(where: { !$0.contains(":") })
            if needsMigration {
                var migrated: [String: String] = [:]
                for (key, value) in dict {
                    if key.contains(":") {
                        migrated[key] = value
                    } else {
                        migrated["cc:\(key)"] = value
                    }
                }
                if let encoded = try? JSONEncoder().encode(migrated),
                   let str = String(data: encoded, encoding: .utf8) {
                    defaults.set(str, forKey: Keys.tmuxSessionModes)
                }
            }
        }

        // One-shot migration: legacy federationURL -> openclawHost.
        // Old picker stored "ws://<host>:8765/federation"; extract <host> and put it
        // into the new openclawHost field, then purge the legacy key.
        if defaults.object(forKey: Keys.openclawHost) == nil,
           let oldURL = defaults.string(forKey: Keys.federationURL),
           let parsed = URL(string: oldURL),
           let extractedHost = parsed.host,
           !extractedHost.isEmpty {
            defaults.set(extractedHost, forKey: Keys.openclawHost)
        }
        defaults.removeObject(forKey: Keys.federationURL)
        defaults.removeObject(forKey: Keys.federationEnabled)
        defaults.removeObject(forKey: Keys.federationToken)
        defaults.removeObject(forKey: Keys.federationReconnectMaxSeconds)

        // Purge the legacy remoteAccessToken UserDefault so it cannot resurface.
        defaults.removeObject(forKey: Keys.legacyRemoteAccessToken)
    }
}
