import SwiftUI
import AppKit

enum PanelTheme {
    private static let theme = GhosttyTheme.current

    // MARK: - Colors

    static let background = theme.background
    static let backgroundCard = theme.cardBackground
    static let cardBorder = theme.cardBorder

    static let textPrimary = theme.textPrimary
    static let textSecondary = theme.foreground.opacity(0.78)
    static let textTertiary = theme.foreground.opacity(0.50)

    static let accentCyan = theme.accentCyan
    static let accentGreen = theme.accentGreen
    static let accentYellow = theme.accentYellow
    static let accentRed = theme.accentRed
    static let accentBlue = theme.accentBlue

    // MARK: - Mode Colors

    static func modeColor(_ mode: String) -> Color {
        switch mode {
        case "autonomous": return accentRed
        case "auto":       return accentYellow
        case "observe":    return accentBlue
        default:           return textTertiary
        }
    }

    static func modeNSColor(_ mode: String) -> NSColor {
        NSColor(modeColor(mode))
    }

    // MARK: - Status Colors

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "running":       return accentGreen
        case "waiting_input": return accentCyan
        default:              return textTertiary
        }
    }

    // MARK: - Session Type Colors

    static func sessionTypeColor(_ sessionType: String) -> Color {
        switch sessionType {
        case "codex":       return accentYellow
        case "claude_code": return accentCyan
        default:            return textSecondary
        }
    }

    static func sessionTypeLabel(_ sessionType: String) -> String {
        switch sessionType {
        case "codex":       return "cdx"
        case "claude_code": return "cc"
        default:            return sessionType
        }
    }

    // MARK: - Connectivity

    static func connectivityColor(_ text: String) -> Color {
        switch text {
        case "Connected":    return accentGreen
        case "Disconnected": return accentRed
        case "Checking":     return accentYellow
        default:             return textTertiary
        }
    }

    // MARK: - Fonts

    static func font(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        theme.font(size: size, weight: weight, monospaced: true)
    }

    static let bodyFont = font(size: 11, weight: .regular)
    static let titleFont = font(size: 12, weight: .semibold)
    static let smallFont = font(size: 10, weight: .regular)
    static let headerFont = font(size: 14, weight: .semibold)

    // MARK: - Layout Constants

    static let spacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 8
    static let padding: CGFloat = 10
    static let cardPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 3
    static let pillRadius: CGFloat = 3

    // MARK: - NSColor for panel background

    static var backgroundNSColor: NSColor {
        NSColor(background)
    }
}
