import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    let onOpenGenerator: () -> Void
    @AppStorage("widget_tip_dismissed") private var widgetTipDismissed = false
    @State private var modeFlow: ModeSelectionFlow?
    @State private var showWeeklyGoalDetail = false
    @State private var showStudyPlanDetail = false
    @State private var showWidgetGuideSheet = false
    @State private var showNotificationPrimer = false
    @State private var showQuickCase = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    dashboardHeader
                    VStack(spacing: 12) {
                        startCaseCard
                        dailyChallengeBlock
                        progressSummaryCard
                        quickAccessRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .padding(.top, 8)
            }
            .background(AppColor.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await state.refreshDashboard()
            }
            .navigationDestination(isPresented: $showWeeklyGoalDetail) {
                WeeklyGoalDetailView()
                    .environmentObject(state)
            }
            .navigationDestination(isPresented: $showStudyPlanDetail) {
                StudyPlanDetailView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showWidgetGuideSheet) {
                NavigationStack {
                    ScrollView {
                        OnboardingWidgetStep()
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                    }
                    .background(AppColor.background.ignoresSafeArea())
                    .navigationTitle("Widget Kurulumu")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Kapat") {
                                showWidgetGuideSheet = false
                            }
                        }
                    }
                }
            }
            .fullScreenCover(item: $modeFlow) { flow in
                NavigationStack {
                    ModeSelectionPage(flow: flow)
                }
            }
            .fullScreenCover(isPresented: $showQuickCase) {
                NavigationStack {
                    CodeBlueSessionView()
                        .environmentObject(state)
                }
            }
            .alert("Bildirimleri açmak ister misin?", isPresented: $showNotificationPrimer) {
                Button("Şimdi Değil", role: .cancel) {
                }
                Button("Aç") {
                    Task {
                        _ = await state.requestNotificationPermissionAndSchedule()
                    }
                }
            } message: {
                Text("Vaka çözmediğin günlerde hatırlatma alırsın ve haftalık özetini kaçırmazsın.")
            }
            .onAppear {
                Task { await state.configureWeeklyGoalNotifications() }
                prepareNotificationPrimerIfNeeded()
                handlePendingHomeTarget()
            }
            .onChange(of: state.pendingHomeOpenTarget) { _ in
                handlePendingHomeTarget()
            }
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(AppColor.primary)
                            .frame(width: 40, height: 40)
                        Image(systemName: "cross.case.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text("Dr.Kynox")
                        .font(AppFont.h3)
                        .foregroundStyle(AppColor.textPrimary)
                }
                Spacer()
                Circle()
                    .fill(AppColor.surfaceAlt)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "bell")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColor.textSecondary)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(greetingTitle)
                    .font(AppFont.h2)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Circle()
                        .fill(AppColor.success)
                        .frame(width: 8, height: 8)
                    Text("Mevcut Odak: \(SpecialtyOption.label(for: preferredSpecialty))")
                        .font(AppFont.secondary)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .clipShape(BottomRoundedShape(radius: 48))
        .appShadow(AppShadow.low)
    }

    private func prepareNotificationPrimerIfNeeded() {
        Task {
            let shouldShow = await state.shouldShowNotificationPrimer()
            if shouldShow {
                showNotificationPrimer = true
            }
        }
    }

    private var startCaseCard: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vaka Başlat")
                    .font(AppFont.h2)
                    .foregroundStyle(.white)
                Text("Yeni bir vakaya başlayarak klinik yeteneklerini geliştir.")
                    .font(AppFont.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(4)

                HStack(spacing: 10) {
                    Button {
                        onOpenGenerator()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Başlat")
                        }
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.primary)
                        .frame(width: 108, height: 44)
                        .background(.white)
                        .clipShape(Capsule())
                        .appShadow(AppShadow.low)
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        showQuickCase = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                            Text("15sn Hızlı Vaka")
                        }
                        .font(AppFont.secondary)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 48, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
            .shadow(color: AppColor.primary.opacity(0.2), radius: 10, x: 0, y: 8)

            Image(systemName: "stethoscope")
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(.white.opacity(0.2))
                .offset(x: 20, y: 12)
        }
    }

    private var dailyChallengeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Günün Vakası")
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text("Kalan: \(state.challengeTimeLeft?.label ?? "--")")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }

            if state.isBusy && state.challenge == nil {
                VStack(spacing: AppSpacing.x1) {
                    ShimmerView()
                        .frame(height: 120)
                }
            } else if let challenge = state.challenge {
                challengeCard(challenge)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Günün vakası şu an alınamadı.")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Bağlantını kontrol edip tekrar deneyebilirsin.")
                        .font(AppFont.secondary)
                        .foregroundStyle(AppColor.textSecondary)
                    Button("Yeniden Dene") {
                        Task {
                            await state.refreshDashboard()
                        }
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .appShadow(AppShadow.low)
            }
        }
    }

    private var progressSummaryCard: some View {
        let summary = state.weeklyGoalSummary
        let progressValue = min(max(summary.progress, 0), 1)
        let progressPercent = Int((progressValue * 100).rounded())
        let subtitle = completedCaseHistory.isEmpty
            ? "İlk vaka için hazırsın!"
            : "\(completedCaseHistory.count) vaka tamamlandı, devam et."

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("İlerlemen")
                        .font(AppFont.h3)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(subtitle)
                        .font(AppFont.secondary)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Text("%\(progressPercent)")
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
            }

            ProgressView(value: progressValue)
                .tint(AppColor.primary)

            HStack(spacing: 8) {
                Text("Hedef: \(summary.completedCount) / \(summary.target) vaka")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
                Button {
                    onOpenGenerator()
                } label: {
                    Text("Yeni Vaka")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppColor.primaryLight)
                        .clipShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(20)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .appShadow(AppShadow.low)
    }

    private var quickAccessRow: some View {
        HStack(spacing: 10) {
            statusQuickAction(
                icon: "arrow.triangle.2.circlepath",
                title: "Çalışma Planı",
                subtitle: state.studyPlan.isConfigured ? "Aktif" : "Kurulmadı",
                background: AppColor.successLight.opacity(0.38),
                iconTint: AppColor.success,
                badgeTint: AppColor.success
            ) {
                showStudyPlanDetail = true
            }

            statusQuickAction(
                icon: "target",
                title: "Haftalık Hedef",
                subtitle: "\(state.weeklyGoalSummary.completedCount) / \(state.weeklyGoalSummary.target) Vaka",
                background: AppColor.primaryLight.opacity(0.32),
                iconTint: AppColor.primary,
                badgeTint: AppColor.primary
            ) {
                showWeeklyGoalDetail = true
            }
        }
    }

    private func statusQuickAction(icon: String,
                                   title: String,
                                   subtitle: String,
                                   background: Color,
                                   iconTint: Color,
                                   badgeTint: Color,
                                   action: @escaping () -> Void) -> some View {
        Button {
            Haptic.selection()
            action()
        } label: {
            VStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(badgeTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.7))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding(.horizontal, 8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var widgetSuggestionCard: some View {
        DSInfoCard(tone: .primary) {
            HStack(alignment: .top, spacing: AppSpacing.x1) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .foregroundStyle(AppColor.primaryDark)
                VStack(alignment: .leading, spacing: AppSpacing.x1) {
                    Text("Widget Önerisi")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Birkaç vaka çözdün. Günün vakasına daha hızlı dönmek için widget ekleyebilirsin.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
            }

            HStack(spacing: AppSpacing.x1) {
                Button("Nasıl Eklenir?") {
                    showWidgetGuideSheet = true
                    Haptic.selection()
                }
                .buttonStyle(DSSecondaryButtonStyle())

                Button("Gizle") {
                    widgetTipDismissed = true
                }
                .dsTertiaryAction(.neutral)
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private var continueBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AppSpacing.x1) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(AppColor.primaryDark)
                Text("Devam Et")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
            }
            ForEach(completedCaseHistory.prefix(2)) { item in
                HistoryCard(item: item)
            }
        }
    }

    private var shouldShowWidgetTip: Bool {
        completedCaseHistory.count >= 3 && !widgetTipDismissed
    }

    private var greetingSection: some View {
        let firstName = state.profile?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = firstName.isEmpty ? "" : " \(firstName)"
        return VStack(alignment: .leading, spacing: AppSpacing.x1 / 2) {
            Text("\(timeGreeting)\(displayName) 👋")
                .font(AppFont.h2)
                .foregroundStyle(AppColor.textPrimary)

            Text("Bugün odak bölümün: \(SpecialtyOption.label(for: preferredSpecialty))")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greetingTitle: String {
        let firstName = state.profile?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = firstName.isEmpty ? "" : " \(firstName)"
        return "\(timeGreeting)\(displayName) 👋"
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Günaydın"
        case 12..<18:
            return "İyi günler"
        case 18..<23:
            return "İyi akşamlar"
        default:
            return "İyi geceler"
        }
    }

    private var statsScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.x1) {
                StatCard(title: "Toplam Vaka", value: "\(state.caseHistory.count)", subtitle: "tamamlanan")
                StatCard(title: "Ortalama Skor", value: averageScoreText, subtitle: "genel başarı")
                StatCard(title: "Günlük Seri", value: "🔥 \(streakDays)", subtitle: "gün")
                StatCard(title: "Haftalık", value: weeklyProgressText, subtitle: "ilerleme")
            }
            .padding(.horizontal, 1)
        }
    }

    private var emptyStatsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vaka başlat")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
            Text("İlk vakanı tamamla; kişisel skorların, seri hedefin ve güçlü yönlerin burada görünmeye başlar.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
            Button {
                onOpenGenerator()
            } label: {
                HStack(spacing: 6) {
                    Text("Vaka başlat")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.primaryDark)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var randomGeneratorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rastgele Vaka Üretici")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            Text("Bölüm ve zorluk seç, ardından sesli veya yazılı vakaya başla.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Button {
                onOpenGenerator()
            } label: {
                HStack {
                    Text("Vaka başlat")
                        .font(AppFont.bodyMedium)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .appPrimaryButtonLabelStyle()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Vaka başlat")
            .accessibilityHint("Bölüm ve zorluk seçimi ekranına geçer")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.primaryLight)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.primary.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var studyPlanCycleCard: some View {
        let plan = state.studyPlan
        let steps = studyPlanStepStates
        let doneCount = steps.filter { $0 }.count
        let progress = steps.isEmpty ? 0 : Double(doneCount) / Double(steps.count)

        return Button {
            showStudyPlanDetail = true
            Haptic.selection()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Çalışma Planı İlerlemesi", systemImage: "arrow.triangle.2.circlepath")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("\(doneCount)/\(steps.count) adım")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.primaryDark)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(AppColor.primaryLight)
                        .clipShape(Capsule())
                }

                if plan.isConfigured {
                    Text(plan.compactLabel)
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(2)
                } else {
                    Text("Planını tamamla, haftalık hedef ve AI önerileri bu döngüye otomatik bağlansın.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(2)
                }

                Text("Toplam \(steps.count) plan adımının \(doneCount) tanesi tamamlandı.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                    .lineSpacing(4)

                ProgressView(value: progress)
                    .tint(doneCount == steps.count ? AppColor.success : AppColor.primary)

                HStack(spacing: 8) {
                    ForEach(Array(steps.prefix(4).enumerated()), id: \.offset) { _, isDone in
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isDone ? AppColor.success : AppColor.textTertiary)
                    }
                    Spacer()
                    Text("Detayı Aç")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.primaryDark)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.primaryDark)
                }
            }
            .padding(12)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var studyPlanStepStates: [Bool] {
        let solved = state.weeklyGoalSummary.completedCount > 0
        let hasWeak = state.weakAreaAnalysis?.hasData == true
        let hasFocus = state.weeklyGoalFocus != nil
        let aiTarget = state.weeklyGoalFocus?.suggestedWeeklyTarget
        let updatedTarget = aiTarget != nil && state.weeklyGoalTarget == aiTarget
        return [
            state.studyPlan.isConfigured,
            state.weeklyGoalTarget > 0,
            solved,
            solved, // flashcard üretimi vaka sonrası tetiklenir
            hasWeak,
            hasFocus,
            updatedTarget
        ]
    }

    private var weeklyGoalCard: some View {
        let summary = state.weeklyGoalSummary
        let progress = min(max(summary.progress, 0), 1)

        return Button {
            showWeeklyGoalDetail = true
            Haptic.selection()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Haftalık Hedef", systemImage: "target")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text(summary.weekLabel)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(AppColor.primary.opacity(0.16), lineWidth: 8)
                            .frame(width: 62, height: 62)
                        Circle()
                            .trim(from: 0, to: max(0.04, progress))
                            .stroke(
                                summary.isCompleted ? AppColor.success : AppColor.primary,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 62, height: 62)
                            .rotationEffect(.degrees(-90))
                        Text("\(summary.completedCount)/\(summary.target)")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.isCompleted ? "Bu haftanın hedefi tamamlandı" : "Bu hafta \(summary.remainingCount) vaka daha gerekiyor")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineSpacing(4)
                        Text(summary.disciplineBadgeUnlocked
                             ? "Disiplinli Hekim rozeti aktif"
                             : "4 hafta üst üste tamamla: Disiplinli Hekim")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Text("Detayı Aç")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.primaryDark)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.primaryDark)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppColor.primaryLight)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(summary.isCompleted ? AppColor.success.opacity(0.35) : AppColor.primary.opacity(0.24), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: (summary.isCompleted ? AppColor.success : AppColor.primary).opacity(0.12), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Haftalık hedef kartı")
        .accessibilityHint("Bu haftanın hedef detayına gider")
    }

    private var weakAreaInsightCard: some View {
        let analysis = state.weakAreaAnalysis
        let weakest = analysis?.specialtyBreakdown.first
        let hasData = analysis?.hasData == true
        let score = weakest?.userAverageScore ?? 0
        let tone: (tint: Color, background: Color) = {
            if score >= 70 { return (AppColor.success, AppColor.successLight) }
            if score >= 50 { return (AppColor.warning, AppColor.warningLight) }
            return (AppColor.error, AppColor.errorLight)
        }()

        return Button {
            state.selectedMainTab = "analysis"
            Haptic.selection()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(AppColor.primaryDark)
                    Text("Zayıf Alan Analizi")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if let caseCount = analysis?.summary.userCaseCount, caseCount > 0 {
                        Text("\(caseCount) vaka")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(AppColor.surfaceAlt)
                            .clipShape(Capsule())
                    }
                }

                if hasData, let weakest {
                    HStack(alignment: .center, spacing: 8) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tone.background)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text("\(Int(score.rounded()))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(tone.tint)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("En zayıf bölüm: \(weakest.specialtyLabel)")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(1)
                            Text("Skor \(Int(weakest.userAverageScore.rounded())) · Detayı açıp önerileri uygula")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                } else {
                    Text("Analiz için yeterli vaka oluşmadı. İlk vakalardan sonra bu alan otomatik dolacak.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                HStack(spacing: 6) {
                    Text("Detaylı analize git")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.primaryDark)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.primaryDark)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Zayıf alan analizi")
        .accessibilityHint("Skor haritası ve bölüm bazlı detayları açar")
    }

    private func challengeCard(_ challenge: DailyChallenge) -> some View {
        Button {
            modeFlow = ModeSelectionFlow(
                context: "daily",
                challenge: challenge,
                specialty: challenge.specialty,
                difficulty: challenge.difficulty
            )
        } label: {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#FF6B00").opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color(hex: "#FF6B00"))
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(challenge.title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(challenge.difficulty)
                            .font(AppFont.caption)
                            .foregroundStyle(Color(hex: "#FF6B00"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "#FF6B00").opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Text("Uzmanlık: \(SpecialtyOption.label(for: challenge.specialty))")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(1)

                    ProgressView(value: 0.62)
                        .tint(AppColor.primary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .appShadow(AppShadow.low)
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Günün Vakasını Aç")
        .accessibilityHint("Günün vakası için mod seçimine gider")
    }

    private var preferredSpecialty: String {
        if let challenge = state.challenge?.specialty, !challenge.isEmpty {
            return challenge
        }
        if let firstInterest = state.profile?.interestAreas.first, !firstInterest.isEmpty {
            return firstInterest
        }
        return "Kardiyoloji"
    }

    private var completedCaseHistory: [CaseSession] {
        state.caseHistory.filter { session in
            if session.score != nil { return true }
            let normalized = session.status
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: Locale(identifier: "tr_TR"))
            return normalized == "ready" || normalized == "completed"
        }
    }

    private var streakDays: Int {
        currentStreakDays(from: completedCaseHistory)
    }

    private var averageScoreText: String {
        let values = completedCaseHistory.compactMap { $0.score?.overallScore }
        guard !values.isEmpty else { return "--" }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.0f", avg)
    }

    private var weeklyProgressText: String {
        let thisWeek = completedCaseHistory.prefix(7).count
        return "+\(thisWeek)"
    }

    private func currentStreakDays(from sessions: [CaseSession], now: Date = Date()) -> Int {
        let solvedDayKeys = Set(
            sessions
                .compactMap { WeeklyGoalCalculator.sessionDate($0) }
                .map { WeeklyGoalCalculator.dayKey(for: $0) }
        )
        guard !solvedDayKeys.isEmpty else { return 0 }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        let startDay: Date
        if solvedDayKeys.contains(WeeklyGoalCalculator.dayKey(for: today)) {
            startDay = today
        } else if solvedDayKeys.contains(WeeklyGoalCalculator.dayKey(for: yesterday)) {
            startDay = yesterday
        } else {
            return 0
        }

        var streak = 0
        var cursor = startDay

        while solvedDayKeys.contains(WeeklyGoalCalculator.dayKey(for: cursor)) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }

        return streak
    }

    private func handlePendingHomeTarget() {
        guard let target = state.pendingHomeOpenTarget else { return }
        state.pendingHomeOpenTarget = nil

        switch target {
        case .weekly:
            showWeeklyGoalDetail = true
        case .daily:
            if let challenge = state.challenge {
                modeFlow = ModeSelectionFlow(
                    context: "daily",
                    challenge: challenge,
                    specialty: challenge.specialty,
                    difficulty: challenge.difficulty
                )
            }
        }
    }
}

private struct BottomRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.bottomLeft, .bottomRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
