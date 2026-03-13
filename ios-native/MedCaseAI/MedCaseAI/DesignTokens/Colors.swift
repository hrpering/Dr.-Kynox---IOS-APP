import SwiftUI

enum DesignColorTokens {
    enum Light {
        static let background = Color(hex: "#F8FAFC")
        static let surface = Color(hex: "#FFFFFF")
        static let surfaceAlt = Color(hex: "#F1F5F9")
        static let surfaceElevated = Color(hex: "#F8FAFC")

        static let primary = Color(hex: "#3B82F6")
        static let primaryLight = Color(hex: "#DBEAFE")
        static let primaryDark = Color(hex: "#0F172A")

        static let success = Color(hex: "#22C55E")
        static let successLight = Color(hex: "#DCFCE7")
        static let warning = Color(hex: "#F59E0B")
        static let warningLight = Color(hex: "#FEF3C7")
        static let error = Color(hex: "#EF4444")
        static let errorLight = Color(hex: "#FEE2E2")

        static let textPrimary = Color(hex: "#0F172A")
        static let textSecondary = Color(hex: "#64748B")
        static let textTertiary = Color(hex: "#94A3B8")
        static let border = Color(hex: "#E2E8F0")

        static let tabBarSurface = Color(hex: "#FFFFFF")
        static let shadowSoft = Color(hex: "#0000000D")
        static let shadowStrong = Color(hex: "#0000001A")
    }

    enum Dark {
        static let background = Color(hex: "#0B1220")
        static let surface = Color(hex: "#111827")
        static let surfaceAlt = Color(hex: "#1F2937")
        static let surfaceElevated = Color(hex: "#111827")

        static let primary = Color(hex: "#60A5FA")
        static let primaryLight = Color(hex: "#1E3A5F")
        static let primaryDark = Color(hex: "#DBEAFE")

        static let success = Color(hex: "#4ADE80")
        static let successLight = Color(hex: "#1F3A2B")
        static let warning = Color(hex: "#FBBF24")
        static let warningLight = Color(hex: "#3D3320")
        static let error = Color(hex: "#F87171")
        static let errorLight = Color(hex: "#3C2323")

        static let textPrimary = Color(hex: "#E5E7EB")
        static let textSecondary = Color(hex: "#CBD5E1")
        static let textTertiary = Color(hex: "#94A3B8")
        static let border = Color(hex: "#334155")

        static let tabBarSurface = Color(hex: "#0F172A")
        static let shadowSoft = Color(hex: "#0000004D")
        static let shadowStrong = Color(hex: "#00000080")
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r: Double
        let g: Double
        let b: Double
        let a: Double

        switch cleaned.count {
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1.0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
