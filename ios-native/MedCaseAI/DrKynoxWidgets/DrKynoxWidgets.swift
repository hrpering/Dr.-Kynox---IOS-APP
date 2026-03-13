import WidgetKit
import SwiftUI

struct DailyChallengePayload: Decodable {
    let challenge: DailyChallengeInfo

    struct DailyChallengeInfo: Decodable {
        let title: String
        let specialty: String
        let difficulty: String
        let summary: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case title
            case specialty
            case difficulty
            case summary
            case expiresAt = "expires_at"
            case expiresAtCamel = "expiresAt"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? container.decode(String.self, forKey: .title)) ?? "Günün Vakası"
            specialty = (try? container.decode(String.self, forKey: .specialty)) ?? "Genel"
            difficulty = (try? container.decode(String.self, forKey: .difficulty)) ?? "Orta"
            summary = try? container.decode(String.self, forKey: .summary)
            expiresAt =
                (try? container.decode(String.self, forKey: .expiresAt)) ??
                (try? container.decode(String.self, forKey: .expiresAtCamel))
        }
    }
}

struct DrKynoxWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let specialty: String
    let difficulty: String
    let summary: String
    let expiresAt: Date?
    let isFallback: Bool
}

struct DrKynoxTimelineProvider: TimelineProvider {
    private let iso = ISO8601DateFormatter()

    private var backendBaseURL: String {
        if let url = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    func placeholder(in context: Context) -> DrKynoxWidgetEntry {
        DrKynoxWidgetEntry(
            date: Date(),
            title: "Günün Vaka Meydan Okuması",
            specialty: "Cardiology",
            difficulty: "Orta",
            summary: "62 yaş erkek hasta, akut göğüs ağrısı ve nefes darlığı.",
            expiresAt: nil,
            isFallback: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DrKynoxWidgetEntry) -> Void) {
        Task {
            let entry = await loadEntry() ?? placeholder(in: context)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DrKynoxWidgetEntry>) -> Void) {
        Task {
            let current = await loadEntry() ?? placeholder(in: context)
            let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
            completion(Timeline(entries: [current], policy: .after(refresh)))
        }
    }

    private func loadEntry() async -> DrKynoxWidgetEntry? {
        guard !backendBaseURL.isEmpty else { return nil }
        guard let url = URL(string: "\(backendBaseURL)/api/challenge/today") else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }

            let decoded = try JSONDecoder().decode(DailyChallengePayload.self, from: data)
            let challenge = decoded.challenge
            let expiresAtDate = parseISODate(challenge.expiresAt)

            return DrKynoxWidgetEntry(
                date: Date(),
                title: cleanTitle(challenge.title),
                specialty: challenge.specialty,
                difficulty: challenge.difficulty,
                summary: cleanSummary(challenge.summary, fallbackTitle: challenge.title),
                expiresAt: expiresAtDate,
                isFallback: false
            )
        } catch {
            return nil
        }
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return iso.date(from: raw)
    }

    private func cleanTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Günün Vaka Meydan Okuması" : trimmed
    }

    private func cleanSummary(_ summary: String?, fallbackTitle: String) -> String {
        let base = (summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (summary ?? "")
            : fallbackTitle

        let normalized = base
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.isEmpty {
            return "Günün vakası hazır."
        }

        let firstSentence = normalized.split(separator: ".").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstSentence, firstSentence.count >= 24 {
            return firstSentence + "."
        }
        return String(normalized.prefix(170))
    }
}

struct DrKynoxWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DrKynoxWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                mediumView
            }
        }
        .widgetURL(URL(string: "drkynox://home?open=daily"))
    }

    private var mediumView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#FFFFFF"), Color(hex: "#F3F8FF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color(hex: "#DCE7F7"), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Günün Vakası", systemImage: "staroflife.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1452B8"))

                    Spacer()

                    if let ttl = ttlText {
                        WidgetBadge(text: ttl, fg: Color(hex: "#1452B8"), bg: Color(hex: "#EAF2FF"))
                    }

                    WidgetBadge(text: difficultyLabel, fg: difficultyColor, bg: difficultyColor.opacity(0.16))
                }

                Text(entry.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: "#0F172A"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)

                HStack(spacing: 6) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#475569"))
                    Text(specialtyLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "#334155"))
                        .lineLimit(1)
                }

                Text(entry.summary)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(hex: "#475569"))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1D6FE8"))
                    Text("Dokun ve Başlat")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1D6FE8"))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(hex: "#EBF2FF"))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .padding(14)
        }
    }

    private var smallView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#FFFFFF"), Color(hex: "#F7FAFF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "#DCE7F7"), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Text("Günün Vakası")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1452B8"))
                    Spacer()
                    WidgetBadge(text: difficultyLabel, fg: difficultyColor, bg: difficultyColor.opacity(0.16), compact: true)
                }

                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: "#EBF2FF"))
                        Image(systemName: "stethoscope")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color(hex: "#1D6FE8"))
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(specialtyLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "#0F172A"))
                            .lineLimit(1)
                        Text(ttlText ?? "Bugün aktif")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(hex: "#64748B"))
                            .lineLimit(1)
                    }
                }

                Text(smallHeadline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: "#334155"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Hemen Başla")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Color(hex: "#1D6FE8"))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(10)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Günün Vakası • \(difficultyLabel)")
                .font(.caption2)
                .foregroundStyle(Color(hex: "#1452B8"))
            Text(entry.title)
                .font(.caption)
                .lineLimit(1)
            Text(specialtyLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var inlineView: some View {
        Text("Dr.Kynox: \(specialtyLabel) · \(difficultyLabel)")
    }

    private var specialtyLabel: String {
        SpecialtyMapper.label(for: entry.specialty)
    }

    private var difficultyLabel: String {
        let raw = entry.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.contains("easy") || raw.contains("kolay") { return "Kolay" }
        if raw.contains("hard") || raw.contains("zor") { return "Zor" }
        return "Orta"
    }

    private var difficultyColor: Color {
        switch difficultyLabel {
        case "Kolay": return Color(hex: "#0D9E6E")
        case "Zor": return Color(hex: "#DC2626")
        default: return Color(hex: "#D97706")
        }
    }

    private var ttlText: String? {
        guard let expiresAt = entry.expiresAt else { return nil }
        let remaining = Int(expiresAt.timeIntervalSinceNow)
        if remaining <= 0 { return "Yenileniyor" }
        if remaining < 3600 {
            let mins = max(1, Int(ceil(Double(remaining) / 60.0)))
            return "\(mins) dk"
        }
        let hours = Int(ceil(Double(remaining) / 3600.0))
        return "\(hours) sa"
    }

    private var smallHeadline: String {
        let compact = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 62 {
            return compact
        }
        let short = compact.split(separator: ".").first.map(String.init) ?? compact
        return String(short.prefix(62))
    }
}

private struct WidgetBadge: View {
    let text: String
    let fg: Color
    let bg: Color
    var compact: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 9 : 10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(bg)
            .clipShape(Capsule())
    }
}

private enum SpecialtyMapper {
    static func label(for value: String) -> String {
        let map: [String: String] = [
            "Cardiology": "Kardiyoloji",
            "Pulmonology": "Pulmonoloji",
            "Gastroenterology": "Gastroenteroloji",
            "Endocrinology": "Endokrinoloji",
            "Nephrology": "Nefroloji",
            "Infectious Diseases": "Enfeksiyon",
            "Rheumatology": "Romatoloji",
            "Hematology": "Hematoloji",
            "Oncology": "Onkoloji",
            "Emergency Medicine": "Acil Tıp",
            "Critical Care Medicine": "Yoğun Bakım",
            "Neurology": "Nöroloji",
            "Psychiatry": "Psikiyatri",
            "General Surgery": "Genel Cerrahi",
            "Trauma Surgery": "Travma Cerrahisi"
        ]
        return map[value] ?? value
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

struct DrKynoxDailyWidget: Widget {
    let kind: String = "DrKynoxDailyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DrKynoxTimelineProvider()) { entry in
            DrKynoxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Günün Vaka Meydan Okuması")
        .description("Dr.Kynox günlük vakasını Ana Ekran ve Kilit Ekranı'nda gösterir.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct WeeklyGoalSnapshotPayload: Decodable {
    let target: Int
    let completedCount: Int
    let progress: Double
    let isCompleted: Bool
    let consecutiveCompletedWeeks: Int
    let weekLabel: String
}

private struct DrKynoxWeeklyEntry: TimelineEntry {
    let date: Date
    let target: Int
    let completedCount: Int
    let progress: Double
    let isCompleted: Bool
    let consecutiveCompletedWeeks: Int
    let weekLabel: String
}

private struct DrKynoxWeeklyProvider: TimelineProvider {
    private let appGroupSuite = "group.com.medcaseai.shared"
    private let snapshotKey = "drkynox.weekly_goal_snapshot"

    func placeholder(in context: Context) -> DrKynoxWeeklyEntry {
        DrKynoxWeeklyEntry(
            date: Date(),
            target: 5,
            completedCount: 2,
            progress: 0.4,
            isCompleted: false,
            consecutiveCompletedWeeks: 1,
            weekLabel: "Bu Hafta"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DrKynoxWeeklyEntry) -> Void) {
        completion(loadEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DrKynoxWeeklyEntry>) -> Void) {
        let entry = loadEntry() ?? placeholder(in: context)
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func loadEntry() -> DrKynoxWeeklyEntry? {
        let shared = UserDefaults(suiteName: appGroupSuite)
        let data = shared?.data(forKey: snapshotKey) ?? UserDefaults.standard.data(forKey: snapshotKey)
        guard let data else { return nil }

        guard let decoded = try? JSONDecoder().decode(WeeklyGoalSnapshotPayload.self, from: data) else {
            return nil
        }

        return DrKynoxWeeklyEntry(
            date: Date(),
            target: max(1, decoded.target),
            completedCount: max(0, decoded.completedCount),
            progress: min(max(decoded.progress, 0), 1),
            isCompleted: decoded.isCompleted,
            consecutiveCompletedWeeks: max(0, decoded.consecutiveCompletedWeeks),
            weekLabel: decoded.weekLabel.isEmpty ? "Bu Hafta" : decoded.weekLabel
        )
    }
}

private struct DrKynoxWeeklyEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DrKynoxWeeklyEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                mediumView
            }
        }
        .widgetURL(URL(string: "drkynox://home?open=weekly"))
    }

    private var mediumView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#FFFFFF"), Color(hex: "#EEF8FF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "#D6E7FF"), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Haftalık Hedef", systemImage: "target")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1452B8"))
                    Spacer()
                    WidgetBadge(
                        text: entry.isCompleted ? "Tamamlandı" : "\(entry.completedCount)/\(entry.target)",
                        fg: entry.isCompleted ? Color(hex: "#0D9E6E") : Color(hex: "#1452B8"),
                        bg: entry.isCompleted ? Color(hex: "#ECFDF5") : Color(hex: "#EBF2FF")
                    )
                }

                Text(entry.weekLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#0F172A"))
                    .lineLimit(1)

                ProgressView(value: entry.progress)
                    .tint(entry.isCompleted ? Color(hex: "#0D9E6E") : Color(hex: "#1D6FE8"))

                HStack(spacing: 8) {
                    Image(systemName: "rosette")
                        .foregroundStyle(Color(hex: "#D97706"))
                    Text("Seri: \(entry.consecutiveCompletedWeeks) hafta")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "#475569"))
                    Spacer()
                }

                Text(entry.isCompleted ? "Hedef tamamlandı. Yeni hafta için ritmi koru." : "Detayı açıp hedefini güncelleyebilirsin.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color(hex: "#475569"))
                    .lineLimit(2)
            }
            .padding(14)
        }
    }

    private var smallView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: "#F8FBFF"))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(hex: "#DCE7F7"), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text("Haftalık Hedef")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "#1452B8"))

                Text("\(entry.completedCount)/\(entry.target)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.isCompleted ? Color(hex: "#0D9E6E") : Color(hex: "#0F172A"))

                ProgressView(value: entry.progress)
                    .tint(entry.isCompleted ? Color(hex: "#0D9E6E") : Color(hex: "#1D6FE8"))

                Text(entry.isCompleted ? "Tamamlandı" : "Devam et")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: "#64748B"))
            }
            .padding(10)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Haftalık Hedef")
                .font(.caption2)
                .foregroundStyle(Color(hex: "#1452B8"))
            Text("\(entry.completedCount)/\(entry.target) vaka")
                .font(.caption)
                .lineLimit(1)
            Text("Seri: \(entry.consecutiveCompletedWeeks) hafta")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var inlineView: some View {
        Text("Hedef \(entry.completedCount)/\(entry.target)")
    }
}

struct DrKynoxWeeklyGoalWidget: Widget {
    let kind: String = "DrKynoxWeeklyGoalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DrKynoxWeeklyProvider()) { entry in
            DrKynoxWeeklyEntryView(entry: entry)
        }
        .configurationDisplayName("Dr.Kynox Haftalık Hedef")
        .description("Haftalık hedef ilerlemeni Ana Ekran ve Kilit Ekranı'nda gösterir.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct DrKynoxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DrKynoxDailyWidget()
        DrKynoxWeeklyGoalWidget()
    }
}
