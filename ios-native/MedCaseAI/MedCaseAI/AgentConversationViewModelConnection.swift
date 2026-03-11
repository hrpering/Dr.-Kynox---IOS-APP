import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI

#if canImport(ElevenLabs)
import ElevenLabs
#endif

extension AgentConversationViewModel {
    func setupObservers(runId: UUID, conversation: Conversation) {
#if canImport(ElevenLabs)
        conversation.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sdkMessages in
                guard let self else { return }
                guard self.activeConnectionRunId == runId else { return }
                let mapped = sdkMessages.compactMap { raw -> Message? in
                    let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return nil }
                    let source = raw.role == .user ? "user" : "ai"
                    if source == "user", content.hasPrefix("[SYS_RESUME_CONTEXT]") {
                        return nil
                    }
                    let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "sdk-\(UUID().uuidString)"
                        : raw.id
                    return Message(id: id, source: source, text: content, timestamp: raw.timestamp)
                }
                self.messages = self.dedupe(mapped)
                self.refreshTranscriptBuffer()
                self.refreshUsageCounters()
                if self.activeMode == .voice {
                    self.enforceVoiceTranscriptLimitIfNeeded()
                }
                self.isAwaitingReply = self.messages.last?.source == "user"
            }
            .store(in: &cancellables)

        conversation.$agentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.activeConnectionRunId == runId else { return }
                let normalized = String(describing: state).lowercased()
                if normalized.contains("listen") {
                    self?.agentState = .listening
                } else if normalized.contains("speak") {
                    self?.agentState = .speaking
                } else if normalized.contains("think") || normalized.contains("process") {
                    self?.agentState = .thinking
                } else {
                    self?.agentState = .unknown
                }
            }
            .store(in: &cancellables)

        conversation.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                guard self.activeConnectionRunId == runId else { return }
                switch state {
                case .idle:
                    // Text modda SDK yanitlar arasi `idle` durumuna dusebilir; bu kopus degildir.
                    if self.activeMode == .text,
                       self.connectionState == .connecting || self.connectionState == .connected {
                        self.logDebug("[connect-state] idle(text) keep-connected runId=\(runId.uuidString) prev=\(self.connectionState)")
                        self.isConversationActive = true
                        self.connectionState = .connected
                        self.statusLine = "Hazır"
                        break
                    }
                    self.isConversationActive = false
                    if self.connectionState != .ending {
                        self.connectionState = .idle
                        self.statusLine = "Hazır"
                    }
                case .connecting:
                    self.isConversationActive = false
                    self.connectionState = .connecting
                    self.statusLine = "Bağlanıyor..."
                    self.logDebug("[connect-state] connecting")
                case .active:
                    self.isConversationActive = true
                    self.connectionState = .connected
                    self.statusLine = "Bağlandı"
                    self.connectedAt = Date()
                    self.logInfo("[connect-state] active")
                    if self.activeMode == .voice {
                        do {
                            try self.prepareVoiceAudioSession()
                        } catch {
                            self.errorText = "Ses oturumu etkinleştirilemedi: \(error.localizedDescription)"
                            self.logError("[audio] active-state prepare failed error=\(String(reflecting: error))")
                        }
                    }
                    self.startSessionHeartbeatIfNeeded()
                    Task { [weak self] in
                        await self?.touchSessionLockIfPossible(reason: "state_active")
                    }
                case .ended(let reason):
                    let diagnostic = self.unexpectedEndDiagnostic(reason)
                    let uptimeSec = self.connectedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                    self.logWarning(
                        "[TextDebug] Conversation ended. reason=\(reason) userRequestedEnd=\(self.endRequestedByUser) diagnostic=\(diagnostic) uptimeSec=\(String(format: "%.1f", uptimeSec)) localEndSource=\(self.lastLocalEndSource ?? "nil") localEndCounter=\(self.localEndCounter) net=\(String(describing: self.lastNetworkStatus))"
                    )
                    self.isConversationActive = false
                    self.agentState = .ended
                    self.statusLine = self.statusTextForEnd(reason)
                    let shouldFinalize = self.endRequestedByUser
                    self.connectionState = .ended
                    self.stopSessionHeartbeat()
                    if shouldFinalize {
                        Task {
                            await self.flushConversationMessages()
                            await self.finalizeIfNeeded()
                        }
                    } else {
                        Task {
                            await self.releaseElevenSessionLock()
                            self.deactivateVoiceAudioSessionIfNeeded()
                            await self.stopConversationAfterUnexpectedEnd()
                        }
                        self.errorText = self.errorTextForUnexpectedEnd(reason, diagnostic: diagnostic)
                    }
                case .error(let error):
                    self.logError("[connect-state] error runId=\(runId.uuidString) error=\(String(reflecting: error))")
                    self.isConversationActive = false
                    self.connectionState = .failed
                    self.statusLine = "Bağlantı hatası"
                    self.errorText = "Bağlantı hatası: \(error.localizedDescription)"
                    self.stopSessionHeartbeat()
                    Task {
                        await self.releaseElevenSessionLock()
                        self.deactivateVoiceAudioSessionIfNeeded()
                        await self.stopConversationAfterUnexpectedEnd()
                    }
                }
            }
            .store(in: &cancellables)

        conversation.$isMuted
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _ in self?.activeConnectionRunId == runId }
            .assign(to: &$isMicMuted)
#endif
    }

    #if canImport(ElevenLabs)
    func statusTextForEnd(_ reason: EndReason) -> String {
        switch reason {
        case .userEnded:
            return "Oturum kapandı"
        case .agentNotConnected:
            return "Agent bağlantısı kurulamadı"
        case .remoteDisconnected:
            return "Bağlantı kesildi"
        }
    }

    func errorTextForUnexpectedEnd(_ reason: EndReason) -> String {
        let diagnostic = unexpectedEndDiagnostic(reason)
        return errorTextForUnexpectedEnd(reason, diagnostic: diagnostic)
    }

    func errorTextForUnexpectedEnd(_ reason: EndReason, diagnostic: String) -> String {
        switch reason {
        case .userEnded:
            if diagnostic.hasPrefix("local_end:") {
                return "Oturum yerel akışta kapandı (\(diagnostic))."
            }
            if diagnostic == "network_transition_or_keepalive_timeout" {
                return "Bağlantı ağ geçişi veya keepalive timeout nedeniyle kapanmış olabilir. Vakayı yeniden başlatabilirsin."
            }
            return "Oturum beklenmedik şekilde kapandı (SDK userEnded eşlemesi / agent end_call olası). Vakayı yeniden başlatabilirsin."
        case .agentNotConnected:
            return "Agent bağlantısı kurulamadı. Tekrar deneyebilirsin."
        case .remoteDisconnected:
            return "Bağlantı kesildi. Vakayı yeniden başlatabilirsin."
        }
    }

    #endif

    func fetchSessionAuth(agentId: String,
                                  dynamicVariables: [String: String]) async throws -> ElevenLabsSessionAuthResponse {
        guard let appState else { throw AppError.sessionMissing }
        return try await appState.fetchElevenLabsSessionAuth(
            agentId: agentId,
            mode: activeMode == .text ? "text" : "voice",
            sessionWindowToken: sessionWindowToken,
            dynamicVariables: dynamicVariables
        )
    }

    func fetchSessionAuthWithConflictRecovery(agentId: String,
                                                      dynamicVariables: [String: String],
                                                      attempt: Int) async throws -> ElevenLabsSessionAuthResponse {
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

    func buildDynamicVariables(from state: AppState) -> [String: String] {
        var vars = config.dynamicVariables

        let fullName = state.profile?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstName = state.profile?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = !firstName.isEmpty
            ? firstName
            : (!fullName.isEmpty ? String(fullName.split(separator: " ").first ?? "") : "")
        let safeUserName = candidate.isEmpty ? "Kullanıcı" : candidate

        if vars["user_name"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            vars["user_name"] = safeUserName
        }
        vars["difficulty"] = config.difficulty
        vars["difficulty_level"] = config.difficulty
        vars["specialty"] = config.specialty
        vars["challenge_type"] = config.challengeType
        vars["session_id"] = config.id
        vars["mode"] = activeMode.rawValue

        let allowedKeys = Set([
            "specialty",
            "difficulty",
            "difficulty_level",
            "challenge_type",
            "mode",
            "session_id",
            "user_name",
            "challenge_id",
            "case_title",
            "case",
            "chief_complaint",
            "expected_diagnosis_hidden",
            "patient_gender",
            "patient_age",
            "specialty_localized",
            "specialty_canonical"
        ])

        return vars.reduce(into: [String: String]()) { partialResult, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedKeys.contains(key) else { return }
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            partialResult[key] = value
        }
    }

    func stopConversationAfterUnexpectedEnd() async {
#if canImport(ElevenLabs)
        guard !isStoppingUnexpectedly else { return }
        isStoppingUnexpectedly = true
        defer { isStoppingUnexpectedly = false }
        // `ended`/`error` callback pathinda SDK zaten kapanis durumuna gecmis olabilir.
        // Ayni conversation icin tekrar `endConversation()` cagirmayi onlemek daha guvenlidir.
        conversation = nil
#endif
        cancellables.removeAll()
        activeConnectionRunId = UUID()
    }

#if canImport(ElevenLabs)
    func startConversation(auth: ElevenLabsSessionAuthResponse,
                                   config runtimeConfig: ConversationConfig) async throws -> Conversation {
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

    func finalizeIfNeeded() async {
        guard !isFinalized else { return }
        isFinalized = true
        agentState = .ended

        guard let appState else { return }

        let endedAt = Date()
        await flushConversationMessages()
        let liveTranscript = normalizedTranscript(messages.map { $0.transcriptLine })
        let bufferedTranscript = normalizedTranscript(transcriptBuffer)
        let cleanTranscript = liveTranscript.count >= bufferedTranscript.count ? liveTranscript : bufferedTranscript
        if !cleanTranscript.isEmpty {
            transcriptBuffer = cleanTranscript
        }

        let pendingPayload = buildSavePayload(
            score: nil,
            status: cleanTranscript.isEmpty ? "incomplete" : "pending_score",
            endedAt: endedAt,
            transcript: cleanTranscript
        )
        await appState.saveCase(payload: pendingPayload)
        await releaseElevenSessionLock()
        deactivateVoiceAudioSessionIfNeeded()
    }

    @discardableResult
    func releaseElevenSessionLock() async -> Bool {
        guard !elevenSessionReleased else { return true }
        guard let appState, let agentId = connectedAgentId else { return false }
        stopSessionHeartbeat()
        let released = await appState.endElevenLabsSession(
            agentId: agentId,
            sessionWindowToken: sessionWindowToken
        )
        if released {
            elevenSessionReleased = true
            sessionWindowToken = nil
        } else {
            logWarning("[session-lock] release failed agentId=\(agentId)")
        }
        return released
    }

    // Session window lock'i hem voice hem text modunda canli tutar.
    // Text oturumlarda SDK'nin `active` durumuna gecisi gecikirse `connecting` asamasinda da touch atmaya devam eder.
    func startSessionHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        guard connectedAgentId != nil else { return }
        let intervalNs = sessionHeartbeatIntervalSec * 1_000_000_000
        Task { [weak self] in
            await self?.touchSessionLockIfPossible(reason: "heartbeat_start")
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard self.connectionState == .connected || self.connectionState == .connecting else { continue }
                let reason = self.connectionState == .connecting ? "heartbeat_connecting" : "heartbeat"
                await self.touchSessionLockIfPossible(reason: reason)
            }
        }
    }

    func touchSessionLockIfPossible(reason: String) async {
        guard let appState = appState,
              let agentId = connectedAgentId,
              let windowToken = sessionWindowToken,
              !windowToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await appState.touchElevenLabsSession(
            agentId: agentId,
            sessionWindowToken: windowToken
        )
        logDebug("[session-lock] touch reason=\(reason) agentId=\(agentId)")
    }

    func stopSessionHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

}
