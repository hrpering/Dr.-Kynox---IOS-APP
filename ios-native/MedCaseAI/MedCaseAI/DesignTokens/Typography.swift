import SwiftUI
import UIKit

private enum TokenFontFactory {
    private static func customOrSystem(name: String, size: CGFloat, fallback: Font.Weight, design: Font.Design = .default) -> Font {
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: fallback, design: design)
    }

    static func lexendRegular(size: CGFloat) -> Font {
        customOrSystem(name: "Lexend-Regular", size: size, fallback: .regular, design: .rounded)
    }

    static func lexendMedium(size: CGFloat) -> Font {
        customOrSystem(name: "Lexend-Medium", size: size, fallback: .medium, design: .rounded)
    }

    static func lexendSemibold(size: CGFloat) -> Font {
        customOrSystem(name: "Lexend-SemiBold", size: size, fallback: .semibold, design: .rounded)
    }

    static func lexendBold(size: CGFloat) -> Font {
        customOrSystem(name: "Lexend-Bold", size: size, fallback: .bold, design: .rounded)
    }

    static func publicSansRegular(size: CGFloat) -> Font {
        customOrSystem(name: "PublicSans-Regular", size: size, fallback: .regular)
    }

    static func publicSansMedium(size: CGFloat) -> Font {
        customOrSystem(name: "PublicSans-Medium", size: size, fallback: .medium)
    }

    static func publicSansSemibold(size: CGFloat) -> Font {
        customOrSystem(name: "PublicSans-SemiBold", size: size, fallback: .semibold)
    }
}

enum TypographyTokens {
    static let display = TokenFontFactory.lexendBold(size: 34)
    static let h1 = TokenFontFactory.lexendBold(size: 30)
    static let h2 = TokenFontFactory.lexendSemibold(size: 24)
    static let h3 = TokenFontFactory.lexendSemibold(size: 20)
    static let body = TokenFontFactory.publicSansRegular(size: 16)
    static let bodyMedium = TokenFontFactory.publicSansSemibold(size: 16)
    static let secondary = TokenFontFactory.publicSansMedium(size: 13)
    static let caption = TokenFontFactory.publicSansMedium(size: 12)
    static let button = TokenFontFactory.lexendSemibold(size: 17)
}

enum AppFont {
    static let h1 = TypographyTokens.h1
    static let h2 = TypographyTokens.h2
    static let h3 = TypographyTokens.h3
    static let body = TypographyTokens.body
    static let bodyMedium = TypographyTokens.bodyMedium
    static let secondary = TypographyTokens.secondary

    static let largeTitle = TypographyTokens.display
    static let title = h2
    static let title2 = h3
    static let caption = TypographyTokens.caption
    static let button = TypographyTokens.button
}
