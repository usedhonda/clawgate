import SwiftUI
import AppKit

struct MainPanelLogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: NSColor
    let event: String   // deduplication key (e.g. entry.event)
}

final class MainPanelModel: ObservableObject {
    @Published var codexSessions: [CCStatusBarClient.CCSession] = []
    @Published var claudeSessions: [CCStatusBarClient.CCSession] = []
    @Published var sessionModes: [String: String] = [:]
    @Published var logs: [MainPanelLogLine] = []
}

struct MainPanelView: View {
    private enum Tab: String, CaseIterable {
        case monitor = "Monitor"
        case config  = "Config"
    }

    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var panelModel: MainPanelModel

    let modeOrder: [String]
    let modeLabel: (String) -> String
    let onSetSessionMode: (String, String, String) -> Void
    let onQuit: () -> Void
    let logLimit: Int

    @State private var selectedTab: Tab = .monitor

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacing) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.rawValue) { tab in
                    PanelTabButton(
                        title: tab.rawValue,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .padding(.bottom, 2)

            // Tab content
            tabContent

            // Quit
            PanelActionButton(title: "Quit", tone: .danger, dense: true, action: onQuit)
        }
        .padding(PanelTheme.padding)
        .frame(minWidth: 380, maxWidth: 700, minHeight: 400, maxHeight: 1400)
        .background(PanelTheme.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .monitor:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
                    sessionSection(title: "Codex Sessions", sessions: panelModel.codexSessions)
                    sessionSection(title: "Claude Code Sessions", sessions: panelModel.claudeSessions)

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

                    Rectangle()
                        .fill(PanelTheme.cardBorder)
                        .frame(height: 1)

                    vibetermSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private func sessionSection(title: String, sessions: [CCStatusBarClient.CCSession]) -> some View {
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

    private func sessionRow(_ session: CCStatusBarClient.CCSession) -> some View {
        let currentMode = panelModel.sessionModes[
            AppConfig.modeKey(sessionType: session.sessionType, project: session.project)
        ] ?? "ignore"

        return SessionRowView(
            session: session,
            currentMode: currentMode,
            modeOrder: modeOrder,
            modeLabel: modeLabel,
            onSetSessionMode: onSetSessionMode
        )
    }

    // MARK: - Ops Logs

    private var opsLogsSection: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacing) {
            PanelSectionHeader(title: "Ops Logs (\(logLimit))", accentColor: PanelTheme.accentYellow)
            if panelModel.logs.isEmpty {
                Text("No recent logs")
                    .font(PanelTheme.smallFont)
                    .foregroundStyle(PanelTheme.textTertiary)
            } else {
                ForEach(panelModel.logs) { row in
                    Text(row.text)
                        .font(PanelTheme.smallFont)
                        .foregroundStyle(logColor(from: row.color))
                        .lineLimit(1)
                }
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

    // MARK: - VibeTerm

    private var vibetermSection: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            PanelSectionHeader(title: "VibeTerm", accentColor: PanelTheme.accentGreen)

            Text("Connect VibeTerm to OpenClaw on iPhone.")
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textSecondary)

            HStack(spacing: 4) {
                PanelPill(text: "OpenClaw-linked", color: PanelTheme.accentCyan, fontSize: 10)
                PanelPill(text: "Mobile Handoff", color: PanelTheme.accentGreen, fontSize: 10)
                PanelPill(text: "Remote Control", color: PanelTheme.accentBlue, fontSize: 10)
            }

            QRCodeView()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - SessionRowView (hover-aware)

private struct SessionRowView: View {
    let session: CCStatusBarClient.CCSession
    let currentMode: String
    let modeOrder: [String]
    let modeLabel: (String) -> String
    let onSetSessionMode: (String, String, String) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(modeOrder, id: \.self) { mode in
                Button {
                    onSetSessionMode(session.sessionType, session.project, mode)
                } label: {
                    HStack {
                        Text(modeLabel(mode))
                        if mode == currentMode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                StatusDot(color: dotColor)

                Text(session.project)
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(PanelTheme.textPrimary)
                    .lineLimit(1)

                PanelPill(
                    text: currentMode,
                    color: PanelTheme.modeColor(currentMode),
                    lit: currentMode != "ignore"
                )

                PanelPill(
                    text: PanelTheme.sessionTypeLabel(session.sessionType),
                    color: PanelTheme.sessionTypeColor(session.sessionType)
                )

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PanelTheme.textTertiary.opacity(isHovered ? 1 : 0))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                    .fill(PanelTheme.textPrimary.opacity(isHovered ? 0.08 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                    .stroke(PanelTheme.textPrimary.opacity(isHovered ? 0.12 : 0), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var dotColor: Color {
        if currentMode == "ignore" { return PanelTheme.textTertiary }
        return PanelTheme.statusColor(session.status)
    }
}
