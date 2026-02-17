import SwiftUI
import Network
import Foundation
import ServiceManagement

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
    private enum ConnectivityState {
        case unknown
        case checking
        case online
        case offline

        var color: Color {
            switch self {
            case .online: return .green
            case .offline: return .red
            case .checking: return .orange
            case .unknown: return .gray
            }
        }

        var text: String {
            switch self {
            case .online: return "Connected"
            case .offline: return "Disconnected"
            case .checking: return "Checking"
            case .unknown: return "Idle"
            }
        }
    }

    @ObservedObject var model: SettingsModel
    @State private var tailscalePeers: [TailscalePeer] = []
    @State private var tmuxState: ConnectivityState = .unknown
    @State private var federationState: ConnectivityState = .unknown
    @State private var probeTimer: Timer?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                headerCard
                if model.config.nodeRole == .server {
                    serverSection
                } else {
                    clientSection
                }
            }
            .padding(12)
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .frame(width: 430)
        .onAppear {
            loadTailscalePeers()
            refreshConnectivity()
            startProbeTimer()
        }
        .onDisappear {
            stopProbeTimer()
        }
        .onChange(of: model.config.nodeRole) { _ in
            applyRecommendedIfNeeded()
            model.save()
        }
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.lineEnabled) { _ in model.save() }
        .onChange(of: model.config.lineDefaultConversation) { _ in model.save() }
        .onChange(of: model.config.linePollIntervalSeconds) { _ in model.save() }
        .onChange(of: model.config.tmuxEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.tmuxStatusBarURL) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.federationEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.federationURL) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.federationToken) { _ in model.save() }
        .onChange(of: model.config.remoteAccessEnabled) { _ in model.save() }
    }

    private var headerCard: some View {
        card("ClawGate", subtitle: model.config.nodeRole == .server ? "Server" : "Client") {
            Picker("Role", selection: $model.config.nodeRole) {
                Text("Server").tag(NodeRole.server)
                Text("Client").tag(NodeRole.client)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button("Apply Recommended") {
                    applyRecommended(force: true)
                }
                .buttonStyle(.bordered)

                Text("Tailscale LAN defaults")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var serverSection: some View {
        Group {
            card("Tmux") {
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            card("LINE") {
                Toggle("Enabled", isOn: $model.config.lineEnabled)
                if model.config.lineEnabled {
                    fieldRow("Conversation") {
                        TextField("e.g. John Doe", text: $model.config.lineDefaultConversation)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    Stepper("Poll: \(model.config.linePollIntervalSeconds)s",
                            value: $model.config.linePollIntervalSeconds, in: 1...30)
                }
            }

            card("Federation") {
                Toggle("Enabled", isOn: $model.config.federationEnabled)
                if model.config.federationEnabled {
                    Toggle("Remote Access (0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
                    if !model.config.remoteAccessEnabled {
                        Text("Remote Access is off — only local clients can connect")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    statusRow(state: federationState)
                    Text("Accepting clients on ws://\(model.config.remoteAccessEnabled ? "0.0.0.0" : "127.0.0.1"):8765/federation")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    fieldRow("Token") {
                        SecureField("federation token", text: $model.config.federationToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }
            }

            card("System") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }
        }
    }

    private var clientSection: some View {
        Group {
            card("Tmux") {
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            card("Federation") {
                Toggle("Enabled", isOn: $model.config.federationEnabled)
                if model.config.federationEnabled {
                    statusRow(state: federationState)
                    fieldRow("Server") {
                        Menu {
                            Button("Manual") {
                                model.config.federationURL = ""
                            }
                            Divider()
                            ForEach(tailscalePeers) { peer in
                                Button(peerShortLabel(peer)) {
                                    federationHostBinding.wrappedValue = peer.hostname
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedServerLabel())
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }

                    if federationPeerSelectionBinding.wrappedValue.isEmpty {
                        TextField("server.tailnet.ts.net", text: federationHostBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    HStack(spacing: 8) {
                        Button("Refresh Hosts") {
                            loadTailscalePeers()
                        }
                        .buttonStyle(.bordered)

                        Text("Detected: \(tailscalePeers.count)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            card("System") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }
        }
    }

    @available(macOS 13.0, *)
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                SMAppService.mainApp.status == .enabled
            },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("[ERROR] Launch at login \(newValue ? "register" : "unregister") failed: \(error)")
                }
            }
        )
    }

    private func card<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            content()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        )
    }

    private func statusRow(state: ConnectivityState) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.5), in: Capsule())
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private var federationHostBinding: Binding<String> {
        Binding(
            get: {
                let (host, _) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 8765)
                return host
            },
            set: { newHost in
                let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
                model.config.federationURL = trimmed.isEmpty ? "" : buildWSURL(host: trimmed, port: 8765, path: "/federation")
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
                if selected.isEmpty {
                    model.config.federationURL = ""
                    return
                }
                federationHostBinding.wrappedValue = selected
            }
        )
    }

    private func parseWSURL(_ value: String, defaultHost: String, defaultPort: Int) -> (String, Int) {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return (defaultHost, defaultPort)
        }
        return (host, url.port ?? defaultPort)
    }

    private func buildWSURL(host: String, port: Int, path: String) -> String {
        "ws://\(host):\(port)\(path)"
    }

    private func peerShortLabel(_ peer: TailscalePeer) -> String {
        let status = peer.online ? "online" : "offline"
        return "\(peer.hostname) (\(status))"
    }

    private func loadTailscalePeers() {
        tailscalePeers = TailscalePeerService.loadPeers()
    }

    private func selectedServerLabel() -> String {
        let selected = federationPeerSelectionBinding.wrappedValue
        if selected.isEmpty { return "Manual (select server)" }
        if let peer = tailscalePeers.first(where: { $0.hostname == selected }) {
            return peerShortLabel(peer)
        }
        return selected
    }

    private func applyRecommended(force: Bool = false) {
        if force || model.config.tmuxStatusBarURL.isEmpty {
            model.config.tmuxStatusBarURL = "ws://localhost:8080/ws/sessions"
        }

        switch model.config.nodeRole {
        case .server:
            if force || !model.config.lineEnabled {
                model.config.lineEnabled = true
            }
            if force || !model.config.federationEnabled {
                model.config.federationEnabled = true
            }
            // Server mode: federationURL is not needed (we're the acceptor)
            if force || !model.config.tmuxEnabled {
                model.config.tmuxEnabled = true
            }
            if force || !model.config.remoteAccessEnabled {
                model.config.remoteAccessEnabled = true
            }
        case .client:
            if force || !model.config.tmuxEnabled {
                model.config.tmuxEnabled = true
            }
            if force || !model.config.federationEnabled {
                model.config.federationEnabled = true
            }
            if force || model.config.lineEnabled {
                model.config.lineEnabled = false
            }
            if force || model.config.federationURL.isEmpty {
                let preferredHost = tailscalePeers.first(where: { $0.online && $0.hostname != localMachineName() })?.hostname
                    ?? tailscalePeers.first(where: { $0.online })?.hostname
                    ?? tailscalePeers.first?.hostname
                    ?? "sshmacmini"
                model.config.federationURL = buildWSURL(host: preferredHost, port: 8765, path: "/federation")
            }
        }

        model.save()
        refreshConnectivity()
    }

    private func applyRecommendedIfNeeded() {
        applyRecommended(force: false)
    }

    private func localMachineName() -> String {
        Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func startProbeTimer() {
        stopProbeTimer()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            refreshConnectivity()
        }
    }

    private func stopProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func refreshConnectivity() {
        probeTmux()
        probeFederation()
    }

    private func probeTmux() {
        guard model.config.tmuxEnabled else {
            tmuxState = .unknown
            return
        }
        let (host, port) = parseWSURL(model.config.tmuxStatusBarURL, defaultHost: "localhost", defaultPort: 8080)
        guard !host.isEmpty else {
            tmuxState = .unknown
            return
        }
        tmuxState = .checking
        probeTCP(host: host, port: port) { ok in
            tmuxState = ok ? .online : .offline
        }
    }

    private func probeFederation() {
        guard model.config.federationEnabled else {
            federationState = .unknown
            return
        }
        if model.config.nodeRole == .server {
            // Server: we're the listener, always "online"
            federationState = .online
            return
        }
        let (host, port) = parseWSURL(model.config.federationURL, defaultHost: "", defaultPort: 8765)
        guard !host.isEmpty else {
            federationState = .unknown
            return
        }
        federationState = .checking
        probeTCP(host: host, port: port) { ok in
            federationState = ok ? .online : .offline
        }
    }

    private func probeTCP(host: String, port: Int, timeout: TimeInterval = 1.2, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(false)
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "clawgate.settings.probe", qos: .utility)
        var done = false

        func finish(_ ok: Bool) {
            if done { return }
            done = true
            conn.cancel()
            DispatchQueue.main.async { completion(ok) }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }

        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }
    }

}
