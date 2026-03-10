import Foundation

@MainActor
final class FlashcardViewModel: ObservableObject {
    var onAccessTokenResolved: ((String?) -> Void)?

    private let api: APIClient
    private let supabase: SupabaseService

    init(api: APIClient, supabase: SupabaseService) {
        self.api = api
        self.supabase = supabase
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
        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        onAccessTokenResolved?(token)
        return try await api.generateFlashcards(
            accessToken: token,
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
            maxCards: maxCards
        )
    }

    func saveFlashcards(sessionId: String?,
                        cards: [FlashcardDraft]) async throws -> [FlashcardItem] {
        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        onAccessTokenResolved?(token)
        let response = try await api.saveFlashcards(
            accessToken: token,
            sessionId: sessionId,
            cards: cards
        )
        return response.cards ?? []
    }

    func fetchFlashcardsToday(specialty: String? = nil,
                              cardType: String? = nil,
                              limit: Int = 30) async throws -> [FlashcardItem] {
        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        onAccessTokenResolved?(token)
        let response = try await api.fetchFlashcardsToday(
            accessToken: token,
            specialty: specialty,
            cardType: cardType,
            limit: limit
        )
        return response.cards
    }

    func fetchFlashcardCollections(specialty: String? = nil,
                                   cardType: String? = nil,
                                   limit: Int = 300) async throws -> FlashcardCollectionsResponse {
        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        onAccessTokenResolved?(token)
        return try await api.fetchFlashcardCollections(
            accessToken: token,
            specialty: specialty,
            cardType: cardType,
            limit: limit
        )
    }

    func reviewFlashcard(cardId: String,
                         rating: FlashcardReviewRating) async throws -> FlashcardItem? {
        guard let token = try await supabase.currentAccessToken(), !token.isEmpty else {
            throw AppError.sessionMissing
        }
        onAccessTokenResolved?(token)
        let response = try await api.reviewFlashcard(
            accessToken: token,
            cardId: cardId,
            rating: rating
        )
        return response.card
    }
}
