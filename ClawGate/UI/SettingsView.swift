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

private struct LineObservationWindowSummary: Identifiable {
    let id: String
    let windowID: String
    let kind: String
    let state: String
    let width: Int
    let height: Int
    let spanCount: Int
    let bodyCandidateCount: Int
    let labelObserved: Bool

    init?(diagnostic: [String: Any]) {
        guard let kind = diagnostic["kind"] as? String,
              let state = diagnostic["state"] as? String else { return nil }
        let rawWindowID: String
        if let value = diagnostic["windowId"] as? String {
            rawWindowID = value
        } else if let value = diagnostic["windowId"] as? Int {
            rawWindowID = String(value)
        } else {
            rawWindowID = "匿名"
        }
        func number(_ key: String) -> Int {
            if let value = diagnostic[key] as? NSNumber { return value.intValue }
            return diagnostic[key] as? Int ?? 0
        }
        self.id = "\(rawWindowID)-\(kind)-\(state)-\(number("width"))-\(number("height"))"
        self.windowID = rawWindowID
        self.kind = kind
        self.state = state
        self.width = number("width")
        self.height = number("height")
        self.spanCount = number("spanCount")
        self.bodyCandidateCount = number("bodyCandidateCount")
        self.labelObserved = diagnostic["labelObserved"] as? Bool ?? false
    }
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
    @AppStorage("clawgate.lineObservationEnabled") private var lineObservationEnabled = true
    @State private var observationStatus = "starting"
    @State private var observationDelivery = "idle"
    @State private var observationQueue = 0
    @State private var sidebarWindowCount: Int? = nil
    @State private var sidebarOCRSpanCount: Int? = nil
    @State private var conversationWindowCount: Int? = nil
    @State private var conversationOCRSpanCount: Int? = nil
    @State private var bodyCandidateCount: Int? = nil
    @State private var localBodyCandidateCount: Int? = nil
    @State private var displayedTimeCount: Int? = nil
    @State private var annotationCount: Int? = nil
    @State private var observedLabelWindowCount: Int? = nil
    @State private var observationWindows: [LineObservationWindowSummary] = []
    @State private var observationLastObservedAt: Date? = nil
    @State private var observationLastAcknowledgedAt: Date? = nil
    @State private var observationSchemaVersion = 1
    @State private var lineState: ConnectivityState = .unknown
    @State private var gatewayState: ConnectivityState = .unknown
    @State private var probeTimer: Timer?
    @State private var tailscalePeers: [TailscalePeer] = []
    @State private var draftJevKey: String = ""
    @State private var jevStatus: String = ""
    @State private var jevCheck: String = ""

    private var contentView: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            if lineSectionShouldShow {
                lineSection
            }
            if model.config.isClientRole { lineObservationSection }
            gatewaySection
            jevSection
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
            refreshJevStatus()
        }
        .onDisappear {
            stopProbeTimer()
        }
        .onChange(of: model.config.debugLogging) { _ in model.save() }
        .onChange(of: model.config.jevEnabled) { _ in model.save() }
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

    private var lineObservationCaptureLabel: String {
        switch observationStatus {
        case "observing": return "表示範囲を観測中"
        case "screenCapturePermissionUnverified": return "画面収録の事前確認で停止"
        case "unknownWindow": return "窓の読取範囲を特定できません"
        case "lineNotRunning": return "LINEが起動していません"
        case "noLineWindows": return "取得できるLINE窓がありません"
        case "disabled": return "停止中"
        case "outbox_full": return "未保存データが上限に達したため取得停止"
        case "observation_limits_exceeded": return "観測データが上限を超えたため一部取得制限"
        case "screen_locked": return "画面ロック中"
        case "storage_unavailable", "outbox_write_failed": return "ローカル保存を確認してください"
        case "captureUnavailable", "unavailable": return "取得できる画面がありません"
        case "unsupported_os": return "このmacOSでは取得できません"
        case "starting": return "準備中"
        default: return "現在取得できません"
        }
    }

    private var lineObservationDeliveryLabel: String {
        switch observationDelivery {
        case "committed", "caught_up": return "保存済み"
        case "http_404": return "サーバー未対応・データ保持中"
        case "hub_committed": return "Hubに保存済み"
        case "hub_capability_unavailable": return "Hub機能を確認できずデータ保持中"
        case "hub_http_401", "hub_http_403": return "Hub接続情報を確認してください"
        case "hub_http_404": return "Hubエンドポイント未対応・データ保持中"
        case "partial_ack": return "一部保存済み"
        case "permanent_rejection": return "受理されないデータを保持中"
        case "auth_unavailable": return "接続情報を確認してください"
        case "idle": return "待機中"
        case "backpressure": return "保存待ちの上限に到達"
        default:
            if observationDelivery.hasPrefix("hub_http_") {
                return "Hub送信失敗・再試行中"
            }
            return "保存を確認できず再試行中"
        }
    }

    private var lineObservationSection: some View {
        PanelCard {
            Text("LINE 状態監視").font(PanelTheme.titleFont)
            Toggle("ユーザーのLINEを受動観測", isOn: $lineObservationEnabled)
            Text("送信・前面化・会話操作はしません。見える範囲だけ取得します。")
                .font(PanelTheme.smallFont).foregroundStyle(PanelTheme.textSecondary)
            Text("取得: \(lineObservationCaptureLabel)").font(PanelTheme.smallFont)
            if observationStatus == "screenCapturePermissionUnverified" {
                Text("ClawGateの事前確認がfalseのため、画面取得・OCRはまだ実行していません。macOS設定がONでも原因は未確定です。")
                    .font(PanelTheme.smallFont).foregroundStyle(PanelTheme.textSecondary)
                Button("画面収録の設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("事前確認 → 窓取得 → OCR → ローカル保存 → サーバー保存")
                .font(PanelTheme.smallFont).foregroundStyle(PanelTheme.textSecondary)
            lineObservationSurfaceStatus
            lineObservationFreshness
            if observationDelivery == "http_404" {
                Text("サーバー404は事前確認・OCRとは独立しています。観測データは保持中です。")
                    .font(PanelTheme.smallFont).foregroundStyle(PanelTheme.textSecondary)
            }
            Text("配送: \(lineObservationDeliveryLabel) · 未保存 \(observationQueue)件").font(PanelTheme.smallFont)
            lineObservationSemanticStatus
            Text("会話同定が不明な観測から未返信を断定しません。")
                .font(PanelTheme.smallFont).foregroundStyle(PanelTheme.textSecondary)
        }
    }

    private var lineObservationSurfaceStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("画面の観測")
                .font(PanelTheme.smallFont)
                .foregroundStyle(PanelTheme.textSecondary)
            if observationCountsUnavailable {
                Text("サイドバー: 利用不可（\(lineObservationCaptureLabel)）")
                Text("本文: 利用不可（\(lineObservationCaptureLabel)）")
                Text("本文整理: 読み取れる会話窓を確認中")
            } else if observationIsStale {
                Text("サイドバー: 前回観測 · 窓 \(sidebarWindowCount ?? 0) / OCRスパン \(sidebarOCRSpanCount ?? 0)")
                Text("本文: 前回観測 · 窓 \(conversationWindowCount ?? 0) / OCRスパン \(conversationOCRSpanCount ?? 0)")
                lineObservationCandidateLabel(prefix: "本文整理（前回観測）")
            } else {
                if (sidebarWindowCount ?? 0) > 0 {
                    Text("サイドバー: 最新 · 窓 \(sidebarWindowCount ?? 0) / OCR文字領域 \(sidebarOCRSpanCount ?? 0)")
                } else { Text("サイドバー: 観測不能（安全な一覧窓なし）") }
                if (conversationWindowCount ?? 0) > 0 {
                    Text("本文: 最新 · 窓 \(conversationWindowCount ?? 0) / OCR文字領域 \(conversationOCRSpanCount ?? 0)")
                } else { Text("本文: 観測不能（安全な会話窓なし）") }
                lineObservationCandidateLabel(prefix: "本文整理")
            }
        }
        .font(PanelTheme.smallFont)
    }

    @ViewBuilder
    private func lineObservationCandidateLabel(prefix: String) -> some View {
        Text("\(prefix): 本文のまとまり \(localBodyCandidateCount ?? 0)件（表示範囲のみ）")
    }

    private var lineObservationSemanticStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("このMacで読み取れた情報")
                .font(PanelTheme.smallFont)
                .foregroundStyle(PanelTheme.textSecondary)
            if observationCountsUnavailable {
                Text("利用不可（\(lineObservationCaptureLabel)）")
            } else {
                let prefix = observationIsStale ? "前回観測 · " : ""
                Text("\(prefix)段落候補 \(localBodyCandidateCount ?? 0)件 · 表示時刻 \(displayedTimeCount ?? 0)件 · 注釈 \(annotationCount ?? 0)件")
                Text("会話名を読めた窓 \(observedLabelWindowCount ?? 0)件 · 発言者・送受信方向: 不明")
                if observationSchemaVersion < 3 {
                    Text("会話名・表示時刻の追加保存は、保存先の対応待ちです")
                        .foregroundStyle(PanelTheme.textSecondary)
                }
            }
            if !observationWindows.isEmpty {
                Text(observationIsStale ? "観測窓（匿名ID・前回観測）" : "観測窓（匿名ID）")
                    .foregroundStyle(PanelTheme.textSecondary)
                ForEach(observationWindows) { window in
                    let status = window.state == "captured" ? "取得済み" : window.state == "unknownWindow" ? "安全な本文領域を特定できません" : "取得できません（\(window.state)）"
                    Text("窓 \(window.windowID) · \(window.kind == "conversation" ? "会話" : window.kind == "sidebar" ? "一覧" : "未識別") · \(status)")
                }
            }
        }
        .font(PanelTheme.smallFont)
    }

    private var lineObservationFreshness: some View {
        VStack(alignment: .leading, spacing: 3) {
            if observationCountsUnavailable {
                Text("観測: 停止／利用不可").foregroundStyle(PanelTheme.textSecondary)
            } else if observationIsStale {
                Text("観測: stale（30秒以上更新なし）")
                    .foregroundStyle(PanelTheme.accentYellow)
            } else if observationLastObservedAt != nil {
                Text("観測: 最新")
                    .foregroundStyle(PanelTheme.accentGreen)
            } else {
                Text("観測: 未確認")
                    .foregroundStyle(PanelTheme.textSecondary)
            }
            Text("最終観測: \(formatObservationDate(observationLastObservedAt))")
            Text("最終コミットACK: \(formatObservationDate(observationLastAcknowledgedAt))")
        }
        .font(PanelTheme.smallFont)
        .foregroundStyle(PanelTheme.textSecondary)
    }

    private var observationCountsUnavailable: Bool {
        guard observationStatus == "observing" else { return true }
        return sidebarWindowCount == nil && sidebarOCRSpanCount == nil &&
            conversationWindowCount == nil && conversationOCRSpanCount == nil
    }

    private var observationIsStale: Bool {
        guard let observed = observationLastObservedAt else { return false }
        return Date().timeIntervalSince(observed) > 30
    }

    private func formatObservationDate(_ date: Date?) -> String {
        guard let date else { return "未確認" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: date)
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

    private var jevSection: some View {
        PanelCard {
            Text("Jev (TypeSafe)")
                .font(PanelTheme.titleFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Text("有効にすると、会話の文字起こしが TypeSafe 社の API に送られます（判定だけを返し、文章は生成しません）。")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textSecondary)
            fieldRow("API key") {
                SecureField("sk-...", text: $draftJevKey)
                    .textFieldStyle(.plain)
                    .modifier(PanelInputModifier())
                Button("保存") {
                    try? JevKeyStore().save(draftJevKey)
                    draftJevKey = ""
                    refreshJevStatus()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if JevKeyStore().isConfigured {
                    Button("削除") {
                        JevKeyStore().delete()
                        refreshJevStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            fieldRow("状態") {
                Text(jevStatus)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
            }
            fieldRow("") {
                Button("接続を確認") {
                    jevCheck = "確認中…"
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = JevClient().verifyKey()
                        DispatchQueue.main.async {
                            switch result {
                            case .valid:
                                jevCheck = "接続できました"
                            case .invalid:
                                jevCheck = "鍵が無効です（401/403）"
                            case .unreachable(let reason):
                                jevCheck = "到達できません: \(reason)"
                            }
                            refreshJevStatus()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!JevKeyStore().isConfigured)
                Text(jevCheck)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
            }
            Toggle("Jev を使う", isOn: $model.config.jevEnabled)
        }
    }

    /// Rebuilds the status line from three facts: whether a key is on disk,
    /// today's usage from the ledger, and whether the breaker has tripped —
    /// never the key itself.
    private func refreshJevStatus() {
        guard JevKeyStore().isConfigured else {
            jevStatus = "未設定"
            return
        }
        let totals = JevLedger().daily(on: Date())
        let cost = String(format: "$%.4f", totals.costUSD)
        var status = "設定済み · 今日 \(totals.calls) 回 · \(cost)"
        if JevBreaker().shouldSkip() {
            status += " · 遮断中（失敗が続いたため一時停止）"
        }
        jevStatus = status
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
        let observation = LineObservationDiagnostics.shared.snapshot()
        observationStatus = observation["captureStatus"] as? String ?? "starting"
        observationDelivery = observation["deliveryStatus"] as? String ?? "idle"
        observationQueue = observation["queueCount"] as? Int ?? 0
        observationSchemaVersion = observation["schemaVersion"] as? Int ?? 1
        observationLastObservedAt = parseObservationDate(observation["lastObservedAt"] as? String)
        observationLastAcknowledgedAt = parseObservationDate(observation["lastAcknowledgedAt"] as? String)
        if observationStatus == "observing" {
            sidebarWindowCount = observation["sidebarWindowCount"] as? Int
            sidebarOCRSpanCount = observation["sidebarOCRSpanCount"] as? Int
            conversationWindowCount = observation["conversationWindowCount"] as? Int
            conversationOCRSpanCount = observation["conversationOCRSpanCount"] as? Int
            bodyCandidateCount = observation["bodyCandidateCount"] as? Int
            localBodyCandidateCount = observation["localBodyCandidateCount"] as? Int
            displayedTimeCount = observation["displayedTimeCount"] as? Int
            annotationCount = observation["annotationCount"] as? Int
            observedLabelWindowCount = observation["observedLabelWindowCount"] as? Int
        } else {
            // A blocked or unavailable capture must not present an old sample as current.
            sidebarWindowCount = nil
            sidebarOCRSpanCount = nil
            conversationWindowCount = nil
            conversationOCRSpanCount = nil
            bodyCandidateCount = nil
            localBodyCandidateCount = nil
            displayedTimeCount = nil
            annotationCount = nil
            observedLabelWindowCount = nil
        }
        observationWindows = (observation["windows"] as? [[String: Any]])?.compactMap { LineObservationWindowSummary(diagnostic: $0) } ?? []
        lineState = model.config.lineEnabled
            ? (lineAppRunning() ? .online : .offline)
            : .unknown
        gatewayState = .online
    }

    private func parseObservationDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func lineAppRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .first != nil
    }
}
