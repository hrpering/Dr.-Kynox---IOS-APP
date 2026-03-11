import Foundation

extension AgentConversationViewModel {
    func fetchSessionAuthWithConflictRecovery(
        agentId: String,
        dynamicVariables: [String: String],
        attempt: Int
    ) async throws -> ElevenLabsSessionAuthResponse {
        do {
            return try await fetchSessionAuth(agentId: agentId, dynamicVariables: dynamicVariables)
        } catch {
            guard isActiveSessionConflict(error) else {
                throw error
            }
            logWarning("[connect] attempt=\(attempt) session-auth ACTIVE_SESSION_EXISTS; forcing lock release")
            let released = await forceReleaseElevenSessionLock(agentId: agentId)
            guard released else {
                throw error
            }
            logInfo("[connect] attempt=\(attempt) session-auth conflict lock released; retrying auth once")
            return try await fetchSessionAuth(agentId: agentId, dynamicVariables: dynamicVariables)
        }
    }

    func isActiveSessionConflict(_ error: Error) -> Bool {
        if case let AppError.apiError(statusCode, code, message) = error {
            if statusCode == 409 && String(code ?? "").uppercased() == "ACTIVE_SESSION_EXISTS" {
                return true
            }
            let normalized = message.lowercased(with: Locale(identifier: "tr_TR"))
            if statusCode == 409 && normalized.contains("aktif bir elevenlabs oturumu var") {
                return true
            }
        }
        if case let AppError.httpError(message) = error {
            let normalized = message.lowercased(with: Locale(identifier: "tr_TR"))
            return normalized.contains("active_session_exists") ||
                normalized.contains("aktif bir elevenlabs oturumu var")
        }
        return false
    }

    @discardableResult
    func forceReleaseElevenSessionLock(agentId: String) async -> Bool {
        guard let appState else { return false }
        stopSessionHeartbeat()
        let released = await appState.endElevenLabsSession(
            agentId: agentId,
            sessionWindowToken: nil
        )
        if released {
            elevenSessionReleased = true
            sessionWindowToken = nil
            logInfo("[session-lock] force release success agentId=\(agentId)")
        } else {
            logWarning("[session-lock] force release failed agentId=\(agentId)")
        }
        return released
    }

    func shouldRetryConversationStart(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == -1011 {
            return true
        }

        let haystack = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription) \(String(reflecting: error))"
            .lowercased()
        let markers = [
            "websockethandshake",
            "websocket handshake",
            "nserrordomain code=-1011",
            "sunucudan geçersiz bir yanıt alındı",
            "invalid response from server"
        ]
        return markers.contains(where: { haystack.contains($0) })
    }
}
