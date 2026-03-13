import SwiftUI

struct ShadowSpec {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum ShadowTokens {
    static let lowRadius: CGFloat = 2
    static let cardRadius: CGFloat = 6
    static let elevatedRadius: CGFloat = 10
}

enum AppShadow {
    static var low: ShadowSpec {
        ShadowSpec(color: AppColor.shadowSoft, radius: ShadowTokens.lowRadius, x: 0, y: 1)
    }

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
