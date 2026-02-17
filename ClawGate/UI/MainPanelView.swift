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
    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var panelModel: MainPanelModel

    let modeOrder: [String]
    let modeLabel: (String) -> String
    let modeColor: (String) -> NSColor
    let onSetSessionMode: (String, String, String) -> Void
    let onOpenQRCode: () -> Void
    let onQuit: () -> Void

    private let bodyFont = Font.system(size: 13, weight: .medium, design: .monospaced)
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
                            .foregroundStyle(Color(nsColor: row.color))
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
                    .foregroundStyle(Color(nsColor: modeColor(currentMode)))
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
}
