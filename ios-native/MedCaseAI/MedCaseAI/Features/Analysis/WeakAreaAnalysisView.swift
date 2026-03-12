import SwiftUI

struct WeakAreaAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var selectedSpecialty: WeakAreaSpecialtyStat?
    @State private var selectedHistoryRangeDays: Int = 30
    @State private var weakAreaHistory: WeakAreaHistoryResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading && state.weakAreaAnalysis == nil {
                    ShimmerView()
                        .frame(height: 230)
                    ShimmerView()
                        .frame(height: 220)
                    ShimmerView()
                        .frame(height: 160)
                } else if let analysis = state.weakAreaAnalysis, analysis.hasData {
                    summaryHeader(analysis)
                    trendHistoryCard
                    scoreMapCard(analysis)
                    specialtyBreakdownCard(analysis)
                    aiRecommendationCard(analysis)
                } else {
                    DSEmptyState(
                        icon: "chart.bar.doc.horizontal",
                        title: "Henüz analiz oluşturmak için yeterli veri yok.",
                        subtitle: "3 vaka tamamladığında zayıf alan haritan burada görünecek."
                    )
                    Button {
                        state.selectedMainTab = "generator"
                        dismiss()
                        Haptic.selection()
                    } label: {
                        Text("Yeni vaka başlat")
                            .appPrimaryButtonLabel()
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Yeni vaka başlat")
                    .accessibilityHint("Vaka seçim ekranına döner")
                }
            }
            .padding(16)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Zayıf Alan Analizi")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task {
            if state.weakAreaAnalysis == nil {
                await refresh()
            }
        }
        .sheet(item: $selectedSpecialty) { item in
            NavigationStack {
                WeakAreaSpecialtyDetailView(item: item)
            }
        }
    }

    private func refresh() async {
        loading = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await state.refreshDashboard(showBusy: false)
            }
            group.addTask {
                do {
                    let history = try await state.fetchWeakAreaHistory(rangeDays: selectedHistoryRangeDays)
                    await MainActor.run {
                        weakAreaHistory = history
                    }
                } catch {
                    await MainActor.run {
                        weakAreaHistory = nil
                    }
                }
            }
        }
        loading = false
    }

    private var trendHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(title: "Zaman Trendi")
                Spacer()
                Picker("Aralık", selection: $selectedHistoryRangeDays) {
                    Text("7g").tag(7)
                    Text("30g").tag(30)
                    Text("90g").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .onChange(of: selectedHistoryRangeDays) { _ in
                    Task { await refresh() }
                }
            }

            let grouped = groupedHistoryRows
            if grouped.isEmpty {
                Text("Trend verisi henüz oluşmadı.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                ForEach(grouped.prefix(8), id: \.date) { item in
                    HStack(spacing: 10) {
                        Text(shortDate(item.date))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { proxy in
                            let ratio = max(0, min(1, item.avgScore / 100))
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppColor.surfaceAlt)
                                Capsule()
                                    .fill(AppColor.primary)
                                    .frame(width: proxy.size.width * ratio)
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int(item.avgScore.rounded()))")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textPrimary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var groupedHistoryRows: [(date: String, avgScore: Double)] {
        let rows = weakAreaHistory?.snapshots ?? []
        let grouped = Dictionary(grouping: rows, by: { $0.snapshotDate })
        return grouped.compactMap { key, values in
            let scores = values.compactMap { $0.userAvgScore }
            guard !scores.isEmpty else { return nil }
            let avg = scores.reduce(0, +) / Double(scores.count)
            return (date: key, avgScore: avg)
        }
        .sorted { $0.date > $1.date }
    }

    private func shortDate(_ token: String) -> String {
        let parts = token.split(separator: "-")
        guard parts.count == 3 else { return token }
        return "\(parts[2]).\(parts[1])"
    }

    private func summaryHeader(_ analysis: WeakAreaAnalysisResponse) -> some View {
        let userScore = analysis.summary.userAverageScore
        let globalScore = analysis.summary.globalAverageScore
        let delta = userScore - globalScore

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Genel Performans")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("\(analysis.summary.userCaseCount) skorlanmış vaka")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Int(userScore.rounded()))")
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.primaryDark)
                    Text("Genel ortalama: \(Int(globalScore.rounded()))")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: delta >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    .foregroundStyle(delta >= 0 ? AppColor.success : AppColor.warning)
                Text(delta >= 0
                     ? "Genel kullanıcı ortalamasının \(Int(abs(delta).rounded())) puan üzerindesin."
                     : "Genel kullanıcı ortalamasının \(Int(abs(delta).rounded())) puan altındasın.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func scoreMapCard(_ analysis: WeakAreaAnalysisResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Genel Skor Haritası")

            WeakAreaRadarChart(
                axes: analysis.scoreMap.axes,
                userValues: analysis.scoreMap.userValues,
                globalValues: analysis.scoreMap.globalValues
            )
            .frame(height: 290)

            HStack(spacing: 12) {
                Label("Senin ortalaman", systemImage: "circle.fill")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primaryDark)
                Label("Genel ortalama", systemImage: "circle")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func specialtyBreakdownCard(_ analysis: WeakAreaAnalysisResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Branş Bazlı Analiz")

            ForEach(analysis.specialtyBreakdown) { item in
                Button {
                    selectedSpecialty = item
                    Haptic.selection()
                } label: {
                    specialtyRow(item)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func specialtyRow(_ item: WeakAreaSpecialtyStat) -> some View {
        let tone = scoreTone(item.userAverageScore)
        let userRatio = max(0, min(1, item.userAverageScore / 100))
        let globalRatio = max(0, min(1, item.globalAverageScore / 100))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.specialtyLabel)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(item.userAverageScore.rounded()))")
                    .font(AppFont.caption)
                    .foregroundStyle(tone.tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tone.background)
                    .clipShape(Capsule())
            }

            HStack(spacing: 6) {
                Text("Sen")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 28, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColor.surfaceAlt)
                        Capsule()
                            .fill(tone.tint)
                            .frame(width: proxy.size.width * userRatio)
                    }
                }
                .frame(height: 7)
            }

            HStack(spacing: 6) {
                Text("Genel")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 28, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColor.surfaceAlt)
                        Capsule()
                            .fill(AppColor.textTertiary.opacity(0.75))
                            .frame(width: proxy.size.width * globalRatio)
                    }
                }
                .frame(height: 7)
            }

            HStack(spacing: 8) {
                Text("Sen \(Int(item.userAverageScore.rounded())) · Genel \(Int(item.globalAverageScore.rounded()))")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(12)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tone.tint.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func aiRecommendationCard(_ analysis: WeakAreaAnalysisResponse) -> some View {
        guard let recommendation = analysis.aiRecommendation else {
            return AnyView(EmptyView())
        }

        let target = recommendation.suggestedWeeklyTarget
        let currentTarget = state.weeklyGoalTarget

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppColor.primaryDark)
                    Text(recommendation.title)
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                }

                Text(recommendation.message)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)

                HStack(spacing: 8) {
                    Badge(text: recommendation.recommendedSpecialtyLabel, tint: AppColor.primaryDark, background: AppColor.primaryLight)
                    Badge(text: recommendation.recommendedDifficulty, tint: AppColor.warning, background: AppColor.warningLight)
                }

                if let focusLabel = recommendation.focusDimensionLabel {
                    Text("Odak metriği: \(focusLabel)\(recommendation.focusDimensionScore != nil ? " · \(Int((recommendation.focusDimensionScore ?? 0).rounded()))/100" : "")")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                HStack(spacing: 10) {
                    Button {
                        launchRecommendedCase(recommendation)
                    } label: {
                        HStack {
                            Text(recommendation.ctaLabel)
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .appPrimaryButtonLabelStyle()
                    }
                    .buttonStyle(PressableButtonStyle())

                    if let target, target > 0, target != currentTarget {
                        Button {
                            state.updateWeeklyGoalTarget(target)
                            Haptic.success()
                        } label: {
                            Text("\(target)/hafta hedefi uygula")
                                .appSecondaryButtonLabel()
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    private func scoreTone(_ score: Double) -> (tint: Color, background: Color) {
        if score >= 70 { return (AppColor.success, AppColor.successLight) }
        if score >= 50 { return (AppColor.warning, AppColor.warningLight) }
        return (AppColor.error, AppColor.errorLight)
    }

    private func launchRecommendedCase(_ recommendation: WeakAreaRecommendation) {
        let specialtyValue = canonicalSpecialtyValue(recommendation.recommendedSpecialty)
        let difficultyValue = canonicalDifficultyValue(recommendation.recommendedDifficulty)
        state.generatorReplayContext = GeneratorReplayContext(
            specialty: specialtyValue,
            difficulty: difficultyValue
        )
        state.selectedMainTab = "generator"
    }

    private func canonicalDifficultyValue(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == "Kolay" || clean == "Orta" || clean == "Zor" {
            return clean
        }
        return "Orta"
    }

    private func canonicalSpecialtyValue(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Random" }
        if let exactValue = SpecialtyOption.list.first(where: { $0.value.caseInsensitiveCompare(clean) == .orderedSame }) {
            return exactValue.value
        }
        if let byLabel = SpecialtyOption.list.first(where: { $0.label.caseInsensitiveCompare(clean) == .orderedSame }) {
            return byLabel.value
        }
        return clean
    }
}
