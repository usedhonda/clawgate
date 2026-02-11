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
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("General")

            Picker("Node Role", selection: $model.config.nodeRole) {
                Text("Server (LINE + tmux)").tag(NodeRole.server)
                Text("Client (tmux only)").tag(NodeRole.client)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button("Host A Preset") { applyHostAPreset() }
                Button("Host B Preset") { applyHostBPreset() }
            }
            .buttonStyle(.bordered)

            Toggle("Debug Logging", isOn: $model.config.debugLogging)
            Toggle("Include Message Body", isOn: $model.config.includeMessageBodyInLogs)

            if model.config.nodeRole != .client {
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
            }

            Divider()
            sectionHeader("Tmux")

            Toggle("Enabled", isOn: $model.config.tmuxEnabled)
            if model.config.tmuxEnabled {
                HStack {
                    Text("Status Host:")
                        .font(.system(size: 11))
                    TextField("localhost", text: tmuxStatusHostBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                Stepper("Status Port: \(tmuxStatusPortBinding.wrappedValue)",
                        value: tmuxStatusPortBinding, in: 1...65535)
                Text("Path: /ws/sessions")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if model.config.nodeRole == .client {
                Divider()
                sectionHeader("Remote")

                Toggle("Federation Client", isOn: $model.config.federationEnabled)
                if model.config.federationEnabled {
                    HStack {
                        Text("Host A:")
                            .font(.system(size: 11))
                        TextField("sshmacmini", text: federationHostBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    Stepper("Federation Port: \(federationPortBinding.wrappedValue)",
                            value: federationPortBinding, in: 1...65535)
                    HStack {
                        Text("Token:")
                            .font(.system(size: 11))
                        TextField("optional bearer token", text: $model.config.federationToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    Text("Auto URL: \(model.config.federationURL)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()
            Toggle("Show Advanced", isOn: $showAdvanced)

            if showAdvanced {
                sectionHeader("Advanced")

                Toggle("Remote Access (bind 0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
                HStack {
                    Text("Remote Bearer:")
                        .font(.system(size: 11))
                    TextField("remote access token", text: $model.config.remoteAccessToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                Toggle("Federation Client", isOn: $model.config.federationEnabled)
                HStack {
                    Text("Federation URL:")
                        .font(.system(size: 11))
                    TextField("ws://host:9100/federation", text: $model.config.federationURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                Stepper("Reconnect Max: \(model.config.federationReconnectMaxSeconds)s",
                        value: $model.config.federationReconnectMaxSeconds, in: 5...300)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
        .frame(width: 320)
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

    private var tmuxStatusHostBinding: Binding<String> {
        Binding(
            get: {
                let (host, _) = parseWSURL(model.config.tmuxStatusBarURL, defaultHost: "localhost", defaultPort: 8080)
                return host
            },
            set: { newHost in
                let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
                let (_, port) = parseWSURL(model.config.tmuxStatusBarURL, defaultHost: "localhost", defaultPort: 8080)
                model.config.tmuxStatusBarURL = buildWSURL(host: trimmed.isEmpty ? "localhost" : trimmed,
                                                           port: port,
                                                           path: "/ws/sessions")
            }
        )
    }

    private var tmuxStatusPortBinding: Binding<Int> {
        Binding(
            get: {
                let (_, port) = parseWSURL(model.config.tmuxStatusBarURL, defaultHost: "localhost", defaultPort: 8080)
                return port
            },
            set: { newPort in
                let (host, _) = parseWSURL(model.config.tmuxStatusBarURL, defaultHost: "localhost", defaultPort: 8080)
                model.config.tmuxStatusBarURL = buildWSURL(host: host, port: newPort, path: "/ws/sessions")
            }
        )
    }

    private var federationHostBinding: Binding<String> {
        Binding(
            get: {
                let (host, _) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 9100)
                return host
            },
            set: { newHost in
                let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
                let (_, port) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 9100)
                model.config.federationURL = trimmed.isEmpty ? "" : buildWSURL(host: trimmed, port: port, path: "/federation")
            }
        )
    }

    private var federationPortBinding: Binding<Int> {
        Binding(
            get: {
                let (_, port) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 9100)
                return port
            },
            set: { newPort in
                let (host, _) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 9100)
                guard !host.isEmpty else { return }
                model.config.federationURL = buildWSURL(host: host, port: newPort, path: "/federation")
            }
        )
    }

    private func parseWSURL(_ value: String, defaultHost: String, defaultPort: Int) -> (String, Int) {
        guard let url = URL(string: value),
              let host = url.host, !host.isEmpty else {
            return (defaultHost, defaultPort)
        }
        return (host, url.port ?? defaultPort)
    }

    private func buildWSURL(host: String, port: Int, path: String) -> String {
        "ws://\(host):\(port)\(path)"
    }

    private func applyHostAPreset() {
        model.config.nodeRole = .server
        model.config.tmuxEnabled = true
        model.config.federationEnabled = false
        model.config.federationURL = ""
        model.config.remoteAccessEnabled = false
        if model.config.tmuxStatusBarURL.isEmpty {
            model.config.tmuxStatusBarURL = "ws://localhost:8080/ws/sessions"
        }
        model.save()
    }

    private func applyHostBPreset() {
        model.config.nodeRole = .client
        model.config.tmuxEnabled = true
        model.config.federationEnabled = true
        if model.config.tmuxStatusBarURL.isEmpty {
            model.config.tmuxStatusBarURL = "ws://localhost:8080/ws/sessions"
        }
        if model.config.federationURL.isEmpty {
            model.config.federationURL = "ws://sshmacmini:9100/federation"
        }
        model.save()
    }
}
