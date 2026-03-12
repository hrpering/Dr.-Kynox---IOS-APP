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

enum MessageBubbleAccessoryAction {
    case openToolResult(toolCallId: String)
    case openImagingResults(anchorToolCallId: String)
}

struct MessageBubbleAccessory: Identifiable {
    let id: String
    let title: String
    let iconSystemName: String
    let tint: Color
    let action: MessageBubbleAccessoryAction
}

enum ToolCategory: String {
    case panel
    case vitals
    case imaging
}

enum ImagingResultSegment: String, CaseIterable, Identifiable {
    case all
    case xray
    case ecg
    case ct
    case mri
    case usg
    case echo
    case vq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .xray:
            return "X-Ray"
        case .ecg:
            return "ECG"
        case .ct:
            return "CT"
        case .mri:
            return "MRI"
        case .usg:
            return "USG"
        case .echo:
            return "ECHO"
        case .vq:
            return "V/Q"
        }
    }
}

enum ToolMetricStatus: String, Codable {
    case normal
    case high
    case low
    case critical
    case abnormal
    case positive
    case negative
    case borderline
    case unknown

    static func normalizedToken(_ rawStatus: String?) -> String {
        (rawStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
    }

    init(rawStatus: String?) {
        let clean = Self.normalizedToken(rawStatus)
        self = ToolMetricStatus(rawValue: clean) ?? .unknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode(String.self)
        self.init(rawStatus: raw)
    }

    var iconSystemName: String {
        switch self {
        case .normal, .negative:
            return "checkmark"
        case .high:
            return "arrow.up"
        case .low:
            return "arrow.down"
        case .critical:
            return "exclamationmark.triangle.fill"
        case .abnormal, .positive, .borderline, .unknown:
            return "exclamationmark"
        }
    }

    var accentColor: Color {
        switch self {
        case .normal, .negative:
            return AppColor.success
        case .critical:
            return AppColor.error
        case .high, .low, .abnormal, .positive, .borderline, .unknown:
            return AppColor.warning
        }
    }

    var cardBackground: Color {
        switch self {
        case .normal, .negative:
            return AppColor.surfaceAlt
        case .critical:
            return AppColor.errorLight
        case .high, .low, .abnormal, .positive, .borderline, .unknown:
            return AppColor.warningLight
        }
    }

    var severityScore: Int {
        switch self {
        case .normal, .negative:
            return 0
        case .unknown:
            return 1
        case .low, .high, .abnormal, .positive, .borderline:
            return 2
        case .critical:
            return 3
        }
    }

    static func mostSevere(_ lhs: ToolMetricStatus, _ rhs: ToolMetricStatus) -> ToolMetricStatus {
        lhs.severityScore >= rhs.severityScore ? lhs : rhs
    }
}

enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let object = try? decoder.singleValueContainer().decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        if let array = try? decoder.singleValueContainer().decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self = .string(string)
            return
        }
        if let number = try? decoder.singleValueContainer().decode(Double.self) {
            self = .number(number)
            return
        }
        if let bool = try? decoder.singleValueContainer().decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if (try? decoder.singleValueContainer().decodeNil()) == true {
            self = .null
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self {
            return object
        }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(format: "%.2f", value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

struct ToolMetricObject {
    let valueText: String
    let unit: String
    let status: ToolMetricStatus
    let statusProvided: Bool
    let statusInvalid: Bool

    init?(object: [String: JSONValue]) {
        let value = object.firstValue(suffix: "_value")?.displayText
        let description = object.firstValue(suffix: "_description")?.displayText
        let directValue = object["value"]?.displayText
        let directDescription = object["description"]?.displayText
        let displayText = [value, directValue, description, directDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !displayText.isEmpty else { return nil }
        valueText = displayText
        unit = (object.firstValue(suffix: "_unit")?.displayText ?? object["unit"]?.displayText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStatus = object.firstValue(suffix: "_status")?.displayText ?? object["status"]?.displayText
        let statusToken = ToolMetricStatus.normalizedToken(rawStatus)
        statusProvided = !statusToken.isEmpty
        status = ToolMetricStatus(rawStatus: rawStatus)
        statusInvalid = statusProvided && status == .unknown && statusToken != ToolMetricStatus.unknown.rawValue
    }
}

struct PanelMetric: Identifiable {
    let id: String
    let title: String
    let valueText: String
    let unit: String
    let status: ToolMetricStatus
    let referenceRange: String?
}

struct PanelToolResult {
    let toolName: String
    let title: String
    let metrics: [PanelMetric]
    let verbalSummary: String
}

struct VitalsMetric: Identifiable {
    let id: String
    let title: String
    let valueText: String
    let unit: String
    let status: ToolMetricStatus
}

struct VitalsToolResult {
    let toolName: String
    let title: String
    let metrics: [VitalsMetric]
    let verbalSummary: String
}

struct ImagingFinding: Identifiable {
    let id: String
    let title: String
    let detail: String
    let status: ToolMetricStatus
}

struct ImagingMetaItem: Identifiable {
    let id: String
    let title: String
    let value: String
}

struct ImagingToolResult {
    let toolName: String
    let title: String
    let segment: ImagingResultSegment
    let findings: [ImagingFinding]
    let metadata: [ImagingMetaItem]
    let impression: String
    let verbalSummary: String
}

enum ToolResultPayload {
    case panel(PanelToolResult)
    case vitals(VitalsToolResult)
    case imaging(ImagingToolResult)

    var category: ToolCategory {
        switch self {
        case .panel:
            return .panel
        case .vitals:
            return .vitals
        case .imaging:
            return .imaging
        }
    }
}

struct PendingToolResult {
    let toolCallId: String
    let toolName: String
    let payload: ToolResultPayload
    let createdAt: Date
}

struct ToolDescriptor {
    let toolName: String
    let category: ToolCategory
    let displayTitle: String
    let ctaTitle: String
    let iconSystemName: String
    let tint: Color
    let metricOrder: [String]
    let referenceRanges: [String: String]
    let imagingSegment: ImagingResultSegment?

    static let all: [ToolDescriptor] = [
        .init(
            toolName: "reveal_lab_cbc",
            category: .panel,
            displayTitle: "Complete Blood Count (CBC)",
            ctaTitle: "CBC Sonuçlarını Gör",
            iconSystemName: "drop.fill",
            tint: AppColor.primary,
            metricOrder: ["wbc", "hemoglobin", "hematocrit", "rbc", "mcv", "mch", "mchc", "rdw", "platelets", "neutrophils", "lymphocytes", "monocytes", "eosinophils", "basophils"],
            referenceRanges: [
                "wbc": "4.5-11.0 x10³/µL",
                "hemoglobin": "13.5-17.5 g/dL",
                "hematocrit": "41-53 %",
                "rbc": "4.5-5.5 x10⁶/µL",
                "mcv": "80-100 fL",
                "mch": "27-33 pg",
                "mchc": "32-36 g/dL",
                "rdw": "11.5-14.5 %",
                "platelets": "150-400 x10³/µL"
            ],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_bmp",
            category: .panel,
            displayTitle: "Basic Metabolic Panel (BMP)",
            ctaTitle: "BMP Sonuçlarını Gör",
            iconSystemName: "cross.case.fill",
            tint: AppColor.primary,
            metricOrder: ["glucose", "bun", "creatinine", "egfr", "sodium", "potassium", "chloride", "bicarbonate", "calcium", "anion_gap"],
            referenceRanges: [
                "glucose": "70-100 mg/dL",
                "bun": "7-20 mg/dL",
                "creatinine": "0.7-1.3 mg/dL",
                "egfr": ">60 mL/min/1.73m²",
                "sodium": "136-145 mEq/L",
                "potassium": "3.5-5.0 mEq/L",
                "chloride": "98-106 mEq/L",
                "bicarbonate": "22-29 mEq/L",
                "calcium": "8.5-10.5 mg/dL",
                "anion_gap": "8-16 mEq/L"
            ],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_cmp",
            category: .panel,
            displayTitle: "Comprehensive Metabolic Panel (CMP)",
            ctaTitle: "CMP Sonuçlarını Gör",
            iconSystemName: "cross.case.fill",
            tint: AppColor.primary,
            metricOrder: ["glucose", "bun", "creatinine", "egfr", "sodium", "potassium", "chloride", "bicarbonate", "calcium", "alt", "ast", "alp", "total_bilirubin", "albumin", "total_protein", "anion_gap"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_lipid",
            category: .panel,
            displayTitle: "Lipid Panel",
            ctaTitle: "Lipid Sonuçlarını Gör",
            iconSystemName: "drop.circle.fill",
            tint: AppColor.warning,
            metricOrder: ["total_cholesterol", "ldl", "hdl", "triglycerides", "vldl", "non_hdl", "cholesterol_hdl_ratio"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_thyroid",
            category: .panel,
            displayTitle: "Thyroid Panel",
            ctaTitle: "Tiroid Sonuçlarını Gör",
            iconSystemName: "waveform.path.ecg",
            tint: AppColor.primary,
            metricOrder: ["tsh", "free_t4", "free_t3", "total_t4", "total_t3", "anti_tpo", "anti_tg"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_vitals",
            category: .vitals,
            displayTitle: "Vital Signs",
            ctaTitle: "Vital Bulguları Gör",
            iconSystemName: "heart.text.square.fill",
            tint: AppColor.primary,
            metricOrder: ["blood_pressure_systolic", "blood_pressure_diastolic", "heart_rate", "respiratory_rate", "oxygen_saturation", "temperature", "gcs", "pain_score"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_cardiac",
            category: .panel,
            displayTitle: "Cardiac Markers",
            ctaTitle: "Kardiyak Sonuçları Gör",
            iconSystemName: "heart.fill",
            tint: AppColor.error,
            metricOrder: ["troponin_i", "troponin_t", "ck_mb", "bnp", "nt_probnp", "myoglobin"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_lft",
            category: .panel,
            displayTitle: "Liver Function Tests (LFT)",
            ctaTitle: "LFT Sonuçlarını Gör",
            iconSystemName: "cross.vial.fill",
            tint: AppColor.warning,
            metricOrder: ["alt", "ast", "alp", "ggt", "total_bilirubin", "direct_bilirubin", "albumin", "total_protein"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_abg",
            category: .panel,
            displayTitle: "Arterial Blood Gas (ABG)",
            ctaTitle: "ABG Sonuçlarını Gör",
            iconSystemName: "lungs.fill",
            tint: AppColor.primary,
            metricOrder: ["ph", "paco2", "pao2", "hco3", "sao2", "base_excess", "lactate"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_coag",
            category: .panel,
            displayTitle: "Coagulation Panel",
            ctaTitle: "Koagülasyon Sonuçlarını Gör",
            iconSystemName: "drop.circle",
            tint: AppColor.error,
            metricOrder: ["pt", "inr", "aptt", "fibrinogen", "d_dimer"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_lab_urinalysis",
            category: .panel,
            displayTitle: "Urinalysis",
            ctaTitle: "İdrar Sonuçlarını Gör",
            iconSystemName: "testtube.2",
            tint: AppColor.primary,
            metricOrder: ["color", "ph", "specific_gravity", "protein", "glucose", "ketones", "blood", "leukocyte_esterase", "nitrite", "wbc_count", "rbc_count"],
            referenceRanges: [:],
            imagingSegment: nil
        ),
        .init(
            toolName: "reveal_imaging_cxr",
            category: .imaging,
            displayTitle: "Chest X-Ray (PA)",
            ctaTitle: "Akciğer Grafisi Sonuçlarını Gör",
            iconSystemName: "xray",
            tint: AppColor.primary,
            metricOrder: ["cardiac_silhouette", "lung_fields", "pleural_space", "mediastinum", "bony_structures"],
            referenceRanges: [:],
            imagingSegment: .xray
        ),
        .init(
            toolName: "reveal_imaging_ecg",
            category: .imaging,
            displayTitle: "ECG / EKG",
            ctaTitle: "EKG Sonuçlarını Gör",
            iconSystemName: "waveform.path.ecg.rectangle",
            tint: AppColor.primary,
            metricOrder: ["rate", "rhythm", "axis", "p_wave", "pr_interval", "qrs_complex", "st_segment", "t_wave", "qtc_interval"],
            referenceRanges: [:],
            imagingSegment: .ecg
        ),
        .init(
            toolName: "reveal_imaging_ct",
            category: .imaging,
            displayTitle: "CT Scan",
            ctaTitle: "CT Sonuçlarını Gör",
            iconSystemName: "viewfinder.circle",
            tint: AppColor.primary,
            metricOrder: ["primary_finding", "secondary_findings", "vascular"],
            referenceRanges: [:],
            imagingSegment: .ct
        ),
        .init(
            toolName: "reveal_imaging_mri",
            category: .imaging,
            displayTitle: "MRI",
            ctaTitle: "MRI Sonuçlarını Gör",
            iconSystemName: "waveform.circle",
            tint: AppColor.error,
            metricOrder: ["primary_finding", "secondary_findings"],
            referenceRanges: [:],
            imagingSegment: .mri
        ),
        .init(
            toolName: "reveal_imaging_usg",
            category: .imaging,
            displayTitle: "Ultrasound (USG)",
            ctaTitle: "USG Sonuçlarını Gör",
            iconSystemName: "dot.radiowaves.left.and.right",
            tint: AppColor.primary,
            metricOrder: ["primary_organ", "secondary_findings", "doppler"],
            referenceRanges: [:],
            imagingSegment: .usg
        ),
        .init(
            toolName: "reveal_imaging_echo",
            category: .imaging,
            displayTitle: "Echocardiography",
            ctaTitle: "EKO Sonuçlarını Gör",
            iconSystemName: "heart.circle.fill",
            tint: AppColor.primary,
            metricOrder: ["lvef", "lv_function", "valves", "pericardium", "right_heart"],
            referenceRanges: [:],
            imagingSegment: .echo
        ),
        .init(
            toolName: "reveal_imaging_vq",
            category: .imaging,
            displayTitle: "V/Q Scan",
            ctaTitle: "V/Q Sonuçlarını Gör",
            iconSystemName: "wind",
            tint: AppColor.warning,
            metricOrder: ["ventilation", "perfusion", "vq_mismatch"],
            referenceRanges: [:],
            imagingSegment: .vq
        )
    ]

    static let byName: [String: ToolDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.toolName, $0) })
}

extension Dictionary where Key == String, Value == JSONValue {
    func firstValue(suffix: String) -> JSONValue? {
        let exact = valuesMatching(suffix: suffix)
        return exact.first
    }

    private func valuesMatching(suffix: String) -> [JSONValue] {
        keys
            .filter { $0.hasSuffix(suffix) }
            .sorted()
            .compactMap { self[$0] }
    }
}

extension JSONValue {
    var displayText: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(format: "%.2f", value)
        case .bool(let value):
            return value ? "Pozitif" : "Negatif"
        default:
            return nil
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
    @Published var pendingToolResults: [PendingToolResult] = []
    @Published var messageAccessoriesByMessageId: [String: [MessageBubbleAccessory]] = [:]
    @Published var toolCallMessageIdMap: [String: String] = [:]
    @Published var toolCallNameMap: [String: String] = [:]
    @Published var resultsByToolCallId: [String: ToolResultPayload] = [:]

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
    var isConversationActive = false
    var didReachActiveState = false
    var lastDisconnectDiagnostic: String?
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
    var handledToolCallIds = Set<String>()

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

    func resetToolAccessoryState() {
        pendingToolResults = []
        messageAccessoriesByMessageId = [:]
        toolCallMessageIdMap = [:]
        toolCallNameMap = [:]
        resultsByToolCallId = [:]
        handledToolCallIds = []
    }
}
