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
    @State private var showRegenerateAlert = false

    private var contentView: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            headerCard
            if lineSectionShouldShow {
                lineSection
            }
            tmuxSection
            gatewaySection
            systemSection
        }
        .padding(embedInScroll ? PanelTheme.padding : 0)
    }

    /// Whether the LINE section makes sense on this machine.
    ///
    /// LINE adapter only works when:
    /// 1. LINE Desktop is installed on this machine, AND
    /// 2. The OpenClaw Gateway we're connecting to is local (on this machine)
    ///
    /// If the Gateway is remote, this machine's LINE Desktop is unrelated to
    /// what the remote Gateway actually operates on. Hide the section.
    private var lineSectionShouldShow: Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.naver.line.mac") != nil else {
            return false
        }
        guard let config = readOpenClawGatewayConfig() else {
            // No OpenClaw config on this machine — nothing uses LINE here.
            return false
        }
        let host = config.host.lowercased()
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
            startProbeTimer()
        }
        .onDisappear {
            stopProbeTimer()
        }
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.includeMessageBodyInLogs) { _ in model.save() }
        .onChange(of: model.config.lineEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.lineDefaultConversation) { _ in model.save() }
        .onChange(of: model.config.linePollIntervalSeconds) { _ in model.save() }
        .onChange(of: model.config.lineDetectionMode) { _ in model.save() }
        .onChange(of: model.config.lineFusionThreshold) { _ in model.save() }
        .onChange(of: model.config.lineEnablePixelSignal) { _ in model.save() }
        .onChange(of: model.config.lineEnableProcessSignal) { _ in model.save() }
        .onChange(of: model.config.lineEnableNotificationStoreSignal) { _ in model.save() }
        .onChange(of: model.config.tmuxEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.tmuxSessionModes) { _ in model.save() }
        .onChange(of: model.config.remoteAccessEnabled) { _ in model.save(); refreshConnectivity() }
        .onChange(of: model.config.remoteAccessToken) { _ in model.save() }
    }

    // MARK: - Header

    private var headerCard: some View {
        PanelCard {
            Text("ClawGate")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
        }
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

    private var tmuxSection: some View {
        PanelCard {
            Text("Tmux")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Enable tmux monitoring", isOn: $model.config.tmuxEnabled)
            if model.config.tmuxEnabled {
                Text("Session behavior is managed from Monitor.")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            }
        }
    }

    private var gatewaySection: some View {
        PanelCard {
            Text("Gateway")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Allow Gateway to connect", isOn: $model.config.remoteAccessEnabled)
            if model.config.remoteAccessEnabled {
                statusRow(state: gatewayState)
                let tokenSet = !model.config.remoteAccessToken.isEmpty
                fieldRow("Token") {
                    HStack(spacing: 6) {
                        SecureField("not set", text: $model.config.remoteAccessToken)
                            .textFieldStyle(.plain)
                            .modifier(PanelInputModifier())
                        if tokenSet {
                            Button(action: copyToken) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .help("Copy token to clipboard")
                            Button(action: { showRegenerateAlert = true }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .help("Regenerate token (invalidates the current one)")
                        } else {
                            Button(action: generateToken) {
                                Text("Generate")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Text("Paste this token into OpenClaw Gateway's ~/.openclaw/openclaw.json under channels.clawgate.default.token, then restart Gateway.")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Regenerate Token?",
               isPresented: $showRegenerateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) { generateToken() }
        } message: {
            Text("The current token will stop working. You'll need to update OpenClaw Gateway's config with the new one.")
        }
    }

    private func generateToken() {
        // URL-safe short UUID
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        model.config.remoteAccessToken = String(raw.prefix(32))
        model.save()
        copyToken()
    }

    private func copyToken() {
        guard !model.config.remoteAccessToken.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.config.remoteAccessToken, forType: .string)
    }

    private var systemSection: some View {
        PanelCard {
            Text("System")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            if #available(macOS 13.0, *) {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
            }
            Toggle("Debug Logging", isOn: $model.config.debugLogging)
            if model.config.debugLogging {
                Toggle("Include message body", isOn: $model.config.includeMessageBodyInLogs)
                    .padding(.leading, 16)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
            }
        }
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
        gatewayState = model.config.remoteAccessEnabled ? .online : .unknown
    }

    private func lineAppRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .first != nil
    }
}
