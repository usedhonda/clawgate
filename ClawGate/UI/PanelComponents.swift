import SwiftUI

// MARK: - PanelSectionHeader

struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(PanelTheme.textPrimary.opacity(0.15))
                .frame(width: 12, height: 1)
            Text(title.uppercased())
                .font(PanelTheme.headerFont)
                .foregroundStyle(PanelTheme.textPrimary)
        }
    }
}

// MARK: - PanelCard

struct PanelCard<Content: View>: View {
    let compact: Bool
    let chrome: Bool
    let content: Content

    init(compact: Bool = false, chrome: Bool = true, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.chrome = chrome
        self.content = content()
    }

    private var cardPadding: CGFloat { compact ? 2 : 6 }
    private var cardSpacing: CGFloat { compact ? 4 : 8 }
    private var cardRadius: CGFloat { compact ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            content
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(chrome ? PanelTheme.backgroundCard : Color.clear)
        )
        .overlay(
            chrome
                ? AnyView(
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .stroke(PanelTheme.cardBorder, lineWidth: 1)
                )
                : AnyView(EmptyView())
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

    private var labelColor: Color {
        lit ? .white : color.brighten(0.12).opacity(0.96)
    }

    private var fillColor: Color {
        if lit { return color.opacity(0.85) }
        return PanelTheme.backgroundCard.brighten(0.04)
    }

    private var tintColor: Color {
        if lit { return .clear }
        return color.opacity(0.10)
    }

    private var strokeColor: Color {
        if lit { return color }
        return color.opacity(0.30)
    }

    var body: some View {
        Text(text)
            .font(PanelTheme.font(size: fontSize, weight: lit ? .bold : .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, lit ? 6 : 5)
            .padding(.vertical, lit ? 2 : 1)
            .background(
                Capsule()
                    .fill(fillColor)
                    .overlay(
                        Capsule()
                            .fill(tintColor)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(strokeColor, lineWidth: lit ? 1 : 0.75)
            )
            .shadow(color: lit ? color.opacity(0.65) : .clear, radius: 4, x: 0, y: 0)
    }
}

// MARK: - ActionButton

enum ActionButtonTone {
    case neutral
    case primary
    case danger
}

struct ActionButtonStyle: ButtonStyle {
    let tone: ActionButtonTone
    let dense: Bool
    let expand: Bool
    let isEnabled: Bool

    @State private var isHovered = false

    private var fillColor: Color {
        switch tone {
        case .neutral:
            if isHovered { return PanelTheme.selectionBg.opacity(0.6) }
            return PanelTheme.textPrimary.opacity(0.08)
        case .primary:
            if isHovered { return PanelTheme.accentBlue.opacity(0.62) }
            return PanelTheme.accentBlue.opacity(0.46)
        case .danger:
            if isHovered { return PanelTheme.accentRed.opacity(0.20) }
            return PanelTheme.accentRed.opacity(0.12)
        }
    }

    private var pressedFillColor: Color {
        switch tone {
        case .neutral: return PanelTheme.selectionBg.opacity(0.4)
        case .primary: return PanelTheme.accentBlue.opacity(0.75)
        case .danger:  return PanelTheme.accentRed.opacity(0.26)
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral: return PanelTheme.textPrimary
        case .primary: return PanelTheme.accentBlue
        case .danger:  return PanelTheme.accentRed
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PanelTheme.font(size: dense ? 11 : 13, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, dense ? 6 : 10)
            .padding(.vertical, dense ? 3 : 5)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(minHeight: dense ? 18 : 32)
            .background(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? pressedFillColor : fillColor)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.02 : 1.0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .opacity(isEnabled ? 1.0 : 0.45)
            .onHover { hovering in isHovered = hovering }
    }
}

struct ActionButton: View {
    let title: String
    var tone: ActionButtonTone = .neutral
    var dense: Bool = false
    var expand: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(ActionButtonStyle(tone: tone, dense: dense, expand: expand, isEnabled: isEnabled))
        .disabled(!isEnabled)
    }
}

// Keep backward compat alias
typealias PanelActionButton = ActionButton
typealias PanelButtonTone = ActionButtonTone

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
                .foregroundStyle(isSelected ? PanelTheme.accentCyan : PanelTheme.textPrimary.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius, style: .continuous)
                        .fill(isSelected
                              ? PanelTheme.accentCyan.opacity(0.12)
                              : PanelTheme.textPrimary.opacity(isHovered ? 0.10 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.cornerRadius, style: .continuous)
                        .stroke(isSelected
                                ? PanelTheme.accentCyan.opacity(0.25)
                                : (isHovered ? PanelTheme.controlBorderStrong : PanelTheme.controlBorder),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering }
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
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius, style: .continuous)
                    .fill(PanelTheme.background.brighten(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.cornerRadius, style: .continuous)
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
