import Foundation

struct PublicConfig: Decodable {
    let supabaseUrl: String
    let supabaseAnonKey: String
    let authorizationUrl: String?
    let sentryEnabled: Bool?
}

struct BasicResponse: Decodable {
    let ok: Bool
}

struct PushDeviceRegisterResponse: Decodable {
    let ok: Bool
}

struct InAppBanner: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let deepLink: String?
    let createdAt: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case deepLink = "deep_link"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct InAppBannerResponse: Decodable {
    let ok: Bool
    let banner: InAppBanner?
}

struct DeleteDataResponse: Decodable {
    let ok: Bool
    let deletedCaseSessions: Int?
    let profileReset: Bool?
}

struct DeleteAccountResponse: Decodable {
    let ok: Bool
    let deletedCaseSessions: Int?
    let deletedProfiles: Int?
    let deletedAuthUser: Bool?
}

struct ErrorResponse: Decodable {
    let error: String
    let code: String?
}

struct UserProfile: Codable {
    let id: String
    let email: String
    let fullName: String
    let phoneNumber: String
    let onboardingCompleted: Bool
    let marketingOptIn: Bool
    let ageRange: String
    let role: String
    let goals: [String]
    let interestAreas: [String]
    let learningLevel: String

    static let empty = UserProfile(
        id: "",
        email: "",
        fullName: "",
        phoneNumber: "",
        onboardingCompleted: false,
        marketingOptIn: false,
        ageRange: "",
        role: "",
        goals: [],
        interestAreas: [],
        learningLevel: ""
    )

    var firstName: String {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        return String(name.split(separator: " ").first ?? "")
    }
}

struct ProfileRow: Codable {
    let id: String
    let email: String?
    let fullName: String?
    let phoneNumber: String?
    let marketingOptIn: Bool?
    let onboardingCompleted: Bool?
    let ageRange: String?
    let role: String?
    let goals: [String]?
    let interestAreas: [String]?
    let learningLevel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case phoneNumber = "phone_number"
        case marketingOptIn = "marketing_opt_in"
        case onboardingCompleted = "onboarding_completed"
        case ageRange = "age_range"
        case role
        case goals
        case interestAreas = "interest_areas"
        case learningLevel = "learning_level"
    }

    func normalized() -> UserProfile {
        UserProfile(
            id: id,
            email: (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            fullName: (fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            phoneNumber: (phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            onboardingCompleted: onboardingCompleted ?? false,
            marketingOptIn: marketingOptIn ?? false,
            ageRange: (ageRange ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            role: (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            goals: goals ?? [],
            interestAreas: interestAreas ?? [],
            learningLevel: (learningLevel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct DailyChallengeBundle {
    let challenge: DailyChallenge
    let timeLeft: ChallengeTimeLeft
    let stats: ChallengeStats?
}

struct ChallengeTimeLeft: Codable {
    let expiresAt: String?
    let minutesLeft: Int?
    let hoursLeft: Double?

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
        case minutesLeft = "minutes_left"
        case hoursLeft = "hours_left"
    }

    var label: String {
        if let hoursLeft {
            let roundedHours = max(0, Int(ceil(hoursLeft)))
            return "\(roundedHours) saat kaldı"
        }
        if let minutesLeft {
            let roundedMinutes = max(0, minutesLeft)
            return "\(roundedMinutes) dk"
        }
        return "--"
    }
}

struct ChallengeStats: Codable {
    let attemptedUsers: Int?
    let participantCount: Int?
    let averageScore: Double?

    enum CodingKeys: String, CodingKey {
        case attemptedUsers = "attempted_users"
        case participantCount = "participant_count"
        case averageScore = "average_score"
    }
}

struct DailyChallenge: Decodable {
    let id: String
    let type: String?
    let title: String
    let summary: String
    let specialty: String
    let difficulty: String
    let chiefComplaint: String?
    let patientGender: String?
    let patientAge: Int?
    let expectedDiagnosis: String?
    let durationMin: Int?
    let bonusPoints: Int?
    let generatedAt: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case summary
        case specialty
        case difficulty
        case chiefComplaint = "chief_complaint"
        case patientGender = "patient_gender"
        case patientAge = "patient_age"
        case expectedDiagnosis = "expected_diagnosis"
        case durationMin = "duration_min"
        case bonusPoints = "bonus_points"
        case generatedAt = "generated_at"
        case expiresAt = "expires_at"
    }
}

struct CaseListResponse: Decodable {
    let cases: [CaseSession]
}

struct CaseSession: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let mode: String
    let status: String
    let startedAt: String?
    let endedAt: String?
    let durationMin: Int?
    let messageCount: Int?
    let difficulty: String?
    let caseContext: CaseContext?
    let transcript: [ConversationLine]?
    let score: ScoreResponse?
    let updatedAt: String?

    struct CaseContext: Codable {
        let title: String?
        let specialty: String?
        let subtitle: String?
        let challengeId: String?
        let challengeType: String?
        let expectedDiagnosis: String?

        enum CodingKeys: String, CodingKey {
            case title
            case specialty
            case subtitle
            case challengeId = "challenge_id"
            case challengeType = "challenge_type"
            case expectedDiagnosis = "expected_diagnosis"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case mode
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMin = "duration_min"
        case messageCount = "message_count"
        case difficulty
        case caseContext = "case_context"
        case transcript
        case score
        case updatedAt = "updated_at"
    }

    var caseTitle: String {
        let value = caseContext?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Klinik Vaka" : value
    }

    var specialty: String {
        let value = caseContext?.specialty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Genel Tıp" : value
    }

    var difficultyLabel: String {
        let value = difficulty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Random" : value
    }
}

struct OnboardingPayload: Encodable {
    let fullName: String
    let phoneNumber: String
    let marketingOptIn: Bool
    let ageRange: String
    let role: String
    let goals: [String]
    let interestAreas: [String]
    let learningLevel: String
    let onboardingCompleted: Bool
}

struct StudyPlanSnapshot: Equatable {
    let examTarget: String
    let examWindow: String
    let cadence: String
    let dailyMinutes: Int
    let recommendedWeeklyTarget: Int

    static let empty = StudyPlanSnapshot(
        examTarget: "",
        examWindow: "",
        cadence: "",
        dailyMinutes: 0,
        recommendedWeeklyTarget: 5
    )

    var isConfigured: Bool {
        !examTarget.isEmpty && !examWindow.isEmpty && dailyMinutes > 0
    }

    var compactLabel: String {
        guard isConfigured else { return "Plan ayarlanmadı" }
        return "\(examTarget) · \(cadence) · \(dailyMinutes) dk/gün"
    }

    var signature: String {
        "\(examTarget)|\(examWindow)|\(cadence)|\(dailyMinutes)|\(recommendedWeeklyTarget)"
    }

    static func from(profile: UserProfile?) -> StudyPlanSnapshot {
        guard let profile else { return .empty }
        let goals = profile.goals

        let examTarget = value(forPrefix: "Hedef sınav:", in: goals)
            ?? value(forPrefix: "Hedef sinav:", in: goals)
            ?? ""

        let examWindow = value(forPrefix: "Sınava kalan süre:", in: goals)
            ?? value(forPrefix: "Sinava kalan sure:", in: goals)
            ?? ""

        let cadence = value(forPrefix: "Plan modu:", in: goals)
            ?? cadenceFromLearningLevel(profile.learningLevel)

        let dailyMinutes = minutesFromGoals(goals) ?? 0
        let recommendedWeeklyTarget = recommendWeeklyTarget(
            dailyMinutes: dailyMinutes,
            cadence: cadence
        )

        return StudyPlanSnapshot(
            examTarget: examTarget,
            examWindow: examWindow,
            cadence: cadence,
            dailyMinutes: dailyMinutes,
            recommendedWeeklyTarget: recommendedWeeklyTarget
        )
    }

    private static func value(forPrefix prefix: String, in goals: [String]) -> String? {
        goals.first { item in
            item.lowercased(with: Locale(identifier: "tr_TR"))
                .hasPrefix(prefix.lowercased(with: Locale(identifier: "tr_TR")))
        }?
        .replacingOccurrences(of: prefix, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func minutesFromGoals(_ goals: [String]) -> Int? {
        for line in goals {
            let numbers = line
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
            if let first = numbers.first, line.lowercased(with: Locale(identifier: "tr_TR")).contains("dakika") {
                return max(15, min(240, first))
            }
        }
        return nil
    }

    private static func cadenceFromLearningLevel(_ learningLevel: String) -> String {
        let value = learningLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Dengeli" }
        if value.contains("Yoğun") || value.contains("Yogun") { return "Yoğun" }
        if value.contains("Düzenli") || value.contains("Duzenli") { return "Düzenli" }
        if value.contains("Dengeli") { return "Dengeli" }
        return "Dengeli"
    }

    private static func recommendWeeklyTarget(dailyMinutes: Int, cadence: String) -> Int {
        let base: Int
        let normalized = cadence.lowercased(with: Locale(identifier: "tr_TR"))
        if normalized.contains("yoğun") || normalized.contains("yogun") {
            base = 6
        } else if normalized.contains("düzenli") || normalized.contains("duzenli") {
            base = 4
        } else {
            base = 5
        }

        let bonus: Int
        switch dailyMinutes {
        case ..<30: bonus = -1
        case 30..<60: bonus = 0
        case 60..<90: bonus = 1
        default: bonus = 2
        }

        return max(2, min(14, base + bonus))
    }
}

struct WeeklyGoalFocus: Equatable {
    let title: String
    let recommendedSpecialty: String
    let recommendedSpecialtyLabel: String
    let recommendedDifficulty: String
    let focusDimensionKey: String?
    let focusDimensionLabel: String?
    let focusDimensionScore: Double?
    let suggestedWeeklyTarget: Int?
    let generatedAt: Date

    var summaryLine: String {
        if let focusDimensionLabel {
            return "\(recommendedSpecialtyLabel) · \(focusDimensionLabel)"
        }
        return "\(recommendedSpecialtyLabel) odağı"
    }
}

struct CaseLaunchConfig: Identifiable, Codable {
    enum Mode: String, Codable {
        case text
        case voice
    }

    let id: String
    let mode: Mode
    let challengeType: String
    let challengeId: String?
    let title: String?
    let summary: String?
    let specialty: String
    let difficulty: String
    let chiefComplaint: String?
    let patientGender: String?
    let patientAge: Int?
    let expectedDiagnosis: String?

    init(
        id: String = UUID().uuidString,
        mode: Mode,
        challengeType: String,
        challengeId: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        specialty: String,
        difficulty: String,
        chiefComplaint: String? = nil,
        patientGender: String? = nil,
        patientAge: Int? = nil,
        expectedDiagnosis: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.challengeType = challengeType
        self.challengeId = challengeId
        self.title = title
        self.summary = summary
        self.specialty = specialty
        self.difficulty = difficulty
        self.chiefComplaint = chiefComplaint
        self.patientGender = patientGender
        self.patientAge = patientAge
        self.expectedDiagnosis = expectedDiagnosis
    }

    var displayTitle: String {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        return challengeType == "daily" ? "Bugünün Vaka Meydan Okuması" : "Rastgele Klinik Vaka"
    }

    var displaySubtitle: String {
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary
        }
        if let chiefComplaint, !chiefComplaint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chiefComplaint
        }
        return "Klinik akış görüşme sırasında oluşacak."
    }

    var agentSeedPrompt: String {
        var lines = [
            "UYGULAMA_VAKA_PARAMETRELERI",
            "specialty: \(specialty)",
            "difficulty_level: \(difficulty)",
            "challenge_type: \(challengeType)",
            "KESIN_KURAL: Vaka bu specialty ve difficulty_level ile birebir uyumlu olacak."
        ]

        if challengeType == "daily" {
            lines.append("case_title: \(title ?? "Belirtilmedi")")
            lines.append("chief_complaint: \(chiefComplaint ?? "Belirtilmedi")")
            let patient = [patientGender, patientAge.map { "\($0) yas" }]
                .compactMap { $0 }
                .joined(separator: ", ")
            lines.append("patient: \(patient.isEmpty ? "Belirtilmedi" : patient)")
            lines.append("expected_diagnosis_hidden: \(expectedDiagnosis ?? "Belirtilmedi")")
        }

        return lines.joined(separator: "\n")
    }

    var dynamicVariables: [String: String] {
        var vars: [String: String] = [
            "specialty": specialty,
            "difficulty": difficulty,
            "difficulty_level": difficulty,
            "challenge_type": challengeType,
            "mode": mode.rawValue,
            "session_id": id
        ]

        if let challengeId, !challengeId.isEmpty {
            vars["challenge_id"] = challengeId
        }
        if let title, !title.isEmpty {
            vars["case_title"] = title
        }
        if let chiefComplaint, !chiefComplaint.isEmpty {
            vars["chief_complaint"] = chiefComplaint
        }
        if let expectedDiagnosis, !expectedDiagnosis.isEmpty {
            vars["expected_diagnosis_hidden"] = expectedDiagnosis
        }
        if let patientGender, !patientGender.isEmpty {
            vars["patient_gender"] = patientGender
        }
        if let patientAge {
            vars["patient_age"] = String(patientAge)
        }
        return vars
    }
}

struct GeneratorReplayContext: Equatable {
    let specialty: String
    let difficulty: String
}

struct ElevenLabsSessionAuthResponse: Decodable {
    let agentId: String?
    let conversationToken: String?
    let signedUrl: String?
    let expiresInSeconds: Int?
    let sessionWindowToken: String?
    let sessionWindowExpiresAt: String?
    let sessionActiveWindowEndsAt: String?

    enum CodingKeys: String, CodingKey {
        case agentId
        case conversationToken
        case signedUrl
        case expiresInSeconds
        case sessionWindowToken
        case sessionWindowExpiresAt
        case sessionActiveWindowEndsAt
    }
}

struct ConversationLine: Codable {
    let source: String
    let message: String
    let timestamp: Int
}

enum FlashcardReviewRating: String, Codable, CaseIterable {
    case again
    case hard
    case easy

    var title: String {
        switch self {
        case .again: return "Bilmiyordum"
        case .hard: return "Zordu"
        case .easy: return "Kolaydı"
        }
    }

    var subtitle: String {
        switch self {
        case .again: return "Yarın tekrar"
        case .hard: return "3 gün sonra"
        case .easy: return "7+ gün sonra"
        }
    }
}

struct FlashcardDraft: Codable, Identifiable, Hashable {
    let id: String
    let cardType: String
    let title: String
    let front: String
    let back: String
    let specialty: String?
    let difficulty: String?
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case cardType
        case title
        case front
        case back
        case specialty
        case difficulty
        case tags
    }
}

struct FlashcardItem: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String?
    let sourceId: String?
    let cardType: String
    let specialty: String?
    let difficulty: String?
    let title: String
    let front: String
    let back: String
    let tags: [String]
    let intervalDays: Int?
    let repetitionCount: Int?
    let easeFactor: Double?
    let dueAt: String?
    let lastReviewedAt: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case sourceId
        case cardType
        case specialty
        case difficulty
        case title
        case front
        case back
        case tags
        case intervalDays
        case repetitionCount
        case easeFactor
        case dueAt
        case lastReviewedAt
        case createdAt
        case updatedAt
    }
}

struct FlashcardGenerateResponse: Decodable {
    let ok: Bool?
    let cards: [FlashcardDraft]
    let generatedCount: Int?
    let promptVersion: String?
    let fallbackUsed: Bool?
    let source: String?
}

struct FlashcardSaveResponse: Decodable {
    let ok: Bool?
    let savedCount: Int?
    let cards: [FlashcardItem]?
}

struct FlashcardTodayResponse: Decodable {
    let ok: Bool?
    let cards: [FlashcardItem]
    let dueCount: Int?
}

struct FlashcardCollectionsResponse: Decodable {
    struct Stats: Codable {
        let total: Int?
        let dueToday: Int?
        let bySpecialty: [String: Int]?
        let byCardType: [String: Int]?
    }

    let ok: Bool?
    let cards: [FlashcardItem]
    let stats: Stats?
}

struct FlashcardReviewResponse: Decodable {
    let ok: Bool?
    let card: FlashcardItem?
    let nextDueAt: String?
}

struct WeakAreaAnalysisResponse: Decodable {
    let generatedAt: String?
    let summary: WeakAreaSummary
    let scoreMap: WeakAreaScoreMap
    let specialtyBreakdown: [WeakAreaSpecialtyStat]
    let aiRecommendation: WeakAreaRecommendation?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case summary
        case scoreMap = "score_map"
        case specialtyBreakdown = "specialty_breakdown"
        case aiRecommendation = "ai_recommendation"
    }

    var hasData: Bool {
        summary.userCaseCount > 0 && !specialtyBreakdown.isEmpty
    }

    static func localFallback(from sessions: [CaseSession], weeklyTarget: Int) -> WeakAreaAnalysisResponse {
        let scored = sessions.compactMap { session -> (CaseSession, ScoreResponse)? in
            guard let score = session.score else { return nil }
            return (session, score)
        }

        let userCaseCount = scored.count
        let userAverage = userCaseCount > 0
            ? weakAreaRound(scored.map { weakAreaScoreToPercent($0.1.overallScore) }.reduce(0, +) / Double(userCaseCount))
            : 0

        var dimensionTotals: [String: (sum: Double, count: Int)] = [:]
        for item in scored {
            for dimension in item.1.dimensions {
                let clean = weakAreaScoreToPercent(dimension.score)
                let current = dimensionTotals[dimension.key] ?? (0, 0)
                dimensionTotals[dimension.key] = (current.sum + clean, current.count + 1)
            }
        }

        let axes = weakAreaDimensionCatalog.map {
            WeakAreaScoreMap.Axis(key: $0.key, label: $0.label, shortLabel: $0.shortLabel)
        }
        let axisUserValues = weakAreaDimensionCatalog.map { item -> Double in
            let current = dimensionTotals[item.key]
            guard let current, current.count > 0 else { return userAverage }
            return weakAreaRound(current.sum / Double(current.count))
        }

        var specialtyAgg: [String: WeakAreaSpecialtyAggregate] = [:]
        for (session, score) in scored {
            let specialty = weakAreaNormalizedSpecialty(session.specialty)
            var aggregate = specialtyAgg[specialty] ?? .init()
            aggregate.caseCount += 1
            aggregate.overallSum += weakAreaScoreToPercent(score.overallScore)
            let difficulty = session.difficultyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !difficulty.isEmpty {
                aggregate.difficultyCounts[difficulty, default: 0] += 1
            }
            for dimension in score.dimensions {
                let clean = weakAreaScoreToPercent(dimension.score)
                let current = aggregate.dimensionTotals[dimension.key] ?? (0, 0)
                aggregate.dimensionTotals[dimension.key] = (current.sum + clean, current.count + 1)
            }
            specialtyAgg[specialty] = aggregate
        }

        let breakdown = specialtyAgg
            .map { (specialty, aggregate) -> WeakAreaSpecialtyStat in
                let average = aggregate.caseCount > 0
                    ? weakAreaRound(aggregate.overallSum / Double(aggregate.caseCount))
                    : 0
                let dimensions = weakAreaDimensionCatalog.map { item -> WeakAreaSpecialtyDimension in
                    let metric = aggregate.dimensionTotals[item.key]
                    let userAverageScore = metric != nil && metric!.count > 0
                        ? weakAreaRound(metric!.sum / Double(metric!.count))
                        : average
                    return WeakAreaSpecialtyDimension(
                        key: item.key,
                        label: item.label,
                        userAverageScore: userAverageScore,
                        globalAverageScore: userAverageScore,
                        userCaseCount: metric?.count ?? aggregate.caseCount,
                        globalCaseCount: metric?.count ?? aggregate.caseCount
                    )
                }
                let weakest = dimensions.min { $0.userAverageScore < $1.userAverageScore } ?? dimensions.first
                return WeakAreaSpecialtyStat(
                    specialty: specialty,
                    specialtyLabel: specialty,
                    userAverageScore: average,
                    globalAverageScore: average,
                    userCaseCount: aggregate.caseCount,
                    globalCaseCount: aggregate.caseCount,
                    recommendedDifficulty: aggregate.mostUsedDifficulty,
                    weakestDimensionKey: weakest?.key,
                    weakestDimensionLabel: weakest?.label,
                    weakestDimensionScore: weakest?.userAverageScore,
                    dimensions: dimensions
                )
            }
            .sorted { left, right in
                if left.userAverageScore == right.userAverageScore {
                    return left.userCaseCount > right.userCaseCount
                }
                return left.userAverageScore < right.userAverageScore
            }

        let recommendation = WeakAreaRecommendation.localFallback(
            breakdown: breakdown,
            target: weeklyTarget
        )

        return WeakAreaAnalysisResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            summary: WeakAreaSummary(
                userCaseCount: userCaseCount,
                userAverageScore: userAverage,
                globalAverageScore: userAverage
            ),
            scoreMap: WeakAreaScoreMap(
                axes: axes,
                userValues: axisUserValues,
                globalValues: axisUserValues
            ),
            specialtyBreakdown: breakdown,
            aiRecommendation: recommendation
        )
    }
}

struct WeakAreaSummary: Decodable {
    let userCaseCount: Int
    let userAverageScore: Double
    let globalAverageScore: Double

    enum CodingKeys: String, CodingKey {
        case userCaseCount = "user_case_count"
        case userAverageScore = "user_average_score"
        case globalAverageScore = "global_average_score"
    }
}

struct WeakAreaScoreMap: Decodable {
    struct Axis: Decodable, Identifiable {
        let key: String
        let label: String
        let shortLabel: String?

        enum CodingKeys: String, CodingKey {
            case key
            case label
            case shortLabel = "short_label"
        }

        var id: String { key }
    }

    let axes: [Axis]
    let userValues: [Double]
    let globalValues: [Double]

    enum CodingKeys: String, CodingKey {
        case axes
        case userValues = "user_values"
        case globalValues = "global_values"
    }
}

struct WeakAreaSpecialtyDimension: Decodable, Identifiable, Hashable {
    let key: String
    let label: String
    let userAverageScore: Double
    let globalAverageScore: Double
    let userCaseCount: Int
    let globalCaseCount: Int

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case userAverageScore = "user_average_score"
        case globalAverageScore = "global_average_score"
        case userCaseCount = "user_case_count"
        case globalCaseCount = "global_case_count"
    }

    var id: String { key }
}

struct WeakAreaSpecialtyStat: Decodable, Identifiable, Hashable {
    let specialty: String
    let specialtyLabel: String
    let userAverageScore: Double
    let globalAverageScore: Double
    let userCaseCount: Int
    let globalCaseCount: Int
    let recommendedDifficulty: String
    let weakestDimensionKey: String?
    let weakestDimensionLabel: String?
    let weakestDimensionScore: Double?
    let dimensions: [WeakAreaSpecialtyDimension]

    enum CodingKeys: String, CodingKey {
        case specialty
        case specialtyLabel = "specialty_label"
        case userAverageScore = "user_average_score"
        case globalAverageScore = "global_average_score"
        case userCaseCount = "user_case_count"
        case globalCaseCount = "global_case_count"
        case recommendedDifficulty = "recommended_difficulty"
        case weakestDimensionKey = "weakest_dimension_key"
        case weakestDimensionLabel = "weakest_dimension_label"
        case weakestDimensionScore = "weakest_dimension_score"
        case dimensions
    }

    var id: String { specialty }
}

struct WeakAreaRecommendation: Decodable {
    let title: String
    let message: String
    let recommendedSpecialty: String
    let recommendedSpecialtyLabel: String
    let recommendedDifficulty: String
    let focusDimensionKey: String?
    let focusDimensionLabel: String?
    let focusDimensionScore: Double?
    let suggestedWeeklyTarget: Int?
    let ctaLabel: String

    enum CodingKeys: String, CodingKey {
        case title
        case message
        case recommendedSpecialty = "recommended_specialty"
        case recommendedSpecialtyLabel = "recommended_specialty_label"
        case recommendedDifficulty = "recommended_difficulty"
        case focusDimensionKey = "focus_dimension_key"
        case focusDimensionLabel = "focus_dimension_label"
        case focusDimensionScore = "focus_dimension_score"
        case suggestedWeeklyTarget = "suggested_weekly_target"
        case ctaLabel = "cta_label"
    }

    static func localFallback(breakdown: [WeakAreaSpecialtyStat], target: Int) -> WeakAreaRecommendation? {
        guard let weakest = breakdown.first else { return nil }
        let weakLabel = weakest.weakestDimensionLabel ?? "kritik alan"
        let weakScore = weakest.weakestDimensionScore ?? weakest.userAverageScore
        let weeklyTarget = max(target, min(7, max(2, weakest.userCaseCount + 1)))
        return WeakAreaRecommendation(
            title: "Dr.Kynox Öneriyor",
            message: "Son vakalarında \(weakest.specialtyLabel) alanında \(weakLabel) puanın düşük (\(String(format: "%.1f", weakScore))/100). Bu hafta bu alana odaklı ek vaka çözmen faydalı olur.",
            recommendedSpecialty: weakest.specialty,
            recommendedSpecialtyLabel: weakest.specialtyLabel,
            recommendedDifficulty: weakest.recommendedDifficulty,
            focusDimensionKey: weakest.weakestDimensionKey,
            focusDimensionLabel: weakLabel,
            focusDimensionScore: weakScore,
            suggestedWeeklyTarget: weeklyTarget,
            ctaLabel: "\(weakest.specialtyLabel) Vakası Başlat"
        )
    }
}

private struct WeakAreaSpecialtyAggregate {
    var caseCount: Int = 0
    var overallSum: Double = 0
    var dimensionTotals: [String: (sum: Double, count: Int)] = [:]
    var difficultyCounts: [String: Int] = [:]

    var mostUsedDifficulty: String {
        let normalized = difficultyCounts
            .sorted { left, right in
                if left.value == right.value {
                    return left.key < right.key
                }
                return left.value > right.value
            }
            .first?.key ?? "Orta"
        if normalized.lowercased(with: Locale(identifier: "tr_TR")) == "random" {
            return "Orta"
        }
        return normalized
    }
}

private let weakAreaDimensionCatalog: [(key: String, label: String, shortLabel: String)] = [
    ("data_gathering_quality", "Veri Toplama", "Veri"),
    ("clinical_reasoning_logic", "Klinik Akıl Yürütme", "Akıl"),
    ("differential_diagnosis_depth", "Ayırıcı Tanı", "Ayırıcı"),
    ("diagnostic_efficiency", "Tanısal Verim", "Verim"),
    ("management_plan_quality", "Yönetim Planı", "Yönetim"),
    ("safety_red_flags", "Güvenlik", "Güvenlik"),
    ("decision_timing", "Zamanlama", "Zaman"),
    ("communication_clarity", "İletişim", "İletişim"),
    ("guideline_consistency", "Kılavuz Uyumu", "Kılavuz"),
    ("professionalism_empathy", "Profesyonellik", "Empati")
]

private func weakAreaRound(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return (value * 10).rounded() / 10
}

private func weakAreaScoreToPercent(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let normalized = value <= 10.0 ? value * 10.0 : value
    return weakAreaRound(max(0, min(100, normalized)))
}

private func weakAreaNormalizedSpecialty(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Genel Tıp" : trimmed
}

extension FlashcardItem {
    var dueDate: Date? {
        guard let dueAt, !dueAt.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: dueAt)
    }

    var dueLabel: String {
        guard let dueDate else { return "Tarih yok" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: dueDate, relativeTo: Date())
    }

    var typeDisplayName: String {
        switch cardType {
        case "diagnosis": return "Tanı"
        case "drug": return "İlaç"
        case "red_flag": return "Kırmızı Bayrak"
        case "differential": return "Ayırıcı Tanı"
        case "management": return "Yönetim"
        case "lab": return "Laboratuvar"
        case "imaging": return "Görüntüleme"
        case "procedure": return "Prosedür"
        default: return "Kavram"
        }
    }
}

struct ScoreRequestPayload: Encodable {
    let conversation: [ConversationLine]
    let rubricPrompt: String
    let mode: String
    let optionalCaseWrapup: String

    static let defaultRubric = "Klinik muhakeme, güvenlik, zamanlama ve iletişim başlıklarında 0-100 arası JSON skor üret."
}

struct ScoreDimension: Codable, Identifiable {
    let key: String
    let score: Double
    let explanation: String
    let recommendation: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case score
        case explanation
        case recommendation
    }

    init(key: String, score: Double, explanation: String, recommendation: String) {
        self.key = key
        self.score = score
        self.explanation = explanation
        self.recommendation = recommendation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? container.decode(String.self, forKey: .key)) ?? UUID().uuidString
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = value
        } else if let value = try? container.decode(Int.self, forKey: .score) {
            score = Double(value)
        } else if let raw = try? container.decode(String.self, forKey: .score),
                  let value = Double(raw.replacingOccurrences(of: ",", with: ".")) {
            score = value
        } else {
            score = 0
        }
        explanation = (try? container.decode(String.self, forKey: .explanation)) ?? ""
        recommendation = (try? container.decode(String.self, forKey: .recommendation)) ?? ""
    }
}

struct PracticeSuggestion: Codable, Identifiable {
    let focus: String
    let microDrill: String
    let examplePrompt: String

    enum CodingKeys: String, CodingKey {
        case focus
        case microDrill = "micro-drill"
        case microDrillSnake = "micro_drill"
        case microDrillCamel = "microDrill"
        case examplePrompt = "example_prompt"
        case examplePromptCamel = "examplePrompt"
    }

    var id: String { "\(focus)|\(microDrill)" }

    init(focus: String, microDrill: String, examplePrompt: String) {
        self.focus = focus
        self.microDrill = microDrill
        self.examplePrompt = examplePrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focus = (try? container.decode(String.self, forKey: .focus)) ?? ""
        microDrill =
            (try? container.decode(String.self, forKey: .microDrill)) ??
            (try? container.decode(String.self, forKey: .microDrillSnake)) ??
            (try? container.decode(String.self, forKey: .microDrillCamel)) ??
            ""
        examplePrompt =
            (try? container.decode(String.self, forKey: .examplePrompt)) ??
            (try? container.decode(String.self, forKey: .examplePromptCamel)) ??
            ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(focus, forKey: .focus)
        try container.encode(microDrill, forKey: .microDrill)
        try container.encode(examplePrompt, forKey: .examplePrompt)
    }
}

struct ScoreResponse: Codable {
    let caseTitle: String
    let trueDiagnosis: String
    let userDiagnosis: String
    let overallScore: Double
    let label: String
    let strengths: [String]
    let improvements: [String]
    let dimensions: [ScoreDimension]
    let briefSummary: String
    let missedOpportunities: [String]
    let nextPracticeSuggestions: [PracticeSuggestion]

    enum CodingKeys: String, CodingKey {
        case caseTitle = "case_title"
        case trueDiagnosis = "true_diagnosis"
        case userDiagnosis = "user_diagnosis"
        case overallScore = "overall_score"
        case label
        case strengths
        case improvements
        case dimensions
        case briefSummary = "brief_summary"
        case missedOpportunities = "missed_opportunities"
        case nextPracticeSuggestions = "next_practice_suggestions"
    }

    init(caseTitle: String,
         trueDiagnosis: String,
         userDiagnosis: String,
         overallScore: Double,
         label: String,
         strengths: [String],
         improvements: [String],
         dimensions: [ScoreDimension],
         briefSummary: String,
         missedOpportunities: [String],
         nextPracticeSuggestions: [PracticeSuggestion]) {
        self.caseTitle = caseTitle
        self.trueDiagnosis = trueDiagnosis
        self.userDiagnosis = userDiagnosis
        self.overallScore = overallScore
        self.label = label
        self.strengths = strengths
        self.improvements = improvements
        self.dimensions = dimensions
        self.briefSummary = briefSummary
        self.missedOpportunities = missedOpportunities
        self.nextPracticeSuggestions = nextPracticeSuggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        caseTitle = (try? container.decode(String.self, forKey: .caseTitle)) ?? "Klinik Vaka"
        trueDiagnosis = (try? container.decode(String.self, forKey: .trueDiagnosis)) ?? "Belirtilmedi"
        userDiagnosis = (try? container.decode(String.self, forKey: .userDiagnosis)) ?? "Belirtilmedi"

        if let value = try? container.decode(Double.self, forKey: .overallScore) {
            overallScore = value
        } else if let value = try? container.decode(Int.self, forKey: .overallScore) {
            overallScore = Double(value)
        } else if let raw = try? container.decode(String.self, forKey: .overallScore),
                  let value = Double(raw.replacingOccurrences(of: ",", with: ".")) {
            overallScore = value
        } else {
            overallScore = 0
        }

        label = (try? container.decode(String.self, forKey: .label)) ?? "Needs Improvement"
        strengths = (try? container.decode([String].self, forKey: .strengths)) ?? []
        improvements = (try? container.decode([String].self, forKey: .improvements)) ?? []
        dimensions = (try? container.decode([ScoreDimension].self, forKey: .dimensions)) ?? []
        briefSummary = (try? container.decode(String.self, forKey: .briefSummary)) ?? ""
        missedOpportunities = (try? container.decode([String].self, forKey: .missedOpportunities)) ?? []
        nextPracticeSuggestions =
            (try? container.decode([PracticeSuggestion].self, forKey: .nextPracticeSuggestions)) ?? []
    }
}

struct SaveCasePayload: Encodable {
    let sessionId: String
    let mode: String
    let status: String
    let startedAt: String
    let endedAt: String?
    let durationMin: Int
    let messageCount: Int
    let difficulty: String
    let caseContext: CaseContext
    let transcript: [ConversationLine]
    let score: ScoreResponse?

    struct CaseContext: Codable {
        let title: String
        let specialty: String
        let subtitle: String
        let challengeId: String?
        let challengeType: String?
        let expectedDiagnosis: String?

        enum CodingKeys: String, CodingKey {
            case title
            case specialty
            case subtitle
            case challengeId = "challenge_id"
            case challengeType = "challenge_type"
            case expectedDiagnosis = "expected_diagnosis"
        }
    }
}

struct CaseSessionRow: Decodable {
    let id: String?
    let sessionId: String
    let mode: String
    let status: String
    let startedAt: String?
    let endedAt: String?
    let durationMin: Int?
    let messageCount: Int?
    let difficulty: String?
    let caseContext: CaseSession.CaseContext?
    let transcript: [ConversationLine]?
    let score: ScoreResponse?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case mode
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMin = "duration_min"
        case messageCount = "message_count"
        case difficulty
        case caseContext = "case_context"
        case transcript
        case score
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try? container.decodeIfPresent(String.self, forKey: .id)

        let decodedSessionId = (try? container.decode(String.self, forKey: .sessionId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedSessionId, !decodedSessionId.isEmpty {
            sessionId = decodedSessionId
        } else if let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionId = id
        } else {
            sessionId = UUID().uuidString
        }

        mode = (try? container.decode(String.self, forKey: .mode)) ?? "text"
        status = (try? container.decode(String.self, forKey: .status)) ?? "ready"
        startedAt = try? container.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try? container.decodeIfPresent(String.self, forKey: .endedAt)
        durationMin = try? container.decodeIfPresent(Int.self, forKey: .durationMin)
        messageCount = try? container.decodeIfPresent(Int.self, forKey: .messageCount)
        difficulty = try? container.decodeIfPresent(String.self, forKey: .difficulty)
        caseContext = try? container.decodeIfPresent(CaseSession.CaseContext.self, forKey: .caseContext)
        transcript = try? container.decodeIfPresent([ConversationLine].self, forKey: .transcript)
        score = try? container.decodeIfPresent(ScoreResponse.self, forKey: .score)
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func toDomain() -> CaseSession {
        CaseSession(
            id: id ?? sessionId,
            sessionId: sessionId,
            mode: mode,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMin: durationMin,
            messageCount: messageCount,
            difficulty: difficulty,
            caseContext: caseContext,
            transcript: transcript,
            score: score,
            updatedAt: updatedAt
        )
    }
}

func canonicalSource(_ raw: String) -> String {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(with: Locale(identifier: "tr_TR"))
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

    if normalized == "user" ||
        normalized == "you" ||
        normalized == "kullanici" ||
        normalized == "caller" ||
        normalized == "human" {
        return "user"
    }

    return "ai"
}
