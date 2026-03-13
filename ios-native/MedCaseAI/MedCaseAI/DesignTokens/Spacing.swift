import SwiftUI

enum SpacingTokens {
    static let x1: CGFloat = 8
    static let x1_5: CGFloat = 12
    static let x2: CGFloat = 16
    static let x3: CGFloat = 24
    static let x4: CGFloat = 32
    static let x5: CGFloat = 40

    static let cardPadding: CGFloat = x2
    static let sectionSpacing: CGFloat = 20
    static let elementSpacing: CGFloat = x2
    static let buttonHeight: CGFloat = 56
    static let listRowHeight: CGFloat = 64
}

enum AppSpacing {
    static let x1: CGFloat = SpacingTokens.x1
    static let x1_5: CGFloat = SpacingTokens.x1_5
    static let x2: CGFloat = SpacingTokens.x2
    static let x3: CGFloat = SpacingTokens.x3
    static let x4: CGFloat = SpacingTokens.x4
    static let x5: CGFloat = SpacingTokens.x5

    static let cardPadding: CGFloat = SpacingTokens.cardPadding
    static let sectionSpacing: CGFloat = SpacingTokens.sectionSpacing
    static let elementSpacing: CGFloat = SpacingTokens.elementSpacing
    static let buttonHeight: CGFloat = SpacingTokens.buttonHeight
    static let listRowHeight: CGFloat = SpacingTokens.listRowHeight
}
