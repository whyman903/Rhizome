import SwiftUI
import RhizomeCore

nonisolated(unsafe) var activeTheme: AppTheme = {
    AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .umber
}()

nonisolated(unsafe) var activeFont: AppFont = {
    AppFont(rawValue: UserDefaults.standard.string(forKey: "appFont") ?? "") ?? .serif
}()

extension AppFont {
    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .mono: return .monospaced
        }
    }
}

struct ThemeColorSet {
    let background: Color
    let backgroundTop: Color
    let surface: Color
    let surfaceHover: Color
    let border: Color
    let borderHover: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentHover: Color
    let warning: Color

    static let ivory = ThemeColorSet(
        background:    Color(red: 0.980, green: 0.978, blue: 0.968),
        backgroundTop: Color(red: 0.950, green: 0.942, blue: 0.922),
        surface:       Color(red: 0.930, green: 0.918, blue: 0.894),
        surfaceHover:  Color(red: 0.900, green: 0.886, blue: 0.858),
        border:        Color(red: 0.840, green: 0.824, blue: 0.792),
        borderHover:   Color(red: 0.770, green: 0.750, blue: 0.714),
        textPrimary:   Color(red: 0.100, green: 0.094, blue: 0.082),
        textSecondary: Color(red: 0.360, green: 0.337, blue: 0.314),
        textTertiary:  Color(red: 0.608, green: 0.580, blue: 0.564),
        accent:        Color(red: 0.720, green: 0.475, blue: 0.180),
        accentHover:   Color(red: 0.830, green: 0.537, blue: 0.227),
        warning:       Color(red: 0.770, green: 0.302, blue: 0.227)
    )

    static let obsidian = ThemeColorSet(
        background:    Color(red: 0.040, green: 0.040, blue: 0.040),
        backgroundTop: Color(red: 0.070, green: 0.070, blue: 0.070),
        surface:       Color(red: 0.100, green: 0.100, blue: 0.100),
        surfaceHover:  Color(red: 0.140, green: 0.140, blue: 0.140),
        border:        Color(red: 0.180, green: 0.180, blue: 0.180),
        borderHover:   Color(red: 0.230, green: 0.230, blue: 0.230),
        textPrimary:   Color(red: 0.910, green: 0.910, blue: 0.910),
        textSecondary: Color(red: 0.540, green: 0.540, blue: 0.540),
        textTertiary:  Color(red: 0.350, green: 0.350, blue: 0.350),
        accent:        Color(red: 0.910, green: 0.910, blue: 0.910),
        accentHover:   Color(red: 1.000, green: 1.000, blue: 1.000),
        warning:       Color(red: 0.880, green: 0.314, blue: 0.251)
    )

    static let umber = ThemeColorSet(
        background:    Color(red: 0.0902, green: 0.0706, blue: 0.0549),
        backgroundTop: Color(red: 0.1098, green: 0.0902, blue: 0.0667),
        surface:       Color(red: 0.1216, green: 0.1020, blue: 0.0784),
        surfaceHover:  Color(red: 0.1490, green: 0.1255, blue: 0.0980),
        border:        Color(red: 0.1765, green: 0.1490, blue: 0.1255),
        borderHover:   Color(red: 0.2275, green: 0.1922, blue: 0.1608),
        textPrimary:   Color(red: 0.9608, green: 0.9333, blue: 0.8745),
        textSecondary: Color(red: 0.7647, green: 0.7216, blue: 0.6275),
        textTertiary:  Color(red: 0.4980, green: 0.4471, blue: 0.3765),
        accent:        Color(red: 0.8314, green: 0.6588, blue: 0.3529),
        accentHover:   Color(red: 0.8941, green: 0.7255, blue: 0.4078),
        warning:       Color(red: 0.8500, green: 0.5200, blue: 0.3200)
    )

    static func forTheme(_ theme: AppTheme) -> ThemeColorSet {
        switch theme {
        case .ivory: return .ivory
        case .obsidian: return .obsidian
        case .umber: return .umber
        }
    }
}

enum EditorialPalette {
    private static var colors: ThemeColorSet { .forTheme(activeTheme) }
    static var background: Color    { colors.background }
    static var backgroundTop: Color { colors.backgroundTop }
    static var surface: Color       { colors.surface }
    static var surfaceHover: Color  { colors.surfaceHover }
    static var border: Color        { colors.border }
    static var borderHover: Color   { colors.borderHover }
    static var textPrimary: Color   { colors.textPrimary }
    static var textSecondary: Color { colors.textSecondary }
    static var textTertiary: Color  { colors.textTertiary }
    static var accent: Color        { colors.accent }
    static var accentHover: Color   { colors.accentHover }
    static var link: Color {
        switch activeTheme {
        case .obsidian:
            return Color(red: 0.520, green: 0.740, blue: 1.000)
        case .ivory, .umber:
            return colors.accent
        }
    }
    static var warning: Color       { colors.warning }
}
