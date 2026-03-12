import Foundation
import SwiftUI

#if canImport(ElevenLabs)
import ElevenLabs
#endif

extension AgentConversationViewModel {
    func connect(using state: AppState) async {
        connectAttemptCounter += 1
        let attempt = connectAttemptCounter
        logDebug("[connect] attempt=\(attempt) enter state=\(connectionState) active=\(isConversationActive)")
        guard !isConnectInFlight else {
            logDebug("[connect] attempt=\(attempt) skip due to in-flight connect")
            return
        }
        guard connectionState == .idle || connectionState == .ended || connectionState == .failed else {
            logDebug("[connect] attempt=\(attempt) skip due to state=\(connectionState)")
            return
        }
        isConnectInFlight = true
        defer { isConnectInFlight = false }
        activeConnectionRunId = UUID() // Eski callback'leri geçersiz kıl.

        appState = state
        startNetworkMonitorIfNeeded()
#if canImport(ElevenLabs)
        if let existingConversation = conversation {
            let stateDesc = String(describing: existingConversation.state).lowercased()
            if stateDesc.contains("active") || stateDesc.contains("connecting") {
                logInfo("[connect] attempt=\(attempt) duplicate connect ignored existingState=\(existingConversation.state)")
                statusLine = "Oturum zaten aktif."
                connectionState = stateDesc.contains("connecting") ? .connecting : .connected
                didReachActiveState = stateDesc.contains("active")
                return
            }
            conversation = nil
        }
#endif
        cancellables.removeAll()
        stopSessionHeartbeat()
        isFinalized = false
        endRequestedByUser = false
        connectedAt = nil
        lastNetworkLossAt = nil
        lastNetworkRecoveryAt = nil
        localEndCounter = 0
        lastLocalEndSource = nil
        lastDisconnectDiagnostic = nil
        transcriptBuffer = []
        isConversationActive = false
        didReachActiveState = false
        resetToolAccessoryState()
        messages = []
        errorText = ""
        statusLine = "Agent'a bağlanıyor..."
        connectionState = .connecting

        let mode = launchModeOverride ?? config.mode
        activeMode = mode
        let agentId = mode == .text ? textAgentId : voiceAgentId
        if connectedAgentId != nil, connectedAgentId != agentId {
            sessionWindowToken = nil
            elevenSessionReleased = false
        }
        logInfo("[connect] attempt=\(attempt) mode=\(mode.rawValue) agentId=\(agentId)")
        connectedAgentId = agentId
        elevenSessionReleased = false
        let runId = UUID()
        activeConnectionRunId = runId
        let runtimeDynamicVariables = buildDynamicVariables(from: state)
        if mode == .voice {
            do {
                try prepareVoiceAudioSession()
            } catch {
                isConversationActive = false
                connectionState = .failed
                statusLine = "Ses oturumu hazırlanamadı"
                errorText = "Ses ayarı yapılamadı: \(error.localizedDescription)"
                logError("[audio] prepare failed error=\(String(reflecting: error))")
                await releaseElevenSessionLock()
                return
            }
            installVoiceAudioObserversIfNeeded()
        } else {
            removeVoiceAudioObservers()
            deactivateVoiceAudioSessionIfNeeded()
        }

#if canImport(ElevenLabs)
        let runtimeConversationOverrides = ConversationOverrides(textOnly: mode == .text)

        let runtimeConfig = ConversationConfig(
            conversationOverrides: runtimeConversationOverrides,
            dynamicVariables: runtimeDynamicVariables,
            onDisconnect: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.activeConnectionRunId == runId else {
                        self.logDebug("[connect-callback] stale onDisconnect ignored runId=\(runId.uuidString)")
                        return
                    }
                    self.logInfo(
                        "[connect-callback] onDisconnect runId=\(runId.uuidString) mode=\(self.activeMode.rawValue) state=\(self.connectionState) localEnd=\(self.lastLocalEndSource ?? "nil") net=\(String(describing: self.lastNetworkStatus))"
                    )
                    self.statusLine = "Bağlantı kesildi"
                }
            }
        )

        do {
            let auth = try await fetchSessionAuthWithConflictRecovery(
                agentId: agentId,
                dynamicVariables: runtimeDynamicVariables,
                attempt: attempt
            )
            let responseAgentId = auth.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !responseAgentId.isEmpty, responseAgentId != agentId {
                throw AppError.httpError("Session auth agent uyuşmuyor. Beklenen: \(agentId), gelen: \(responseAgentId)")
            }
            let traceId = auth.traceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            logInfo("[connect] attempt=\(attempt) session-auth ok traceId=\(traceId.isEmpty ? "-" : traceId) token=\(!((auth.conversationToken ?? "").isEmpty)) signed=\(!((auth.signedUrl ?? "").isEmpty))")
            startConversationCallCounter += 1
            logDebug("[connect] attempt=\(attempt) startConversation call=\(startConversationCallCounter)")
            let startedConversation: Conversation
            do {
                startedConversation = try await startConversation(auth: auth, config: runtimeConfig)
            } catch {
                logConversationHandshakeFailure(
                    error: error,
                    auth: auth,
                    attempt: attempt,
                    stage: "initial"
                )
                guard shouldRetryConversationStart(after: error) else {
                    throw error
                }
                logWarning("[connect] attempt=\(attempt) startConversation handshake failed; refreshing session-auth once")
                let retryAuth = try await fetchSessionAuthWithConflictRecovery(
                    agentId: agentId,
                    dynamicVariables: runtimeDynamicVariables,
                    attempt: attempt
                )
                let retryResponseAgentId = retryAuth.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !retryResponseAgentId.isEmpty, retryResponseAgentId != agentId {
                    throw AppError.httpError("Session auth agent uyuşmuyor. Beklenen: \(agentId), gelen: \(retryResponseAgentId)")
                }
                let retryTraceId = retryAuth.traceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                logInfo("[connect] attempt=\(attempt) session-auth retry ok traceId=\(retryTraceId.isEmpty ? "-" : retryTraceId) token=\(!((retryAuth.conversationToken ?? "").isEmpty)) signed=\(!((retryAuth.signedUrl ?? "").isEmpty))")
                startConversationCallCounter += 1
                logDebug("[connect] attempt=\(attempt) startConversation retry call=\(startConversationCallCounter)")
                do {
                    startedConversation = try await startConversation(auth: retryAuth, config: runtimeConfig)
                } catch {
                    logConversationHandshakeFailure(
                        error: error,
                        auth: retryAuth,
                        attempt: attempt,
                        stage: "retry"
                    )
                    throw error
                }
            }
            conversation = startedConversation
            setupObservers(runId: runId, conversation: startedConversation)
            connectionState = .connecting
            statusLine = "Bağlantı doğrulanıyor..."
            startSessionHeartbeatIfNeeded()
            logInfo("[connect] attempt=\(attempt) startConversation returned")
        } catch {
            isConversationActive = false
            connectionState = .failed
            statusLine = "Bağlantı başarısız"
            errorText = "Bağlantı kurulamadı: \(error.localizedDescription)"
            stopSessionHeartbeat()
            await releaseElevenSessionLock()
            logError("[connect] attempt=\(attempt) failed error=\(String(reflecting: error))")
        }
#else
        connectionState = .failed
        errorText = "ElevenLabs Swift SDK bulunamadı."
#endif
    }

    func sendMessage(_ text: String) async throws {
        guard activeMode == .text else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard connectionState == .connected, isConversationActive, didReachActiveState else {
            throw AppError.httpError("Text oturumu henüz hazır değil. Birkaç saniye sonra tekrar deneyin.")
        }

#if canImport(ElevenLabs)
        guard let conversation else {
            throw AppError.httpError("Text oturumu hazır değil.")
        }
        isAwaitingReply = true
        agentState = .thinking
        appendLocalMessage(source: "user", text: clean, id: "user-local-\(UUID().uuidString)")
        logDebug("[text-send] chars=\(clean.count)")
        Task { [weak self] in
            await self?.touchSessionLockIfPossible(reason: "text_send_preflight")
        }

        do {
            try await conversation.sendMessage(clean)
            logDebug("[text-send] delivered")
            Task { [weak self] in
                await self?.touchSessionLockIfPossible(reason: "text_send_delivered")
            }
        } catch {
            isAwaitingReply = false
            agentState = .unknown
            throw AppError.httpError("Mesaj gönderilemedi: \(error.localizedDescription)")
        }
#else
        throw AppError.httpError("ElevenLabs Swift SDK bulunamadı.")
#endif
    }

    func setMuted(_ muted: Bool) async throws {
        guard activeMode == .voice else { return }
        guard connectionState == .connected else { return }
        guard isMicMuted != muted else { return }

#if canImport(ElevenLabs)
        guard let conversation else { return }
        isMutingInFlight = true
        defer { isMutingInFlight = false }
        do {
            try await conversation.setMuted(muted)
            isMicMuted = muted
        } catch {
            throw AppError.httpError("Mikrofon güncellenemedi: \(error.localizedDescription)")
        }
#endif
    }

    func end() async {
        guard connectionState == .connected else { return }
        endRequestedByUser = true
        connectionState = .ending
        statusLine = "Oturum kapatılıyor..."
        resetToolAccessoryState()
        refreshTranscriptBuffer()

#if canImport(ElevenLabs)
        if let conversation {
            markLocalEnd(source: "end_user_requested")
            await conversation.endConversation()
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {}
            await flushConversationMessages()
            return
        }
#endif

        agentState = .ended
        connectionState = .ended
        statusLine = "Oturum kapandı"
        await finalizeIfNeeded()
    }

    func markUserRequestedEnd() {
        endRequestedByUser = true
    }

    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            if activeMode == .voice, connectionState == .connected || connectionState == .connecting {
                do {
                    try prepareVoiceAudioSession()
                    statusLine = "Ses oturumu aktif."
                } catch {
                    errorText = "Ses oturumu yeniden etkinleştirilemedi: \(error.localizedDescription)"
                    logError("[audio] reactivate failed error=\(String(reflecting: error))")
                }
            } else if activeMode == .text, connectionState == .connected {
                statusLine = "Metin oturumu aktif."
            }
        case .background:
            if activeMode == .voice {
                if !hasBackgroundAudioCapability, connectionState == .connected {
                    statusLine = "Uygulama arka plana alındı. Sesli bağlantı iOS tarafından kesilebilir."
                }
                deactivateVoiceAudioSessionIfNeeded()
            } else if activeMode == .text, connectionState == .connected {
                statusLine = "Uygulama arka planda. Metin bağlantısı iOS tarafından kesilebilir."
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
