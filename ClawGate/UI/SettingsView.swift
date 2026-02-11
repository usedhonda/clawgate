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
    @State private var tailscalePeers: [TailscalePeer] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("General")

            Picker("Node Role", selection: $model.config.nodeRole) {
                Text("Server (LINE + tmux)").tag(NodeRole.server)
                Text("Client (tmux only)").tag(NodeRole.client)
            }
            .pickerStyle(.segmented)

            Text(model.config.nodeRole == .server
                 ? "Host A: LINE and Gateway run on this machine."
                 : "Host B: tmux and federation client only.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Host A Preset") { applyHostAPreset() }
                Button("Host B Preset") { applyHostBPreset() }
            }
            .buttonStyle(.bordered)

            Toggle("Debug Logging", isOn: $model.config.debugLogging)
            if showAdvanced {
                Toggle("Include Message Body", isOn: $model.config.includeMessageBodyInLogs)
            }

            if model.config.nodeRole == .server {
                serverSection
            } else {
                clientSection
            }

            Divider()
            Toggle("Show Advanced", isOn: $showAdvanced)

            if showAdvanced {
                sectionHeader("Advanced")

                if model.config.nodeRole == .server {
                    Toggle("Remote Access (bind 0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
                    HStack {
                        Text("Remote Bearer:")
                            .font(.system(size: 11))
                        TextField("remote access token", text: $model.config.remoteAccessToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }

                if model.config.nodeRole == .client {
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
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
        .frame(width: 340)
        .onAppear {
            loadTailscalePeers()
        }
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

    private var serverSection: some View {
        Group {
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
            if model.config.tmuxEnabled {
                HStack {
                    Text("Status Host")
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
        }
    }

    private var clientSection: some View {
        Group {
            Divider()
            sectionHeader("Tmux")

            Toggle("Enabled", isOn: $model.config.tmuxEnabled)
            if model.config.tmuxEnabled {
                HStack {
                    Text("Status Host")
                        .font(.system(size: 11))
                    TextField("localhost", text: tmuxStatusHostBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                Stepper("Status Port: \(tmuxStatusPortBinding.wrappedValue)",
                        value: tmuxStatusPortBinding, in: 1...65535)
            }

            Divider()
            sectionHeader("Federation")

            Toggle("Enabled", isOn: $model.config.federationEnabled)
            if model.config.federationEnabled {
                HStack {
                    Text("Host A")
                        .font(.system(size: 11))
                    Picker("", selection: federationPeerSelectionBinding) {
                        Text("Manual").tag("")
                        ForEach(tailscalePeers) { peer in
                            Text(peerLabel(peer)).tag(peer.hostname)
                        }
                    }
                    .labelsHidden()
                }

                if federationPeerSelectionBinding.wrappedValue.isEmpty {
                    TextField("host-a.tailnet.ts.net", text: federationHostBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                Stepper("Federation Port: \(federationPortBinding.wrappedValue)",
                        value: federationPortBinding, in: 1...65535)

                Text("URL: \(model.config.federationURL)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("Refresh Tailscale Hosts") {
                    loadTailscalePeers()
                }
                .buttonStyle(.bordered)

                HStack {
                    Text("Detected:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tailscalePeers.count)")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
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

    private var federationPeerSelectionBinding: Binding<String> {
        Binding(
            get: {
                let host = federationHostBinding.wrappedValue
                return tailscalePeers.contains(where: { $0.hostname == host }) ? host : ""
            },
            set: { selected in
                guard !selected.isEmpty else { return }
                federationHostBinding.wrappedValue = selected
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

    private func peerLabel(_ peer: TailscalePeer) -> String {
        let status = peer.online ? "online" : "offline"
        if peer.ip.isEmpty {
            return "\(peer.hostname) (\(status))"
        }
        return "\(peer.hostname) (\(peer.ip), \(status))"
    }

    private func loadTailscalePeers() {
        tailscalePeers = TailscalePeerService.loadPeers()
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
        let preferredHost = tailscalePeers.first(where: { $0.online })?.hostname
            ?? tailscalePeers.first?.hostname
            ?? "sshmacmini"
        model.config.federationURL = buildWSURL(host: preferredHost, port: 9100, path: "/federation")
        model.save()
    }
}
