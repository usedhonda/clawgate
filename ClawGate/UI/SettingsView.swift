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

            Picker("Node Role", selection: $model.config.nodeRole) {
                Text("Server (LINE + tmux)").tag(NodeRole.server)
                Text("Client (tmux only)").tag(NodeRole.client)
            }
            .pickerStyle(.segmented)

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
                Text("Status WS:")
                    .font(.system(size: 11))
                TextField("ws://localhost:8080/ws/sessions", text: $model.config.tmuxStatusBarURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Divider()
            sectionHeader("Remote")

            Toggle("Remote Access (bind 0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
            HStack {
                Text("Bearer:")
                    .font(.system(size: 11))
                TextField("remote access token", text: $model.config.remoteAccessToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Toggle("Federation Client", isOn: $model.config.federationEnabled)
            HStack {
                Text("Federation URL:")
                    .font(.system(size: 11))
                TextField("ws://remote:9100/federation", text: $model.config.federationURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            HStack {
                Text("Federation Token:")
                    .font(.system(size: 11))
                TextField("optional bearer token", text: $model.config.federationToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            Stepper("Reconnect Max: \(model.config.federationReconnectMaxSeconds)s",
                    value: $model.config.federationReconnectMaxSeconds, in: 5...300)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
        .frame(width: 280)
        .onChange(of: model.config.nodeRole) { _ in model.save() }
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.includeMessageBodyInLogs) { _ in model.save() }
        .onChange(of: model.config.lineDefaultConversation) { _ in model.save() }
        .onChange(of: model.config.linePollIntervalSeconds) { _ in model.save() }
        .onChange(of: model.config.tmuxEnabled) { _ in model.save() }
        .onChange(of: model.config.tmuxStatusBarURL) { _ in model.save() }
        .onChange(of: model.config.remoteAccessEnabled) { _ in model.save() }
        .onChange(of: model.config.remoteAccessToken) { _ in model.save() }
        .onChange(of: model.config.federationEnabled) { _ in model.save() }
        .onChange(of: model.config.federationURL) { _ in model.save() }
        .onChange(of: model.config.federationToken) { _ in model.save() }
        .onChange(of: model.config.federationReconnectMaxSeconds) { _ in model.save() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}
