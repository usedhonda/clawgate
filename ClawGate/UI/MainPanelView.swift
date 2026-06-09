import SwiftUI
import AppKit

struct MainPanelLogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: NSColor
    let event: String   // deduplication key (e.g. entry.event)
}

final class MainPanelModel: ObservableObject {
    @Published var codexSessions: [SessionSnapshot] = []
    @Published var claudeSessions: [SessionSnapshot] = []
    @Published var sessionModes: [String: String] = [:]
    @Published var logs: [MainPanelLogLine] = []
    @Published var isCollapsed = false
}

struct MainPanelView: View {
    private enum Tab: String, CaseIterable {
        case monitor  = "Monitor"
        case log      = "Log"
        case avatar   = "Avatar"
        case vibeterm = "VibeTerm"
        case config   = "Config"

        var systemImage: String {
            switch self {
            case .monitor:  return "waveform.path.ecg"
            case .log:      return "text.bubble"
            case .avatar:   return "person.crop.circle"
            case .vibeterm: return "terminal"
            case .config:   return "gearshape"
            }
        }
    }

    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var panelModel: MainPanelModel
    @ObservedObject var petModel: PetModel

    let modeOrder: [String]
    let onSetSessionMode: (String, String, String) -> Void
    let onToggleCollapse: () -> Void
    let logLimit: Int

    @State private var selectedTab: Tab = .monitor

    private var visibleTabs: [Tab] {
        // Conversation Log is a client-only feature (ambient capture runs on the
        // client, the host that points at a remote Gateway).
        if ConfigStore().load().isClientRole { return Tab.allCases }
        return Tab.allCases.filter { $0 != .log }
    }

    var body: some View {
        if panelModel.isCollapsed {
            CollapsedBarView(onExpand: onToggleCollapse)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PanelTheme.background)
                .preferredColorScheme(.dark)
        } else {
            normalContent
        }
    }

    @ViewBuilder
    private var normalContent: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacing) {
            // Tab bar — wraps to two rows when the panel is too narrow
            tabBar
                .padding(.bottom, 2)

            // Tab content
            tabContent
        }
        .padding(PanelTheme.padding)
        .frame(minWidth: 200, maxWidth: 700, minHeight: 400, maxHeight: 1400)
        .background(PanelTheme.background.opacity(PanelTheme.appBackgroundOpacity))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var tabBar: some View {
        let tabs = visibleTabs
        let midpoint = (tabs.count + 1) / 2
        let firstHalf = Array(tabs.prefix(midpoint))
        let secondHalf = Array(tabs.dropFirst(midpoint))

        if #available(macOS 13.0, *) {
            // ViewThatFits: prefer single-row layout; fall back to a two-row
            // split when the panel is too narrow for all tabs on one line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    tabButtons(for: tabs)
                    Spacer()
                    collapseButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        tabButtons(for: firstHalf)
                        Spacer()
                        collapseButton
                    }
                    HStack(spacing: 2) {
                        tabButtons(for: secondHalf)
                        Spacer()
                    }
                }
            }
        } else {
            // macOS 12 fallback: always use single-row layout.
            HStack(spacing: 2) {
                tabButtons(for: tabs)
                Spacer()
                collapseButton
            }
        }
    }

    @ViewBuilder
    private func tabButtons(for tabs: [Tab]) -> some View {
        ForEach(tabs, id: \.rawValue) { tab in
            PanelTabButton(
                title: tab.rawValue,
                systemImage: tab.systemImage,
                isSelected: selectedTab == tab,
                action: { selectedTab = tab }
            )
        }
    }

    private var collapseButton: some View {
        Button(action: onToggleCollapse) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PanelTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Collapse panel")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .monitor:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
                    sessionSection(title: "Codex", sessions: panelModel.codexSessions)
                    sessionSection(title: "Claude Code", sessions: panelModel.claudeSessions)

                    Rectangle()
                        .fill(PanelTheme.cardBorder)
                        .frame(height: 1)

                    opsLogsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .config:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
                    PanelSectionHeader(title: "Settings")
                    InlineSettingsView(model: settingsModel, embedInScroll: false, onOpenQRCode: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .log:
            AmbientLogView()
        case .avatar:
            ScrollView(showsIndicators: false) {
                AvatarSettingsView(petModel: petModel)
            }
        case .vibeterm:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
                    Text("Connect VibeTerm to OpenClaw on iPhone.")
                        .font(PanelTheme.bodyFont)
                        .foregroundStyle(PanelTheme.textSecondary)

                    HStack(spacing: 4) {
                        PanelPill(text: "OpenClaw-linked", tint: PanelTheme.accentCyan)
                        PanelPill(text: "Mobile Handoff", tint: PanelTheme.accentGreen)
                        PanelPill(text: "Remote Control", tint: PanelTheme.accentBlue)
                    }

                    QRCodeView(settingsModel: settingsModel)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private func sessionSection(title: String, sessions: [SessionSnapshot]) -> some View {
        PanelSectionHeader(title: title)
        if sessions.isEmpty {
            Text("No active sessions")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textTertiary)
                .padding(.leading, 4)
        } else {
            ForEach(sessions, id: \.id) { session in
                sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: SessionSnapshot) -> some View {
        let currentMode = panelModel.sessionModes[
            AppConfig.modeKey(sessionType: session.sessionType, project: session.project)
        ] ?? "ignore"

        return SessionRowView(
            session: session,
            currentMode: currentMode,
            modeOrder: modeOrder,
            onSetSessionMode: onSetSessionMode
        )
    }

    // MARK: - Ops Logs

    private var opsLogsSection: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacing) {
            PanelSectionHeader(title: "Ops Logs (\(logLimit))")
            if panelModel.logs.isEmpty {
                Text("No recent logs")
                    .font(PanelTheme.smallFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panelModel.logs) { row in
                        Text(row.text)
                            .font(PanelTheme.monoFont(size: 10))
                            .foregroundStyle(logColor(from: row.color))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func logColor(from nsColor: NSColor) -> Color {
        // Resolve the NSColor to RGB in the current appearance context.
        // Boost if luminance is too low to be readable on our dark background.
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
            return PanelTheme.textPrimary
        }
        var r = rgb.redComponent
        var g = rgb.greenComponent
        var b = rgb.blueComponent
        let luminance = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)

        let minLuminance: CGFloat = 0.45
        if luminance < minLuminance {
            let lift = min((minLuminance - luminance) / max(1.0 - luminance, 0.001), 1.0)
            r = r + (1.0 - r) * lift * 0.9
            g = g + (1.0 - g) * lift * 0.9
            b = b + (1.0 - b) * lift * 0.9
        }

        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }

}

// MARK: - SessionRowView (tproj card style)

private struct SessionRowView: View {
    let session: SessionSnapshot
    let currentMode: String
    let modeOrder: [String]
    let onSetSessionMode: (String, String, String) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(modeOrder, id: \.self) { mode in
                Button {
                    onSetSessionMode(session.sessionType, session.project, mode)
                } label: {
                    if mode == currentMode {
                        Label(mode.capitalized, systemImage: "checkmark")
                    } else {
                        Text(mode.capitalized)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.project)
                    .font(PanelTheme.font(size: 12, weight: .semibold))
                    .foregroundStyle(PanelTheme.textPrimary)
                    .lineLimit(1)

                PanelPill(
                    text: currentMode,
                    tint: PanelTheme.modeColor(currentMode)
                )

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PanelTheme.textTertiary.opacity(isHovered ? 1 : 0))
            }
            .padding(.vertical, 2)
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(PanelTheme.textPrimary.opacity(isHovered ? 0.08 : 0.05))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(PanelTheme.accentCyan)
                    .frame(width: 2)
                    .shadow(color: PanelTheme.accentCyan.opacity(0.7), radius: 3, x: 0, y: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Collapsed Bar View

struct CollapsedBarView: View {
    let onExpand: () -> Void
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    PanelTheme.accentCyan.opacity(isHovered ? 0.5 : 0.3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(PanelTheme.textSecondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onExpand() }
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Ambient Conversation Log

private struct AmbientLogEntry: Identifiable {
    let id = UUID()
    let text: String
}

private final class AmbientLogModel: ObservableObject {
    @Published var entries: [AmbientLogEntry] = []
    @Published var sessionLabel: String = ""
    private var timer: Timer?

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        let (label, segs) = AmbientStorage.latestSessionSegments(limit: 300)
        sessionLabel = label
        entries = segs.map { AmbientLogEntry(text: $0.text) }
    }
}

/// Conversation Log tab: shows the ambient transcript of the surrounding
/// conversation (most recent session), scrollable and auto-refreshing. The
/// machine transcript is not quote-safe — treat it as context, not record.
struct AmbientLogView: View {
    @StateObject private var model = AmbientLogModel()

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            PanelSectionHeader(title: "Conversation Log")

            if !model.sessionLabel.isEmpty {
                Text(model.sessionLabel)
                    .font(PanelTheme.smallFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            }

            if model.entries.isEmpty {
                Text("No ambient conversation yet. Start Context Stream from the menu bar (right-click the menu-bar icon) to begin capturing nearby speech.")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.entries) { entry in
                                Text(entry.text)
                                    .font(PanelTheme.bodyFont)
                                    .foregroundStyle(PanelTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("ambient-log-bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.entries.count) { _ in
                        proxy.scrollTo("ambient-log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
