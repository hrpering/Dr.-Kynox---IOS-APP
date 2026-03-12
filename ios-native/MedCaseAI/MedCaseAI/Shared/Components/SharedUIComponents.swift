import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct WeeklyProgressChart: View {
    let values: [Double]

    var body: some View {
        let hasRealData = values.contains { $0 > 0 }
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { idx, value in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(hasRealData ? (value > 0 ? AppColor.primary : AppColor.border.opacity(0.45)) : AppColor.border.opacity(0.55))
                            .frame(
                                width: 18,
                                height: hasRealData
                                    ? max(12, min(84, CGFloat(value) * 0.84))
                                    : placeholderHeight(index: idx)
                            )
                        Text(shortDay(index: idx))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if !hasRealData {
                Text("Henüz veri yok")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .bottom)
    }

    private func shortDay(index: Int) -> String {
        let symbols = ["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"]
        return symbols[index % symbols.count]
    }

    private func placeholderHeight(index: Int) -> CGFloat {
        let pattern: [CGFloat] = [6, 8, 5, 7, 4, 8, 6]
        return pattern[index % pattern.count]
    }
}

struct HistoryCard: View {
    let item: CaseSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.caseTitle)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)

            HStack(spacing: 7) {
                Badge(text: SpecialtyOption.label(for: item.specialty), tint: AppColor.primary, background: AppColor.primaryLight)
                Badge(text: item.difficultyLabel, tint: AppColor.warning, background: AppColor.warningLight)
            }

            if let score = item.score?.overallScore {
                Text("Skor: \(Int(score.rounded()))")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
    }
}

struct ScoringLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let primaryText: String
    let secondaryText: String?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(AppColor.primary.opacity(0.18), lineWidth: 14)
                    .frame(width: 110, height: 110)
                Circle()
                    .trim(from: 0.1, to: 0.82)
                    .stroke(
                        AngularGradient(
                            colors: [AppColor.primary, AppColor.success, AppColor.primary],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(pulse ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1.05).repeatForever(autoreverses: false),
                        value: pulse
                    )
                Image(systemName: "stethoscope")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColor.primary)
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(AppColor.primary.opacity(0.75))
                        .frame(width: 8, height: 8)
                        .scaleEffect((pulse && !reduceMotion) ? (idx == 1 ? 1.15 : 0.85) : 1.0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(Double(idx) * 0.12),
                            value: pulse
                        )
                }
            }

            Text(primaryText)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .onAppear { pulse = true }
    }
}

struct MessageBubble: View {
    let row: AgentConversationViewModel.Message
    var accessories: [MessageBubbleAccessory] = []
    var onAccessoryTap: ((MessageBubbleAccessory) -> Void)? = nil

    var body: some View {
        VStack(alignment: row.source == "user" ? .trailing : .leading, spacing: 8) {
            HStack {
                if row.source == "user" { Spacer(minLength: 40) }

                Text(row.text)
                    .font(AppFont.body)
                    .foregroundStyle(row.source == "user" ? AppColor.textPrimary : AppColor.textPrimary)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(row.source == "user" ? AppColor.primaryLight : AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(row.source == "user" ? AppColor.primary.opacity(0.25) : AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if row.source != "user" { Spacer(minLength: 40) }
            }

            if !accessories.isEmpty {
                HStack {
                    if row.source == "user" { Spacer(minLength: 40) }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(accessories) { accessory in
                            Button {
                                onAccessoryTap?(accessory)
                            } label: {
                                Label(accessory.title, systemImage: accessory.iconSystemName)
                                    .font(AppFont.caption)
                                    .foregroundStyle(accessory.tint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(accessory.tint.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(accessory.tint.opacity(0.35), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if row.source != "user" { Spacer(minLength: 40) }
                }
            }
        }
    }
}

struct FeatureHighlightRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HowItWorksCard: View {
    let icon: String
    let title: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                Text(text)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
    }
}

struct VoiceFeatureMiniDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wavePhase: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { idx in
                    Capsule()
                        .fill(AppColor.primary.opacity(0.78))
                        .frame(width: 6, height: barHeight(for: idx))
                }
            }
            .frame(height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sesli görüşme akışı")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Text("Canlı dalga formu")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(AppColor.primaryLight)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                wavePhase = .pi * 2
            }
        }
        .onDisappear {
            wavePhase = 0
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let bases: [CGFloat] = [16, 22, 30, 24, 18, 28, 20, 26]
        guard !reduceMotion else { return bases[index % bases.count] }

        let base = bases[index % bases.count]
        let amplitude: CGFloat = 7
        let offset = CGFloat(index) * 0.65
        let wave = sin(wavePhase + offset)
        return max(12, base + wave * amplitude)
    }
}

struct ModeExplainerCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let icon: String
    let title: String
    let detail: String
    let tint: Color

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1.02 : 1))

            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            Text(detail)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct AnimatedMiniPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppColor.primaryLight, AppColor.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.primary)
                        .frame(width: 28, height: 28)
                        .background(AppColor.surface)
                        .clipShape(Circle())

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColor.primaryLight)
                        .frame(width: 120, height: 34)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColor.surface)
                        .frame(width: 96, height: 30)
                }

                Circle()
                    .fill(AppColor.primary)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: AppColor.primary.opacity(glow ? 0.32 : 0.18), radius: glow ? 18 : 8, x: 0, y: 4)
                    .scaleEffect(reduceMotion ? 1 : (glow ? 1.04 : 1))
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

struct IntroMediaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer? = {
        guard let url = Bundle.main.url(forResource: "intro", withExtension: "mp4") else {
            return nil
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        return player
    }()

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        guard !reduceMotion else { return }
                        player.seek(to: .zero)
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
                        player.seek(to: .zero)
                        if !reduceMotion {
                            player.play()
                        }
                    }
            } else {
                MockupHeroView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
    }
}

struct MockupHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColor.primaryLight, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColor.surface)
                    .frame(height: 26)
                    .overlay(
                        HStack {
                            Circle().fill(AppColor.primary.opacity(0.3)).frame(width: 8, height: 8)
                            Circle().fill(AppColor.warning.opacity(0.3)).frame(width: 8, height: 8)
                            Circle().fill(AppColor.success.opacity(0.3)).frame(width: 8, height: 8)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                    )

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.surface)
                    .frame(height: 58)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.primaryLight)
                    .overlay(
                        Capsule()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 64, height: 18)
                            .offset(x: phase ? 36 : -36)
                    )
                    .frame(height: 44)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.surface)
                    .overlay(
                        Capsule()
                            .fill(AppColor.primary.opacity(0.15))
                            .frame(width: 44, height: 10)
                            .offset(x: phase ? -28 : 28)
                    )
                    .frame(height: 44)
            }
            .padding(16)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct BrandLogoImage: View {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 20) {
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFill()
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
            .appShadow(AppShadow.card)
    }
}

struct StethoscopeBadge: View {
    var body: some View {
        Image(systemName: "stethoscope")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(AppColor.primaryDark)
            .frame(width: 86, height: 86)
            .background(AppColor.primaryLight)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.35), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
