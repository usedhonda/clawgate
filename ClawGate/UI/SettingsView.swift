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
    @State private var tmuxState: ConnectivityState = .unknown
    @State private var gatewayState: ConnectivityState = .unknown
    @State private var probeTimer: Timer?

    private var contentView: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            headerCard
            lineSection
            tmuxSection
            gatewaySection
            systemSection
            utilitiesSection
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ClawGate")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                Text("Standalone")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
            }

            Text("Capabilities are configured directly. LINE is the only machine-local branch.")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textTertiary)

            HStack(spacing: 8) {
                ActionButton(title: "Apply Recommended", tone: .primary) {
                    applyRecommended()
                }
                Text("tmux direct poll + Gateway direct access")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            }
        }
    }

    private var lineSection: some View {
        PanelCard {
            Text("LINE")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Enable LINE adapter", isOn: $model.config.lineEnabled)
            statusRow(state: lineState)
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
        }
    }

    private var tmuxSection: some View {
        PanelCard {
            Text("Tmux")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Enable tmux monitoring", isOn: $model.config.tmuxEnabled)
            statusRow(state: tmuxState)
            Text("Source: Built-in tmux poller")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textTertiary)
            if model.config.tmuxSessionModes.isEmpty {
                Text("Session modes are managed from Monitor.")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session modes")
                        .font(PanelTheme.titleFont)
                        .foregroundStyle(PanelTheme.textSecondary)
                    ForEach(model.config.tmuxSessionModes.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 8) {
                            Text(key)
                                .font(PanelTheme.smallFont)
                                .foregroundStyle(PanelTheme.textSecondary)
                            Spacer(minLength: 0)
                            Text(model.config.tmuxSessionModes[key] ?? "ignore")
                                .font(PanelTheme.smallFont)
                                .foregroundStyle(PanelTheme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private var gatewaySection: some View {
        PanelCard {
            Text("Gateway")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Toggle("Allow Gateway to connect", isOn: $model.config.remoteAccessEnabled)
            statusRow(state: gatewayState)
            fieldRow("Token") {
                SecureField("gateway token", text: $model.config.remoteAccessToken)
                    .textFieldStyle(.plain)
                    .modifier(PanelInputModifier())
            }
            Text(model.config.remoteAccessEnabled ? "Binding on 0.0.0.0:8765" : "Binding on 127.0.0.1:8765")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textTertiary)
        }
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
            Toggle("Include message body in logs", isOn: $model.config.includeMessageBodyInLogs)
        }
    }

    @ViewBuilder
    private var utilitiesSection: some View {
        if let onOpenQRCode {
            PanelCard {
                Text("Utilities")
                    .font(PanelTheme.titleFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                ActionButton(title: "Show QR Code for [VibeTerm]", tone: .neutral) {
                    onOpenQRCode()
                }
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

    private func applyRecommended() {
        model.config.tmuxEnabled = true
        model.config.remoteAccessEnabled = true
        if lineAppRunning() {
            model.config.lineEnabled = true
        }
        model.save()
        refreshConnectivity()
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
        probeTmux()
        gatewayState = model.config.remoteAccessEnabled ? .online : .unknown
    }

    private func lineAppRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .first != nil
    }

    private func probeTmux() {
        guard model.config.tmuxEnabled else {
            tmuxState = .unknown
            return
        }
        tmuxState = .checking
        DispatchQueue.global(qos: .utility).async {
            let ok = ((try? TmuxShell.listSessions())?.isEmpty == false)
            DispatchQueue.main.async {
                tmuxState = ok ? .online : .offline
            }
        }
    }
}
