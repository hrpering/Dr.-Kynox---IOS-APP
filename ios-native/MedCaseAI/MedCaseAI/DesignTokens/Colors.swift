import SwiftUI

enum DesignColorTokens {
    enum Light {
        static let background = Color(hex: "#F3F8F8")
        static let surface = Color(hex: "#FFFFFF")
        static let surfaceAlt = Color(hex: "#EAF3F3")
        static let surfaceElevated = Color(hex: "#FFFFFF")

        static let primary = Color(hex: "#4EA7A6")
        static let primaryLight = Color(hex: "#DFF1F1")
        static let primaryDark = Color(hex: "#2A6E70")

        static let success = Color(hex: "#16A562")
        static let successLight = Color(hex: "#ECFDF3")
        static let warning = Color(hex: "#F97316")
        static let warningLight = Color(hex: "#FFF3E8")
        static let error = Color(hex: "#EA4335")
        static let errorLight = Color(hex: "#FDECEC")

        static let textPrimary = Color(hex: "#112025")
        static let textSecondary = Color(hex: "#465B64")
        static let textTertiary = Color(hex: "#7E95A0")
        static let border = Color(hex: "#D3E3E6")

        static let tabBarSurface = Color(hex: "#FFFFFF")
        static let shadowSoft = Color(hex: "#08222E1F")
        static let shadowStrong = Color(hex: "#08222E33")
    }

    enum Dark {
        static let background = Color(hex: "#0D1720")
        static let surface = Color(hex: "#17232A")
        static let surfaceAlt = Color(hex: "#223038")
        static let surfaceElevated = Color(hex: "#1B2931")

        static let primary = Color(hex: "#63B8B7")
        static let primaryLight = Color(hex: "#1A3A43")
        static let primaryDark = Color(hex: "#C2EAEB")

        static let success = Color(hex: "#39D391")
        static let successLight = Color(hex: "#1A3D2A")
        static let warning = Color(hex: "#FBC15E")
        static let warningLight = Color(hex: "#433117")
        static let error = Color(hex: "#F87171")
        static let errorLight = Color(hex: "#452123")

        static let textPrimary = Color(hex: "#F1F7F8")
        static let textSecondary = Color(hex: "#C1D2D8")
        static let textTertiary = Color(hex: "#8FA4AF")
        static let border = Color(hex: "#2D4450")

        static let tabBarSurface = Color(hex: "#16242C")
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
