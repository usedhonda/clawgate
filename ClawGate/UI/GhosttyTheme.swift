import SwiftUI
import AppKit

// MARK: - Color Helpers

extension Color {
    func brighten(_ amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: min(Double(r) + amount, 1.0),
                     green: min(Double(g) + amount, 1.0),
                     blue: min(Double(b) + amount, 1.0))
    }

    func asNSColor() -> NSColor {
        NSColor(self)
    }
}

// MARK: - GhosttyTheme

struct GhosttyTheme {
    let background: Color
    let foreground: Color
    let cursorColor: Color
    let selectionBg: Color
    let selectionFg: Color
    let palette: [Color]
    let fontFamily: String?
    let fontSize: CGFloat
    let backgroundOpacity: Double

    var backgroundLighter: Color { background.brighten(0.10) }
    var cardBackground: Color { background.brighten(0.04) }
    var cardBorder: Color { foreground.opacity(0.06) }
    var textPrimary: Color { foreground }
    var textSecondary: Color { foreground.opacity(0.7) }
    var textTertiary: Color { foreground.opacity(0.35) }
    var accentBlue: Color { palette.indices.contains(4) ? palette[4] : .blue }
    var accentRed: Color { palette.indices.contains(1) ? palette[1] : .red }
    var accentGreen: Color { palette.indices.contains(2) ? palette[2] : .green }
    var accentYellow: Color { palette.indices.contains(3) ? palette[3] : .yellow }
    var accentCyan: Color { palette.indices.contains(6) ? palette[6] : .cyan }

    func font(size: CGFloat, weight: Font.Weight, monospaced: Bool = false) -> Font {
        if let family = fontFamily,
           NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            return Font.custom(family, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }

    static let current = GhosttyConfigParser.load()

    static let fallback = GhosttyTheme(
        background: Color(red: 0.05, green: 0.06, blue: 0.08),
        foreground: .white,
        cursorColor: .white,
        selectionBg: Color(red: 0.3, green: 0.3, blue: 0.3),
        selectionFg: .white,
        palette: [
            Color(red: 0.27, green: 0.27, blue: 0.27), .red, .green, .orange,
            .blue, .purple, .cyan, Color(red: 0.75, green: 0.75, blue: 0.75),
            Color(red: 0.5, green: 0.5, blue: 0.5), .red, .green, .yellow,
            .blue, .purple, .cyan, .white,
        ],
        fontFamily: nil,
        fontSize: 14,
        backgroundOpacity: 1.0
    )
}

// MARK: - GhosttyConfigParser

enum GhosttyConfigParser {
    private struct ParsedConfig {
        var settings: [String: String] = [:]
        var palette: [Int: String] = [:]
    }

    static func load() -> GhosttyTheme {
        let home = NSHomeDirectory()
        let configPath = "\(home)/.config/ghostty/config"

        guard let config = parseFile(configPath) else { return .fallback }

        var merged = ParsedConfig()
        if let themeName = config.settings["theme"],
           let themeConfig = loadTheme(themeName, home: home) {
            merged.settings = themeConfig.settings
            merged.palette = themeConfig.palette
        }

        for (key, value) in config.settings { merged.settings[key] = value }
        for (index, hex) in config.palette { merged.palette[index] = hex }

        return buildTheme(from: merged)
    }

    private static func parseFile(_ filePath: String) -> ParsedConfig? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        var config = ParsedConfig()
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                if let innerEq = rawValue.firstIndex(of: "=") {
                    let idxStr = rawValue[..<innerEq].trimmingCharacters(in: .whitespaces)
                    let colorHex = String(rawValue[rawValue.index(after: innerEq)...]).trimmingCharacters(in: .whitespaces)
                    if let idx = Int(idxStr) { config.palette[idx] = colorHex }
                }
            } else {
                config.settings[key] = rawValue
            }
        }
        return config
    }

    private static func loadTheme(_ name: String, home: String) -> ParsedConfig? {
        let candidates = [
            "\(home)/.config/ghostty/themes/\(name)",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)",
        ]
        for candidatePath in candidates {
            if let config = parseFile(candidatePath),
               !config.settings.isEmpty || !config.palette.isEmpty {
                return config
            }
        }
        return nil
    }

    private static func buildTheme(from config: ParsedConfig) -> GhosttyTheme {
        var palette = GhosttyTheme.fallback.palette
        for (index, hex) in config.palette {
            if palette.indices.contains(index), let color = parseHex(hex) {
                palette[index] = color
            }
        }

        let bg = config.settings["background"].flatMap(parseHex) ?? GhosttyTheme.fallback.background
        let fg = config.settings["foreground"].flatMap(parseHex) ?? GhosttyTheme.fallback.foreground

        return GhosttyTheme(
            background: bg,
            foreground: fg,
            cursorColor: config.settings["cursor-color"].flatMap(parseHex) ?? fg,
            selectionBg: config.settings["selection-background"].flatMap(parseHex) ?? GhosttyTheme.fallback.selectionBg,
            selectionFg: config.settings["selection-foreground"].flatMap(parseHex) ?? fg,
            palette: palette,
            fontFamily: config.settings["font-family"],
            fontSize: config.settings["font-size"].flatMap { CGFloat(Double($0) ?? 14) } ?? 14,
            backgroundOpacity: config.settings["background-opacity"].flatMap(Double.init) ?? 1.0
        )
    }

    private static func parseHex(_ hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        return Color(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}
