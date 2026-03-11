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
