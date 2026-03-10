import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    var onStatusMessage: ((String) -> Void)?

    struct RefreshResult {
        let profile: UserProfile
        let accessToken: String?
    }

    struct DeleteDataResult {
        let profile: UserProfile?
        let statusMessage: String
        let accessToken: String
    }

    @Published private(set) var challenge: DailyChallenge?
    @Published private(set) var challengeTimeLeft: ChallengeTimeLeft?
    @Published private(set) var challengeStats: ChallengeStats?
    @Published private(set) var weakAreaAnalysis: WeakAreaAnalysisResponse?
    @Published private(set) var weeklyGoalFocus: WeeklyGoalFocus?
    @Published private(set) var studyPlan: StudyPlanSnapshot
    @Published private(set) var caseHistory: [CaseSession] = []
    @Published private(set) var weeklyGoalTarget: Int
    @Published private(set) var weeklyGoalSummary: WeeklyGoalSummary
    @Published private(set) var inAppBanner: InAppBanner?
    @Published private(set) var isBusy: Bool = false

    private let api: APIClient
    private let supabase: SupabaseService
    private let defaults: UserDefaults

    private var lastInAppFetchAt: Date?
    private var seenBannerIds = Set<String>()
    private var busyOperationCount: Int = 0

    private static let weakAreaAppliedSignatureKey = "drkynox.weekly_goal.ai_applied_signature"
    private static let studyPlanAppliedSignatureKey = "drkynox.study_plan.applied_signature"

    init(
        api: APIClient,
        supabase: SupabaseService,
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.supabase = supabase
        self.defaults = defaults
        let target = WeeklyGoalStorage.loadTarget()
        self.weeklyGoalTarget = target
        self.weeklyGoalSummary = .empty
        self.studyPlan = .empty
    }

    func refreshDashboard(showBusy: Bool = true, routeIsHome: Bool = true) async throws -> RefreshResult {
        if showBusy {
            beginBusyOperation()
        }
        defer {
            if showBusy {
                endBusyOperation()
            }
        }

        async let caseListCall = supabase.fetchCaseList(limit: 80)
        async let profileCall = supabase.fetchProfile()
        async let tokenCall = supabase.currentAccessToken()
        async let challengeCall = try? supabase.fetchTodayChallenge()

        let (cases, me, token, challengeBundle) = try await (caseListCall, profileCall, tokenCall, challengeCall)
        challenge = challengeBundle?.challenge
        challengeTimeLeft = challengeBundle?.timeLeft
        challengeStats = challengeBundle?.stats
        caseHistory = cases
        refreshWeeklyGoalState()
        syncStudyPlanFromProfile(me, forceApplyTarget: false)
        await refreshWeakAreaState(cases: cases, token: token)
        await refreshInAppBannerIfNeeded(force: true, routeIsHome: routeIsHome)
        return RefreshResult(profile: me, accessToken: token)
    }

    func clearForSignedOut() {
        inAppBanner = nil
        caseHistory = []
        challenge = nil
        challengeTimeLeft = nil
        challengeStats = nil
        weakAreaAnalysis = nil
        weeklyGoalFocus = nil
        studyPlan = .empty
        weeklyGoalSummary = .empty
        lastInAppFetchAt = nil
        seenBannerIds.removeAll()
        busyOperationCount = 0
        isBusy = false
    }

    func deleteMyData() async throws -> DeleteDataResult {
        beginBusyOperation()
        defer { endBusyOperation() }

        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }

        let response = try await api.deleteMyData(accessToken: token)
        caseHistory = []
        challengeStats = nil
        refreshWeeklyGoalState()
        weakAreaAnalysis = WeakAreaAnalysisResponse.localFallback(from: [], weeklyTarget: weeklyGoalTarget)

        let message = response.deletedCaseSessions != nil
            ? "Tüm vaka verilerin silindi."
            : "Vaka verilerin temizlendi."

        let profile: UserProfile?
        do {
            profile = try await supabase.fetchProfile()
        } catch {
            profile = nil
        }

        return DeleteDataResult(profile: profile, statusMessage: message, accessToken: token)
    }

    func submitContentReport(caseSession: CaseSession?,
                             category: String,
                             details: String) async throws -> String {
        beginBusyOperation()
        defer { endBusyOperation() }

        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }

        _ = try await api.submitContentReport(
            accessToken: token,
            caseSessionId: caseSession?.id,
            caseTitle: caseSession?.caseTitle,
            mode: caseSession?.mode,
            difficulty: caseSession?.difficulty,
            specialty: caseSession?.specialty,
            category: category,
            details: details
        )
        return "Raporun alındı. En kısa sürede inceleyeceğiz."
    }

    func submitUserFeedback(topic: String, message: String) async throws -> String {
        beginBusyOperation()
        defer { endBusyOperation() }

        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }

        _ = try await api.submitUserFeedback(
            accessToken: token,
            topic: topic,
            message: message
        )
        return "Feedback mesajın alındı. Teşekkür ederiz."
    }

    func updateWeeklyGoalTarget(_ target: Int) async {
        applyWeeklyGoalTarget(target, source: .manual)
        refreshWeeklyGoalState()

        let token = try? await supabase.currentAccessToken()
        await refreshWeakAreaState(cases: caseHistory, token: token ?? nil)
    }

    func refreshInAppBannerIfNeeded(force: Bool, routeIsHome: Bool) async {
        let now = Date()
        if !force, let last = lastInAppFetchAt, now.timeIntervalSince(last) < 20 {
            return
        }

        guard routeIsHome else {
            inAppBanner = nil
            return
        }

        guard let token = try? await supabase.currentAccessToken(), !token.isEmpty else {
            inAppBanner = nil
            return
        }

        do {
            let response = try await api.fetchInAppBanner(accessToken: token)
            lastInAppFetchAt = Date()
            inAppBanner = response.banner
            if let bannerId = response.banner?.id {
                await acknowledgeInAppBannerSeenIfNeeded(broadcastId: bannerId)
            }
        } catch {
            // Banner hataları sessiz geçilir; ana akışı kesmesin.
        }
    }

    func dismissInAppBanner(broadcastId: String) async {
        guard let token = try? await supabase.currentAccessToken(), !token.isEmpty else {
            inAppBanner = nil
            return
        }

        do {
            _ = try await api.acknowledgeInAppBanner(
                accessToken: token,
                broadcastId: broadcastId,
                action: "dismiss"
            )
        } catch {
            // Kullanıcı deneyimini bozmasın.
        }
        inAppBanner = nil
    }

    func syncStudyPlanFromProfile(_ profile: UserProfile?, forceApplyTarget: Bool) {
        studyPlan = StudyPlanSnapshot.from(profile: profile)
        guard studyPlan.isConfigured else { return }

        if forceApplyTarget {
            WeeklyGoalStorage.markUserCustomizedTarget(false)
        }

        let signature = studyPlan.signature
        let previousSignature = defaults.string(forKey: Self.studyPlanAppliedSignatureKey)
        let userCustomized = WeeklyGoalStorage.isUserCustomizedTarget()
        let shouldApply = forceApplyTarget || (!userCustomized && (previousSignature != signature || weeklyGoalTarget <= 0))

        if shouldApply {
            applyWeeklyGoalTarget(studyPlan.recommendedWeeklyTarget, source: .studyPlan)
            refreshWeeklyGoalState()
        }

        defaults.set(signature, forKey: Self.studyPlanAppliedSignatureKey)
    }

    func saveCase(payload: SaveCasePayload) async throws {
        do {
            if let token = try await supabase.currentAccessToken(), !token.isEmpty {
                try await api.saveCase(accessToken: token, payload: payload)
            } else {
                try await supabase.saveCase(payload)
            }
            caseHistory = try await supabase.fetchCaseList(limit: 80)
            refreshWeeklyGoalState()
            let token = try? await supabase.currentAccessToken()
            await refreshWeakAreaState(cases: caseHistory, token: token ?? nil)
        } catch {
            do {
                // Backend gecici hatasinda dogrudan Supabase yazimini fallback tut.
                try await supabase.saveCase(payload)
                caseHistory = try await supabase.fetchCaseList(limit: 80)
                refreshWeeklyGoalState()
                let token = try? await supabase.currentAccessToken()
                await refreshWeakAreaState(cases: caseHistory, token: token ?? nil)
            } catch {
                throw error
            }
        }
    }

    private func refreshWeeklyGoalState() {
        weeklyGoalSummary = WeeklyGoalCalculator.buildSummary(from: caseHistory, target: weeklyGoalTarget)
        WeeklyGoalStorage.writeWidgetSnapshot(weeklyGoalSummary)
        Task {
            await WeeklyGoalNotificationManager.shared.configureNotifications(summary: weeklyGoalSummary)
        }
    }

    private func beginBusyOperation() {
        busyOperationCount += 1
        isBusy = busyOperationCount > 0
    }

    private func endBusyOperation() {
        busyOperationCount = max(0, busyOperationCount - 1)
        isBusy = busyOperationCount > 0
    }

    private func refreshWeakAreaState(cases: [CaseSession], token: String?) async {
        let fallback = WeakAreaAnalysisResponse.localFallback(from: cases, weeklyTarget: weeklyGoalTarget)
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            weakAreaAnalysis = fallback
            syncWeakAreaLoop(analysis: fallback)
            return
        }

        do {
            weakAreaAnalysis = try await api.fetchWeakAreaAnalysis(accessToken: token)
            if let analysis = weakAreaAnalysis {
                syncWeakAreaLoop(analysis: analysis)
            }
        } catch {
            weakAreaAnalysis = fallback
            syncWeakAreaLoop(analysis: fallback)
        }
    }

    private func acknowledgeInAppBannerSeenIfNeeded(broadcastId: String) async {
        let cleanId = broadcastId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        guard !seenBannerIds.contains(cleanId) else { return }
        guard let token = try? await supabase.currentAccessToken(), !token.isEmpty else {
            return
        }

        do {
            _ = try await api.acknowledgeInAppBanner(
                accessToken: token,
                broadcastId: cleanId,
                action: "seen"
            )
            seenBannerIds.insert(cleanId)
        } catch {
            // Ack hatası banner gösterimini engellemez.
        }
    }

    private enum WeeklyGoalUpdateSource {
        case manual
        case studyPlan
        case weakAreaAI
    }

    private func applyWeeklyGoalTarget(_ target: Int, source: WeeklyGoalUpdateSource) {
        let normalized = max(1, min(14, target))
        guard weeklyGoalTarget != normalized else { return }
        weeklyGoalTarget = normalized
        WeeklyGoalStorage.saveTarget(normalized)
        switch source {
        case .manual:
            WeeklyGoalStorage.markUserCustomizedTarget(true)
        case .studyPlan, .weakAreaAI:
            break
        }
    }

    private func syncWeakAreaLoop(analysis: WeakAreaAnalysisResponse) {
        if let recommendation = analysis.aiRecommendation {
            weeklyGoalFocus = WeeklyGoalFocus(
                title: recommendation.title,
                recommendedSpecialty: recommendation.recommendedSpecialty,
                recommendedSpecialtyLabel: recommendation.recommendedSpecialtyLabel,
                recommendedDifficulty: recommendation.recommendedDifficulty,
                focusDimensionKey: recommendation.focusDimensionKey,
                focusDimensionLabel: recommendation.focusDimensionLabel,
                focusDimensionScore: recommendation.focusDimensionScore,
                suggestedWeeklyTarget: recommendation.suggestedWeeklyTarget,
                generatedAt: Date()
            )
        } else {
            weeklyGoalFocus = nil
        }

        guard let recommendation = analysis.aiRecommendation,
              let suggested = recommendation.suggestedWeeklyTarget else { return }

        let weekKey = WeeklyGoalCalculator.dayKey(for: weeklyGoalSummary.weekStart)
        let signature = "\(weekKey)|\(suggested)|\(recommendation.recommendedSpecialty)|\(recommendation.focusDimensionKey ?? "")"
        let lastApplied = defaults.string(forKey: Self.weakAreaAppliedSignatureKey)
        guard signature != lastApplied else { return }

        let userCustomized = WeeklyGoalStorage.isUserCustomizedTarget()
        let targetToApply = userCustomized ? max(weeklyGoalTarget, suggested) : suggested
        let previousTarget = weeklyGoalTarget
        applyWeeklyGoalTarget(targetToApply, source: .weakAreaAI)
        refreshWeeklyGoalState()
        defaults.set(signature, forKey: Self.weakAreaAppliedSignatureKey)

        if previousTarget != weeklyGoalTarget {
            onStatusMessage?("Zayıf alan analizine göre haftalık hedefin güncellendi: \(targetToApply) vaka.")
        }
    }
}
