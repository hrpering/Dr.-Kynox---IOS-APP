import Foundation

#if canImport(Supabase)
import Supabase
#endif

final class SupabaseService {
    private let apiClient: APIClient

    enum SignUpResult {
        case authenticated(token: String)
        case emailVerificationRequired
    }

    #if canImport(Supabase)
    private var client: SupabaseClient?
    #endif

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func configure(forceRefresh: Bool = false) async throws {
        _ = try await buildClient(forceRefresh: forceRefresh)
    }

    func currentAccessToken() async throws -> String? {
        #if canImport(Supabase)
        let client = try await buildClient()
        do {
            let session = try await client.auth.session
            return session.accessToken
        } catch {
            return nil
        }
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func signIn(email: String, password: String) async throws -> String {
        #if canImport(Supabase)
        let client = try await buildClient()
        let session = try await client.auth.signIn(email: email, password: password)
        return session.accessToken
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func signUp(email: String, password: String) async throws -> SignUpResult {
        #if canImport(Supabase)
        let client = try await buildClient()
        // Eski/local cache session'in yeni kayıt akışını kirletmesini önle.
        try? await client.auth.signOut()
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            data: nil
        )

        if let token = response.session?.accessToken, !token.isEmpty {
            return .authenticated(token: token)
        }

        return .emailVerificationRequired
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func verifyEmailOTP(email: String, code: String) async throws -> String {
        #if canImport(Supabase)
        let client = try await buildClient()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanEmail.isEmpty, !cleanCode.isEmpty else {
            throw AppError.httpError("E-posta ve doğrulama kodu zorunludur.")
        }

        let verifyTypes: [EmailOTPType] = [.signup, .email]
        var lastError: Error?
        for verifyType in verifyTypes {
            do {
                let response = try await client.auth.verifyOTP(
                    email: cleanEmail,
                    token: cleanCode,
                    type: verifyType
                )
                if let token = response.session?.accessToken, !token.isEmpty {
                    return token
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AppError.httpError("Doğrulama kodu geçersiz veya süresi dolmuş.")
        #else
        _ = email
        _ = code
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func resendSignupOTP(email: String) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty else {
            throw AppError.httpError("Geçerli bir e-posta adresi gir.")
        }
        try await client.auth.resend(email: cleanEmail, type: .signup)
        #else
        _ = email
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func signOut() async {
        #if canImport(Supabase)
        do {
            let client = try await buildClient()
            try await client.auth.signOut()
        } catch {
            // Sessizce devam et.
        }
        #endif
    }

    func sendPasswordReset(email: String) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        // OTP tabanli sifre sifirlama akisi icin redirect yerine dogrudan recovery kodu gonder.
        try await client.auth.resetPasswordForEmail(email)
        #else
        _ = email
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func verifyPasswordResetOTP(email: String, code: String) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanEmail.isEmpty, !cleanCode.isEmpty else {
            throw AppError.httpError("E-posta ve doğrulama kodu zorunludur.")
        }

        _ = try await client.auth.verifyOTP(
            email: cleanEmail,
            token: cleanCode,
            type: .recovery
        )
        #else
        _ = email
        _ = code
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func updatePasswordAfterRecovery(_ newPassword: String) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        let cleanPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPassword.count >= 8 else {
            throw AppError.httpError("Yeni şifre en az 8 karakter olmalı.")
        }
        _ = try await client.auth.update(user: UserAttributes(password: cleanPassword))
        #else
        _ = newPassword
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func upsertProfile(fullName: String, phoneNumber: String?, marketingOptIn: Bool) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        let context = try await currentAuthContext(client)
        let row = ProfileUpsertRow(
            id: context.userId,
            email: context.email,
            fullName: fullName.isEmpty ? nil : fullName,
            phoneNumber: phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? phoneNumber : nil,
            marketingOptIn: marketingOptIn,
            onboardingCompleted: false,
            ageRange: nil,
            role: nil,
            goals: nil,
            interestAreas: nil,
            learningLevel: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        _ = try await client
            .from("profiles")
            .upsert(row, onConflict: "id")
            .execute()
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func fetchProfile() async throws -> UserProfile {
        #if canImport(Supabase)
        let client = try await buildClient()
        let context = try await currentAuthContext(client)

        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select()
            .eq("id", value: context.userId)
            .limit(1)
            .execute()
            .value

        if let row = rows.first {
            return row.normalized()
        }

        let seedRow = ProfileUpsertRow(
            id: context.userId,
            email: context.email,
            fullName: nil,
            phoneNumber: nil,
            marketingOptIn: false,
            onboardingCompleted: false,
            ageRange: nil,
            role: nil,
            goals: [],
            interestAreas: [],
            learningLevel: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        _ = try await client
            .from("profiles")
            .upsert(seedRow, onConflict: "id")
            .execute()

        let updatedRows: [ProfileRow] = try await client
            .from("profiles")
            .select()
            .eq("id", value: context.userId)
            .limit(1)
            .execute()
            .value

        if let updated = updatedRows.first {
            return updated.normalized()
        }

        return .empty
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func submitOnboarding(_ payload: OnboardingPayload) async throws -> UserProfile {
        #if canImport(Supabase)
        let client = try await buildClient()
        let context = try await currentAuthContext(client)

        let row = ProfileUpsertRow(
            id: context.userId,
            email: context.email,
            fullName: payload.fullName,
            phoneNumber: payload.phoneNumber,
            marketingOptIn: payload.marketingOptIn,
            onboardingCompleted: payload.onboardingCompleted,
            ageRange: payload.ageRange,
            role: payload.role,
            goals: payload.goals,
            interestAreas: payload.interestAreas,
            learningLevel: payload.learningLevel,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        _ = try await client
            .from("profiles")
            .upsert(row, onConflict: "id")
            .execute()

        return try await fetchProfile()
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func fetchTodayChallenge() async throws -> DailyChallengeBundle {
        #if canImport(Supabase)
        do {
            let client = try await buildClient()
            let now = Date()
            let nowIso = ISO8601DateFormatter().string(from: now)
            let todayDateKey = utcDateKey(now)

            var rows = try await fetchDailyChallengeRows(client: client)
            let hasActive = rows.contains(where: {
                guard let expiresAt = parseISODate($0.expiresAt) else { return false }
                return expiresAt > now
            })

            // Tablo tarafi bos/expired ise LLM uretimini backendde tetikle, sonra tekrar tablodan oku.
            if !hasActive {
                _ = try? await apiClient.ensureDailyChallengeGenerated()
                rows = (try? await fetchDailyChallengeRows(client: client)) ?? rows
            }

            guard let picked = pickDailyChallengeRow(rows: rows, now: now, todayDateKey: todayDateKey) else {
                return try await apiClient.fetchTodayChallenge()
            }

            let challenge = normalizeDailyChallenge(row: picked, nowIso: nowIso, fallbackDateKey: todayDateKey)
            let timeLeft = computeChallengeTimeLeft(expiresAt: challenge.expiresAt, now: now)
            let stats = try? await fetchChallengeStats(challengeId: challenge.id, client: client)

            return DailyChallengeBundle(
                challenge: challenge,
                timeLeft: timeLeft,
                stats: stats
            )
        } catch {
            return try await apiClient.fetchTodayChallenge()
        }
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func fetchCaseList(limit: Int = 50) async throws -> [CaseSession] {
        #if canImport(Supabase)
        let client = try await buildClient()
        let context = try await currentAuthContext(client)

        let rows: [CaseSessionRow] = try await client
            .from("case_sessions")
            .select("id,session_id,mode,status,started_at,ended_at,duration_min,message_count,difficulty,case_context,transcript,score,updated_at")
            .eq("user_id", value: context.userId)
            .order("updated_at", ascending: false)
            .limit(max(1, min(limit, 200)))
            .execute()
            .value

        return rows.map { $0.toDomain() }
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    func saveCase(_ payload: SaveCasePayload) async throws {
        #if canImport(Supabase)
        let client = try await buildClient()
        let context = try await currentAuthContext(client)

        let row = CaseSessionUpsertRow(
            userId: context.userId,
            sessionId: payload.sessionId,
            mode: payload.mode,
            status: payload.status,
            startedAt: payload.startedAt,
            endedAt: payload.endedAt,
            durationMin: payload.durationMin,
            messageCount: payload.messageCount,
            difficulty: payload.difficulty,
            caseContext: payload.caseContext,
            transcript: payload.transcript,
            score: payload.score,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        let existingRows: [CaseSessionLookupRow] = try await client
            .from("case_sessions")
            .select("id")
            .eq("user_id", value: context.userId)
            .eq("session_id", value: payload.sessionId)
            .limit(1)
            .execute()
            .value

        if existingRows.isEmpty {
            _ = try await client
                .from("case_sessions")
                .insert(row)
                .execute()
        } else {
            _ = try await client
                .from("case_sessions")
                .update(row)
                .eq("user_id", value: context.userId)
                .eq("session_id", value: payload.sessionId)
                .execute()
        }
        #else
        throw AppError.dependencyMissing("Supabase Swift SDK bulunamadı. Xcode'da supabase-swift paketi eklenmeli.")
        #endif
    }

    #if canImport(Supabase)
    private func buildClient(forceRefresh: Bool = false) async throws -> SupabaseClient {
        if !forceRefresh, let client {
            return client
        }

        let config = try await apiClient.fetchPublicConfig(forceRefresh: forceRefresh)
        guard let url = URL(string: config.supabaseUrl) else {
            throw AppError.invalidURL
        }

        let options = SupabaseClientOptions(
            auth: .init(
                emitLocalSessionAsInitialSession: true
            )
        )
        let created = SupabaseClient(
            supabaseURL: url,
            supabaseKey: config.supabaseAnonKey,
            options: options
        )
        self.client = created
        return created
    }

    private func fetchDailyChallengeRows(client: SupabaseClient) async throws -> [DailyChallengeRow] {
        try await client
            .from("daily_challenges")
            .select("date_key,payload,expires_at,created_at,updated_at")
            .order("expires_at", ascending: false)
            .limit(30)
            .execute()
            .value
    }

    private func currentAuthContext(_ client: SupabaseClient) async throws -> AuthContext {
        let session = try await client.auth.session
        let userId = session.user.id.uuidString
        let email = session.user.email
        return AuthContext(userId: userId, email: email)
    }

    private func pickDailyChallengeRow(rows: [DailyChallengeRow],
                                       now: Date,
                                       todayDateKey: String) -> DailyChallengeRow? {
        let activeRows = rows.filter { row in
            guard let expiresAt = parseISODate(row.payload?.expiresAt ?? row.expiresAt ?? ""),
                  let startAt = parseISODate(row.payload?.generatedAt ?? row.createdAt ?? ""),
                  expiresAt > now else {
                return false
            }
            return startAt <= now
        }

        if let active = activeRows.sorted(by: {
            let lhs = parseISODate($0.payload?.generatedAt ?? $0.createdAt ?? "")?.timeIntervalSince1970 ?? 0
            let rhs = parseISODate($1.payload?.generatedAt ?? $1.createdAt ?? "")?.timeIntervalSince1970 ?? 0
            return lhs > rhs
        }).first {
            return active
        }

        let upcomingRows = rows.filter { row in
            guard let startAt = parseISODate(row.payload?.generatedAt ?? row.createdAt ?? "") else {
                return false
            }
            return startAt > now
        }
        if let upcoming = upcomingRows.sorted(by: {
            let lhs = parseISODate($0.payload?.generatedAt ?? $0.createdAt ?? "")?.timeIntervalSince1970 ?? .infinity
            let rhs = parseISODate($1.payload?.generatedAt ?? $1.createdAt ?? "")?.timeIntervalSince1970 ?? .infinity
            return lhs < rhs
        }).first {
            return upcoming
        }

        let fallback = rows
            .filter { row in
                let dayToken = row.challengeDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !dayToken.isEmpty && dayToken <= todayDateKey
            }
            .sorted { ($0.challengeDate ?? "") > ($1.challengeDate ?? "") }
            .first
        if let fallback {
            return fallback
        }

        return rows.sorted {
            ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }.first
    }

    private func normalizeDailyChallenge(row: DailyChallengeRow,
                                         nowIso: String,
                                         fallbackDateKey: String) -> DailyChallenge {
        let payload = row.payload ?? DailyChallengePayload.empty
        let dateKey = nonEmpty(row.challengeDate) ?? fallbackDateKey
        let challengeId = nonEmpty(payload.id) ?? "daily-\(dateKey)"
        let title = nonEmpty(payload.title) ?? "Bugünün Vaka Meydan Okuması"
        let summary = nonEmpty(payload.summary) ?? "Klinik vaka akışını adım adım yönet."
        let specialty = nonEmpty(payload.specialty) ?? "Acil Tıp"
        let difficulty = nonEmpty(payload.difficulty) ?? "Orta"

        return DailyChallenge(
            id: challengeId,
            type: nonEmpty(payload.type) ?? "daily",
            title: title,
            summary: summary,
            specialty: specialty,
            difficulty: difficulty,
            chiefComplaint: nonEmpty(payload.chiefComplaint),
            patientGender: nonEmpty(payload.patientGender),
            patientAge: payload.patientAge,
            expectedDiagnosis: nonEmpty(payload.expectedDiagnosis),
            durationMin: payload.durationMin,
            bonusPoints: payload.bonusPoints,
            generatedAt: nonEmpty(payload.generatedAt) ?? nonEmpty(row.createdAt) ?? nowIso,
            expiresAt: nonEmpty(payload.expiresAt) ?? nonEmpty(row.expiresAt)
        )
    }

    private func computeChallengeTimeLeft(expiresAt: String?, now: Date) -> ChallengeTimeLeft {
        guard let expiresAt,
              let expiresDate = parseISODate(expiresAt) else {
            return ChallengeTimeLeft(expiresAt: nil, minutesLeft: nil, hoursLeft: nil)
        }

        let diff = max(0, expiresDate.timeIntervalSince(now))
        let minutes = Int(ceil(diff / 60.0))
        let hours = Double(round((diff / 3600.0) * 100) / 100)

        return ChallengeTimeLeft(
            expiresAt: ISO8601DateFormatter().string(from: expiresDate),
            minutesLeft: minutes,
            hoursLeft: hours
        )
    }

    private func fetchChallengeStats(challengeId: String, client: SupabaseClient) async throws -> ChallengeStats {
        let rows: [CaseSessionStatsRow] = try await client
            .from("case_sessions")
            .select("user_id,score,updated_at,case_context")
            .order("updated_at", ascending: false)
            .limit(2000)
            .execute()
            .value

        let filtered = rows.filter {
            let rowChallengeId = $0.caseContext?.challengeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return rowChallengeId == challengeId
        }

        if filtered.isEmpty {
            return ChallengeStats(attemptedUsers: 0, participantCount: 0, averageScore: nil)
        }

        let sorted = filtered.sorted {
            let lhs = parseISODate($0.updatedAt)?.timeIntervalSince1970 ?? 0
            let rhs = parseISODate($1.updatedAt)?.timeIntervalSince1970 ?? 0
            return lhs > rhs
        }

        var latestByUser: [String: CaseSessionStatsRow] = [:]
        for row in sorted {
            guard let userId = nonEmpty(row.userId), latestByUser[userId] == nil else {
                continue
            }
            latestByUser[userId] = row
        }

        var scoreSum = 0.0
        var scoreCount = 0
        for row in latestByUser.values {
            if let score = row.score?.overallScore, score.isFinite {
                scoreCount += 1
                scoreSum += score
            }
        }

        let avg = scoreCount > 0 ? Double(round((scoreSum / Double(scoreCount)) * 10) / 10) : nil
        return ChallengeStats(
            attemptedUsers: latestByUser.count,
            participantCount: scoreCount,
            averageScore: avg
        )
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = iso.date(from: value) {
            return parsed
        }

        let fallbackIso = ISO8601DateFormatter()
        if let parsed = fallbackIso.date(from: value) {
            return parsed
        }

        let postgres = DateFormatter()
        postgres.locale = Locale(identifier: "en_US_POSIX")
        postgres.timeZone = TimeZone(secondsFromGMT: 0)
        postgres.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        return postgres.date(from: value)
    }

    private func utcDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func passwordResetRedirectURL() -> URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let base = URL(string: trimmed) {
                return base
                    .appendingPathComponent("auth")
                    .appendingPathComponent("reset-password")
            }
        }
        return URL(string: "https://www.medcase.website/auth/reset-password")
    }
    #endif
}

private struct AuthContext {
    let userId: String
    let email: String?
}

private struct ProfileUpsertRow: Encodable {
    let id: String
    let email: String?
    let fullName: String?
    let phoneNumber: String?
    let marketingOptIn: Bool?
    let onboardingCompleted: Bool?
    let ageRange: String?
    let role: String?
    let goals: [String]?
    let interestAreas: [String]?
    let learningLevel: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case phoneNumber = "phone_number"
        case marketingOptIn = "marketing_opt_in"
        case onboardingCompleted = "onboarding_completed"
        case ageRange = "age_range"
        case role
        case goals
        case interestAreas = "interest_areas"
        case learningLevel = "learning_level"
        case updatedAt = "updated_at"
    }
}

private struct CaseSessionUpsertRow: Encodable {
    let userId: String
    let sessionId: String
    let mode: String
    let status: String
    let startedAt: String
    let endedAt: String?
    let durationMin: Int
    let messageCount: Int
    let difficulty: String
    let caseContext: SaveCasePayload.CaseContext
    let transcript: [ConversationLine]
    let score: ScoreResponse?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
        case mode
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMin = "duration_min"
        case messageCount = "message_count"
        case difficulty
        case caseContext = "case_context"
        case transcript
        case score
        case updatedAt = "updated_at"
    }
}

private struct CaseSessionLookupRow: Decodable {
    let id: String?
}

private struct DailyChallengeRow: Decodable {
    let challengeDate: String?
    let payload: DailyChallengePayload?
    let expiresAt: String?
    let createdAt: String?
    let updatedAt: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyJSONKey.self)
        let dayField = "date_" + "k" + "ey"
        challengeDate = try container.decodeIfPresent(String.self, forKey: AnyJSONKey(dayField))
        payload = try container.decodeIfPresent(DailyChallengePayload.self, forKey: AnyJSONKey("payload"))
        expiresAt = try container.decodeIfPresent(String.self, forKey: AnyJSONKey("expires_at"))
        createdAt = try container.decodeIfPresent(String.self, forKey: AnyJSONKey("created_at"))
        updatedAt = try container.decodeIfPresent(String.self, forKey: AnyJSONKey("updated_at"))
    }
}

private struct AnyJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ value: String) {
        stringValue = value
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct DailyChallengePayload: Decodable {
    let id: String?
    let type: String?
    let title: String?
    let summary: String?
    let specialty: String?
    let difficulty: String?
    let chiefComplaint: String?
    let patientGender: String?
    let patientAge: Int?
    let expectedDiagnosis: String?
    let durationMin: Int?
    let bonusPoints: Int?
    let generatedAt: String?
    let expiresAt: String?

    static let empty = DailyChallengePayload(
        id: nil,
        type: nil,
        title: nil,
        summary: nil,
        specialty: nil,
        difficulty: nil,
        chiefComplaint: nil,
        patientGender: nil,
        patientAge: nil,
        expectedDiagnosis: nil,
        durationMin: nil,
        bonusPoints: nil,
        generatedAt: nil,
        expiresAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case summary
        case specialty
        case difficulty
        case chiefComplaint = "chief_complaint"
        case patientGender = "patient_gender"
        case patientAge = "patient_age"
        case expectedDiagnosis = "expected_diagnosis"
        case durationMin = "duration_min"
        case bonusPoints = "bonus_points"
        case generatedAt = "generated_at"
        case expiresAt = "expires_at"
    }
}

private struct CaseSessionStatsRow: Decodable {
    struct CaseContext: Decodable {
        let challengeId: String?

        enum CodingKeys: String, CodingKey {
            case challengeId = "challenge_id"
        }
    }

    struct ScoreLite: Decodable {
        let overallScore: Double?

        enum CodingKeys: String, CodingKey {
            case overallScore = "overall_score"
        }
    }

    let userId: String?
    let score: ScoreLite?
    let updatedAt: String?
    let caseContext: CaseContext?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case score
        case updatedAt = "updated_at"
        case caseContext = "case_context"
    }
}
