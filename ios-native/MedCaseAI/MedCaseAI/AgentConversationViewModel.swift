import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI
import OSLog

#if canImport(ElevenLabs)
import ElevenLabs
#endif

enum AppLogLevel: Int {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4
    case fault = 5

    init?(name: String) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "debug":
            self = .debug
        case "info":
            self = .info
        case "notice":
            self = .notice
        case "warning", "warn":
            self = .warning
        case "error":
            self = .error
        case "fault":
            self = .fault
        default:
            return nil
        }
    }
}

enum AppLogCategory: String {
    case agentConversation = "agent-conversation"
    case caseSession = "case-session"
}

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MedCaseAI"

    private static let minimumLevel: AppLogLevel = {
        if let envLevel = ProcessInfo.processInfo.environment["APP_LOG_LEVEL"],
           let parsed = AppLogLevel(name: envLevel) {
            return parsed
        }
        if let defaultsLevel = UserDefaults.standard.string(forKey: "app_log_level"),
           let parsed = AppLogLevel(name: defaultsLevel) {
            return parsed
        }
#if DEBUG
        return .debug
#else
        return .warning
#endif
    }()

    static func log(_ message: @autoclosure () -> String, level: AppLogLevel, category: AppLogCategory) {
        guard level.rawValue >= minimumLevel.rawValue else { return }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        let text = message()

        switch level {
        case .debug:
            logger.debug("\(text, privacy: .private)")
        case .info:
            logger.info("\(text, privacy: .private)")
        case .notice:
            logger.notice("\(text, privacy: .private)")
        case .warning:
            logger.notice("warning: \(text, privacy: .private)")
        case .error:
            logger.error("\(text, privacy: .private)")
        case .fault:
            logger.fault("\(text, privacy: .private)")
        }
    }
}

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
    var conversation: Conversation?
#endif

    var cancellables = Set<AnyCancellable>()
    weak var appState: AppState?
    var isFinalized = false
    var endRequestedByUser = false
    var sessionWindowToken: String?
    var connectedAgentId: String?
    var connectAttemptCounter = 0
    var launchModeOverride: CaseLaunchConfig.Mode?
    var activeMode: CaseLaunchConfig.Mode
    var elevenSessionReleased = false
    var heartbeatTask: Task<Void, Never>?
    var transcriptBuffer: [ConversationLine] = []
    var textUserCharacterCount = 0
    var textUserMessageCount = 0
    var textAICharacterCount = 0
    var textAIMessageCount = 0
    var voiceUserTranscriptCharacterCount = 0
    var voiceUserTranscriptMessageCount = 0
    var sessionLimitReached = false
    var isConversationActive = false
    var isStoppingUnexpectedly = false
    var isConnectInFlight = false
    var activeConnectionRunId = UUID()
    var audioInterruptionObserver: NSObjectProtocol?
    var audioRouteChangeObserver: NSObjectProtocol?
    var networkMonitor: NWPathMonitor?
    let networkMonitorQueue = DispatchQueue(label: "com.medcaseai.elevenlabs.network-monitor")
    var lastNetworkStatus: NWPath.Status?
    var lastNetworkLossAt: Date?
    var lastNetworkRecoveryAt: Date?
    var connectedAt: Date?
    var localEndCounter = 0
    var lastLocalEndSource: String?
    var startConversationCallCounter = 0

    let voiceSessionTranscriptCharacterLimit = 7000
    let sessionHeartbeatIntervalSec: UInt64 = 8
    let nearTextDuplicateWindowSeconds: TimeInterval = 2.5

    let voiceAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    let textAgentId = "agent_3701kj62fctpe75v3a0tca39fy26"
    static let iso8601 = ISO8601DateFormatter()

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
            logInfo("[connect] attempt=\(attempt) session-auth ok token=\(!((auth.conversationToken ?? "").isEmpty)) signed=\(!((auth.signedUrl ?? "").isEmpty))")
            startConversationCallCounter += 1
            logDebug("[connect] attempt=\(attempt) startConversation call=\(startConversationCallCounter)")
            let startedConversation: Conversation
            do {
                startedConversation = try await startConversation(auth: auth, config: runtimeConfig)
            } catch {
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
                logInfo("[connect] attempt=\(attempt) session-auth retry ok token=\(!((retryAuth.conversationToken ?? "").isEmpty)) signed=\(!((retryAuth.signedUrl ?? "").isEmpty))")
                startConversationCallCounter += 1
                logDebug("[connect] attempt=\(attempt) startConversation retry call=\(startConversationCallCounter)")
                startedConversation = try await startConversation(auth: retryAuth, config: runtimeConfig)
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

    func logDebug(_ message: @autoclosure () -> String) {
        AppLog.log(message(), level: .debug, category: .agentConversation)
    }

    func logInfo(_ message: @autoclosure () -> String) {
        AppLog.log(message(), level: .info, category: .agentConversation)
    }

    func logWarning(_ message: @autoclosure () -> String) {
        AppLog.log(message(), level: .warning, category: .agentConversation)
    }

    func logError(_ message: @autoclosure () -> String) {
        AppLog.log(message(), level: .error, category: .agentConversation)
    }
}
