import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig
    @State private var token: String

    private let configStore: ConfigStore
    private let tokenManager: BridgeTokenManager

    init(configStore: ConfigStore, tokenManager: BridgeTokenManager) {
        self.configStore = configStore
        self.tokenManager = tokenManager
        self._config = State(initialValue: configStore.load())
        self._token = State(initialValue: tokenManager.currentToken())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ClawGate Settings")
                .font(.headline)

            HStack {
                Text("Bridge Token")
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Button("Regenerate") {
                    token = tokenManager.regenerateToken()
                }
            }

            Toggle("Debug Logging", isOn: $config.debugLogging)
            Toggle("Include Message Body in Logs", isOn: $config.includeMessageBodyInLogs)

            Stepper("Poll Interval: \(config.pollIntervalSeconds)s", value: $config.pollIntervalSeconds, in: 1...30)

            HStack {
                Spacer()
                Button("Save") {
                    configStore.save(config)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
