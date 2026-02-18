import SwiftUI
import AppKit

struct MainPanelLogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: NSColor
}

final class MainPanelModel: ObservableObject {
    @Published var codexSessions: [CCStatusBarClient.CCSession] = []
    @Published var claudeSessions: [CCStatusBarClient.CCSession] = []
    @Published var sessionModes: [String: String] = [:]
    @Published var logs: [MainPanelLogLine] = []
}

struct MainPanelView: View {
    private enum MainPanelTab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case opsLogs = "Ops Logs"
        case settings = "Settings"
        case vibeterm = "VibeTerm"

        var id: String { rawValue }
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var panelModel: MainPanelModel

    let modeOrder: [String]
    let modeLabel: (String) -> String
    let modeColor: (String) -> NSColor
    let onSetSessionMode: (String, String, String) -> Void
    let onQuit: () -> Void
    let logLimit: Int

    @State private var selectedTab: MainPanelTab = .sessions

    private let bodyFont = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    private let titleFont = Font.system(size: 13, weight: .semibold, design: .monospaced)

    private struct HoverInteractiveRowModifier: ViewModifier {
        let cornerRadius: CGFloat
        @State private var isHovered = false

        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.22 : 0), lineWidth: 1)
                )
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Section", selection: $selectedTab) {
                ForEach(MainPanelTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Divider()

            tabContent

            Divider()

            Button(action: onQuit) {
                HStack(spacing: 8) {
                    Text("Quit")
                        .font(titleFont)
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .modifier(HoverInteractiveRowModifier(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 700, minHeight: 400, maxHeight: 1400)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .sessions:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sessionSection(title: "Codex Sessions", sessions: panelModel.codexSessions)
                    sessionSection(title: "Claude Code Sessions", sessions: panelModel.claudeSessions)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .opsLogs:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Ops Logs (latest \(logLimit))")
                    if panelModel.logs.isEmpty {
                        Text("  No recent logs")
                            .font(bodyFont)
                            .foregroundStyle(Color.secondary)
                    } else {
                        ForEach(panelModel.logs) { row in
                            Text("  \(row.text)")
                                .font(bodyFont)
                                .foregroundStyle(readableSemanticColor(from: row.color))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .settings:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Settings")
                    InlineSettingsView(model: settingsModel, embedInScroll: false, onOpenQRCode: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .vibeterm:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("VibeTerm")

                    Text("Connect VibeTerm to OpenClaw on iPhone and keep your coding flow alive away from desk.")
                        .font(bodyFont)
                        .foregroundStyle(Color.secondary)

                    HStack(spacing: 8) {
                        vibetermPill("OpenClaw-linked", icon: "bolt.horizontal.circle")
                        vibetermPill("Mobile Handoff", icon: "arrow.triangle.2.circlepath")
                        vibetermPill("Remote Control", icon: "network")
                    }

                    QRCodeView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func sessionSection(title: String, sessions: [CCStatusBarClient.CCSession]) -> some View {
        sectionTitle(title)
        if sessions.isEmpty {
            Text("  No active sessions")
                .font(bodyFont)
                .foregroundStyle(Color.secondary)
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

        return Menu {
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
            HStack(spacing: 8) {
                Text("  \(statusIcon(session: session, mode: currentMode)) \(session.project)")
                    .font(bodyFont)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("[\(currentMode)]")
                    .font(bodyFont)
                    .foregroundStyle(readableSemanticColor(from: modeColor(currentMode)))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .modifier(HoverInteractiveRowModifier(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(titleFont)
            .foregroundStyle(Color.primary)
    }

    private func vibetermPill(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Color.primary.opacity(0.82))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private func statusIcon(session: CCStatusBarClient.CCSession, mode: String) -> String {
        if mode == "ignore" {
            return "○"
        }
        switch session.status {
        case "running":
            return "▶"
        case "waiting_input":
            return "●"
        default:
            return "○"
        }
    }

    private func readableSemanticColor(from color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return Color(nsColor: color)
        }
        var red = rgb.redComponent
        var green = rgb.greenComponent
        var blue = rgb.blueComponent
        let alpha = max(rgb.alphaComponent, 0.94)
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)

        if colorScheme == .light {
            let maxLuminance: CGFloat = 0.42
            if luminance > maxLuminance {
                let scale = maxLuminance / max(luminance, 0.001)
                red *= scale
                green *= scale
                blue *= scale
            }
            if let label = NSColor.labelColor.usingColorSpace(.deviceRGB) {
                let blend: CGFloat = 0.16
                red = (red * (1.0 - blend)) + (label.redComponent * blend)
                green = (green * (1.0 - blend)) + (label.greenComponent * blend)
                blue = (blue * (1.0 - blend)) + (label.blueComponent * blend)
            }
        } else {
            let minLuminance: CGFloat = 0.60
            if luminance < minLuminance {
                let lift = min((minLuminance - luminance) / max(1.0 - luminance, 0.001), 1.0)
                red = red + (1.0 - red) * lift * 0.55
                green = green + (1.0 - green) * lift * 0.55
                blue = blue + (1.0 - blue) * lift * 0.55
            }
        }

        return Color(nsColor: NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        ))
    }
}
