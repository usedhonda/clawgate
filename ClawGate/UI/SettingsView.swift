import SwiftUI

final class SettingsModel: ObservableObject {
    private let configStore: ConfigStore
    @Published var config: AppConfig

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.config = configStore.load()
    }

    func reload() { config = configStore.load() }
    func save() { configStore.save(config) }
}

struct InlineSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("General")

            Toggle("Debug Logging", isOn: $model.config.debugLogging)
            Toggle("Include Message Body", isOn: $model.config.includeMessageBodyInLogs)

            Divider()
            sectionHeader("LINE")

            HStack {
                Text("Conversation:")
                    .font(.system(size: 11))
                TextField("e.g. John Doe", text: $model.config.lineDefaultConversation)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Stepper("Poll: \(model.config.linePollIntervalSeconds)s",
                    value: $model.config.linePollIntervalSeconds, in: 1...30)

            Divider()
            sectionHeader("Tmux")

            Toggle("Enabled", isOn: $model.config.tmuxEnabled)

            HStack {
                Text("URL:")
                    .font(.system(size: 11))
                TextField("ws://...", text: $model.config.tmuxStatusBarUrl)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
        .frame(width: 280)
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.includeMessageBodyInLogs) { _ in model.save() }
        .onChange(of: model.config.lineDefaultConversation) { _ in model.save() }
        .onChange(of: model.config.linePollIntervalSeconds) { _ in model.save() }
        .onChange(of: model.config.tmuxEnabled) { _ in model.save() }
        .onChange(of: model.config.tmuxStatusBarUrl) { _ in model.save() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}
