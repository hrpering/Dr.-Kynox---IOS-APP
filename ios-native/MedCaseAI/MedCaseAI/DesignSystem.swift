import SwiftUI

enum AppSemanticTone {
    case primary
    case success
    case warning
    case danger
    case neutral

    var foreground: Color {
        switch self {
        case .primary: return AppColor.primary
        case .success: return AppColor.success
        case .warning: return AppColor.warning
        case .danger: return AppColor.error
        case .neutral: return AppColor.textSecondary
        }
    }

    var background: Color {
        switch self {
        case .primary: return AppColor.primaryLight
        case .success: return AppColor.successLight
        case .warning: return AppColor.warningLight
        case .danger: return AppColor.errorLight
        case .neutral: return AppColor.surfaceAlt
        }
    }

    var border: Color {
        switch self {
        case .primary: return AppColor.primary.opacity(0.32)
        case .success: return AppColor.success.opacity(0.32)
        case .warning: return AppColor.warning.opacity(0.32)
        case .danger: return AppColor.error.opacity(0.32)
        case .neutral: return AppColor.border
        }
    }
}

struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.button)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(
                LinearGradient(
                    colors: [AppColor.primaryDark, AppColor.primary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .appShadow(AppShadow.elevated)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.button)
            .foregroundStyle(AppColor.primaryDark)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.34), lineWidth: 1.2)
            )
            .appShadow(AppShadow.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DSTertiaryTextActionStyle: ViewModifier {
    let tone: AppSemanticTone

    func body(content: Content) -> some View {
        content
            .font(AppFont.bodyMedium)
            .foregroundStyle(tone.foreground)
    }
}

extension View {
    func dsTertiaryAction(_ tone: AppSemanticTone = .primary) -> some View {
        modifier(DSTertiaryTextActionStyle(tone: tone))
    }
}

struct DSInfoCard<Content: View>: View {
    let tone: AppSemanticTone
    @ViewBuilder let content: Content

    init(tone: AppSemanticTone = .neutral, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            content
        }
        .padding(AppSpacing.cardPadding)
        .background(baseBackground)
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(accentOverlay)
                .frame(height: 52)
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(tone.border, lineWidth: 1)
        )
        .appShadow(AppShadow.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private var baseBackground: Color {
        switch tone {
        case .neutral:
            return AppColor.surface
        default:
            return AppColor.surfaceElevated
        }
    }

    private var accentOverlay: Color {
        switch tone {
        case .primary:
            return AppColor.primaryLight.opacity(0.6)
        case .success:
            return AppColor.successLight.opacity(0.6)
        case .warning:
            return AppColor.warningLight.opacity(0.6)
        case .danger:
            return AppColor.errorLight.opacity(0.55)
        case .neutral:
            return .clear
        }
    }
}

struct DSAlertCard<Content: View>: View {
    let tone: AppSemanticTone
    @ViewBuilder let content: Content

    init(tone: AppSemanticTone, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        DSInfoCard(tone: tone) {
            content
        }
    }
}

struct DSStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let tone: AppSemanticTone

    init(title: String, value: String, subtitle: String, tone: AppSemanticTone = .neutral) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            Text(title)
                .font(AppFont.secondary)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.h2)
                .foregroundStyle(AppColor.textPrimary)
            Text(subtitle)
                .font(AppFont.secondary)
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(AppSpacing.cardPadding)
        .frame(width: 136, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(tone == .neutral ? AppColor.border : tone.border, lineWidth: 1)
        )
        .appShadow(AppShadow.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }
}

struct DSEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let tone: AppSemanticTone

    init(
        icon: String = "tray",
        title: String,
        subtitle: String,
        tone: AppSemanticTone = .neutral
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
    }

    var body: some View {
        DSInfoCard(tone: tone) {
            HStack(alignment: .top, spacing: AppSpacing.x1) {
                Image(systemName: icon)
                    .foregroundStyle(tone.foreground)
                VStack(alignment: .leading, spacing: AppSpacing.x1) {
                    Text(title)
                        .font(AppFont.h3)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(subtitle)
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
            }
        }
    }
}

struct DSNavigationRow<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder let accessory: Accessory

    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: AppSpacing.x2) {
            Image(systemName: icon)
                .foregroundStyle(AppColor.primary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.secondary)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, AppSpacing.cardPadding)
        .frame(minHeight: AppSpacing.listRowHeight)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .appShadow(AppShadow.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}
