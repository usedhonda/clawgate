import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig

    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self._config = State(initialValue: configStore.load())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClawGate Settings")
                .font(.headline)

            GroupBox(label: Text("General")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Debug Logging", isOn: $config.debugLogging)
                    Toggle("Include Message Body in Logs", isOn: $config.includeMessageBodyInLogs)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Text("LINE")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Default Conversation:")
                        TextField("e.g. John Doe", text: $config.lineDefaultConversation)
                            .textFieldStyle(.roundedBorder)
                    }
                    Stepper("Poll Interval: \(config.linePollIntervalSeconds)s", value: $config.linePollIntervalSeconds, in: 1...30)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Text("Tmux")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enabled", isOn: $config.tmuxEnabled)
                    HStack {
                        Text("Status Bar URL:")
                        TextField("ws://localhost:8080/ws/sessions", text: $config.tmuxStatusBarUrl)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Session selection is in the menu bar submenu.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

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
