import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct AnalysisHubView: View {
    @EnvironmentObject private var state: AppState
    private enum AnalysisRange: String, CaseIterable {
        case weekly = "Haftalık"
        case monthly = "Aylık"
        case yearly = "Yıllık"
    }
    private enum Destination: Int, Identifiable {
        case weakArea
        case quickFavorites
        var id: Int { rawValue }
    }
    @State private var destination: Destination?
    @State private var isLoadingFavoriteStats = false
    @State private var favoriteCardTotal = 0
    @State private var latestFavoriteLabel = "--"
    @State private var didInitialLoad = false
    @State private var selectedRange: AnalysisRange = .monthly

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    analysisHeroCard
                    analysisRangeTabs
                    summaryStatsRow

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Analiz Araçları")
                            .font(AppFont.title2)
                            .foregroundStyle(AppColor.textPrimary)

                        Button {
                            destination = .weakArea
                            state.selectedMainTab = "analysis"
                            Haptic.selection()
                        } label: {
                            analysisHubCard(
                                icon: "chart.line.uptrend.xyaxis",
                                title: "Zayıf Alan Analizi",
                                subtitle: hasEnoughAnalysisData
                                    ? "Skor haritanı, bölüm bazlı performansını ve AI önerilerini gör."
                                    : "3 vaka tamamlandığında detaylı zayıf alan haritan açılır.",
                                tint: AppColor.primary,
                                background: AppColor.primaryLight
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            destination = .quickFavorites
                            state.selectedMainTab = "analysis"
                            Haptic.selection()
                        } label: {
                            analysisHubCard(
                                icon: "star.square.on.square.fill",
                                title: "Favori Hızlı Vaka Kartları",
                                subtitle: "15sn vakalarda işaretlediğin kartları burada tekrar incele.",
                                tint: AppColor.success,
                                background: AppColor.successLight
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    if !hasEnoughAnalysisData {
                        DSEmptyState(
                            icon: "chart.bar.doc.horizontal",
                            title: "Henüz analiz oluşturmak için yeterli veri yok.",
                            subtitle: "3 vaka tamamladığında zayıf alan haritan burada görünecek."
                        )
                        Button {
                            state.selectedMainTab = "generator"
                            Haptic.selection()
                        } label: {
                            Text("Yeni vaka başlat")
                                .appPrimaryButtonLabel()
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Yeni vaka başlat")
                        .accessibilityHint("Vaka seçim ekranına geçer")
                    }

                    scoreTrendCard
                    specialtyInsightCard
                    quickCaseFavoriteStatusCard
                    aiRecommendationPreviewCard
                }
                .padding(16)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Analiz Merkezi")
            .onAppear {
                if state.selectedMainTab == "flashcards" {
                    destination = .quickFavorites
                }
            }
            .refreshable {
                await refreshHub()
            }
            .task {
                guard !didInitialLoad else { return }
                didInitialLoad = true
                await refreshHub()
            }
            .onChange(of: state.selectedMainTab) { value in
                if value == "flashcards" {
                    destination = .quickFavorites
                }
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { destination != nil },
                    set: { isPresented in
                        if !isPresented {
                            destination = nil
                        }
                    }
                )
            ) {
                Group {
                    switch destination {
                    case .weakArea:
                        WeakAreaAnalysisView()
                            .environmentObject(state)
                    case .quickFavorites:
                        FlashcardsHubView()
                            .environmentObject(state)
                    case .none:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var analysisHeroCard: some View {
        HeroHeader(
            eyebrow: "Analiz",
            title: "Analiz Merkezi",
            subtitle: "Genel skor trendi, bölüm bazlı analiz ve üretkenlik özetini takip et.",
            icon: "waveform.path.ecg.rectangle",
            metrics: [
                .init(title: "Skorlu vaka", value: "\(scoredSessions.count)"),
                .init(title: "Son 7 gün", value: "\(last7DayBuckets.map(\.caseCount).reduce(0, +))"),
                .init(title: "Favori kart", value: "\(favoriteCardTotal)")
            ]
        )
    }

    private var analysisRangeTabs: some View {
        HStack(spacing: 10) {
            ForEach(AnalysisRange.allCases, id: \.rawValue) { range in
                Button {
                    selectedRange = range
                    Haptic.selection()
                } label: {
                    Text(range.rawValue)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(selectedRange == range ? AppColor.primary : AppColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(selectedRange == range ? AppColor.primaryLight : AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selectedRange == range ? AppColor.primary : AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private var completedSessions: [CaseSession] {
        state.caseHistory.filter {
            $0.score != nil || $0.status.lowercased(with: Locale(identifier: "tr_TR")) == "completed"
        }
    }

    private var scoredSessions: [CaseSession] {
        completedSessions.filter { $0.score != nil }
    }

    private var hasEnoughAnalysisData: Bool {
        completedSessions.count >= 3
    }

    private var summaryStatsRow: some View {
        let avgScoreText: String = {
            let values = scoredSessions.compactMap { normalizeScore($0.score?.overallScore ?? 0) }
            guard !values.isEmpty else { return "--" }
            let avg = values.reduce(0, +) / Double(values.count)
            return "\(Int(avg.rounded()))"
        }()
        let last7Count = last7DayBuckets.map(\.caseCount).reduce(0, +)
        let strongest = strongestSpecialtyLabel

        return MetricBand(
            items: [
                .init(title: "Ortalama", value: avgScoreText, icon: "chart.line.uptrend.xyaxis"),
                .init(title: "Son 7 gün", value: "\(last7Count)", icon: "calendar"),
                .init(title: "Öne çıkan", value: strongest, icon: "sparkles")
            ]
        )
    }

    private var scoreTrendCard: some View {
        DSInfoCard(tone: .primary) {
            sectionHeader(title: "Genel Skor Trendi")
            Text("\(selectedRange.rawValue) görünümde skor ve vaka yoğunluğu")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(last7DayBuckets) { bucket in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(AppColor.surfaceAlt)
                                .frame(width: 18, height: 68)
                            Capsule()
                                .fill(bucket.averageScore == nil ? AppColor.textTertiary.opacity(0.35) : AppColor.primary)
                                .frame(width: 18, height: bucketBarHeight(bucket))
                        }
                        Text(bucket.dayLabel)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                        Text("\(bucket.caseCount)")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text(hasEnoughAnalysisData
                 ? "Her gün çözdüğün vaka sayısı ve skor ortalaman bu grafikte görünür."
                 : "Bu grafik 3 vaka tamamlandıktan sonra daha anlamlı hale gelir.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
    }

    private var specialtyInsightCard: some View {
        DSInfoCard(tone: .warning) {
            sectionHeader(title: "Bölüm Bazlı Güçlü/Zayıf Alan")
            if let weakest = weakestSpecialty, let strongest = strongestSpecialty {
                specialtyInsightRow(
                    title: "Geliştirilecek",
                    specialty: weakest.specialtyLabel,
                    score: Int(weakest.userAverageScore.rounded()),
                    tone: .warning
                )
                specialtyInsightRow(
                    title: "Güçlü taraf",
                    specialty: strongest.specialtyLabel,
                    score: Int(strongest.userAverageScore.rounded()),
                    tone: .success
                )
            } else {
                Text("Henüz bölüm bazlı karşılaştırma için yeterli skor verisi yok.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
        }
    }

    private var quickCaseFavoriteStatusCard: some View {
        DSInfoCard(tone: .success) {
            sectionHeader(title: "Hızlı Vaka Favori Kartları")
            HStack(spacing: 8) {
                favoriteMetricPill(
                    icon: "star.fill",
                    title: "Toplam Kart",
                    value: isLoadingFavoriteStats ? "..." : "\(favoriteCardTotal)"
                )
                favoriteMetricPill(
                    icon: "clock.fill",
                    title: "Son Eklenen",
                    value: isLoadingFavoriteStats ? "..." : latestFavoriteLabel
                )
            }
            Text("15sn oturum sonrasında favoriye eklediğin ön/arka kartlar burada birikir.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
    }

    private var aiRecommendationPreviewCard: some View {
        DSInfoCard(tone: .neutral) {
            sectionHeader(title: "Kısa AI Önerisi")
            if let recommendation = state.weakAreaAnalysis?.aiRecommendation {
                Text(recommendation.message)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Badge(
                        text: recommendation.recommendedSpecialtyLabel,
                        tint: AppColor.primaryDark,
                        background: AppColor.primaryLight
                    )
                    Badge(
                        text: recommendation.recommendedDifficulty,
                        tint: AppColor.warning,
                        background: AppColor.warningLight
                    )
                }
            } else {
                Text("İlk birkaç vakadan sonra Dr.Kynox burada kişiselleştirilmiş öneriler sunacak.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
        }
    }

    private func specialtyInsightRow(title: String,
                                     specialty: String,
                                     score: Int,
                                     tone: AppSemanticTone) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: 86, alignment: .leading)
            Text(specialty)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(score)")
                .font(AppFont.caption)
                .foregroundStyle(tone.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tone.background)
                .clipShape(Capsule())
        }
    }

    private func favoriteMetricPill(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.success)
                .frame(width: 24, height: 24)
                .background(AppColor.successLight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Text(value)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var weakestSpecialty: WeakAreaSpecialtyStat? {
        state.weakAreaAnalysis?.specialtyBreakdown.min { $0.userAverageScore < $1.userAverageScore }
    }

    private var strongestSpecialty: WeakAreaSpecialtyStat? {
        state.weakAreaAnalysis?.specialtyBreakdown.max { $0.userAverageScore < $1.userAverageScore }
    }

    private var strongestSpecialtyLabel: String {
        strongestSpecialty?.specialtyLabel ?? "--"
    }

    private struct DailyTrendBucket: Identifiable {
        let id: Date
        let dayLabel: String
        let caseCount: Int
        let averageScore: Double?
    }

    private var last7DayBuckets: [DailyTrendBucket] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { idx in
            calendar.date(byAdding: .day, value: idx - 6, to: today)
        }

        return days.map { day in
            let sessions = completedSessions.filter { session in
                guard let date = sessionDate(session) else { return false }
                return calendar.isDate(date, inSameDayAs: day)
            }
            let scoreValues = sessions.compactMap { session -> Double? in
                guard let raw = session.score?.overallScore else { return nil }
                return normalizeScore(raw)
            }
            let avgScore = scoreValues.isEmpty ? nil : scoreValues.reduce(0, +) / Double(scoreValues.count)
            return DailyTrendBucket(
                id: day,
                dayLabel: shortWeekday(day),
                caseCount: sessions.count,
                averageScore: avgScore
            )
        }
    }

    private func bucketBarHeight(_ bucket: DailyTrendBucket) -> CGFloat {
        guard let score = bucket.averageScore else { return 8 }
        let clamped = max(0, min(100, score))
        return max(8, CGFloat(clamped / 100) * 68)
    }

    private func normalizeScore(_ raw: Double) -> Double {
        let value = raw <= 10 ? raw * 10 : raw
        return max(0, min(100, value))
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private func sessionDate(_ session: CaseSession) -> Date? {
        parseISODate(session.endedAt) ?? parseISODate(session.startedAt) ?? parseISODate(session.updatedAt)
    }

    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let withFraction = Self.isoFormatterWithFractional.date(from: raw) {
            return withFraction
        }
        return Self.isoFormatter.date(from: raw)
    }

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func refreshHub() async {
        await state.refreshDashboard(showBusy: false)
        await refreshFavoriteStats()
    }

    private func refreshFavoriteStats() async {
        isLoadingFavoriteStats = true
        defer { isLoadingFavoriteStats = false }
        do {
            let favorites = try await state.fetchCodeBlueFavorites(limit: 1)
            favoriteCardTotal = favorites.totalCount ?? favorites.items.count
            if let latest = favorites.items.first?.createdAt, let date = parseISODate(latest) {
                latestFavoriteLabel = shortDayMonth(date)
            } else {
                latestFavoriteLabel = "--"
            }
        } catch {
            favoriteCardTotal = 0
            latestFavoriteLabel = "--"
        }
    }

    private func shortDayMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "dd.MM"
        return formatter.string(from: date)
    }

    private func analysisHubCard(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color,
        background: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                Text(subtitle)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
