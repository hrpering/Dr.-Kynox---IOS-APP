import SwiftUI

struct ShadowSpec {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum ShadowTokens {
    static let cardRadius: CGFloat = 10
    static let elevatedRadius: CGFloat = 16
}

enum AppShadow {
    static var card: ShadowSpec {
        ShadowSpec(color: AppColor.shadowSoft, radius: ShadowTokens.cardRadius, x: 0, y: 4)
    }

    static var elevated: ShadowSpec {
        ShadowSpec(color: AppColor.shadowStrong, radius: ShadowTokens.elevatedRadius, x: 0, y: 8)
    }
}

extension View {
    func appShadow(_ shadow: ShadowSpec) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}
