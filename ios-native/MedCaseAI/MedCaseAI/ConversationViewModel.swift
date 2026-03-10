import Foundation
import Combine

#if canImport(ElevenLabs)
import ElevenLabs
#endif

struct DisplayMessage: Identifiable, Hashable {
    let id: String
    let role: String   // "user" | "agent"
    let content: String
    let timestamp: Date

    init(id: String = UUID().uuidString,
         role: String,
         content: String,
         timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    var asConversationLine: ConversationLine {
        ConversationLine(
            source: role == "user" ? "user" : "ai",
            message: content,
            timestamp: Int(timestamp.timeIntervalSince1970 * 1000)
        )
    }
}

@MainActor
final class ConversationViewModel: ObservableObject {
    // MARK: - State
    @Published var messages: [DisplayMessage] = []
    @Published var agentState: AgentState = .idle
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isMuted: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isScoring: Bool = false
    @Published var isScoreCompleted: Bool = false

    // MARK: - Config
    var mode: ConversationMode = .voice
    var difficulty: String = "kolay"
    var specialty: String = "dahiliye"
    var sessionId: UUID? = nil
    var challengeType: String = "random"
    var challengeId: String? = nil
    var expectedDiagnosis: String? = nil
    var sessionStartedAt: Date = Date()

    // MARK: - Private
    #if canImport(ElevenLabs)
    private var conversation: Conversation? = nil
    #endif
    private var cancellables = Set<AnyCancellable>()
    private var isFinalized = false
    private var hasTriggeredBudgetEnd = false
    private weak var appState: AppState?
    private var sessionWindowToken: String? = nil
    private var connectedAgentId: String? = nil
    private var elevenSessionReleased = false
    private let voiceAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    private let textAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    private let maxSessionMessages = 48
    private let maxSessionUserMessages = 24
    private let maxSessionUserChars = 2800

    enum ConversationMode { case voice, text }
    enum AgentState { case idle, listening, thinking, speaking }
    enum ConnectionState { case disconnected, connecting, connected, ended }

    func attach(appState: AppState) {
        self.appState = appState
    }

    @discardableResult
    func startSession(id: UUID = UUID(), startedAt: Date = Date()) -> (id: UUID, startedAt: Date) {
        sessionId = id
        sessionStartedAt = startedAt
        return (id, startedAt)
    }

    private func activeSessionId() -> UUID {
        if let sessionId {
            return sessionId
        }
        return startSession().id
    }

    // MARK: - Connect
    // Sadece kullanıcı "Başlat" butonundan çağrılır.
    func connect() async {
        guard connectionState == .disconnected else { return }

        isFinalized = false
        hasTriggeredBudgetEnd = false
        isScoreCompleted = false
        elevenSessionReleased = false
        connectionState = .connecting
        errorMessage = nil

        let selectedMode = mode
        let selectedDifficulty = difficulty
        let selectedSpecialty = specialty
        let agentId = selectedMode == .voice ? voiceAgentId : textAgentId
        let activeSessionId = activeSessionId()
        connectedAgentId = agentId

        #if canImport(ElevenLabs)
        let config = ConversationConfig(
            conversationOverrides: ConversationOverrides(
                textOnly: selectedMode == .text
            ),
            dynamicVariables: [
                "difficulty": selectedDifficulty,
                "difficulty_level": selectedDifficulty,
                "specialty": selectedSpecialty,
                "session_id": activeSessionId.uuidString,
                "challenge_type": challengeType,
                "mode": selectedMode == .voice ? "voice" : "text"
            ]
        )

        do {
            let token = try await fetchSessionToken(agentId: agentId)
            let convo = try await ElevenLabs.startConversation(
                conversationToken: token,
                config: config
            )
            conversation = convo
            connectionState = .connecting
            setupObservers()
        } catch {
            connectionState = .disconnected
            errorMessage = "Bağlantı kurulamadı: \(error.localizedDescription)"
            print("[conversation-connect] failed error=\(String(reflecting: error))")
            await releaseElevenSessionLock()
        }
        #else
        connectionState = .disconnected
        errorMessage = "ElevenLabs Swift SDK bulunamadı."
        #endif
    }

    // MARK: - Observers
    private func setupObservers() {
        #if canImport(ElevenLabs)
        guard let conversation else { return }
        cancellables.removeAll()

        conversation.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .active:
                    self.connectionState = .connected
                case .ended:
                    self.connectionState = .ended
                    guard !self.isFinalized else { return }
                    self.isFinalized = true
                    let snapshot = self.messages
                    Task { await self.finalizeSession(transcript: snapshot) }
                case .connecting:
                    self.connectionState = .connecting
                case .error(let err):
                    print("[conversation-state] error=\(String(reflecting: err))")
                    self.connectionState = .disconnected
                    self.errorMessage = "Bağlantı hatası: \(err)"
                    Task { await self.releaseElevenSessionLock() }
                case .idle:
                    break
                }
            }
            .store(in: &cancellables)

        conversation.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sdkMessages in
                guard let self else { return }
                self.messages = sdkMessages.compactMap { msg in
                    let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let role = msg.role == .user ? "user" : "agent"
                    let id = msg.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? UUID().uuidString
                        : msg.id
                    return DisplayMessage(
                        id: id,
                        role: role,
                        content: text,
                        timestamp: msg.timestamp
                    )
                }
                if let limitReason = self.sessionLimitReason(for: self.messages),
                   !self.hasTriggeredBudgetEnd,
                   self.connectionState == .connected,
                   !self.isFinalized {
                    self.hasTriggeredBudgetEnd = true
                    self.errorMessage = "\(limitReason) Oturum otomatik sonlandırılıyor."
                    Task { await self.endConversation() }
                }
            }
            .store(in: &cancellables)

        conversation.$agentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let normalized = String(describing: state).lowercased()
                if normalized.contains("listening") || normalized.contains("listen") {
                    self?.agentState = .listening
                } else if normalized.contains("speaking") || normalized.contains("speak") {
                    self?.agentState = .speaking
                } else if normalized.contains("thinking") || normalized.contains("think") || normalized.contains("process") {
                    self?.agentState = .thinking
                } else {
                    self?.agentState = .idle
                }
            }
            .store(in: &cancellables)

        conversation.$isMuted
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMuted)
        #endif
    }

    // MARK: - Text message (sadece text mode)
    func sendTextMessage(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .text,
              !clean.isEmpty,
              connectionState == .connected
        else { return }
        if let limitReason = sessionLimitReason(for: messages) {
            errorMessage = "\(limitReason) Yeni mesaj gönderilemiyor."
            return
        }

        #if canImport(ElevenLabs)
        guard let conversation else { return }
        guard conversation.state.isActive else {
            errorMessage = "Bağlantı henüz hazır değil. 1-2 saniye içinde tekrar deneyin."
            return
        }
        do {
            try await conversation.sendMessage(clean)
        } catch {
            errorMessage = "Mesaj gönderilemedi: \(error.localizedDescription)"
        }
        #endif
    }

    private func sessionLimitReason(for transcript: [DisplayMessage]) -> String? {
        let totalMessages = transcript.count
        let userMessages = transcript.filter { $0.role == "user" }.count
        let userChars = transcript.reduce(0) { partial, item in
            guard item.role == "user" else { return partial }
            return partial + item.content.trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        if totalMessages >= maxSessionMessages {
            return "Oturum mesaj limiti doldu (\(maxSessionMessages))."
        }
        if userMessages >= maxSessionUserMessages {
            return "Kullanıcı mesaj limiti doldu (\(maxSessionUserMessages))."
        }
        if userChars >= maxSessionUserChars {
            return "Bu oturum için metin/konuşma karakter limiti doldu (\(maxSessionUserChars))."
        }
        return nil
    }

    // MARK: - Mute (sadece voice mode)
    func toggleMute() async {
        guard mode == .voice else { return }
        #if canImport(ElevenLabs)
        guard let conversation else { return }
        do {
            try await conversation.setMuted(!isMuted)
        } catch {
            errorMessage = "Mikrofon güncellenemedi: \(error.localizedDescription)"
        }
        #endif
    }

    // MARK: - End
    func endConversation() async {
        #if canImport(ElevenLabs)
        guard let conversation, connectionState == .connected else { return }
        await conversation.endConversation()
        #endif
    }

    // MARK: - Finalize & Score
    // SADECE .ended observer'ından çağrılır.
    private func finalizeSession(transcript: [DisplayMessage]) async {
        guard let sessionId, let appState else { return }

        let endedAt = Date()
        let transcriptLines = transcript
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.asConversationLine }

        let pendingPayload = SaveCasePayload(
            sessionId: sessionId.uuidString,
            mode: mode == .voice ? "voice" : "text",
            status: transcriptLines.isEmpty ? "incomplete" : "pending_score",
            startedAt: ISO8601DateFormatter().string(from: sessionStartedAt),
            endedAt: ISO8601DateFormatter().string(from: endedAt),
            durationMin: max(1, Int(endedAt.timeIntervalSince(sessionStartedAt) / 60)),
            messageCount: transcriptLines.count,
            difficulty: difficulty,
            caseContext: .init(
                title: challengeType == "daily" ? "Günün Vaka Meydan Okuması" : "Rastgele Klinik Vaka",
                specialty: specialty,
                subtitle: "Konuşma oturumu tamamlandı",
                challengeId: challengeId,
                challengeType: challengeType,
                expectedDiagnosis: expectedDiagnosis
            ),
            transcript: transcriptLines,
            score: nil
        )
        await appState.saveCase(payload: pendingPayload)

        guard !transcriptLines.isEmpty else {
            await releaseElevenSessionLock()
            return
        }

        isScoring = true
        defer { isScoring = false }

        do {
            let wrapup = expectedDiagnosis.map { "Vaka doğru tanısı: \($0)." } ?? ""
            let scored = try await appState.scoreConversation(
                mode: mode == .voice ? "voice" : "text",
                transcript: transcriptLines,
                wrapup: wrapup
            )

            let completedPayload = SaveCasePayload(
                sessionId: sessionId.uuidString,
                mode: mode == .voice ? "voice" : "text",
                status: "ready",
                startedAt: ISO8601DateFormatter().string(from: sessionStartedAt),
                endedAt: ISO8601DateFormatter().string(from: endedAt),
                durationMin: max(1, Int(endedAt.timeIntervalSince(sessionStartedAt) / 60)),
                messageCount: transcriptLines.count,
                difficulty: difficulty,
                caseContext: .init(
                    title: scored.caseTitle.isEmpty ? (challengeType == "daily" ? "Günün Vaka Meydan Okuması" : "Rastgele Klinik Vaka") : scored.caseTitle,
                    specialty: specialty,
                    subtitle: "Skorlandı",
                    challengeId: challengeId,
                    challengeType: challengeType,
                    expectedDiagnosis: scored.trueDiagnosis.isEmpty ? expectedDiagnosis : scored.trueDiagnosis
                ),
                transcript: transcriptLines,
                score: scored
            )
            await appState.saveCase(payload: completedPayload)
            isScoreCompleted = true
        } catch {
            errorMessage = "Skor üretilemedi: \(error.localizedDescription)"
        }

        await releaseElevenSessionLock()
    }

    private func fetchSessionToken(agentId: String) async throws -> String {
        guard let appState else {
            throw AppError.sessionMissing
        }

        let auth = try await appState.fetchElevenLabsSessionAuth(
            agentId: agentId,
            mode: mode == .text ? "text" : "voice",
            sessionWindowToken: sessionWindowToken,
            dynamicVariables: [
                "difficulty": difficulty,
                "difficulty_level": difficulty,
                "specialty": specialty,
                "session_id": activeSessionId().uuidString
            ]
        )
        sessionWindowToken = auth.sessionWindowToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        elevenSessionReleased = false

        guard let token = auth.conversationToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AppError.httpError("ElevenLabs session token alınamadı.")
        }
        return token
    }

    @discardableResult
    private func releaseElevenSessionLock() async -> Bool {
        guard !elevenSessionReleased else { return true }
        guard let appState, let agentId = connectedAgentId else { return false }
        let released = await appState.endElevenLabsSession(
            agentId: agentId,
            sessionWindowToken: sessionWindowToken
        )
        if released {
            elevenSessionReleased = true
            sessionWindowToken = nil
        }
        return released
    }

    // MARK: - Cleanup
    func cleanup() async {
        await releaseElevenSessionLock()
        cancellables.removeAll()
        #if canImport(ElevenLabs)
        conversation = nil
        #endif
        connectionState = .disconnected
        isFinalized = false
        hasTriggeredBudgetEnd = false
        isScoring = false
        elevenSessionReleased = false
        messages = []
        connectedAgentId = nil
    }
}
