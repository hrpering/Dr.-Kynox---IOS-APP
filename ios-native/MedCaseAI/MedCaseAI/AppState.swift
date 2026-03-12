import Foundation
import Combine
import UIKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum SignUpOutcome {
        case signedIn
        case emailVerificationRequired
    }

    enum Route {
        case loading
        case auth
        case onboarding
        case home
    }

    enum HomeOpenTarget: String {
        case daily
        case weekly
    }

    @Published var route: Route = .loading
    @Published var selectedMainTab: String = "home"
    @Published var generatorReplayContext: GeneratorReplayContext?
    @Published var pendingHomeOpenTarget: HomeOpenTarget?
    @Published var statusMessage: String = ""

    var accessToken: String? { authViewModel.accessToken }
    var profile: UserProfile? { authViewModel.profile }
    var uiLanguageCode: String {
        AppLanguage.normalizeBCP47(profile?.preferredLanguageCode, fallback: "tr")
    }
    var uiLanguageName: String {
        AppLanguage.displayName(for: uiLanguageCode)
    }
    var uiCountryCode: String {
        let fromProfile = AppCountry.normalize(profile?.countryCode)
        if !fromProfile.isEmpty {
            return fromProfile
        }
        return AppCountry.normalize(Locale.current.region?.identifier)
    }
    var uiLocale: Locale {
        let region = uiCountryCode
        let language = uiLanguageCode
        if region.isEmpty {
            return Locale(identifier: language)
        }
        return Locale(identifier: "\(language)-\(region)")
    }
    var uiLayoutDirection: LayoutDirection {
        let isRTL = AppLanguage.supported.first(where: { $0.code == uiLanguageCode })?.isRTL == true
        return isRTL ? .rightToLeft : .leftToRight
    }

    var challenge: DailyChallenge? { dashboardViewModel.challenge }
    var challengeTimeLeft: ChallengeTimeLeft? { dashboardViewModel.challengeTimeLeft }
    var challengeStats: ChallengeStats? { dashboardViewModel.challengeStats }
    var weakAreaAnalysis: WeakAreaAnalysisResponse? { dashboardViewModel.weakAreaAnalysis }
    var weeklyGoalFocus: WeeklyGoalFocus? { dashboardViewModel.weeklyGoalFocus }
    var studyPlan: StudyPlanSnapshot { dashboardViewModel.studyPlan }
    var caseHistory: [CaseSession] { dashboardViewModel.caseHistory }
    var weeklyGoalTarget: Int { dashboardViewModel.weeklyGoalTarget }
    var weeklyGoalSummary: WeeklyGoalSummary { dashboardViewModel.weeklyGoalSummary }
    var inAppBanner: InAppBanner? { dashboardViewModel.inAppBanner }
    var isBusy: Bool { authViewModel.isBusy || dashboardViewModel.isBusy }

    private let api: APIClient
    private let supabase: SupabaseService
    private let authViewModel: AuthViewModel
    private let dashboardViewModel: DashboardViewModel
    private let flashcardViewModel: FlashcardViewModel
    private let notificationManager: NotificationManager

    private var didBootstrap = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        let api = APIClient()
        let supabase = SupabaseService()

        self.api = api
        self.supabase = supabase
        self.authViewModel = AuthViewModel(supabase: supabase)
        self.dashboardViewModel = DashboardViewModel(api: api, supabase: supabase)
        self.flashcardViewModel = FlashcardViewModel(api: api, supabase: supabase)
        self.notificationManager = NotificationManager(api: api, supabase: supabase)

        route = authViewModel.hasSessionHint ? .loading : .auth

        bindChildChanges()
        configureModuleCallbacks()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            let hint = try await authViewModel.bootstrapFromStoredSessionHint()
            route = route(for: hint)

            if route == .home {
                dashboardViewModel.syncStudyPlanFromProfile(profile, forceApplyTarget: false)
                await refreshDashboard(showBusy: false)
                await syncPushRegistrationIfPossible(force: false)
            }
        } catch {
            route = .auth
            statusMessage = error.localizedDescription
        }
    }

    func signIn(email: String, password: String) async throws {
        let hint = try await authViewModel.signIn(email: email, password: password)
        dashboardViewModel.syncStudyPlanFromProfile(profile, forceApplyTarget: false)
        route = route(for: hint)

        if route == .home {
            await refreshDashboard(showBusy: false)
            await syncPushRegistrationIfPossible(force: false)
        }
    }

    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        let outcome = try await authViewModel.signUp(email: email, password: password)
        switch outcome {
        case .emailVerificationRequired:
            return .emailVerificationRequired
        case .signedIn(let routeHint):
            dashboardViewModel.syncStudyPlanFromProfile(profile, forceApplyTarget: false)
            route = route(for: routeHint)
            if route == .home {
                await refreshDashboard(showBusy: false)
                await syncPushRegistrationIfPossible(force: false)
            }
            return .signedIn
        }
    }

    func resendVerificationEmail(email: String, fullName: String? = nil) async throws {
        _ = fullName
        try await authViewModel.resendVerificationEmail(email: email)
    }

    func verifyEmailOTP(email: String, code: String) async throws {
        try await authViewModel.verifyEmailOTP(email: email, code: code)
        route = .auth
        selectedMainTab = "home"
        statusMessage = "E-posta doğrulandı. Şimdi giriş yapabilirsin."
    }

    func completeOnboarding(payload: OnboardingPayload) async throws {
        try await authViewModel.completeOnboarding(payload: payload)
        dashboardViewModel.syncStudyPlanFromProfile(profile, forceApplyTarget: true)
        route = .home
        await refreshDashboard(showBusy: false)
        await syncPushRegistrationIfPossible(force: false)
    }

    func updateLanguagePreferences(preferredLanguageCode: String,
                                   countryCode: String?,
                                   source: String = "profile_edit") async throws {
        let updated = try await supabase.updateLanguagePreferences(
            preferredLanguageCode: preferredLanguageCode,
            countryCode: countryCode,
            languageSource: source
        )
        authViewModel.updateProfile(updated)
    }

    func refreshDashboard(showBusy: Bool = true) async {
        do {
            let result = try await dashboardViewModel.refreshDashboard(showBusy: showBusy, routeIsHome: route == .home)
            authViewModel.updateProfile(result.profile)
            authViewModel.updateSessionToken(result.accessToken)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() {
        authViewModel.signOut()
        resetToAuthState()
    }

    func deleteMyData() async throws {
        let result = try await dashboardViewModel.deleteMyData()
        authViewModel.updateSessionToken(result.accessToken)
        if let refreshedProfile = result.profile {
            authViewModel.updateProfile(refreshedProfile)
        } else if profile == nil {
            authViewModel.updateProfile(.empty)
        }
        statusMessage = result.statusMessage
    }

    func deleteMyAccount() async throws {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }

        _ = try await api.deleteMyAccount(accessToken: token)
        await supabase.signOut()
        statusMessage = "Hesabın ve verilerin kalıcı olarak silindi."
        resetToAuthState()
    }

    func submitContentReport(caseSession: CaseSession?,
                             category: String,
                             details: String) async throws {
        statusMessage = try await dashboardViewModel.submitContentReport(
            caseSession: caseSession,
            category: category,
            details: details
        )
    }

    func submitUserFeedback(topic: String, message: String) async throws {
        statusMessage = try await dashboardViewModel.submitUserFeedback(topic: topic, message: message)
    }

    func generateFlashcards(sessionId: String,
                            specialty: String,
                            difficulty: String,
                            caseTitle: String,
                            trueDiagnosis: String,
                            userDiagnosis: String,
                            overallScore: Double?,
                            scoreLabel: String?,
                            briefSummary: String?,
                            strengths: [String],
                            improvements: [String],
                            missedOpportunities: [String],
                            dimensions: [ScoreDimension],
                            nextPracticeSuggestions: [PracticeSuggestion],
                            maxCards: Int = 6) async throws -> FlashcardGenerateResponse {
        try await flashcardViewModel.generateFlashcards(
            sessionId: sessionId,
            specialty: specialty,
            difficulty: difficulty,
            caseTitle: caseTitle,
            trueDiagnosis: trueDiagnosis,
            userDiagnosis: userDiagnosis,
            overallScore: overallScore,
            scoreLabel: scoreLabel,
            briefSummary: briefSummary,
            strengths: strengths,
            improvements: improvements,
            missedOpportunities: missedOpportunities,
            dimensions: dimensions,
            nextPracticeSuggestions: nextPracticeSuggestions,
            uiLanguageCode: uiLanguageCode,
            maxCards: maxCards
        )
    }

    func saveFlashcards(sessionId: String?,
                        cards: [FlashcardDraft]) async throws -> [FlashcardItem] {
        try await flashcardViewModel.saveFlashcards(sessionId: sessionId, cards: cards)
    }

    func fetchFlashcardsToday(specialty: String? = nil,
                              cardType: String? = nil,
                              limit: Int = 30) async throws -> [FlashcardItem] {
        try await flashcardViewModel.fetchFlashcardsToday(
            specialty: specialty,
            cardType: cardType,
            limit: limit
        )
    }

    func fetchFlashcardCollections(specialty: String? = nil,
                                   cardType: String? = nil,
                                   limit: Int = 300) async throws -> FlashcardCollectionsResponse {
        try await flashcardViewModel.fetchFlashcardCollections(
            specialty: specialty,
            cardType: cardType,
            limit: limit
        )
    }

    func reviewFlashcard(cardId: String,
                         rating: FlashcardReviewRating) async throws -> FlashcardItem? {
        try await flashcardViewModel.reviewFlashcard(cardId: cardId, rating: rating)
    }

    func fetchCaseDetail(sessionId: String) async throws -> CaseSessionDetailResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        return try await api.fetchCaseDetail(accessToken: token, sessionId: sessionId)
    }

    func fetchWeakAreaHistory(rangeDays: Int = 30) async throws -> WeakAreaHistoryResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        return try await api.fetchWeakAreaHistory(accessToken: token, rangeDays: rangeDays)
    }

    func fetchFlashcardPerformance(rangeDays: Int = 30) async throws -> FlashcardPerformanceResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        return try await api.fetchFlashcardPerformance(accessToken: token, rangeDays: rangeDays)
    }

    func fetchSubscriptionStatus() async throws -> SubscriptionStatusResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        return try await api.fetchSubscriptionStatus(accessToken: token)
    }

    func handleDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "drkynox" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let openValue = components.queryItems?.first(where: { $0.name == "open" })?.value?.lowercased(),
           let target = HomeOpenTarget(rawValue: openValue) {
            pendingHomeOpenTarget = target
        }

        let absolute = url.absoluteString.lowercased()
        let isSignupVerifyLink =
            absolute.contains("type=signup") ||
            absolute.contains("verified=1") ||
            absolute.contains("email_confirmed") ||
            absolute.contains("verify")

        if isSignupVerifyLink {
            route = .auth
            selectedMainTab = "home"
            statusMessage = "E-posta doğrulandı. Şimdi giriş yapabilirsin."
            return
        }

        if accessToken != nil {
            route = .home
            selectedMainTab = "home"
            return
        }

        route = .auth
    }

    func updateWeeklyGoalTarget(_ target: Int) {
        Task {
            await dashboardViewModel.updateWeeklyGoalTarget(target)
        }
    }

    func configureWeeklyGoalNotifications() async {
        await notificationManager.configureWeeklyGoalNotifications(summary: weeklyGoalSummary)
    }

    func shouldShowNotificationPrimer() async -> Bool {
        await notificationManager.shouldShowNotificationPrimer()
    }

    func fetchNotificationAuthorizationState() async -> NotificationAuthorizationState {
        await notificationManager.fetchNotificationAuthorizationState()
    }

    @discardableResult
    func requestNotificationPermissionAndSchedule() async -> Bool {
        await notificationManager.requestNotificationPermissionAndSchedule(summary: weeklyGoalSummary)
    }

    func onAppDidBecomeActive() async {
        await syncPushRegistrationIfPossible(force: false)
        await refreshInAppBannerIfNeeded(force: false)
    }

    func refreshInAppBannerIfNeeded(force: Bool) async {
        await dashboardViewModel.refreshInAppBannerIfNeeded(force: force, routeIsHome: route == .home)
    }

    func dismissInAppBanner(broadcastId: String) async {
        await dashboardViewModel.dismissInAppBanner(broadcastId: broadcastId)
    }

    func sendPasswordReset(email: String) async throws {
        try await authViewModel.sendPasswordReset(email: email)
    }

    func verifyPasswordResetOTP(email: String, code: String) async throws {
        try await authViewModel.verifyPasswordResetOTP(email: email, code: code)
    }

    func completePasswordReset(newPassword: String) async throws {
        try await authViewModel.completePasswordReset(newPassword: newPassword)
        resetToAuthState()
        statusMessage = "Şifren güncellendi. Yeni şifrenle giriş yapabilirsin."
    }

    func fetchElevenLabsSessionAuth(agentId: String,
                                    mode: String,
                                    sessionWindowToken: String?,
                                    dynamicVariables: [String: String]) async throws -> ElevenLabsSessionAuthResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }

        authViewModel.updateSessionToken(token)
        return try await api.fetchElevenLabsSessionAuth(
            accessToken: token,
            agentId: agentId,
            mode: mode,
            sessionWindowToken: sessionWindowToken,
            dynamicVariables: dynamicVariables
        )
    }

    @discardableResult
    func endElevenLabsSession(agentId: String,
                              sessionWindowToken: String?) async -> Bool {
        do {
            guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
                return false
            }
            authViewModel.updateSessionToken(token)
            try await api.endElevenLabsSession(
                accessToken: token,
                agentId: agentId,
                sessionWindowToken: sessionWindowToken
            )
            return true
        } catch {
            // Oturum sonlandirma hatasi kritik degil; reconnect icin tekrar denenebilir.
            print("[session-lock] end failed agentId=\(agentId) error=\(String(reflecting: error))")
            return false
        }
    }

    func touchElevenLabsSession(agentId: String,
                                sessionWindowToken: String?) async {
        do {
            guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
                return
            }
            authViewModel.updateSessionToken(token)
            try await api.touchElevenLabsSession(
                accessToken: token,
                agentId: agentId,
                sessionWindowToken: sessionWindowToken
            )
        } catch {
            // Heartbeat hatasi kritik degil; bir sonraki turda tekrar denenir.
            print("[session-lock] touch failed agentId=\(agentId) error=\(String(reflecting: error))")
        }
    }

    func scoreConversation(mode: String,
                           transcript: [ConversationLine],
                           wrapup: String) async throws -> ScoreResponse {
        guard let token = try await authViewModel.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        authViewModel.updateSessionToken(token)
        return try await api.scoreConversation(
            accessToken: token,
            mode: mode,
            transcript: transcript,
            optionalCaseWrapup: wrapup,
            uiLanguageCode: uiLanguageCode
        )
    }

    func saveCase(payload: SaveCasePayload) async {
        do {
            try await dashboardViewModel.saveCase(payload: payload)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func bindChildChanges() {
        authViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        dashboardViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        flashcardViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        notificationManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func configureModuleCallbacks() {
        dashboardViewModel.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }

        flashcardViewModel.onAccessTokenResolved = { [weak self] token in
            self?.authViewModel.updateSessionToken(token)
        }

        notificationManager.onAccessTokenResolved = { [weak self] token in
            self?.authViewModel.updateSessionToken(token)
        }

        notificationManager.onDeepLink = { [weak self] url in
            self?.handleDeepLink(url)
        }

        notificationManager.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }

        notificationManager.userIdProvider = { [weak self] in
            self?.profile?.id
        }
    }

    private func resetToAuthState() {
        authViewModel.clearSession()
        dashboardViewModel.clearForSignedOut()
        notificationManager.resetForSignedOut()
        generatorReplayContext = nil
        pendingHomeOpenTarget = nil
        selectedMainTab = "home"
        route = .auth
    }

    private func route(for hint: AuthViewModel.RouteHint) -> Route {
        switch hint {
        case .auth:
            return .auth
        case .onboarding:
            return .onboarding
        case .home:
            return .home
        }
    }

    private func syncPushRegistrationIfPossible(force: Bool) async {
        await notificationManager.syncPushRegistrationIfPossible(force: force)
    }
}
