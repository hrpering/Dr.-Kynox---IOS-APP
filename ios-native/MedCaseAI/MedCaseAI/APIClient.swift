import Foundation
import Sentry

enum AppError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(String)
    case sessionMissing
    case malformedPayload
    case dependencyMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Geçersiz URL."
        case .invalidResponse:
            return "Sunucu yanıtı okunamadı."
        case .httpError(let message):
            return message
        case .sessionMissing:
            return "Oturum bulunamadı."
        case .malformedPayload:
            return "Beklenen veri alınamadı."
        case .dependencyMissing(let message):
            return message
        }
    }
}

final class APIClient {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder: JSONEncoder = {
        JSONEncoder()
    }()

    private var cachedConfig: PublicConfig?
    private let defaults = UserDefaults.standard
    private let publicConfigCacheKey = "drkynox.public_config.cache.v1"

    private var backendBaseURL: String {
        if let url = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String,
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func fetchPublicConfig(forceRefresh: Bool = false) async throws -> PublicConfig {
        if !forceRefresh, let config = cachedConfig {
            return config
        }

        if !forceRefresh, let persisted = loadPersistedPublicConfig() {
            cachedConfig = persisted
            return persisted
        }

        let url = try buildURL(path: "/api/public-config")
        do {
            let response: PublicConfig = try await request(url: url, method: "GET", timeout: 8)
            cachedConfig = response
            persistPublicConfig(response)
            return response
        } catch {
            if let persisted = loadPersistedPublicConfig() {
                cachedConfig = persisted
                return persisted
            }
            throw error
        }
    }

    func fetchElevenLabsSessionAuth(accessToken: String,
                                    agentId: String,
                                    mode: String,
                                    sessionWindowToken: String?,
                                    dynamicVariables: [String: String]) async throws -> ElevenLabsSessionAuthResponse {
        let url = try buildURL(path: "/api/elevenlabs/session-auth")
        struct Payload: Encodable {
            let agentId: String
            let mode: String
            let sessionWindowToken: String?
            let dynamicVariables: [String: String]
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                agentId: agentId,
                mode: mode,
                sessionWindowToken: sessionWindowToken,
                dynamicVariables: dynamicVariables
            )
        )
    }

    func endElevenLabsSession(accessToken: String,
                              agentId: String,
                              sessionWindowToken: String?) async throws {
        let url = try buildURL(path: "/api/elevenlabs/session-end")
        struct Payload: Encodable {
            let agentId: String
            let sessionWindowToken: String?
        }

        let _: BasicResponse = try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                agentId: agentId,
                sessionWindowToken: sessionWindowToken
            ),
            timeout: 20
        )
    }

    func touchElevenLabsSession(accessToken: String,
                                agentId: String,
                                sessionWindowToken: String?) async throws {
        let url = try buildURL(path: "/api/elevenlabs/session-touch")
        struct Payload: Encodable {
            let agentId: String
            let sessionWindowToken: String
        }

        let cleanToken = (sessionWindowToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            throw AppError.httpError("Geçerli session token bulunamadı.")
        }

        let _: BasicResponse = try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                agentId: agentId,
                sessionWindowToken: cleanToken
            ),
            timeout: 15
        )
    }

    func ensureDailyChallengeGenerated() async throws {
        let url = try buildURL(path: "/api/challenge/today")
        let _: BasicResponse = try await request(url: url, method: "GET")
    }

    func fetchTodayChallenge() async throws -> DailyChallengeBundle {
        let url = try buildURL(path: "/api/challenge/today")

        struct ResponsePayload: Decodable {
            let challenge: DailyChallenge
            let timeLeft: ChallengeTimeLeft?
            let stats: ChallengeStats?

            enum CodingKeys: String, CodingKey {
                case challenge
                case timeLeft = "time_left"
                case stats
            }
        }

        let response: ResponsePayload = try await request(url: url, method: "GET")
        return DailyChallengeBundle(
            challenge: response.challenge,
            timeLeft: response.timeLeft ?? ChallengeTimeLeft(expiresAt: nil, minutesLeft: nil, hoursLeft: nil),
            stats: response.stats
        )
    }

    func scoreConversation(accessToken: String,
                           mode: String,
                           transcript: [ConversationLine],
                           optionalCaseWrapup: String) async throws -> ScoreResponse {
        let url = try buildURL(path: "/api/score")
        let payload = ScoreRequestPayload(
            conversation: transcript,
            rubricPrompt: ScoreRequestPayload.defaultRubric,
            mode: mode,
            optionalCaseWrapup: optionalCaseWrapup
        )
        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: payload,
            timeout: 40
        )
    }

    func saveCase(accessToken: String, payload: SaveCasePayload) async throws {
        let url = try buildURL(path: "/api/cases/save")
        let _: BasicResponse = try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: payload,
            timeout: 45
        )
    }

    func deleteMyData(accessToken: String) async throws -> DeleteDataResponse {
        let url = try buildURL(path: "/api/profile/delete-data")
        struct Payload: Encodable {
            let confirmation: String
        }
        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(confirmation: "DELETE_DATA"),
            timeout: 45
        )
    }

    func deleteMyAccount(accessToken: String) async throws -> DeleteAccountResponse {
        let url = try buildURL(path: "/api/profile/delete-account")
        struct Payload: Encodable {
            let confirmation: String
        }
        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(confirmation: "DELETE_ACCOUNT"),
            timeout: 45
        )
    }

    func submitContentReport(accessToken: String,
                             caseSessionId: String?,
                             caseTitle: String?,
                             mode: String?,
                             difficulty: String?,
                             specialty: String?,
                             category: String,
                             details: String) async throws -> BasicResponse {
        let url = try buildURL(path: "/api/reports/create")
        struct Payload: Encodable {
            let caseSessionId: String?
            let caseTitle: String?
            let mode: String?
            let difficulty: String?
            let specialty: String?
            let category: String
            let details: String
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                caseSessionId: caseSessionId,
                caseTitle: caseTitle,
                mode: mode,
                difficulty: difficulty,
                specialty: specialty,
                category: category,
                details: details
            ),
            timeout: 45
        )
    }

    func submitUserFeedback(accessToken: String,
                            topic: String,
                            message: String) async throws -> BasicResponse {
        let url = try buildURL(path: "/api/feedback/create")
        struct Payload: Encodable {
            let topic: String
            let message: String
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(topic: topic, message: message),
            timeout: 45
        )
    }

    func generateFlashcards(accessToken: String,
                            sessionId: String,
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
        let url = try buildURL(path: "/api/flashcards/generate")
        struct Payload: Encodable {
            let sessionId: String
            let specialty: String
            let difficulty: String
            let caseTitle: String
            let trueDiagnosis: String
            let userDiagnosis: String
            let overallScore: Double?
            let scoreLabel: String?
            let briefSummary: String?
            let strengths: [String]
            let improvements: [String]
            let missedOpportunities: [String]
            let dimensions: [ScoreDimension]
            let nextPracticeSuggestions: [PracticeSuggestion]
            let maxCards: Int
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
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
                maxCards: max(3, min(10, maxCards))
            ),
            timeout: 40
        )
    }

    func saveFlashcards(accessToken: String,
                        sessionId: String?,
                        cards: [FlashcardDraft]) async throws -> FlashcardSaveResponse {
        let url = try buildURL(path: "/api/flashcards/save")
        struct Payload: Encodable {
            let sessionId: String?
            let cards: [FlashcardDraft]
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(sessionId: sessionId, cards: cards),
            timeout: 30
        )
    }

    func fetchFlashcardsToday(accessToken: String,
                              specialty: String?,
                              cardType: String?,
                              limit: Int = 30) async throws -> FlashcardTodayResponse {
        var components = URLComponents(url: try buildURL(path: "/api/flashcards/today"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            .init(name: "limit", value: String(max(1, min(120, limit))))
        ]
        if let specialty, !specialty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(.init(name: "specialty", value: specialty))
        }
        if let cardType, !cardType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(.init(name: "cardType", value: cardType))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw AppError.invalidURL
        }

        return try await request(
            url: url,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(accessToken)"
            ],
            timeout: 30
        )
    }

    func fetchFlashcardCollections(accessToken: String,
                                   specialty: String?,
                                   cardType: String?,
                                   limit: Int = 300) async throws -> FlashcardCollectionsResponse {
        var components = URLComponents(url: try buildURL(path: "/api/flashcards/collections"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            .init(name: "limit", value: String(max(1, min(500, limit))))
        ]
        if let specialty, !specialty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(.init(name: "specialty", value: specialty))
        }
        if let cardType, !cardType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(.init(name: "cardType", value: cardType))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw AppError.invalidURL
        }

        return try await request(
            url: url,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(accessToken)"
            ],
            timeout: 30
        )
    }

    func reviewFlashcard(accessToken: String,
                         cardId: String,
                         rating: FlashcardReviewRating) async throws -> FlashcardReviewResponse {
        let url = try buildURL(path: "/api/flashcards/review")
        struct Payload: Encodable {
            let cardId: String
            let rating: String
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(cardId: cardId, rating: rating.rawValue),
            timeout: 25
        )
    }

    func fetchWeakAreaAnalysis(accessToken: String) async throws -> WeakAreaAnalysisResponse {
        let url = try buildURL(path: "/api/analytics/weak-areas")
        return try await request(
            url: url,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(accessToken)"
            ],
            timeout: 30
        )
    }

    func resendVerificationEmail(email: String, fullName: String?) async throws -> BasicResponse {
        let url = try buildURL(path: "/api/auth/resend-verification")
        struct Payload: Encodable {
            let email: String
            let fullName: String?
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json"
            ],
            body: Payload(
                email: email,
                fullName: fullName
            ),
            timeout: 20
        )
    }

    func registerPushDevice(accessToken: String,
                            deviceToken: String,
                            notificationsEnabled: Bool,
                            apnsEnvironment: String,
                            deviceModel: String?,
                            appVersion: String?,
                            locale: String?,
                            timezone: String?) async throws -> PushDeviceRegisterResponse {
        let url = try buildURL(path: "/api/push/register-device")
        struct Payload: Encodable {
            let deviceToken: String
            let notificationsEnabled: Bool
            let apnsEnvironment: String
            let deviceModel: String?
            let appVersion: String?
            let locale: String?
            let timezone: String?
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                deviceToken: deviceToken,
                notificationsEnabled: notificationsEnabled,
                apnsEnvironment: apnsEnvironment,
                deviceModel: deviceModel,
                appVersion: appVersion,
                locale: locale,
                timezone: timezone
            ),
            timeout: 20
        )
    }

    func fetchInAppBanner(accessToken: String) async throws -> InAppBannerResponse {
        let url = try buildURL(path: "/api/in-app/banner")
        return try await request(
            url: url,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(accessToken)"
            ],
            timeout: 20
        )
    }

    func acknowledgeInAppBanner(accessToken: String, broadcastId: String, action: String) async throws -> BasicResponse {
        let url = try buildURL(path: "/api/in-app/banner/ack")
        struct Payload: Encodable {
            let broadcastId: String
            let action: String
        }

        return try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json"
            ],
            body: Payload(
                broadcastId: broadcastId,
                action: action
            ),
            timeout: 20
        )
    }

    private func buildURL(path: String) throws -> URL {
        guard !backendBaseURL.isEmpty else {
            throw AppError.dependencyMissing("BACKEND_BASE_URL ayarı eksik.")
        }
        guard let url = URL(string: "\(backendBaseURL)\(path)") else {
            throw AppError.invalidURL
        }
        return url
    }

    private func request<T: Decodable>(url: URL,
                                       method: String,
                                       headers: [String: String] = [:],
                                       body: Encodable? = nil,
                                       timeout: TimeInterval = 45) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        var mergedHeaders = headers
        if body != nil {
            let hasContentType = mergedHeaders.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
            if !hasContentType {
                mergedHeaders["Content-Type"] = "application/json"
            }
        }
        mergedHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        if let body {
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }

        addNetworkBreadcrumb(stage: "request", method: method, url: url)

        let data: Data
        let response: URLResponse
        do {
            let result = try await URLSession.shared.data(for: req)
            data = result.0
            response = result.1
        } catch {
            addNetworkBreadcrumb(stage: "transport_error",
                                 method: method,
                                 url: url,
                                 errorMessage: error.localizedDescription)
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            addNetworkBreadcrumb(stage: "invalid_response", method: method, url: url)
            throw AppError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let apiError = try? decoder.decode(ErrorResponse.self, from: data)
            let message = apiError?.error ?? "Sunucu hatası: \(http.statusCode)"
            addNetworkBreadcrumb(stage: "http_error",
                                 method: method,
                                 url: url,
                                 statusCode: http.statusCode,
                                 errorMessage: message)
            throw AppError.httpError(message)
        }

        addNetworkBreadcrumb(stage: "response", method: method, url: url, statusCode: http.statusCode)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if T.self == BasicResponse.self {
                return BasicResponse(ok: true) as! T
            }
            addNetworkBreadcrumb(stage: "decode_error",
                                 method: method,
                                 url: url,
                                 statusCode: http.statusCode,
                                 errorMessage: error.localizedDescription)
            throw AppError.malformedPayload
        }
    }

    private func addNetworkBreadcrumb(stage: String,
                                      method: String,
                                      url: URL,
                                      statusCode: Int? = nil,
                                      errorMessage: String? = nil) {
        let crumb = Breadcrumb()
        crumb.category = "http.client"
        crumb.type = "http"
        crumb.level = errorMessage == nil ? .info : .warning
        crumb.message = "\(method.uppercased()) \(url.path)"
        var data: [String: Any] = [
            "stage": stage,
            "method": method.uppercased(),
            "path": url.path
        ]
        if let statusCode {
            data["status_code"] = statusCode
        }
        if let errorMessage, !errorMessage.isEmpty {
            data["error"] = String(errorMessage.prefix(200))
        }
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }
}

private extension APIClient {
    struct PersistedPublicConfig: Codable {
        let supabaseUrl: String
        let supabaseAnonKey: String
        let authorizationUrl: String?
    }

    func persistPublicConfig(_ config: PublicConfig) {
        let payload = PersistedPublicConfig(
            supabaseUrl: config.supabaseUrl,
            supabaseAnonKey: config.supabaseAnonKey,
            authorizationUrl: config.authorizationUrl
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: publicConfigCacheKey)
    }

    func loadPersistedPublicConfig() -> PublicConfig? {
        guard let data = defaults.data(forKey: publicConfigCacheKey) else { return nil }
        guard let payload = try? JSONDecoder().decode(PersistedPublicConfig.self, from: data) else {
            return nil
        }
        let url = payload.supabaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let anon = payload.supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !anon.isEmpty else { return nil }
        return PublicConfig(
            supabaseUrl: url,
            supabaseAnonKey: anon,
            authorizationUrl: payload.authorizationUrl
        )
    }
}

private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ encodable: Encodable) {
        self.encodeFunc = encodable.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
