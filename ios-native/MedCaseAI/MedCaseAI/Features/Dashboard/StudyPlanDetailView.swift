import SwiftUI

struct StudyPlanDetailView: View {
    @EnvironmentObject private var state: AppState

    @State private var isLoadingFlashcardStats = false
    @State private var flashcardTotal = 0

    private struct CycleStep: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        let done: Bool
        let icon: String
        let tint: Color
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.x2) {
                planSummaryCard
                loopProgressCard
                loopTimelineCard
            }
            .padding(AppSpacing.x2)
            .padding(.bottom, AppSpacing.x1)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Çalışma Planı")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshLoopState()
        }
        .task {
            await refreshLoopState()
        }
    }

    private var planSummaryCard: some View {
        let plan = state.studyPlan

        return VStack(alignment: .leading, spacing: AppSpacing.x1) {
            HStack {
                Text("Kişisel Plan")
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Badge(
                    text: plan.isConfigured ? "Aktif" : "Eksik",
                    tint: plan.isConfigured ? AppColor.success : AppColor.warning,
                    background: plan.isConfigured ? AppColor.successLight : AppColor.warningLight
                )
            }

            Text("Bu plan seni TUS hedefin için haftalık vaka ritminde tutar.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if plan.isConfigured {
                planRow(icon: "target", title: "Hedef sınav", value: plan.examTarget)
                planRow(icon: "calendar", title: "Sınav penceresi", value: plan.examWindow)
                planRow(icon: "timer", title: "Günlük süre", value: "\(plan.dailyMinutes) dakika")
                planRow(icon: "bolt.fill", title: "Plan modu", value: plan.cadence)
            } else {
                Text("Onboarding'de çalışma planını tamamladığında bu alan otomatik dolar.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
        }
        .padding(AppSpacing.cardPadding)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private var loopProgressCard: some View {
        let steps = cycleSteps
        let doneCount = steps.filter(\.done).count
        let progress = steps.isEmpty ? 0 : Double(doneCount) / Double(steps.count)

        return VStack(alignment: .leading, spacing: AppSpacing.x1) {
            HStack {
                Text("7 Adımlı Döngü")
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text("\(doneCount)/\(steps.count)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primaryDark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppColor.primaryLight)
                    .clipShape(Capsule())
            }

            ProgressView(value: progress)
                .tint(doneCount == steps.count ? AppColor.success : AppColor.primary)

            Text("İlerleme, tamamlanan adım sayısına göre hesaplanır. Her tamamlanan vaka döngüyü bir sonraki adıma taşır.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let focus = state.weeklyGoalFocus {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppColor.primaryDark)
                    Text("Haftalık odak: \(focus.summaryLine) · hedef \(focus.suggestedWeeklyTarget ?? state.weeklyGoalTarget)/hafta")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(2)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(AppColor.warning)
                    Text("En az 1 vaka tamamlandığında haftalık odak önerisi görünür.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
        .padding(AppSpacing.cardPadding)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private var loopTimelineCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.x1) {
            Text("Adımlar")
                .font(AppFont.h3)
                .foregroundStyle(AppColor.textPrimary)

            ForEach(cycleSteps) { step in
                HStack(alignment: .center, spacing: AppSpacing.x1) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : step.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(step.done ? step.tint : AppColor.textSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(1)
                        Text(step.subtitle)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)

                    if step.done {
                        Text("Tamam")
                            .font(AppFont.caption)
                            .foregroundStyle(step.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(step.tint.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, AppSpacing.x1 + 2)
                .padding(.vertical, AppSpacing.x1)
                .background(step.done ? step.tint.opacity(0.10) : AppColor.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .stroke(step.done ? step.tint.opacity(0.35) : AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }

            if !hasCompletedCase {
                HStack(spacing: AppSpacing.x1) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppColor.primary)
                    Text("Henüz tamamlanan vaka yok.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Spacer()
                    Button("Vaka başlat") {
                        state.selectedMainTab = "generator"
                    }
                    .font(AppFont.caption)
                    .dsTertiaryAction(.primary)
                }
                .padding(.top, 2)
            }
        }
        .padding(AppSpacing.cardPadding)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private var completedCaseCount: Int {
        state.caseHistory.filter {
            $0.score != nil || $0.status.lowercased(with: Locale(identifier: "tr_TR")) == "completed"
        }.count
    }

    private var hasCompletedCase: Bool {
        completedCaseCount > 0
    }

    private var cycleSteps: [CycleStep] {
        let solvedAtLeastOne = hasCompletedCase
        let weakReady = state.weakAreaAnalysis?.hasData == true
        let aiReady = state.weeklyGoalFocus != nil
        let aiTarget = state.weeklyGoalFocus?.suggestedWeeklyTarget
        let weeklyUpdated = aiTarget != nil && aiTarget == state.weeklyGoalTarget

        return [
            .init(id: 1, title: "Plan bilgisi tamamlandı", subtitle: state.studyPlan.isConfigured ? state.studyPlan.compactLabel : "Hedef ve sınav bilgisi girilmedi", done: state.studyPlan.isConfigured, icon: "doc.text", tint: AppColor.primary),
            .init(id: 2, title: "Haftalık hedef belirlendi", subtitle: "Hedef: \(state.weeklyGoalTarget) vaka / hafta", done: state.weeklyGoalTarget > 0, icon: "target", tint: AppColor.primary),
            .init(id: 3, title: "Vaka pratikleri tamamlandı", subtitle: solvedAtLeastOne ? "\(completedCaseCount) vaka tamamlandı" : "Henüz tamamlanan vaka yok", done: solvedAtLeastOne, icon: "stethoscope", tint: AppColor.success),
            .init(id: 4, title: "Hızlı tekrar kartları hazır", subtitle: isLoadingFlashcardStats ? "Kartlar yükleniyor..." : "\(flashcardTotal) kart kayıtlı", done: flashcardTotal > 0, icon: "rectangle.stack", tint: AppColor.success),
            .init(id: 5, title: "Zayıf alan haritası güncel", subtitle: weakReady ? "Analiz güncel" : "Analiz için daha fazla vaka gerekiyor", done: weakReady, icon: "chart.line.uptrend.xyaxis", tint: AppColor.warning),
            .init(id: 6, title: "Haftalık odak önerisi üretildi", subtitle: aiReady ? (state.weeklyGoalFocus?.summaryLine ?? "Odak önerisi hazır") : "Odak önerisi bekleniyor", done: aiReady, icon: "sparkles", tint: AppColor.warning),
            .init(id: 7, title: "Yeni haftalık hedefe geçildi", subtitle: "Mevcut hedef: \(state.weeklyGoalTarget) vaka / hafta", done: weeklyUpdated, icon: "arrow.triangle.2.circlepath", tint: AppColor.error)
        ]
    }

    private func planRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.primary)
                .frame(width: 26, height: 26)
                .background(AppColor.primaryLight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
    }

    private func refreshLoopState() async {
        isLoadingFlashcardStats = true
        defer { isLoadingFlashcardStats = false }
        do {
            let collections = try await state.fetchFlashcardCollections(limit: 1)
            flashcardTotal = collections.stats?.total ?? collections.cards.count
        } catch {
            flashcardTotal = 0
        }
    }
}
