import SwiftUI

enum AppColor {
    static let background = Color(hex: "#F8FAFC")
    static let surface = Color(hex: "#FFFFFF")
    static let surfaceAlt = Color(hex: "#F1F5F9")
    static let primary = Color(hex: "#1D6FE8")
    static let primaryLight = Color(hex: "#EBF2FF")
    static let primaryDark = Color(hex: "#1452B8")
    static let success = Color(hex: "#0D9E6E")
    static let successLight = Color(hex: "#ECFDF5")
    static let warning = Color(hex: "#D97706")
    static let warningLight = Color(hex: "#FFFBEB")
    static let error = Color(hex: "#DC2626")
    static let errorLight = Color(hex: "#FEF2F2")
    static let textPrimary = Color(hex: "#0F172A")
    static let textSecondary = Color(hex: "#475569")
    static let textTertiary = Color(hex: "#94A3B8")
    static let border = Color(hex: "#E2E8F0")
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
