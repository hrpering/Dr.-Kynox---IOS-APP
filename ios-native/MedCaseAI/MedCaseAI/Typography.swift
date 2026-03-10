import SwiftUI

enum AppFont {
    // 3-tier typography system
    static let h1 = Font.system(size: 28, weight: .bold, design: .rounded)
    static let h2 = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let h3 = Font.system(size: 18, weight: .semibold, design: .default)
    static let body = Font.system(size: 16, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 16, weight: .medium, design: .default)
    static let secondary = Font.system(size: 13, weight: .medium, design: .default)

    // Backward-compatible aliases used across existing screens
    static let largeTitle = h1
    static let title = h2
    static let title2 = h3
    static let caption = secondary
}
