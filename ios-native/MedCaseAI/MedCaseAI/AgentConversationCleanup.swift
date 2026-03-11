import Foundation

#if canImport(ElevenLabs)
import ElevenLabs
#endif

extension AgentConversationViewModel {
    func cleanup() {
        activeConnectionRunId = UUID()
        stopSessionHeartbeat()
        removeVoiceAudioObservers()
        deactivateVoiceAudioSessionIfNeeded()
        stopNetworkMonitor()
#if canImport(ElevenLabs)
        if let existingConversation = conversation {
            let stateDesc = String(describing: existingConversation.state).lowercased()
            if stateDesc.contains("active") || stateDesc.contains("connecting") {
                markLocalEnd(source: "cleanup")
                Task { [existingConversation] in
                    await existingConversation.endConversation()
                }
            }
        }
#endif
        if !elevenSessionReleased {
            Task { [weak self] in
                await self?.releaseElevenSessionLock()
            }
        }
        cancellables.removeAll()
#if canImport(ElevenLabs)
        conversation = nil
#endif
        messages = []
        isAwaitingReply = false
        isMutingInFlight = false
        connectionState = .idle
        agentState = .unknown
        statusLine = "Hazır"
        errorText = ""
        isFinalized = false
        endRequestedByUser = false
        launchModeOverride = nil
        activeMode = config.mode
        transcriptBuffer = []
        resetToolAccessoryState()
        textUserCharacterCount = 0
        textUserMessageCount = 0
        textAICharacterCount = 0
        textAIMessageCount = 0
        voiceUserTranscriptCharacterCount = 0
        voiceUserTranscriptMessageCount = 0
        sessionLimitReached = false
        isConversationActive = false
        didReachActiveState = false
        lastDisconnectDiagnostic = nil
        isStoppingUnexpectedly = false
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
        resetToolAccessoryState()
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
}
