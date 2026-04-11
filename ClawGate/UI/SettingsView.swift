import SwiftUI
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
    @State private var lineState: ConnectivityState = .unknown
    @State private var gatewayState: ConnectivityState = .unknown
    @State private var probeTimer: Timer?
    @State private var tailscalePeers: [TailscalePeer] = []

    private var contentView: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            if lineSectionShouldShow {
                lineSection
            }
            gatewaySection
            systemSection
            chromeSection
        }
        .padding(embedInScroll ? PanelTheme.padding : 0)
    }

    /// Whether the LINE section makes sense on this machine.
    ///
    /// LINE adapter only works when:
    /// 1. LINE Desktop is installed on this machine, AND
    /// 2. The OpenClaw Gateway we're configured to connect to is local
    ///
    /// If the Gateway is remote, this machine's LINE Desktop is unrelated to
    /// what the remote Gateway actually operates on. Hide the section.
    private var lineSectionShouldShow: Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.naver.line.mac") != nil else {
            return false
        }
        let host = model.config.openclawHost.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
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
            refreshConnectivity()
            loadTailscalePeers()
            startProbeTimer()
        }
        .onDisappear {
            stopProbeTimer()
        }
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.lineEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.lineDefaultConversation) { _ in model.save() }
        .onChange(of: model.config.linePollIntervalSeconds) { _ in model.save() }
        .onChange(of: model.config.lineDetectionMode) { _ in model.save() }
        .onChange(of: model.config.lineFusionThreshold) { _ in model.save() }
        .onChange(of: model.config.lineEnablePixelSignal) { _ in model.save() }
        .onChange(of: model.config.lineEnableProcessSignal) { _ in model.save() }
        .onChange(of: model.config.lineEnableNotificationStoreSignal) { _ in model.save() }
        .onChange(of: model.config.tmuxSessionModes) { _ in model.save() }
        .onChange(of: model.config.openclawHost) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.openclawPort) { _ in model.save(); refreshConnectivity() }
    }

    private var lineSection: some View {
        PanelCard {
            Text("LINE")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Enable LINE adapter", isOn: $model.config.lineEnabled)
            if model.config.lineEnabled {
                statusRow(state: lineState)
                fieldRow("Conversation") {
                    TextField("e.g. John Doe", text: $model.config.lineDefaultConversation)
                        .textFieldStyle(.plain)
                        .modifier(PanelInputModifier())
                }
                Stepper("Poll: \(model.config.linePollIntervalSeconds)s",
                        value: $model.config.linePollIntervalSeconds, in: 1...30)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldRow("Detect") {
                            TextField("hybrid", text: $model.config.lineDetectionMode)
                                .textFieldStyle(.plain)
                                .modifier(PanelInputModifier())
                        }
                        Stepper("Fusion: \(model.config.lineFusionThreshold)",
                                value: $model.config.lineFusionThreshold, in: 1...100)
                            .font(PanelTheme.bodyFont)
                            .foregroundStyle(PanelTheme.textSecondary)
                        Toggle("Pixel signal", isOn: $model.config.lineEnablePixelSignal)
                        Toggle("Process signal", isOn: $model.config.lineEnableProcessSignal)
                        Toggle("Notification-store signal", isOn: $model.config.lineEnableNotificationStoreSignal)
                    }
                    .padding(.top, 4)
                }
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textSecondary)
            }
        }
    }

    private var gatewaySection: some View {
        PanelCard {
            Text("Gateway")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            statusRow(state: gatewayState)
            fieldRow("Host") {
                HStack(spacing: 6) {
                    TextField("127.0.0.1", text: $model.config.openclawHost)
                        .textFieldStyle(.plain)
                        .modifier(PanelInputModifier())
                    Menu {
                        Button("Use local (127.0.0.1)") {
                            model.config.openclawHost = "127.0.0.1"
                        }
                        if !tailscalePeers.isEmpty {
                            Divider()
                            ForEach(tailscalePeers) { peer in
                                Button(peerShortLabel(peer)) {
                                    model.config.openclawHost = peer.hostname
                                }
                            }
                        }
                        Divider()
                        Button("Refresh peers") { loadTailscalePeers() }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick a Tailscale peer or reset to local")
                }
            }
            fieldRow("Port") {
                TextField("18789", value: $model.config.openclawPort, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .modifier(PanelInputModifier())
            }
        }
    }

    private func loadTailscalePeers() {
        tailscalePeers = TailscalePeerService.loadPeers()
    }

    private func peerShortLabel(_ peer: TailscalePeer) -> String {
        let status = peer.online ? "online" : "offline"
        return "\(peer.hostname) (\(status))"
    }

    @AppStorage("chromeExtensionProvisioned") private var chromeExtensionProvisioned: Bool = false

    private var systemSection: some View {
        PanelCard {
            Text("System")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            if #available(macOS 13.0, *) {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
            }
            Toggle("Debug Logging", isOn: $model.config.debugLogging)
        }
    }

    private var chromeSection: some View {
        PanelCard {
            Text("Chrome Extension")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            fieldRow("Extension") {
                Spacer()
                Button("Open Installer") {
                    openChromeExtensionInstaller()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            fieldRow("Status") {
                Text(chromeExtensionProvisioned ? "✓ Connected" : "Not connected")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(chromeExtensionProvisioned ? PanelTheme.accentGreen : PanelTheme.textSecondary)
                Spacer()
            }
        }
    }

    private func openChromeExtensionInstaller() {
        // Prefer the extension bundled in app Resources (production build).
        // Fall back to the source directory for dev builds (swift build).
        let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("clawgate-chrome")
        let devPath = Bundle.main.executableURL?
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // ClawGate.app
            .deletingLastPathComponent()   // debug / release
            .deletingLastPathComponent()   // .build
            .appendingPathComponent("extensions/clawgate-chrome")

        let fm = FileManager.default
        guard let extDir = [bundledPath, devPath]
            .compactMap({ $0 })
            .first(where: { fm.fileExists(atPath: $0.path) })
        else { return }

        // Reveal the extension folder in Finder so the user can drag it into Chrome.
        NSWorkspace.shared.selectFile(extDir.path, inFileViewerRootedAtPath: extDir.deletingLastPathComponent().path)

        // Open chrome://extensions/ in Chrome (works even if Chrome is already running).
        let openExtensionsPage = Process()
        openExtensionsPage.launchPath = "/usr/bin/open"
        openExtensionsPage.arguments = ["-a", "Google Chrome", "chrome://extensions/"]
        try? openExtensionsPage.run()

        NotificationCenter.default.post(
            name: .petBubbleNotify,
            object: nil,
            userInfo: [
                "text": "Turn on Developer Mode in Chrome, then drag the folder from Finder into the extensions page. Press 'Mark Installed' when done.",
                "source": "settings"
            ]
        )
    }

    @available(macOS 13.0, *)
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                LaunchAtLoginManager.shared.isEnabled
            },
            set: { newValue in
                do {
                    try LaunchAtLoginManager.shared.setEnabled(newValue) { level, message in
                        print("[\(level.rawValue.uppercased())] \(message)")
                    }
                } catch {
                    print("[ERROR] Launch at login \(newValue ? "register" : "unregister") failed: \(error)")
                }
            }
        )
    }

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

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textSecondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
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
        lineState = model.config.lineEnabled
            ? (lineAppRunning() ? .online : .offline)
            : .unknown
        gatewayState = .online
    }

    private func lineAppRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .first != nil
    }
}
