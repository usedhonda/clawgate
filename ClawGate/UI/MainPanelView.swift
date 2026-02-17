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
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var panelModel: MainPanelModel

    let modeOrder: [String]
    let modeLabel: (String) -> String
    let modeColor: (String) -> NSColor
    let onSetSessionMode: (String, String, String) -> Void
    let onOpenQRCode: () -> Void
    let onQuit: () -> Void

    private let bodyFont = Font.system(size: 13, weight: .semibold, design: .monospaced)
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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                sessionSection(title: "Codex Sessions", sessions: panelModel.codexSessions)
                sessionSection(title: "Claude Code Sessions", sessions: panelModel.claudeSessions)

                Divider()

                sectionTitle("Ops Logs (latest 10)")
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

                Divider()

                sectionTitle("Settings")
                InlineSettingsView(model: settingsModel, embedInScroll: false, onOpenQRCode: onOpenQRCode)

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
        }
        .frame(width: 520, height: 780)
        .background(.ultraThinMaterial)
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
