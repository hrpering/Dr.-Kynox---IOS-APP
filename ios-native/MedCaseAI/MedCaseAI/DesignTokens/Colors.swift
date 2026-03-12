import SwiftUI

enum DesignColorTokens {
    enum Light {
        static let background = Color(hex: "#F6F7F7")
        static let surface = Color(hex: "#FFFFFF")
        static let surfaceAlt = Color(hex: "#ECF1F1")
        static let surfaceElevated = Color(hex: "#FFFFFF")

        static let primary = Color(hex: "#53B1AD")
        static let primaryLight = Color(hex: "#DFF1F1")
        static let primaryDark = Color(hex: "#2C7A7B")

        static let success = Color(hex: "#22C55E")
        static let successLight = Color(hex: "#ECFDF3")
        static let warning = Color(hex: "#FF6B00")
        static let warningLight = Color(hex: "#FFF3E8")
        static let error = Color(hex: "#EA4335")
        static let errorLight = Color(hex: "#FDECEC")

        static let textPrimary = Color(hex: "#151D1D")
        static let textSecondary = Color(hex: "#4A5D5D")
        static let textTertiary = Color(hex: "#8A9A9A")
        static let border = Color(hex: "#DDE7E7")

        static let tabBarSurface = Color(hex: "#FFFFFF")
        static let shadowSoft = Color(hex: "#0A132520")
        static let shadowStrong = Color(hex: "#0A132536")
    }

    enum Dark {
        static let background = Color(hex: "#0A1325")
        static let surface = Color(hex: "#151D1D")
        static let surfaceAlt = Color(hex: "#1E2A2A")
        static let surfaceElevated = Color(hex: "#1A2424")

        static let primary = Color(hex: "#5EB1B1")
        static let primaryLight = Color(hex: "#1A3A3A")
        static let primaryDark = Color(hex: "#B8E1E1")

        static let success = Color(hex: "#34D399")
        static let successLight = Color(hex: "#163826")
        static let warning = Color(hex: "#FBBC05")
        static let warningLight = Color(hex: "#3B2D0F")
        static let error = Color(hex: "#F87171")
        static let errorLight = Color(hex: "#3A1C1C")

        static let textPrimary = Color(hex: "#F6F7F7")
        static let textSecondary = Color(hex: "#C8D7D7")
        static let textTertiary = Color(hex: "#95A7A7")
        static let border = Color(hex: "#2C5C5C")

        static let tabBarSurface = Color(hex: "#151D1D")
        static let shadowSoft = Color(hex: "#00000066")
        static let shadowStrong = Color(hex: "#00000099")
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
