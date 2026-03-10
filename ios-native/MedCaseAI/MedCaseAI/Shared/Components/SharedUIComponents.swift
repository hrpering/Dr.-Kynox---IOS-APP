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
        VStack(alignment: .leading, spacing: 6) {
            Text(item.caseTitle)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Badge(text: SpecialtyOption.label(for: item.specialty), tint: AppColor.primary, background: AppColor.primaryLight)
                Badge(text: item.difficultyLabel, tint: AppColor.warning, background: AppColor.warningLight)
            }

            if let score = item.score?.overallScore {
                Text("Skor: \(Int(score.rounded()))")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    var body: some View {
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
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

struct ModeSelectionFlow: Identifiable {
    let id = UUID()
    let context: String
    let challenge: DailyChallenge?
    let specialty: String
    let difficulty: String
}

struct ModeSelectionPage: View {
    @Environment(\.dismiss) private var dismiss

    let flow: ModeSelectionFlow

    @State private var selectedMode: CaseLaunchConfig.Mode?
    @State private var activeCase: CaseLaunchConfig?

    private var pageTitle: String {
        flow.context == "daily" ? "Günün vakası için mod seç" : "Mod seç"
    }

    private var selectedSpecialtyLabel: String {
        let raw = flow.specialty.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.lowercased(with: Locale(identifier: "tr_TR")) == "random" {
            return "Rastgele Bölüm"
        }
        return SpecialtyOption.label(for: raw)
    }

    private var selectedDifficultyLabel: String {
        let raw = flow.difficulty.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.lowercased(with: Locale(identifier: "tr_TR")) == "random" {
            return "Rastgele Zorluk"
        }
        return raw
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppSpacing.x2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Adım 3/3")
                        .font(AppFont.caption)
                        .foregroundStyle(.white.opacity(0.9))

                    Text(pageTitle)
                        .font(AppFont.title)
                        .foregroundStyle(.white)

                    Text("Bölüm ve zorluk seçildi. Şimdi nasıl ilerlemek istediğini belirle.")
                        .font(AppFont.body)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [AppColor.primaryDark, AppColor.primary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.primary.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: AppColor.primary.opacity(0.22), radius: 10, x: 0, y: 5)

                modeCard(
                    mode: .voice,
                    icon: "mic.fill",
                    title: "Sesli Mod",
                    subtitle: "Konuşarak ilerle, gerçek zamanlı simülasyon akışı yaşa.",
                    accent: AppColor.success,
                    background: AppColor.successLight,
                    badgeText: "Doğal Etkileşim",
                    estimate: "Tahmini süre: 8-12 dk"
                )

                modeCard(
                    mode: .text,
                    icon: "keyboard",
                    title: "Yazılı Mod",
                    subtitle: "Kısa mesajlarla tetkik ve yönetim kararlarını hızlı ilerlet.",
                    accent: AppColor.primary,
                    background: AppColor.primaryLight,
                    badgeText: "Hızlı Mesajlaşma",
                    estimate: "Tahmini süre: 6-10 dk"
                )

                modeDecisionInfoRow
            }
            .padding(.horizontal, AppSpacing.x2)
            .padding(.top, AppSpacing.x1)
            .padding(.bottom, AppSpacing.x3)
        }
        .background(AppColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                startSessionButton
                    .padding(.horizontal, AppSpacing.x2)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
            .background(AppColor.surface)
        }
        .navigationTitle("Mod seç")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Geri")
                .accessibilityHint("Önceki ekrana döner")
            }
        }
        .sheet(item: $activeCase) { config in
            CaseSessionView(config: config)
        }
    }

    private var startSessionButton: some View {
        Button {
            guard let mode = selectedMode else { return }
            activeCase = buildLaunchConfig(mode: mode)
        } label: {
            let hasSelection = selectedMode != nil
            HStack {
                Text("Vaka başlat")
                    .font(AppFont.bodyMedium)
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(hasSelection ? Color.white : AppColor.primaryDark.opacity(0.62))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(hasSelection ? AppColor.primary : AppColor.primaryLight)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hasSelection ? AppColor.primary : AppColor.primary.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(hasSelection ? 1 : 0.78)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(selectedMode == nil)
        .accessibilityLabel("Vaka başlat")
        .accessibilityHint("Seçilen mod ile vakayı başlatır")
    }

    private func modeCard(mode: CaseLaunchConfig.Mode,
                          icon: String,
                          title: String,
                          subtitle: String,
                          accent: Color,
                          background: Color,
                          badgeText: String,
                          estimate: String) -> some View {
        Button {
            selectedMode = mode
            Haptic.selection()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selectedMode == mode ? accent : accent.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(selectedMode == mode ? .white : accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Text(badgeText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(accent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(2)
                    Label(estimate, systemImage: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selectedMode == mode ? accent : AppColor.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .background(selectedMode == mode ? background : AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selectedMode == mode ? accent : AppColor.border, lineWidth: selectedMode == mode ? 2.2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: selectedMode == mode ? accent.opacity(0.18) : .clear, radius: 9, x: 0, y: 4)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var modeDecisionInfoRow: some View {
        let info = selectedModeInfo
        return HStack(spacing: 10) {
            Label("Süre: \(info.duration)", systemImage: "clock")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Spacer()
            Label(info.recommendation, systemImage: "sparkles")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var selectedModeInfo: (duration: String, recommendation: String) {
        switch selectedMode {
        case .voice:
            return ("Tahmini 8-12 dk", "Sesli pratiğe en uygun")
        case .text:
            return ("Tahmini 6-10 dk", "Hızlı tekrar için ideal")
        case .none:
            return ("Tahmini 6-12 dk", "Mod seçerek ilerle")
        }
    }

    private func buildLaunchConfig(mode: CaseLaunchConfig.Mode) -> CaseLaunchConfig {
        if flow.context == "daily", let challenge = flow.challenge {
            return CaseLaunchConfig(
                mode: mode,
                challengeType: "daily",
                challengeId: challenge.id,
                title: challenge.title,
                summary: challenge.summary,
                specialty: challenge.specialty,
                difficulty: challenge.difficulty,
                chiefComplaint: challenge.chiefComplaint,
                patientGender: challenge.patientGender,
                patientAge: challenge.patientAge,
                expectedDiagnosis: challenge.expectedDiagnosis
            )
        }

        return CaseLaunchConfig(
            mode: mode,
            challengeType: "random",
            specialty: flow.specialty,
            difficulty: flow.difficulty
        )
    }
}

struct QuickSpecialtyChip: Identifiable {
    let label: String
    let value: String
    var id: String { "\(label)|\(value)" }
}

struct SpecialtySelectionRow: Identifiable {
    let label: String
    let value: String
    let hint: String
    var id: String { value }
}

struct DifficultyCardConfig: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let count: Int
    let bg: Color
    let stroke: Color
}

struct DifficultyCard: View {
    let config: DifficultyCardConfig
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(config.title)
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                if isSelected {
                    HStack(spacing: AppSpacing.x1 / 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(config.stroke)
                        Text("Seçili")
                            .font(AppFont.caption)
                            .foregroundStyle(config.stroke)
                    }
                }
            }

            Text(config.subtitle)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
            Text(config.detail)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
            if config.count > 0 {
                Text("\(config.count) vaka")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
        .background(isSelected ? config.bg : AppColor.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(config.stroke)
                .frame(width: isSelected ? 4 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(isSelected ? config.stroke : AppColor.border, lineWidth: isSelected ? 2.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .shadow(color: isSelected ? config.stroke.opacity(0.16) : .clear, radius: 8, x: 0, y: 3)
    }
}

struct Badge: View {
    let text: String
    let tint: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(AppFont.secondary)
            .foregroundStyle(tint)
            .padding(.horizontal, AppSpacing.x1)
            .padding(.vertical, AppSpacing.x1 / 2)
            .background(background)
            .clipShape(Capsule())
    }
}

struct BadgePill: View {
    let title: String
    let icon: String
    let unlocked: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: unlocked ? icon : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(AppFont.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(unlocked ? accent : AppColor.textTertiary)
        .padding(.horizontal, AppSpacing.x1 + 2)
        .padding(.vertical, AppSpacing.x1 - 1)
        .frame(minWidth: 118, minHeight: 34)
        .background(unlocked ? accent.opacity(0.14) : AppColor.surfaceAlt.opacity(0.52))
        .overlay(
            Capsule().stroke(unlocked ? accent.opacity(0.46) : AppColor.border.opacity(0.9), lineWidth: 1)
        )
        .clipShape(Capsule())
        .opacity(unlocked ? 1 : 0.62)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        DSStatCard(title: title, value: value, subtitle: subtitle)
    }
}

struct FeedbackCard: View {
    let icon: String
    let title: String
    let items: [String]
    let subtitle: String
    let tint: Color
    let background: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
            }

            Text(subtitle)
                .font(AppFont.secondary)
                .foregroundStyle(AppColor.textSecondary)

            if items.isEmpty {
                Text("Bu bölüm için kayıtlı madde yok.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            } else {
                ForEach(items.prefix(4), id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(tint)
                            .frame(width: 4, height: 22)
                            .padding(.top, 2)

                        Text(item)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortExplanation(for: item))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.horizontal, AppSpacing.x1 + 2)
                    .padding(.vertical, AppSpacing.x1)
                    .background(AppColor.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .stroke(tint.opacity(0.2), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
            }
        }
        .padding(AppSpacing.cardPadding)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private func shortExplanation(for item: String) -> String {
        let normalized = item
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))

        if title.lowercased(with: Locale(identifier: "tr_TR")).contains("güçlü") {
            if normalized.contains("anamnez") || normalized.contains("öykü") {
                return "Erken ve yapılandırılmış anamnez, doğru tanıya ulaşma süresini kısaltır."
            }
            if normalized.contains("öncelik") || normalized.contains("zaman") {
                return "Doğru önceliklendirme, kritik hata riskini azaltıp akışı güvenli tutar."
            }
            if normalized.contains("tetkik") || normalized.contains("test") || normalized.contains("kan") {
                return "Hedefe yönelik tetkik istemi, gereksiz işlem yükünü azaltır ve karar kalitesini artırır."
            }
            return "Bu yaklaşımı koruman, benzer vakalarda karar hızını ve doğruluğu birlikte yükseltir."
        }

        if normalized.contains("anamnez") || normalized.contains("öykü") {
            return "Anamnez derinliğini artırmak, ayırıcı tanıyı erkenden daraltmana yardımcı olur."
        }
        if normalized.contains("öncelik") || normalized.contains("zaman") {
            return "Kritik adımları daha erken almak, komplikasyon ve gecikme riskini düşürür."
        }
        if normalized.contains("ayırıcı") || normalized.contains("diferansiyel") {
            return "Ayırıcı tanıyı genişletmek, yanlış tanı olasılığını belirgin şekilde azaltır."
        }
        return "Bu alanı güçlendirmek, klinik akışın tutarlılığını ve nihai skorunu artırır."
    }
}

struct DiagnosisSummaryRow: View {
    let title: String
    let value: String
    let accent: Color
    let valueColor: Color
    let isSystemHint: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(accent)
                if isSystemHint {
                    Text(value)
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textTertiary)
                        .lineSpacing(4)
                        .italic()
                } else {
                    Text(value)
                        .font(AppFont.body)
                        .foregroundStyle(valueColor)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ErrorStateCard: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        DSAlertCard(tone: .danger) {
            HStack(spacing: AppSpacing.x1) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(AppColor.error)
                Text(message)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(4)
            }

            if let retry {
                Button("Tekrar Dene") {
                    retry()
                }
                .dsTertiaryAction(.danger)
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateDots = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(AppColor.textTertiary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(reduceMotion ? 0.85 : (animateDots ? 1.0 : 0.6))
                    .opacity(reduceMotion ? 0.7 : (animateDots ? 1.0 : 0.45))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 0.35).repeatForever(autoreverses: true).delay(Double(idx) * 0.12),
                        value: animateDots
                    )
            }
            Text("Yanıt hazırlanıyor")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColor.surfaceAlt)
        .clipShape(Capsule())
        .onAppear {
            guard !reduceMotion else { return }
            animateDots = true
        }
        .onDisappear {
            animateDots = false
        }
    }
}

struct ShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.8

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(AppColor.border)
            .overlay(
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: proxy.size.width * 0.45)
                    .offset(x: phase * proxy.size.width)
                }
                .clipped()
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

struct AppTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            TextField(placeholder, text: $text)
                .font(AppFont.body)
                .keyboardType(keyboardType)
                .padding(.horizontal, AppSpacing.x2 - 4)
                .frame(minHeight: AppSpacing.buttonHeight)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }
}

struct AppSecureField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            SecureField(placeholder, text: $text)
                .font(AppFont.body)
                .padding(.horizontal, AppSpacing.x2 - 4)
                .frame(minHeight: AppSpacing.buttonHeight)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }
}

enum LegalPageLink: String, CaseIterable, Identifiable {
    case privacy
    case terms
    case medicalDisclaimer
    case kvkk
    case consent
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Gizlilik Politikası"
        case .terms: return "Kullanım Koşulları"
        case .medicalDisclaimer: return "Tıbbi Sorumluluk Reddi"
        case .kvkk: return "KVKK Aydınlatma Metni"
        case .consent: return "Açık Rıza Beyanı"
        case .support: return "Destek Sayfası"
        }
    }

    var path: String {
        switch self {
        case .privacy: return "/legal/privacy"
        case .terms: return "/legal/terms"
        case .medicalDisclaimer: return "/legal/medical-disclaimer"
        case .kvkk: return "/legal/kvkk"
        case .consent: return "/legal/consent"
        case .support: return "/support"
        }
    }

    var icon: String {
        switch self {
        case .privacy: return "lock.shield.fill"
        case .terms: return "doc.text.fill"
        case .medicalDisclaimer: return "stethoscope"
        case .kvkk: return "person.text.rectangle.fill"
        case .consent: return "checkmark.shield.fill"
        case .support: return "lifepreserver.fill"
        }
    }
}

struct LegalSheetItem: Identifiable {
    let title: String
    let url: URL

    var id: String { url.absoluteString }
}

enum LegalLinkResolver {
    static func url(for page: LegalPageLink) -> URL? {
        guard let base = backendBaseURL() else { return nil }
        return URL(string: page.path, relativeTo: base)?.absoluteURL
    }

    private static func backendBaseURL() -> URL? {
        let rawConfigured = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String
        let configured = (rawConfigured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "https://www.medcase.website"
        let raw = configured.isEmpty ? fallback : configured
        return URL(string: raw)
    }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(AppColor.primary)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

enum Haptic {
    private static var isEnabled: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return UIApplication.shared.applicationState == .active
#endif
    }

    static func selection() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            UISoundEngine.shared.play(.success)
        }
    }

    static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        Task { @MainActor in
            UISoundEngine.shared.play(.error)
        }
    }
}

func requestMicrophoneAccess() async -> Bool {
    let captureStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    if captureStatus == .authorized {
        return true
    }
    if captureStatus == .denied || captureStatus == .restricted {
        return false
    }

    if captureStatus == .notDetermined {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}

extension View {
    func appPrimaryButton() -> some View {
        self
            .buttonStyle(DSPrimaryButtonStyle())
    }

    func appSecondaryButton() -> some View {
        self
            .buttonStyle(DSSecondaryButtonStyle())
    }

    func appPrimaryButtonLabelStyle() -> some View {
        self
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(AppColor.primary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    func appSecondaryButtonLabelStyle() -> some View {
        self
            .foregroundStyle(AppColor.primary)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }
}

extension Text {
    func appPrimaryButtonLabel() -> some View {
        self
            .font(AppFont.bodyMedium)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(AppColor.primary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    func appSecondaryButtonLabel() -> some View {
        self
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.primary)
            .frame(maxWidth: .infinity, minHeight: AppSpacing.buttonHeight)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

}

struct SpecialtyOption {
    let label: String
    let value: String

    static let list: [SpecialtyOption] = [
        .init(label: "Kardiyoloji", value: "Cardiology"),
        .init(label: "Pulmonoloji", value: "Pulmonology"),
        .init(label: "Gastroenteroloji", value: "Gastroenterology"),
        .init(label: "Endokrinoloji", value: "Endocrinology"),
        .init(label: "Nefroloji", value: "Nephrology"),
        .init(label: "Enfeksiyon Hastalıkları", value: "Infectious Diseases"),
        .init(label: "Romatoloji", value: "Rheumatology"),
        .init(label: "Hematoloji", value: "Hematology"),
        .init(label: "Onkoloji", value: "Oncology"),
        .init(label: "Acil Tıp", value: "Emergency Medicine"),
        .init(label: "Yoğun Bakım", value: "Critical Care Medicine"),
        .init(label: "Nöroloji", value: "Neurology"),
        .init(label: "Psikiyatri", value: "Psychiatry"),
        .init(label: "Nörokritik Bakım-Toksikoloji", value: "Neurocritical Care-Toxicology"),
        .init(label: "Genel Cerrahi", value: "General Surgery"),
        .init(label: "Vasküler Cerrahi", value: "Vascular Surgery"),
        .init(label: "Kardiyotorasik Cerrahi", value: "Cardiothoracic Surgery"),
        .init(label: "Nöroşirürji", value: "Neurosurgery"),
        .init(label: "Ortopedi", value: "Orthopedic Surgery"),
        .init(label: "Plastik Cerrahi", value: "Plastic Surgery"),
        .init(label: "Travma Cerrahisi", value: "Trauma Surgery"),
        .init(label: "Obstetri", value: "Obstetrics"),
        .init(label: "Jinekoloji", value: "Gynecology"),
        .init(label: "Genel Pediatri", value: "General Pediatrics"),
        .init(label: "Pediatrik Acil", value: "Pediatric Emergency"),
        .init(label: "Dermatoloji", value: "Dermatology"),
        .init(label: "Neonatoloji", value: "Neonatology"),
        .init(label: "Oftalmoloji", value: "Ophthalmology"),
        .init(label: "Kulak Burun Boğaz", value: "Otolaryngology (ENT)"),
        .init(label: "Geriatri", value: "Geriatric Medicine"),
        .init(label: "Üroloji", value: "Urology")
    ]

    static func label(for value: String) -> String {
        list.first(where: { $0.value == value })?.label ?? value
    }

    static func description(for value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return ""
        }
        if normalized.lowercased(with: Locale(identifier: "tr_TR")) == "random" {
            return "Bölüm rastgele seçilir; farklı klinik senaryolarla pratik yaparsın."
        }

        let descriptions: [String: String] = [
            "Cardiology": "Göğüs ağrısı, ritim bozukluğu ve akut koroner sendrom odaklı vakalar.",
            "Pulmonology": "Dispne, öksürük, hipoksemi ve solunum yolu yönetimi içeren olgular.",
            "Gastroenterology": "Karın ağrısı, gastrointestinal kanama ve hepatobiliyer değerlendirme vakaları.",
            "Endocrinology": "Diyabet, tiroid ve hormon dengesizliklerinde tanı-yönetim kararları.",
            "Nephrology": "Akut böbrek hasarı, elektrolit bozukluğu ve sıvı dengesi odaklı senaryolar.",
            "Infectious Diseases": "Ateş odağı, sepsis değerlendirmesi ve antibiyotik stratejisi vakaları.",
            "Rheumatology": "Eklem yakınmaları ve otoimmün süreçlerde ayırıcı tanı egzersizleri.",
            "Hematology": "Anemi, sitopeni ve hematolojik acillerle ilgili karar adımları.",
            "Oncology": "Kanser ilişkili semptomlar, komplikasyonlar ve önceliklendirme yönetimi.",
            "Emergency Medicine": "Acil başvurularda hızlı triyaj, kritik test ve stabilizasyon kararları.",
            "Critical Care Medicine": "Yoğun bakım düzeyinde hemodinamik, ventilasyon ve çoklu sistem yönetimi.",
            "Neurology": "İnme, nöbet ve nörolojik defisitlerde hızlı klinik akıl yürütme vakaları.",
            "Psychiatry": "Duygudurum, anksiyete ve risk değerlendirmesi içeren psikiyatrik görüşmeler.",
            "General Surgery": "Akut batın ve cerrahi karar zamanlamasının kritik olduğu olgular."
        ]

        return descriptions[normalized] ?? "Bu bölümde tanı, önceliklendirme ve yönetim akışını adım adım çalışırsın."
    }

    static func focusHint(for value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return ""
        }
        if normalized.lowercased(with: Locale(identifier: "tr_TR")) == "random" {
            return "Tüm bölümlerden karışık klinik senaryolar."
        }

        let hints: [String: String] = [
            "Cardiology": "Tipik vakalar: göğüs ağrısı, ritim, AKS.",
            "Pulmonology": "Tipik vakalar: dispne, hipoksemi, pnömoni.",
            "Gastroenterology": "Tipik vakalar: karın ağrısı, GİS kanama.",
            "Endocrinology": "Tipik vakalar: diyabet, tiroid, DKA.",
            "Nephrology": "Tipik vakalar: AKI, elektrolit, sıvı dengesi.",
            "Infectious Diseases": "Tipik vakalar: ateş odağı, sepsis, antibiyotik seçimi.",
            "Emergency Medicine": "Tipik vakalar: triyaj, stabilizasyon, hızlı karar.",
            "Neurology": "Tipik vakalar: inme, nöbet, akut nörolojik defisit.",
            "Psychiatry": "Tipik vakalar: anksiyete, duygudurum, risk değerlendirmesi.",
            "General Surgery": "Tipik vakalar: akut batın, cerrahi zamanlama."
        ]

        return hints[normalized] ?? "Tipik vakalar: tanı, önceliklendirme ve yönetim akışı."
    }
}

func sectionHeader(title: String) -> some View {
    HStack {
        Text(title)
            .font(AppFont.h3)
            .foregroundStyle(AppColor.textPrimary)
        Spacer()
    }
}

struct KeyboardAdaptiveModifier: ViewModifier {
    @State private var keyboardInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardInset)
            .animation(.easeOut(duration: 0.2), value: keyboardInset)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                keyboardInset = keyboardInsetForNotification(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardInset = 0
            }
    }

    private func keyboardInsetForNotification(_ notification: Notification) -> CGFloat {
        guard
            let userInfo = notification.userInfo,
            let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else {
            return 0
        }

        let endFrame = frameValue.cgRectValue
        guard
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow })
        else {
            return 0
        }

        let converted = keyWindow.convert(endFrame, from: nil)
        let overlap = max(0, keyWindow.bounds.maxY - converted.minY - keyWindow.safeAreaInsets.bottom)
        return max(0, overlap)
    }
}

extension View {
    func keyboardAdaptive() -> some View {
        modifier(KeyboardAdaptiveModifier())
    }
}
