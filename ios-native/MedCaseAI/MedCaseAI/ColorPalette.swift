import SwiftUI

enum AppColor {
    private static var palette: AppThemePalette { ThemeManager.shared.activePalette }

    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var surfaceAlt: Color { palette.surfaceAlt }
    static var surfaceElevated: Color { palette.surfaceElevated }
    static var primary: Color { palette.primary }
    static var primaryLight: Color { palette.primaryLight }
    static var primaryDark: Color { palette.primaryDark }
    static var success: Color { palette.success }
    static var successLight: Color { palette.successLight }
    static var warning: Color { palette.warning }
    static var warningLight: Color { palette.warningLight }
    static var error: Color { palette.error }
    static var errorLight: Color { palette.errorLight }
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var textTertiary: Color { palette.textTertiary }
    static var border: Color { palette.border }
    static var tabBarSurface: Color { palette.tabBarSurface }
    static var shadowSoft: Color { palette.shadowSoft }
    static var shadowStrong: Color { palette.shadowStrong }
}
