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

    private enum UITheme {
        static let baseFontSize: CGFloat = 13
        static let bodyFont = Font.system(size: baseFontSize, weight: .medium, design: .monospaced)
        static let titleFont = Font.system(size: baseFontSize, weight: .semibold, design: .monospaced)

        static let panelWidth: CGFloat = 430
        static let sectionSpacing: CGFloat = 12
        static let panelPadding: CGFloat = 12
        static let cardPadding: CGFloat = 12
        static let cardSpacing: CGFloat = 9
        static let cardRadius: CGFloat = 14

        static let accent = Color(red: 0.15, green: 0.44, blue: 0.95)
        static let primaryText = Color.primary
        static let secondaryText = Color.primary.opacity(0.78)
        static let tertiaryText = Color.primary.opacity(0.62)

        static let cardTop = Color.white.opacity(0.78)
        static let cardBottom = Color.white.opacity(0.6)
        static let cardStroke = Color.white.opacity(0.82)
        static let cardInnerStroke = Color.black.opacity(0.1)
        static let cardShadow = Color.black.opacity(0.1)

        static let chipFill = Color.white.opacity(0.84)
        static let chipStroke = Color.black.opacity(0.12)
        static let inputFill = Color.white.opacity(0.9)
        static let inputStroke = Color.black.opacity(0.14)

        static let buttonFill = Color.white.opacity(0.88)
        static let buttonStroke = Color.black.opacity(0.14)
    }

    private struct GlassButtonStyle: ButtonStyle {
        let prominent: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(UITheme.titleFont)
                .foregroundStyle(prominent ? Color.white : UITheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            prominent
                            ? UITheme.accent.opacity(configuration.isPressed ? 0.72 : 0.9)
                            : UITheme.buttonFill.opacity(configuration.isPressed ? 0.72 : 0.9)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            prominent
                            ? Color.white.opacity(0.22)
                            : UITheme.buttonStroke.opacity(configuration.isPressed ? 0.7 : 1.0),
                            lineWidth: 1
                        )
                )
        }
    }

    private struct InputChromeModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(UITheme.bodyFont)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(UITheme.inputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(UITheme.inputStroke, lineWidth: 1)
                )
        }
    }

    private struct HoverInteractiveControlModifier: ViewModifier {
        let cornerRadius: CGFloat
        @State private var isHovered = false

        func body(content: Content) -> some View {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(UITheme.accent.opacity(isHovered ? 0.55 : 0), lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(UITheme.accent.opacity(isHovered ? 0.12 : 0))
                )
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovered = hovering
                    }
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
        VStack(alignment: .leading, spacing: UITheme.sectionSpacing) {
            headerCard
            if model.config.nodeRole == .server {
                serverSection
            } else {
                clientSection
            }
        }
        .padding(UITheme.panelPadding)
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
        .tint(UITheme.accent)
        .frame(width: UITheme.panelWidth)
        .font(UITheme.bodyFont)
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
                .buttonStyle(GlassButtonStyle(prominent: true))
                .modifier(HoverInteractiveControlModifier(cornerRadius: 9))

                Text("Tailscale LAN defaults")
                    .font(UITheme.bodyFont)
                    .foregroundStyle(UITheme.tertiaryText)
            }
        }
    }

    private var serverSection: some View {
        Group {
            card("Tmux") {
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(UITheme.bodyFont)
                    .foregroundStyle(UITheme.tertiaryText)
                    .lineLimit(1)
            }

            card("LINE") {
                Toggle("Enabled", isOn: $model.config.lineEnabled)
                if model.config.lineEnabled {
                    fieldRow("Conversation") {
                        TextField("e.g. John Doe", text: $model.config.lineDefaultConversation)
                            .textFieldStyle(.plain)
                            .modifier(InputChromeModifier())
                    }
                    Stepper("Poll: \(model.config.linePollIntervalSeconds)s",
                            value: $model.config.linePollIntervalSeconds, in: 1...30)
                    .font(UITheme.bodyFont)
                    .foregroundStyle(UITheme.secondaryText)
                }
            }

            card("Federation") {
                Toggle("Enabled", isOn: $model.config.federationEnabled)
                if model.config.federationEnabled {
                    Toggle("Remote Access (0.0.0.0)", isOn: $model.config.remoteAccessEnabled)
                    if !model.config.remoteAccessEnabled {
                        Text("Remote Access is off — only local clients can connect")
                            .font(UITheme.bodyFont)
                            .foregroundStyle(.orange)
                    }
                    statusRow(state: federationState)
                    Text("Accepting clients on ws://\(model.config.remoteAccessEnabled ? "0.0.0.0" : "127.0.0.1"):8765/federation")
                        .font(UITheme.bodyFont)
                        .foregroundStyle(UITheme.tertiaryText)
                        .lineLimit(2)
                    fieldRow("Token") {
                        SecureField("federation token", text: $model.config.federationToken)
                            .textFieldStyle(.plain)
                            .modifier(InputChromeModifier())
                    }
                }
            }

            card("System") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }

            utilitiesSection
        }
    }

    private var clientSection: some View {
        Group {
            card("Tmux") {
                Toggle("Enabled", isOn: $model.config.tmuxEnabled)
                statusRow(state: tmuxState)
                Text("Feed: \(model.config.tmuxStatusBarURL)")
                    .font(UITheme.bodyFont)
                    .foregroundStyle(UITheme.tertiaryText)
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
                                    .font(UITheme.bodyFont)
                                    .foregroundStyle(UITheme.primaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(UITheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(InputChromeModifier())
                            .modifier(HoverInteractiveControlModifier(cornerRadius: 8))
                        }
                    }

                    if federationPeerSelectionBinding.wrappedValue.isEmpty {
                        TextField("server.tailnet.ts.net", text: federationHostBinding)
                            .textFieldStyle(.plain)
                            .modifier(InputChromeModifier())
                    }

                    HStack(spacing: 8) {
                        Button("Refresh Hosts") {
                            loadTailscalePeers()
                        }
                        .buttonStyle(GlassButtonStyle(prominent: false))
                        .modifier(HoverInteractiveControlModifier(cornerRadius: 9))

                        Text("Detected: \(tailscalePeers.count)")
                            .font(UITheme.bodyFont)
                            .foregroundStyle(UITheme.tertiaryText)
                    }
                }
            }

            card("System") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                }
                Toggle("Debug Logging", isOn: $model.config.debugLogging)
            }

            utilitiesSection
        }
    }

    @ViewBuilder
    private var utilitiesSection: some View {
        if let onOpenQRCode {
            card("Utilities") {
                Button("Show QR Code for [VibeTerm]") {
                    onOpenQRCode()
                }
                .buttonStyle(GlassButtonStyle(prominent: false))
                .modifier(HoverInteractiveControlModifier(cornerRadius: 9))
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
        VStack(alignment: .leading, spacing: UITheme.cardSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(UITheme.titleFont)
                    .foregroundStyle(UITheme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(UITheme.bodyFont)
                        .foregroundStyle(UITheme.secondaryText)
                        .lineLimit(1)
                }
            }
            content()
        }
        .padding(UITheme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: UITheme.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [UITheme.cardTop, UITheme.cardBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: UITheme.cardRadius, style: .continuous)
                .stroke(UITheme.cardStroke, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UITheme.cardRadius, style: .continuous)
                .inset(by: 0.5)
                .stroke(UITheme.cardInnerStroke, lineWidth: 0.5)
        )
        .shadow(color: UITheme.cardShadow, radius: 8, x: 0, y: 3)
    }

    private func statusRow(state: ConnectivityState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.text)
                .font(UITheme.titleFont)
                .foregroundStyle(UITheme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(UITheme.chipFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(UITheme.chipStroke, lineWidth: 1)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(state.color.opacity(0.22), lineWidth: 1)
        )
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(UITheme.titleFont)
                .foregroundStyle(UITheme.secondaryText)
                .frame(width: 84, alignment: .leading)
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
                lines.append("LINE app is not running.")
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
