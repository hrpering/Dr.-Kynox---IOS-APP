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
                let previousMessageIds = Set(self.messages.map(\.id))
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
                let newAiMessages = self.messages.filter { row in
                    row.source == "ai" && !previousMessageIds.contains(row.id)
                }
                if !newAiMessages.isEmpty {
                    for row in newAiMessages {
                        self.attachPendingToolAccessoriesIfNeeded(to: row)
                    }
                } else if let latestAi = self.messages.last(where: { $0.source == "ai" }) {
                    // Agent response corrections can update same message id.
                    self.attachPendingToolAccessoriesIfNeeded(to: latestAi)
                }
                self.isAwaitingReply = self.messages.last?.source == "user"
            }
            .store(in: &cancellables)

        conversation.$pendingToolCalls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] toolCalls in
                guard let self else { return }
                guard self.activeConnectionRunId == runId else { return }
                self.handlePendingClientToolCalls(toolCalls, conversation: conversation)
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
                       !self.didReachActiveState,
                       (self.connectionState == .connecting || self.connectionState == .connected) {
                        self.logDebug("[connect-state] idle(text) waiting-active runId=\(runId.uuidString) prev=\(self.connectionState)")
                        self.isConversationActive = false
                        self.connectionState = .connecting
                        self.statusLine = "Bağlantı doğrulanıyor..."
                        break
                    }
                    if self.activeMode == .text,
                       self.didReachActiveState,
                       (self.connectionState == .connecting || self.connectionState == .connected) {
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
                    self.didReachActiveState = true
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
                    self.lastDisconnectDiagnostic = diagnostic
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
                    self.lastDisconnectDiagnostic = "state_error:\(error.localizedDescription)"
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

    func normalizedReadyMessageTrigger(_ text: String) -> String {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
        let withoutPunctuation = lowered.replacingOccurrences(
            of: "[^a-z0-9\\s]+",
            with: " ",
            options: .regularExpression
        )
        return withoutPunctuation.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func attachPendingToolAccessoriesIfNeeded(to aiMessage: Message) {
        guard aiMessage.source == "ai" else { return }
        guard normalizedReadyMessageTrigger(aiMessage.text) == "sonuclar hazir" else { return }
        guard !pendingToolResults.isEmpty else { return }

        var accessories = messageAccessoriesByMessageId[aiMessage.id] ?? []
        var attachedToolCallIds = Set<String>()
        for pending in pendingToolResults.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard toolCallMessageIdMap[pending.toolCallId] == nil else { continue }
            guard let descriptor = ToolDescriptor.byName[pending.toolName] else { continue }
            let accessoryId = "\(pending.toolName)-\(pending.toolCallId)"
            let alreadyAdded = accessories.contains { $0.id == accessoryId }
            if !alreadyAdded {
                let action: MessageBubbleAccessoryAction = descriptor.category == .imaging
                    ? .openImagingResults(anchorToolCallId: pending.toolCallId)
                    : .openToolResult(toolCallId: pending.toolCallId)
                accessories.append(
                    MessageBubbleAccessory(
                        id: accessoryId,
                        title: descriptor.ctaTitle,
                        iconSystemName: descriptor.iconSystemName,
                        tint: descriptor.tint,
                        action: action
                    )
                )
            }
            toolCallMessageIdMap[pending.toolCallId] = aiMessage.id
            attachedToolCallIds.insert(pending.toolCallId)
        }
        guard !attachedToolCallIds.isEmpty else { return }
        messageAccessoriesByMessageId[aiMessage.id] = accessories
        pendingToolResults.removeAll { attachedToolCallIds.contains($0.toolCallId) }
    }

#if canImport(ElevenLabs)
    func handlePendingClientToolCalls(_ toolCalls: [ClientToolCallEvent], conversation: Conversation) {
        for toolCall in toolCalls {
            let toolCallId = toolCall.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toolCallId.isEmpty else { continue }
            guard let descriptor = ToolDescriptor.byName[toolCall.toolName] else { continue }
            guard !handledToolCallIds.contains(toolCallId) else { continue }
            handledToolCallIds.insert(toolCallId)

            do {
                let payload = try ToolResultPayload.decode(from: toolCall.parametersData, descriptor: descriptor)
                pendingToolResults.append(
                    PendingToolResult(
                        toolCallId: toolCallId,
                        toolName: descriptor.toolName,
                        payload: payload,
                        createdAt: Date()
                    )
                )
                resultsByToolCallId[toolCallId] = payload
                toolCallNameMap[toolCallId] = descriptor.toolName
                Task { [weak self] in
                    do {
                        try await conversation.sendToolResult(
                            for: toolCallId,
                            result: ["status": "ok"],
                            isError: false
                        )
                    } catch {
                        self?.logError("[tool-result] sendToolResult failed name=\(descriptor.toolName) id=\(toolCallId) error=\(error.localizedDescription)")
                    }
                }
            } catch {
                logError("[tool-result] decode failed name=\(descriptor.toolName) id=\(toolCallId) error=\(error.localizedDescription)")
                Task { [weak self] in
                    do {
                        try await conversation.sendToolResult(
                            for: toolCallId,
                            result: ["status": "decode_failed", "error": error.localizedDescription],
                            isError: true
                        )
                    } catch {
                        self?.logError("[tool-result] sendToolResult(error) failed name=\(descriptor.toolName) id=\(toolCallId) error=\(error.localizedDescription)")
                    }
                }
            }
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
