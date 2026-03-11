import Foundation

#if canImport(ElevenLabs)
import ElevenLabs
#endif

extension AgentConversationViewModel {
#if canImport(ElevenLabs)
    func startConversation(
        auth: ElevenLabsSessionAuthResponse,
        config runtimeConfig: ConversationConfig
    ) async throws -> Conversation {
        sessionWindowToken = auth.sessionWindowToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        elevenSessionReleased = false
        if let token = auth.conversationToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return try await ElevenLabs.startConversation(conversationToken: token, config: runtimeConfig)
        }

        if let signedUrl = auth.signedUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !signedUrl.isEmpty {
            throw AppError.httpError(
                "Backend signedUrl döndürdü ancak iOS SDK bu akışta conversationToken bekliyor."
            )
        }

        throw AppError.httpError("ElevenLabs oturum tokenı alınamadı.")
    }
#endif
}
