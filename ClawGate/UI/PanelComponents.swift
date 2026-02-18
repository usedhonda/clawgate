import SwiftUI

// MARK: - PanelSectionHeader

struct PanelSectionHeader: View {
    let title: String
    var accentColor: Color = PanelTheme.accentCyan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(PanelTheme.headerFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Rectangle()
                .fill(accentColor)
                .frame(width: 12, height: 2)
        }
    }
}

// MARK: - PanelCard

struct PanelCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacing) {
            content
        }
        .padding(PanelTheme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                .fill(PanelTheme.backgroundCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                .stroke(PanelTheme.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - PanelPill

struct PanelPill: View {
    let text: String
    var color: Color = PanelTheme.textSecondary
    var fontSize: CGFloat = 9
    /// When true, pill renders as a solid lit badge with glow.
    var lit: Bool = false

    var body: some View {
        Text(text)
            .font(PanelTheme.font(size: fontSize, weight: lit ? .bold : .semibold))
            .foregroundStyle(lit ? .white : color)
            .padding(.horizontal, lit ? 6 : 5)
            .padding(.vertical, lit ? 2 : 1)
            .background(
                RoundedRectangle(cornerRadius: PanelTheme.pillRadius)
                    .fill(lit ? color.opacity(0.85) : color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.pillRadius)
                    .stroke(lit ? color : color.opacity(0.20), lineWidth: lit ? 1 : 0.5)
            )
            .shadow(color: lit ? color.opacity(0.65) : .clear, radius: 4, x: 0, y: 0)
    }
}

// MARK: - PanelActionButton

enum PanelButtonTone {
    case neutral
    case primary
    case danger
}

struct PanelActionButton: View {
    let title: String
    var tone: PanelButtonTone = .neutral
    var dense: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var fillColor: Color {
        switch tone {
        case .neutral: return PanelTheme.textPrimary.opacity(isHovered ? 0.12 : 0.06)
        case .primary: return PanelTheme.accentCyan.opacity(isHovered ? 0.22 : 0.14)
        case .danger:  return PanelTheme.accentRed.opacity(isHovered ? 0.22 : 0.14)
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral: return PanelTheme.textPrimary
        case .primary: return PanelTheme.accentCyan
        case .danger:  return PanelTheme.accentRed
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: return PanelTheme.textPrimary.opacity(isHovered ? 0.18 : 0.10)
        case .primary: return PanelTheme.accentCyan.opacity(isHovered ? 0.30 : 0.20)
        case .danger:  return PanelTheme.accentRed.opacity(isHovered ? 0.30 : 0.20)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelTheme.font(size: dense ? 10 : 11, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, dense ? 6 : 10)
                .padding(.vertical, dense ? 3 : 5)
                .background(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

// MARK: - PanelTabButton

struct PanelTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelTheme.font(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? PanelTheme.accentCyan : PanelTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                        .fill(isSelected
                              ? PanelTheme.accentCyan.opacity(0.12)
                              : (isHovered ? PanelTheme.textPrimary.opacity(0.06) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                        .stroke(isSelected
                                ? PanelTheme.accentCyan.opacity(0.25)
                                : (isHovered ? PanelTheme.textPrimary.opacity(0.10) : Color.clear),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

// MARK: - PanelInputModifier

struct PanelInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(PanelTheme.bodyFont)
            .foregroundStyle(PanelTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                    .fill(PanelTheme.background.brighten(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius)
                    .stroke(PanelTheme.textPrimary.opacity(0.10), lineWidth: 1)
            )
    }
}

// MARK: - Status Dot (5x5 tproj style)

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
    }
}
