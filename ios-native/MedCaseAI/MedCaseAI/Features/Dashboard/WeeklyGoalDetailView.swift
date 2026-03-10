import SwiftUI

struct WeeklyGoalDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var localTarget = 5
    @State private var showConfetti = false
    @State private var didTriggerConfetti = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                goalSetterCard
                thisWeekCasesCard
                historyCalendarCard
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Haftalık Hedef")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bildirimleri Aç") {
                    Task { await state.configureWeeklyGoalNotifications() }
                }
                .foregroundStyle(AppColor.primary)
            }
        }
        .overlay {
            if showConfetti && !reduceMotion {
                ConfettiBurstView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear {
            localTarget = state.weeklyGoalTarget
            triggerConfettiIfNeeded()
        }
        .onChange(of: state.weeklyGoalSummary) { _ in
            triggerConfettiIfNeeded()
        }
    }

    private var headerCard: some View {
        let summary = state.weeklyGoalSummary
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bu Haftanın Özeti")
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(summary.weekLabel)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Badge(
                    text: summary.isCompleted ? "Hedef Tamam" : "\(summary.completedCount)/\(summary.target)",
                    tint: summary.isCompleted ? AppColor.success : AppColor.primary,
                    background: summary.isCompleted ? AppColor.successLight : AppColor.primaryLight
                )
            }

            ProgressView(value: summary.progress)
                .tint(summary.isCompleted ? AppColor.success : AppColor.primary)
                .frame(maxWidth: .infinity, minHeight: 8)

            HStack(spacing: 10) {
                statPill(icon: "list.bullet.rectangle", label: "Tamamlanan", value: "\(summary.completedCount)")
                statPill(icon: "calendar", label: "Hedef", value: "\(summary.target)")
                statPill(icon: "flame.fill", label: "Seri", value: "\(summary.consecutiveCompletedWeeks) hafta")
            }

            weekDayProgressStrip(summary: summary)

            if summary.disciplineBadgeUnlocked {
                HStack(spacing: 8) {
                    Image(systemName: "rosette")
                        .foregroundStyle(AppColor.warning)
                    Text("Disiplinli Hekim rozeti açıldı")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppColor.warningLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppColor.warning.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let focus = state.weeklyGoalFocus {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppColor.primaryDark)
                    Text("AI odak: \(focus.summaryLine) · önerilen hedef \(focus.suggestedWeeklyTarget ?? summary.target)/hafta")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppColor.primaryLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppColor.primary.opacity(0.24), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var goalSetterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hedef Ayarla")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            Stepper(value: $localTarget, in: 1...14, step: 1) {
                Text("Haftalık hedef: \(localTarget) vaka")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(4)
            }
            .tint(AppColor.primary)
            .onChange(of: localTarget) { newValue in
                state.updateWeeklyGoalTarget(newValue)
                Haptic.selection()
            }

            Text("Hedefini yükselttikçe günlük hatırlatmalar ve haftalık özet bildirimleri buna göre güncellenir.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var thisWeekCasesCard: some View {
        let sessions = state.weeklyGoalSummary.thisWeekCases
        return VStack(alignment: .leading, spacing: 10) {
            Text("Bu Haftanın Vakaları")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            if sessions.isEmpty {
                Text("Bu hafta henüz tamamlanan vaka yok.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            } else {
                ForEach(Array(sessions.prefix(8).enumerated()), id: \.element.id) { _, session in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.caseTitle)
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(2)
                            Text(sessionTimestamp(session))
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        Spacer()
                        Badge(
                            text: session.score.map { "\(Int($0.overallScore.rounded()))" } ?? "--",
                            tint: AppColor.primaryDark,
                            background: AppColor.primaryLight
                        )
                    }
                    .padding(10)
                    .background(AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var historyCalendarCard: some View {
        let weeks = state.weeklyGoalSummary.previousWeeks
        return VStack(alignment: .leading, spacing: 10) {
            Text("Geçmiş Haftalar")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(weeks) { week in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(week.shortLabel)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Image(systemName: week.isCompleted ? "checkmark.seal.fill" : "clock.fill")
                                .foregroundStyle(week.isCompleted ? AppColor.success : AppColor.warning)
                            Text("\(week.completedCount)/\(week.target)")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                    .background(week.isCompleted ? AppColor.successLight : AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke((week.isCompleted ? AppColor.success : AppColor.border).opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statPill(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(AppFont.caption)
            }
            .foregroundStyle(AppColor.textSecondary)

            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColor.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func weekDayProgressStrip(summary: WeeklyGoalSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hafta İçi Takip")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            HStack(spacing: 8) {
                ForEach(weekDayItems(summary: summary), id: \.key) { item in
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(item.isDone ? AppColor.success : AppColor.surfaceAlt)
                                .frame(width: 30, height: 30)
                            Image(systemName: item.isDone ? "checkmark" : "circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.isDone ? .white : AppColor.textTertiary)
                        }

                        Text(item.label)
                            .font(AppFont.caption)
                            .foregroundStyle(item.isToday ? AppColor.primaryDark : AppColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func weekDayItems(summary: WeeklyGoalSummary) -> [(key: String, label: String, isDone: Bool, isToday: Bool)] {
        let calendar = Calendar(identifier: .gregorian)
        let nowKey = WeeklyGoalCalculator.dayKey(for: Date())
        let labels = ["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"]

        return (0..<7).map { idx in
            let date = calendar.date(byAdding: .day, value: idx, to: summary.weekStart) ?? summary.weekStart
            let key = WeeklyGoalCalculator.dayKey(for: date)
            return (
                key: key,
                label: labels[idx],
                isDone: summary.solvedDayKeysThisWeek.contains(key),
                isToday: key == nowKey
            )
        }
    }

    private func sessionTimestamp(_ session: CaseSession) -> String {
        guard let date = WeeklyGoalCalculator.sessionDate(session) else {
            return "Zaman bilgisi yok"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "EEE, d MMM · HH:mm"
        return formatter.string(from: date)
    }

    private func triggerConfettiIfNeeded() {
        guard !reduceMotion else { return }
        let summary = state.weeklyGoalSummary
        guard summary.isCompleted else { return }
        let weekId = WeeklyGoalCalculator.dayKey(for: summary.weekStart)
        guard !didTriggerConfetti else { return }
        didTriggerConfetti = true
        showConfetti = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if weekId == WeeklyGoalCalculator.dayKey(for: state.weeklyGoalSummary.weekStart) {
                showConfetti = false
            }
        }
    }
}

