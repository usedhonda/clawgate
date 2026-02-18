import SwiftUI
import Network
import Foundation
import ServiceManagement
import AppKit

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
    let embedInScroll: Bool
    let onOpenQRCode: (() -> Void)?

    init(model: SettingsModel, embedInScroll: Bool = true, onOpenQRCode: (() -> Void)? = nil) {
        self.model = model
        self.embedInScroll = embedInScroll
        self.onOpenQRCode = onOpenQRCode
    }

    private enum ConnectivityState {
        case unknown, checking, online, offline

        var color: Color {
            switch self {
            case .online:   return PanelTheme.accentGreen
            case .offline:  return PanelTheme.accentRed
            case .checking: return PanelTheme.accentYellow
            case .unknown:  return PanelTheme.textTertiary
            }
        }

        var text: String {
            switch self {
            case .online:   return "Connected"
            case .offline:  return "Disconnected"
            case .checking: return "Checking"
            case .unknown:  return "Idle"
            }
        }
    }

    @ObservedObject var model: SettingsModel
    @State private var tailscalePeers: [TailscalePeer] = []
    @State private var tmuxState: ConnectivityState = .unknown
    @State private var federationState: ConnectivityState = .unknown
    @State private var probeTimer: Timer?
    @State private var suppressNodeRoleChange = false
    @State private var showServerRoleBlockedAlert = false
    @State private var serverRoleBlockedMessage = ""

    private var contentView: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            headerCard
            if model.config.nodeRole == .server {
                serverSection
            } else {
                clientSection
            }
        }
        .padding(embedInScroll ? PanelTheme.padding : 0)
    }

    var body: some View {
        Group {
            if embedInScroll {
                ScrollView(showsIndicators: false) {
                    contentView
                }
            } else {
                contentView
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .tint(PanelTheme.accentCyan)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(PanelTheme.bodyFont)
        .onAppear {
            loadTailscalePeers()
            refreshConnectivity()
            startProbeTimer()
        }
        .onDisappear {
            stopProbeTimer()
        }
        .onChange(of: model.config.nodeRole) { newRole in
            if suppressNodeRoleChange {
                suppressNodeRoleChange = false
                return
            }
            if newRole == .server {
                let check = evaluateServerRolePrerequisites()
                if !check.ok {
                    suppressNodeRoleChange = true
                    model.config.nodeRole = .client
                    applyRecommendedIfNeeded()
                    model.save()
                    serverRoleBlockedMessage = check.message
                    showServerRoleBlockedAlert = true
                    return
                }
            }
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
        .alert("Cannot enable Server role", isPresented: $showServerRoleBlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(serverRoleBlockedMessage)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        PanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ClawGate")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Text(model.config.nodeRole == .server ? "Server" : "Client")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
            }

            Picker("Role", selection: $model.config.nodeRole) {
                Text("Server").tag(NodeRole.server)
                Text("Client").tag(NodeRole.client)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                PanelActionButton(title: "Apply Recommended", tone: .primary) {
                    applyRecommended(force: true)
                }
                Text("Tailscale LAN defaults")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            }
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Group {
            PanelCard {
                Text("Tmux")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
                    .lineLimit(1)
            }

            PanelCard {
                Text("Messenger (LINE)")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Toggle("Enabled", isOn: $model.config.lineEnabled)
                if model.config.lineEnabled {
                    fieldRow("Conversation") {
                        TextField("e.g. John Doe", text: $model.config.lineDefaultConversation)
                            .textFieldStyle(.plain)
                            .modifier(PanelInputModifier())
                    }
                    Stepper("Poll: \(model.config.linePollIntervalSeconds)s",
                            value: $model.config.linePollIntervalSeconds, in: 1...30)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
                }
            }

            PanelCard {
                Text("Federation")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Toggle("Enabled", isOn: $model.config.federationEnabled)
                if model.config.federationEnabled {
                    Toggle("Remote Access (0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
                    if !model.config.remoteAccessEnabled {
                        Text("Remote Access is off — only local clients can connect")
                            .font(PanelTheme.bodyFont)
                            .foregroundStyle(PanelTheme.accentYellow)
                    }
                    statusRow(state: federationState)
                    Text("Accepting clients on ws://\(model.config.remoteAccessEnabled ? "0.0.0.0" : "127.0.0.1"):8765/federation")
                        .font(PanelTheme.bodyFont)
                        .foregroundStyle(PanelTheme.textTertiary)
                        .lineLimit(2)
                    fieldRow("Token") {
                        SecureField("federation token", text: $model.config.federationToken)
                            .textFieldStyle(.plain)
                            .modifier(PanelInputModifier())
                    }
                }
            }

            PanelCard {
                Text("System")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }

            utilitiesSection
        }
    }

    // MARK: - Client Section

    private var clientSection: some View {
        Group {
            PanelCard {
                Text("Tmux")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
                    .lineLimit(1)
            }

            PanelCard {
                Text("Federation")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
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
                                    .font(PanelTheme.bodyFont)
                                    .foregroundStyle(PanelTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PanelTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(PanelInputModifier())
                        }
                    }

                    if federationPeerSelectionBinding.wrappedValue.isEmpty {
                        TextField("server.tailnet.ts.net", text: federationHostBinding)
                            .textFieldStyle(.plain)
                            .modifier(PanelInputModifier())
                    }

                    HStack(spacing: 8) {
                        PanelActionButton(title: "Refresh Hosts", tone: .neutral) {
                            loadTailscalePeers()
                        }
                        Text("Detected: \(tailscalePeers.count)")
                            .font(PanelTheme.bodyFont)
                            .foregroundStyle(PanelTheme.textTertiary)
                    }
                }
            }

            PanelCard {
                Text("System")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }

            utilitiesSection
        }
    }

    // MARK: - Utilities

    @ViewBuilder
    private var utilitiesSection: some View {
        if let onOpenQRCode {
            PanelCard {
                Text("Utilities")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                PanelActionButton(title: "Show QR Code for [VibeTerm]", tone: .neutral) {
                    onOpenQRCode()
                }
            }
        }
    }

    // MARK: - Launch at Login

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

    // MARK: - Status Row

    private func statusRow(state: ConnectivityState) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: state.color)
            Text(state.text)
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textPrimary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                .fill(state.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                .stroke(state.color.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Field Row

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textSecondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }

    // MARK: - Federation Bindings

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

    // MARK: - Server Prerequisites

    private func evaluateServerRolePrerequisites() -> (ok: Bool, message: String) {
        let openClawReady: Bool
        if let gateway = readOpenClawGatewayConfig() {
            openClawReady = probeTCPBlocking(host: "127.0.0.1", port: gateway.port, timeout: 0.8)
        } else {
            openClawReady = false
        }

        let lineReady = NSRunningApplication
            .runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .first != nil

        guard openClawReady && lineReady else {
            var lines: [String] = []
            if !openClawReady {
                lines.append("OpenClaw gateway is not running on this machine.")
            }
            if !lineReady {
                lines.append("Messenger app (LINE) is not running.")
            }
            lines.append("Start both, then select Server again.")
            return (false, lines.joined(separator: "\n"))
        }
        return (true, "")
    }

    private func readOpenClawGatewayConfig() -> (port: Int, token: String)? {
        let configPath = NSString("~/.openclaw/openclaw.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let port = gateway["port"] as? Int ?? 18789
        guard (1...65535).contains(port) else { return nil }
        return (port: port, token: token)
    }

    // MARK: - Recommended Settings

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

    // MARK: - Connectivity Probes

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

    private func probeTCPBlocking(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "clawgate.settings.server-gate.probe", qos: .utility)
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        var done = false

        func finish(_ ok: Bool) {
            if done { return }
            done = true
            result = ok
            conn.cancel()
            semaphore.signal()
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
        _ = semaphore.wait(timeout: .now() + timeout + 0.2)
        return result
    }
}
