import SwiftUI

enum SpacingTokens {
    static let x1: CGFloat = 10
    static let x1_5: CGFloat = 14
    static let x2: CGFloat = 18
    static let x3: CGFloat = 26
    static let x4: CGFloat = 34
    static let x5: CGFloat = 42

    static let cardPadding: CGFloat = x2
    static let sectionSpacing: CGFloat = 22
    static let elementSpacing: CGFloat = x2
    static let buttonHeight: CGFloat = 54
    static let listRowHeight: CGFloat = 62
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
