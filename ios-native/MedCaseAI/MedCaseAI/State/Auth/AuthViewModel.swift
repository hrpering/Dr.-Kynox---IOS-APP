import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    enum RouteHint {
        case auth
        case onboarding
        case home
    }

    enum SignUpOutcome {
        case signedIn(routeHint: RouteHint)
        case emailVerificationRequired
    }

    @Published private(set) var accessToken: String?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isBusy: Bool = false

    private let supabase: SupabaseService
    private let defaults: UserDefaults

    private static let sessionHintKey = "drkynox.session_hint"

    init(supabase: SupabaseService, defaults: UserDefaults = .standard) {
        self.supabase = supabase
        self.defaults = defaults
    }

    var hasSessionHint: Bool {
        defaults.bool(forKey: Self.sessionHintKey)
    }

    func bootstrapFromStoredSessionHint() async throws -> RouteHint {
        guard hasSessionHint else {
            return .auth
        }

        do {
            try await supabase.configure()
            let token = try await supabase.currentAccessToken()
            guard let token, !token.isEmpty else {
                clearSession()
                return .auth
            }

            accessToken = token
            setSessionHint(true)
            profile = try await supabase.fetchProfile()
            return profile?.onboardingCompleted == true ? .home : .onboarding
        } catch {
            clearSession()
            throw error
        }
    }

    func signIn(email: String, password: String) async throws -> RouteHint {
        isBusy = true
        defer { isBusy = false }

        let token = try await supabase.signIn(email: email, password: password)
        accessToken = token
        setSessionHint(true)

        profile = try await supabase.fetchProfile()
        return profile?.onboardingCompleted == true ? .home : .onboarding
    }

    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        isBusy = true
        defer { isBusy = false }

        let signUpResult = try await supabase.signUp(email: email, password: password)
        switch signUpResult {
        case .emailVerificationRequired:
            clearSession()
            return .emailVerificationRequired
        case .authenticated(let token):
            accessToken = token
            setSessionHint(true)
            profile = try await supabase.fetchProfile()
            let routeHint: RouteHint = profile?.onboardingCompleted == true ? .home : .onboarding
            return .signedIn(routeHint: routeHint)
        }
    }

    func resendVerificationEmail(email: String) async throws {
        try await supabase.resendSignupOTP(email: email)
    }

    func verifyEmailOTP(email: String, code: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let token = try await supabase.verifyEmailOTP(email: email, code: code)
        accessToken = token
        setSessionHint(true)
        _ = try? await supabase.fetchProfile()

        await supabase.signOut()
        clearSession()
    }

    func completeOnboarding(payload: OnboardingPayload) async throws {
        isBusy = true
        defer { isBusy = false }
        profile = try await supabase.submitOnboarding(payload)
    }

    func sendPasswordReset(email: String) async throws {
        isBusy = true
        defer { isBusy = false }
        try await supabase.sendPasswordReset(email: email)
    }

    func verifyPasswordResetOTP(email: String, code: String) async throws {
        isBusy = true
        defer { isBusy = false }
        try await supabase.verifyPasswordResetOTP(email: email, code: code)
    }

    func completePasswordReset(newPassword: String) async throws {
        isBusy = true
        defer { isBusy = false }
        try await supabase.updatePasswordAfterRecovery(newPassword)
        await supabase.signOut()
        clearSession()
    }

    func signOut() {
        Task {
            await supabase.signOut()
        }
        clearSession()
    }

    func clearSession() {
        setSessionHint(false)
        accessToken = nil
        profile = nil
    }

    func updateSessionToken(_ token: String?) {
        accessToken = token
        setSessionHint((token?.isEmpty == false))
    }

    func updateProfile(_ profile: UserProfile?) {
        self.profile = profile
    }

    func currentAccessToken() async throws -> String? {
        try await supabase.currentAccessToken()
    }

    func fetchProfile() async throws -> UserProfile {
        try await supabase.fetchProfile()
    }

    private func setSessionHint(_ hasSession: Bool) {
        defaults.set(hasSession, forKey: Self.sessionHintKey)
    }
}
