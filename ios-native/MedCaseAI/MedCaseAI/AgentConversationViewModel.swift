import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI

#if canImport(ElevenLabs)
import ElevenLabs
#endif

@MainActor
final class AgentConversationViewModel: ObservableObject {
    struct Message: Identifiable, Hashable {
        let id: String
        let source: String
        let text: String
        let timestamp: Date

        var transcriptLine: ConversationLine {
            ConversationLine(
                source: source,
                message: text,
                timestamp: Int(timestamp.timeIntervalSince1970 * 1000)
            )
        }
    }

    enum AgentState: Equatable {
        case listening
        case thinking
        case speaking
        case ended
        case unknown
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case ending
        case ended
        case failed
    }

    @Published var messages: [Message] = []
    @Published var agentState: AgentState = .unknown
    @Published var connectionState: ConnectionState = .idle
    @Published var isAwaitingReply = false
    @Published var errorText = ""
    @Published var statusLine = "Hazır"
    @Published var isMicMuted = true
    @Published var isMutingInFlight = false
    @Published var isScoring = false

    var isConnecting: Bool { connectionState == .connecting }
    var isConnected: Bool { connectionState == .connected }
    var isEnding: Bool { connectionState == .ending }

    let config: CaseLaunchConfig
    let startedAt: Date

#if canImport(ElevenLabs)
    private var conversation: Conversation?
#endif

    private var cancellables = Set<AnyCancellable>()
    private weak var appState: AppState?
    private var isFinalized = false
    private var endRequestedByUser = false
    private var sessionWindowToken: String?
    private var connectedAgentId: String?
    private var connectAttemptCounter = 0
    private var launchModeOverride: CaseLaunchConfig.Mode?
    private var activeMode: CaseLaunchConfig.Mode
    private var elevenSessionReleased = false
    private var heartbeatTask: Task<Void, Never>?
    private var transcriptBuffer: [ConversationLine] = []
    private var textUserCharacterCount = 0
    private var textUserMessageCount = 0
    private var textAICharacterCount = 0
    private var textAIMessageCount = 0
    private var voiceUserTranscriptCharacterCount = 0
    private var voiceUserTranscriptMessageCount = 0
    private var sessionLimitReached = false
    private var isConversationActive = false
    private var isStoppingUnexpectedly = false
    private var isConnectInFlight = false
    private var activeConnectionRunId = UUID()
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioRouteChangeObserver: NSObjectProtocol?
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "com.medcaseai.elevenlabs.network-monitor")
    private var lastNetworkStatus: NWPath.Status?
    private var lastNetworkLossAt: Date?
    private var lastNetworkRecoveryAt: Date?
    private var connectedAt: Date?
    private var localEndCounter = 0
    private var lastLocalEndSource: String?
    private var startConversationCallCounter = 0

    private let voiceSessionTranscriptCharacterLimit = 7000
    private let sessionHeartbeatIntervalSec: UInt64 = 8
    private let nearTextDuplicateWindowSeconds: TimeInterval = 2.5

    private let voiceAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    private let textAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    private static let iso8601 = ISO8601DateFormatter()

    init(config: CaseLaunchConfig, saveHandler: (() async throws -> Void)? = nil) {
        self.config = config
        self.activeMode = config.mode
        self.startedAt = Date()
        _ = saveHandler
    }

    var transcript: [ConversationLine] {
        messages.map { $0.transcriptLine }
    }

    var stableTranscript: [ConversationLine] {
        let live = normalizedTranscript(messages.map { $0.transcriptLine })
        return live.count >= transcriptBuffer.count ? live : transcriptBuffer
    }

    func setTextOnlyOverride(_ enabled: Bool) {
        launchModeOverride = enabled ? .text : nil
    }

    func connect(using state: AppState) async {
        connectAttemptCounter += 1
        let attempt = connectAttemptCounter
        print("[connect] attempt=\(attempt) enter state=\(connectionState) active=\(isConversationActive)")
        guard !isConnectInFlight else {
            print("[connect] attempt=\(attempt) skip due to in-flight connect")
            return
        }
        guard connectionState == .idle || connectionState == .ended || connectionState == .failed else {
            print("[connect] attempt=\(attempt) skip due to state=\(connectionState)")
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
                print("[connect] attempt=\(attempt) duplicate connect ignored existingState=\(existingConversation.state)")
                statusLine = "Oturum zaten aktif."
                connectionState = stateDesc.contains("connecting") ? .connecting : .connected
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
        transcriptBuffer = []
        textUserCharacterCount = 0
        textUserMessageCount = 0
        textAICharacterCount = 0
        textAIMessageCount = 0
        voiceUserTranscriptCharacterCount = 0
        voiceUserTranscriptMessageCount = 0
        sessionLimitReached = false
        isConversationActive = false
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
        print("[connect] attempt=\(attempt) mode=\(mode.rawValue) agentId=\(agentId)")
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
                print("[audio] prepare failed error=\(String(reflecting: error))")
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
                        print("[connect-callback] stale onDisconnect ignored runId=\(runId.uuidString)")
                        return
                    }
                    print(
                        "[connect-callback] onDisconnect runId=\(runId.uuidString) mode=\(self.activeMode.rawValue) state=\(self.connectionState) localEnd=\(self.lastLocalEndSource ?? "nil") net=\(String(describing: self.lastNetworkStatus))"
                    )
                    self.statusLine = "Bağlantı kesildi"
                }
            }
        )

        do {
            let auth = try await fetchSessionAuth(agentId: agentId, dynamicVariables: runtimeDynamicVariables)
            let responseAgentId = auth.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !responseAgentId.isEmpty, responseAgentId != agentId {
                throw AppError.httpError("Session auth agent uyuşmuyor. Beklenen: \(agentId), gelen: \(responseAgentId)")
            }
            print("[connect] attempt=\(attempt) session-auth ok token=\(!((auth.conversationToken ?? "").isEmpty)) signed=\(!((auth.signedUrl ?? "").isEmpty))")
            startConversationCallCounter += 1
            print("[connect] attempt=\(attempt) startConversation call=\(startConversationCallCounter)")
            let startedConversation: Conversation
            do {
                startedConversation = try await startConversation(auth: auth, config: runtimeConfig)
            } catch {
                guard shouldRetryConversationStart(after: error) else {
                    throw error
                }
                print("[connect] attempt=\(attempt) startConversation handshake failed; refreshing session-auth once")
                let retryAuth = try await fetchSessionAuth(agentId: agentId, dynamicVariables: runtimeDynamicVariables)
                let retryResponseAgentId = retryAuth.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !retryResponseAgentId.isEmpty, retryResponseAgentId != agentId {
                    throw AppError.httpError("Session auth agent uyuşmuyor. Beklenen: \(agentId), gelen: \(retryResponseAgentId)")
                }
                print("[connect] attempt=\(attempt) session-auth retry ok token=\(!((retryAuth.conversationToken ?? "").isEmpty)) signed=\(!((retryAuth.signedUrl ?? "").isEmpty))")
                startConversationCallCounter += 1
                print("[connect] attempt=\(attempt) startConversation retry call=\(startConversationCallCounter)")
                startedConversation = try await startConversation(auth: retryAuth, config: runtimeConfig)
            }
            conversation = startedConversation
            setupObservers(runId: runId, conversation: startedConversation)
            connectionState = .connecting
            statusLine = "Bağlantı doğrulanıyor..."
            startSessionHeartbeatIfNeeded()
            print("[connect] attempt=\(attempt) startConversation returned")
        } catch {
            isConversationActive = false
            connectionState = .failed
            statusLine = "Bağlantı başarısız"
            errorText = "Bağlantı kurulamadı: \(error.localizedDescription)"
            stopSessionHeartbeat()
            await releaseElevenSessionLock()
            print("[connect] attempt=\(attempt) failed error=\(String(reflecting: error))")
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
        guard connectionState == .connected, isConversationActive else {
            throw AppError.httpError("Önce vakayı başlatın.")
        }

#if canImport(ElevenLabs)
        guard let conversation else {
            throw AppError.httpError("Text oturumu hazır değil.")
        }
        isAwaitingReply = true
        agentState = .thinking
        appendLocalMessage(source: "user", text: clean, id: "user-local-\(UUID().uuidString)")
        print("[text-send] chars=\(clean.count)")
        Task { [weak self] in
            await self?.touchSessionLockIfPossible(reason: "text_send_preflight")
        }

        do {
            try await conversation.sendMessage(clean)
            print("[text-send] delivered")
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
                    print("[audio] reactivate failed error=\(String(reflecting: error))")
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

    private func setupObservers(runId: UUID, conversation: Conversation) {
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
                        print("[connect-state] idle(text) keep-connected runId=\(runId.uuidString) prev=\(self.connectionState)")
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
                    print("[connect-state] connecting")
                case .active:
                    self.isConversationActive = true
                    self.connectionState = .connected
                    self.statusLine = "Bağlandı"
                    self.connectedAt = Date()
                    print("[connect-state] active")
                    if self.activeMode == .voice {
                        do {
                            try self.prepareVoiceAudioSession()
                        } catch {
                            self.errorText = "Ses oturumu etkinleştirilemedi: \(error.localizedDescription)"
                            print("[audio] active-state prepare failed error=\(String(reflecting: error))")
                        }
                    }
                    self.startSessionHeartbeatIfNeeded()
                    Task { [weak self] in
                        await self?.touchSessionLockIfPossible(reason: "state_active")
                    }
                case .ended(let reason):
                    let diagnostic = self.unexpectedEndDiagnostic(reason)
                    let uptimeSec = self.connectedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                    print(
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
                    print("[connect-state] error runId=\(runId.uuidString) error=\(String(reflecting: error))")
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
    private func statusTextForEnd(_ reason: EndReason) -> String {
        switch reason {
        case .userEnded:
            return "Oturum kapandı"
        case .agentNotConnected:
            return "Agent bağlantısı kurulamadı"
        case .remoteDisconnected:
            return "Bağlantı kesildi"
        }
    }

    private func errorTextForUnexpectedEnd(_ reason: EndReason) -> String {
        let diagnostic = unexpectedEndDiagnostic(reason)
        return errorTextForUnexpectedEnd(reason, diagnostic: diagnostic)
    }

    private func errorTextForUnexpectedEnd(_ reason: EndReason, diagnostic: String) -> String {
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

    private func fetchSessionAuth(agentId: String,
                                  dynamicVariables: [String: String]) async throws -> ElevenLabsSessionAuthResponse {
        guard let appState else { throw AppError.sessionMissing }
        return try await appState.fetchElevenLabsSessionAuth(
            agentId: agentId,
            mode: activeMode == .text ? "text" : "voice",
            sessionWindowToken: sessionWindowToken,
            dynamicVariables: dynamicVariables
        )
    }

    private func buildDynamicVariables(from state: AppState) -> [String: String] {
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

    private func stopConversationAfterUnexpectedEnd() async {
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
    private func startConversation(auth: ElevenLabsSessionAuthResponse,
                                   config runtimeConfig: ConversationConfig) async throws -> Conversation {
        sessionWindowToken = auth.sessionWindowToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        elevenSessionReleased = false
        if let token = auth.conversationToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return try await ElevenLabs.startConversation(conversationToken: token, config: runtimeConfig)
        }

        if let signedUrl = auth.signedUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !signedUrl.isEmpty,
           let token = extractTokenFromSignedURL(signedUrl) {
            return try await ElevenLabs.startConversation(conversationToken: token, config: runtimeConfig)
        }

        throw AppError.httpError("ElevenLabs oturum tokenı alınamadı.")
    }
#endif

    private func extractTokenFromSignedURL(_ raw: String) -> String? {
        guard let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let keys = [
            "conversation_token",
            "conversationToken",
            "token",
            "access_token",
            "accessToken",
            "conversation_signature",
            "conversationSignature"
        ]
        for key in keys {
            if let value = queryItems.first(where: { $0.name == key })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func shouldRetryConversationStart(after error: Error) -> Bool {
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

    private func finalizeIfNeeded() async {
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
    private func releaseElevenSessionLock() async -> Bool {
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
            print("[session-lock] release failed agentId=\(agentId)")
        }
        return released
    }

    // Session window lock'i hem voice hem text modunda canli tutar.
    // Text oturumlarda SDK'nin `active` durumuna gecisi gecikirse `connecting` asamasinda da touch atmaya devam eder.
    private func startSessionHeartbeatIfNeeded() {
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

    private func touchSessionLockIfPossible(reason: String) async {
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
        print("[session-lock] touch reason=\(reason) agentId=\(agentId)")
    }

    private func stopSessionHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private var hasBackgroundAudioCapability: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("audio")
    }

    private func prepareVoiceAudioSession() throws {
        guard activeMode == .voice else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
        print("[EL] AVAudioSession category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        print("[EL] AVAudioSession otherAudioPlaying=\(session.isOtherAudioPlaying)")
        print("[EL] Mic permission=\(session.recordPermission.rawValue)")
    }

    private func deactivateVoiceAudioSessionIfNeeded() {
        guard activeMode == .voice else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[audio] deactivate failed error=\(String(reflecting: error))")
        }
    }

    private func installVoiceAudioObserversIfNeeded() {
        guard activeMode == .voice else { return }
        if audioInterruptionObserver == nil {
            audioInterruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioInterruption(notification)
                }
            }
        }
        if audioRouteChangeObserver == nil {
            audioRouteChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioRouteChange(notification)
                }
            }
        }
    }

    private func removeVoiceAudioObservers() {
        if let token = audioInterruptionObserver {
            NotificationCenter.default.removeObserver(token)
            audioInterruptionObserver = nil
        }
        if let token = audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(token)
            audioRouteChangeObserver = nil
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard activeMode == .voice else { return }
        guard let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }
        switch type {
        case .began:
            statusLine = "Ses kesintisi algılandı."
            print("[audio] interruption began")
            if connectionState == .connected, !isMicMuted {
                Task { try? await self.setMuted(true) }
            }
        case .ended:
            let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            print("[audio] interruption ended options=\(options.rawValue)")
            guard options.contains(.shouldResume) else {
                statusLine = "Ses kesintisi bitti. Devam etmek için tekrar konuş."
                return
            }
            do {
                try prepareVoiceAudioSession()
                statusLine = "Ses oturumu geri yüklendi."
            } catch {
                errorText = "Ses kesintisi sonrası oturum geri yüklenemedi: \(error.localizedDescription)"
            }
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard activeMode == .voice else { return }
        guard let userInfo = notification.userInfo,
              let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return
        }
        print("[audio] route change reason=\(reason.rawValue)")
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .routeConfigurationChange:
            do {
                try prepareVoiceAudioSession()
                if connectionState == .connected {
                    statusLine = "Ses aygıtı değişti. Oturum güncellendi."
                }
            } catch {
                errorText = "Ses aygıtı değişiminden sonra oturum güncellenemedi: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    private func startNetworkMonitorIfNeeded() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathStatus(path.status)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    private func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
        lastNetworkStatus = nil
        lastNetworkLossAt = nil
        lastNetworkRecoveryAt = nil
    }

    private func handleNetworkPathStatus(_ status: NWPath.Status) {
        let previous = lastNetworkStatus
        lastNetworkStatus = status
        let now = Date()
        if previous == status {
            return
        }
        print("[network] status=\(String(describing: status)) previous=\(String(describing: previous))")
        if status != .satisfied {
            lastNetworkLossAt = now
            if connectionState == .connected || connectionState == .connecting {
                statusLine = "İnternet bağlantısı kesildi. Bağlantı geri geldiğinde yeniden deneyebilirsin."
            }
            return
        }
        if previous == .unsatisfied || previous == .requiresConnection {
            lastNetworkRecoveryAt = now
            if connectionState == .failed || connectionState == .ended {
                errorText = "İnternet bağlantısı geri geldi. Oturumu yeniden başlatabilirsin."
            } else if connectionState == .connected {
                statusLine = "İnternet bağlantısı geri geldi."
            }
        }
    }

    private func didNetworkTransitionRecently(within seconds: TimeInterval = 20) -> Bool {
        let now = Date()
        if let lastNetworkLossAt, now.timeIntervalSince(lastNetworkLossAt) <= seconds {
            return true
        }
        if let lastNetworkRecoveryAt, now.timeIntervalSince(lastNetworkRecoveryAt) <= seconds {
            return true
        }
        return false
    }

    #if canImport(ElevenLabs)
    private func unexpectedEndDiagnostic(_ reason: EndReason) -> String {
        if endRequestedByUser {
            return "user_requested"
        }
        if let source = lastLocalEndSource, localEndCounter > 0 {
            return "local_end:\(source)"
        }
        switch reason {
        case .userEnded:
            if didNetworkTransitionRecently() {
                return "network_transition_or_keepalive_timeout"
            }
            return "sdk_userEnded_mapping_or_agent_end_call"
        case .agentNotConnected:
            return "agent_not_connected"
        case .remoteDisconnected:
            if didNetworkTransitionRecently() {
                return "network_transition"
            }
            return "remote_disconnected"
        }
    }
    #endif

    private func markLocalEnd(source: String) {
        localEndCounter += 1
        lastLocalEndSource = source
#if canImport(ElevenLabs)
        let conversationState = conversation.map { String(describing: $0.state) } ?? "nil"
#else
        let conversationState = "unavailable"
#endif
        print(
            "[LOCAL_END] #\(localEndCounter) source=\(source) mode=\(activeMode.rawValue) conn=\(connectionState) convo=\(conversationState) net=\(String(describing: lastNetworkStatus))"
        )
    }

    private func buildSavePayload(score: ScoreResponse?,
                                  status: String,
                                  endedAt: Date,
                                  transcript: [ConversationLine]) -> SaveCasePayload {
        SaveCasePayload(
            sessionId: config.id,
            mode: activeMode.rawValue,
            status: status,
            startedAt: Self.iso8601.string(from: startedAt),
            endedAt: Self.iso8601.string(from: endedAt),
            durationMin: max(1, Int(endedAt.timeIntervalSince(startedAt) / 60)),
            messageCount: transcript.count,
            difficulty: config.difficulty,
            caseContext: .init(
                title: score?.caseTitle ?? config.displayTitle,
                specialty: config.specialty,
                subtitle: config.displaySubtitle,
                challengeId: config.challengeId,
                challengeType: config.challengeType,
                expectedDiagnosis: score?.trueDiagnosis ?? config.expectedDiagnosis
            ),
            transcript: transcript,
            score: score
        )
    }

    private func flushConversationMessages() async {
#if canImport(ElevenLabs)
        guard let conversation else { return }
        let sdkMessages = conversation.messages
        guard !sdkMessages.isEmpty else { return }
        let mapped = sdkMessages.compactMap { raw -> Message? in
            let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let source = raw.role == .user ? "user" : "ai"
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "flush-\(UUID().uuidString)"
                : raw.id
            return Message(id: id, source: source, text: content, timestamp: raw.timestamp)
        }
        messages = dedupe(mapped)
        refreshTranscriptBuffer()
        isAwaitingReply = messages.last?.source == "user"
#endif
    }

    private func normalizedTranscript(_ lines: [ConversationLine]) -> [ConversationLine] {
        lines.compactMap { line in
            let text = line.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ConversationLine(source: canonicalSource(line.source), message: text, timestamp: line.timestamp)
        }
    }

    private func refreshTranscriptBuffer() {
        let normalized = normalizedTranscript(messages.map { $0.transcriptLine })
        guard !normalized.isEmpty else { return }
        if normalized.count >= transcriptBuffer.count {
            transcriptBuffer = normalized
        }
    }

    private func refreshUsageCounters() {
        var nextTextUserChars = 0
        var nextTextUserMessages = 0
        var nextTextAIChars = 0
        var nextTextAIMessages = 0
        var nextVoiceUserChars = 0
        var nextVoiceUserMessages = 0

        for line in normalizedTranscript(messages.map { $0.transcriptLine }) {
            let source = canonicalSource(line.source)
            let length = line.message.count
            if source == "user" {
                nextTextUserChars += length
                nextTextUserMessages += 1
                nextVoiceUserChars += length
                nextVoiceUserMessages += 1
            } else {
                nextTextAIChars += length
                nextTextAIMessages += 1
            }
        }

        textUserCharacterCount = nextTextUserChars
        textUserMessageCount = nextTextUserMessages
        textAICharacterCount = nextTextAIChars
        textAIMessageCount = nextTextAIMessages
        voiceUserTranscriptCharacterCount = nextVoiceUserChars
        voiceUserTranscriptMessageCount = nextVoiceUserMessages
    }

    private func enforceVoiceTranscriptLimitIfNeeded() {
        guard activeMode == .voice else { return }
        guard !sessionLimitReached else { return }
        guard voiceUserTranscriptCharacterCount >= voiceSessionTranscriptCharacterLimit else { return }
        sessionLimitReached = true
        let message = "Oturum transkript limiti doldu."
        errorText = message
        statusLine = message
        Task { [weak self] in
            await self?.end()
        }
    }

    private func dedupe(_ input: [Message]) -> [Message] {
        let sorted = input.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }

        var output: [Message] = []
        var seenById = Set<String>()
        var seenNearText: [String: Date] = [:]

        for item in sorted {
            if seenById.contains(item.id) {
                continue
            }
            seenById.insert(item.id)

            let fingerprint = "\(item.source)|\(normalize(item.text))"
            if let last = seenNearText[fingerprint], abs(item.timestamp.timeIntervalSince(last)) < nearTextDuplicateWindowSeconds {
                continue
            }
            seenNearText[fingerprint] = item.timestamp
            output.append(item)
        }
        return output
    }

    private func appendLocalMessage(source: String, text: String, id: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        messages = dedupe(messages + [Message(id: id, source: source, text: clean, timestamp: Date())])
        refreshTranscriptBuffer()
        refreshUsageCounters()
    }

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

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
        textUserCharacterCount = 0
        textUserMessageCount = 0
        textAICharacterCount = 0
        textAIMessageCount = 0
        voiceUserTranscriptCharacterCount = 0
        voiceUserTranscriptMessageCount = 0
        sessionLimitReached = false
        isConversationActive = false
        isStoppingUnexpectedly = false
    }
}
