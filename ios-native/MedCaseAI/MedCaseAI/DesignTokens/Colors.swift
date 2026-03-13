import SwiftUI

enum DesignColorTokens {
    enum Light {
        static let background = Color(hex: "#F3F5F9")
        static let surface = Color(hex: "#FFFFFF")
        static let surfaceAlt = Color(hex: "#EEF2F8")
        static let surfaceElevated = Color(hex: "#F8FAFD")

        static let primary = Color(hex: "#3F7FF2")
        static let primaryLight = Color(hex: "#E8F0FF")
        static let primaryDark = Color(hex: "#0F1B3A")

        static let success = Color(hex: "#20B87A")
        static let successLight = Color(hex: "#E7F7EF")
        static let warning = Color(hex: "#F58A1D")
        static let warningLight = Color(hex: "#FFF1E3")
        static let error = Color(hex: "#EC4D4D")
        static let errorLight = Color(hex: "#FEECEC")

        static let textPrimary = Color(hex: "#111B35")
        static let textSecondary = Color(hex: "#61728D")
        static let textTertiary = Color(hex: "#9BA9BF")
        static let border = Color(hex: "#DFE6F1")

        static let tabBarSurface = Color(hex: "#FFFFFF")
        static let shadowSoft = Color(hex: "#0D1F3D14")
        static let shadowStrong = Color(hex: "#0D1F3D24")
    }

    enum Dark {
        static let background = Color(hex: "#0A1023")
        static let surface = Color(hex: "#111B31")
        static let surfaceAlt = Color(hex: "#1A2740")
        static let surfaceElevated = Color(hex: "#151F36")

        static let primary = Color(hex: "#6EA1FF")
        static let primaryLight = Color(hex: "#243A63")
        static let primaryDark = Color(hex: "#EAF1FF")

        static let success = Color(hex: "#43D89C")
        static let successLight = Color(hex: "#1B3A30")
        static let warning = Color(hex: "#FDB14F")
        static let warningLight = Color(hex: "#41321B")
        static let error = Color(hex: "#FF8C8C")
        static let errorLight = Color(hex: "#45242A")

        static let textPrimary = Color(hex: "#F2F6FF")
        static let textSecondary = Color(hex: "#B3C0D7")
        static let textTertiary = Color(hex: "#8295B4")
        static let border = Color(hex: "#263759")

        static let tabBarSurface = Color(hex: "#10182D")
        static let shadowSoft = Color(hex: "#00000052")
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
