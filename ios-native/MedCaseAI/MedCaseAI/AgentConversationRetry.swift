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

    func logConversationHandshakeFailure(
        error: Error,
        auth: ElevenLabsSessionAuthResponse,
        attempt: Int,
        stage: String
    ) {
        let nsError = error as NSError
        let traceId = String(auth.traceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let httpStatusText = extractHTTPStatusCode(from: nsError).map(String.init) ?? "unknown"
        let bodySnippet = extractHTTPBodySnippet(from: nsError) ?? "-"
        let trimmedBodySnippet = String(bodySnippet.prefix(240))
        let failingURL = extractFailingURL(from: nsError) ?? "-"
        let trimmedFailingURL = String(failingURL.prefix(220))
        let conversationExp = describeJWTExpiry(auth.conversationToken)
        let sessionWindowExp = describeJWTExpiry(auth.sessionWindowToken)

        logWarning(
            "[connect] attempt=\(attempt) handshake_failed stage=\(stage) traceId=\(traceId.isEmpty ? "-" : traceId) domain=\(nsError.domain) code=\(nsError.code) httpStatus=\(httpStatusText) failUrl=\(trimmedFailingURL) responseBody=\(trimmedBodySnippet) convTokenExp=\(conversationExp) sessionWindowExp=\(sessionWindowExp) err=\(String(reflecting: error))"
        )
    }

    func extractHTTPStatusCode(from error: NSError) -> Int? {
        let responseKeys = [
            "NSURLErrorFailingURLResponseErrorKey",
            "NSErrorFailingURLResponseErrorKey",
            "NSErrorFailingURLResponseKey"
        ]
        for key in responseKeys {
            if let response = error.userInfo[key] as? HTTPURLResponse {
                return response.statusCode
            }
        }
        return nil
    }

    func extractHTTPBodySnippet(from error: NSError) -> String? {
        let dataKeys = [
            "NSErrorFailingURLResponseDataErrorKey",
            "NSURLErrorFailingURLResponseDataErrorKey",
            "_NSURLErrorFailingURLResponseDataErrorKey"
        ]
        for key in dataKeys {
            if let data = error.userInfo[key] as? Data, !data.isEmpty {
                if let utf8 = String(data: data, encoding: .utf8),
                   !utf8.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return utf8
                }
                return data.base64EncodedString()
            }
            if let text = error.userInfo[key] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    func extractFailingURL(from error: NSError) -> String? {
        if let url = error.userInfo["NSErrorFailingURLKey"] as? URL {
            return url.absoluteString
        }
        let urlKeys = [
            "NSErrorFailingURLStringKey",
            "NSURLErrorFailingURLStringErrorKey"
        ]
        for key in urlKeys {
            if let value = error.userInfo[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    func describeJWTExpiry(_ token: String?) -> String {
        let clean = String(token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "missing" }
        guard let claims = decodeJWTClaims(clean) else { return "not_jwt_or_decode_failed" }
        guard let expSec = numericClaim(claims["exp"]) else { return "exp_missing" }

        let nowSec = Int(Date().timeIntervalSince1970)
        let remainingSec = expSec - nowSec
        let expISO = Self.iso8601.string(from: Date(timeIntervalSince1970: TimeInterval(expSec)))
        if let winSec = numericClaim(claims["win"]) {
            let winISO = Self.iso8601.string(from: Date(timeIntervalSince1970: TimeInterval(winSec)))
            return "exp=\(expISO) rem=\(remainingSec)s win=\(winISO)"
        }
        return "exp=\(expISO) rem=\(remainingSec)s"
    }

    func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payloadData = decodeBase64URL(String(parts[1])) else { return nil }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: payloadData),
              let claims = jsonObject as? [String: Any] else {
            return nil
        }
        return claims
    }

    func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    func numericClaim(_ raw: Any?) -> Int? {
        if let intValue = raw as? Int { return intValue }
        if let doubleValue = raw as? Double { return Int(doubleValue) }
        if let numberValue = raw as? NSNumber { return numberValue.intValue }
        if let stringValue = raw as? String,
           let parsed = Double(stringValue),
           parsed.isFinite {
            return Int(parsed)
        }
        return nil
    }
}
