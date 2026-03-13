import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "Sistem"
        case .light:
            return "Açık"
        case .dark:
            return "Koyu"
        }
    }
}

struct AppThemePalette {
    let background: Color
    let surface: Color
    let surfaceAlt: Color
    let surfaceElevated: Color

    let primary: Color
    let primaryLight: Color
    let primaryDark: Color

    let success: Color
    let successLight: Color
    let warning: Color
    let warningLight: Color
    let error: Color
    let errorLight: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let border: Color

    let tabBarSurface: Color
    let shadowSoft: Color
    let shadowStrong: Color
}

protocol AppTheme {
    var palette: AppThemePalette { get }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var mode: ThemeMode
    @Published private(set) var systemColorScheme: ColorScheme = .light

    private let key = "settings.theme.mode"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: key) ?? ThemeMode.system.rawValue
        self.mode = ThemeMode(rawValue: stored) ?? .system
    }

    func setMode(_ newMode: ThemeMode) {
        guard mode != newMode else { return }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: key)
    }

    func setSystemColorScheme(_ scheme: ColorScheme) {
        guard systemColorScheme != scheme else { return }
        systemColorScheme = scheme
    }

    var preferredColorScheme: ColorScheme? {
        switch mode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var resolvedColorScheme: ColorScheme {
        switch mode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var activePalette: AppThemePalette {
        switch resolvedColorScheme {
        case .dark:
            return DarkTheme().palette
        default:
            return LightTheme().palette
        }
    }
}
