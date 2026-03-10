import Foundation
import UserNotifications

#if canImport(WidgetKit)
import WidgetKit
#endif

struct WeeklyWeekSnapshot: Identifiable, Equatable {
    let id: String
    let weekStart: Date
    let weekEnd: Date
    let completedCount: Int
    let target: Int

    var isCompleted: Bool { completedCount >= target }

    var shortLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "d MMM"
        return "\(fmt.string(from: weekStart)) - \(fmt.string(from: weekEnd))"
    }
}

struct WeeklyGoalSummary: Equatable {
    let weekStart: Date
    let weekEnd: Date
    let completedCount: Int
    let target: Int
    let thisWeekCases: [CaseSession]
    let previousWeeks: [WeeklyWeekSnapshot]
    let consecutiveCompletedWeeks: Int
    let solvedDayKeysThisWeek: Set<String>

    static let empty = WeeklyGoalSummary(
        weekStart: Date(),
        weekEnd: Date(),
        completedCount: 0,
        target: 5,
        thisWeekCases: [],
        previousWeeks: [],
        consecutiveCompletedWeeks: 0,
        solvedDayKeysThisWeek: []
    )

    var remainingCount: Int {
        max(0, target - completedCount)
    }

    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(completedCount) / Double(target))
    }

    var isCompleted: Bool {
        completedCount >= target
    }

    var weekLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "d MMM"
        return "\(fmt.string(from: weekStart)) - \(fmt.string(from: weekEnd))"
    }

    var disciplineBadgeUnlocked: Bool {
        consecutiveCompletedWeeks >= 4
    }

    static func == (lhs: WeeklyGoalSummary, rhs: WeeklyGoalSummary) -> Bool {
        lhs.weekStart == rhs.weekStart &&
        lhs.weekEnd == rhs.weekEnd &&
        lhs.completedCount == rhs.completedCount &&
        lhs.target == rhs.target &&
        lhs.consecutiveCompletedWeeks == rhs.consecutiveCompletedWeeks &&
        lhs.solvedDayKeysThisWeek == rhs.solvedDayKeysThisWeek &&
        lhs.previousWeeks == rhs.previousWeeks &&
        lhs.thisWeekCases.map(\.id) == rhs.thisWeekCases.map(\.id)
    }
}

struct WeeklyGoalWidgetSnapshot: Codable {
    let target: Int
    let completedCount: Int
    let progress: Double
    let isCompleted: Bool
    let consecutiveCompletedWeeks: Int
    let weekLabel: String
    let updatedAt: String
}

enum WeeklyGoalStorage {
    static let appGroupSuite = "group.com.medcaseai.shared"
    static let targetKey = "drkynox.weekly_goal_target"
    static let snapshotKey = "drkynox.weekly_goal_snapshot"
    static let goalReachedWeekKey = "drkynox.weekly_goal.notified_week"
    static let userCustomizedTargetKey = "drkynox.weekly_goal.user_customized_target"

    static func loadTarget(defaultValue: Int = 5) -> Int {
        let raw = UserDefaults.standard.integer(forKey: targetKey)
        if raw <= 0 { return defaultValue }
        return max(1, min(14, raw))
    }

    static func saveTarget(_ target: Int) {
        UserDefaults.standard.set(max(1, min(14, target)), forKey: targetKey)
    }

    static func markUserCustomizedTarget(_ customized: Bool) {
        UserDefaults.standard.set(customized, forKey: userCustomizedTargetKey)
    }

    static func isUserCustomizedTarget() -> Bool {
        UserDefaults.standard.bool(forKey: userCustomizedTargetKey)
    }

    static func writeWidgetSnapshot(_ summary: WeeklyGoalSummary) {
        let snapshot = WeeklyGoalWidgetSnapshot(
            target: summary.target,
            completedCount: summary.completedCount,
            progress: summary.progress,
            isCompleted: summary.isCompleted,
            consecutiveCompletedWeeks: summary.consecutiveCompletedWeeks,
            weekLabel: summary.weekLabel,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        if let shared = UserDefaults(suiteName: appGroupSuite) {
            shared.set(data, forKey: snapshotKey)
        }
        UserDefaults.standard.set(data, forKey: snapshotKey)

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "DrKynoxWeeklyGoalWidget")
        #endif
    }
}

struct NotificationPreferenceState {
    let dailyReminder: Bool
    let weeklySummary: Bool
    let challengeReminder: Bool

    static let dailyKey = "settings.notifications.daily_reminder"
    static let weeklyKey = "settings.notifications.weekly_summary"
    static let challengeKey = "settings.notifications.challenge_reminder"

    static func load(from defaults: UserDefaults = .standard) -> NotificationPreferenceState {
        .init(
            dailyReminder: defaults.object(forKey: dailyKey) == nil ? false : defaults.bool(forKey: dailyKey),
            weeklySummary: defaults.object(forKey: weeklyKey) == nil ? false : defaults.bool(forKey: weeklyKey),
            challengeReminder: defaults.object(forKey: challengeKey) == nil ? false : defaults.bool(forKey: challengeKey)
        )
    }

    var hasAnyEnabled: Bool {
        dailyReminder || weeklySummary || challengeReminder
    }
}

enum NotificationAuthorizationState: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var isEnabled: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}

enum WeeklyGoalCalculator {
    private static let trLocale = Locale(identifier: "tr_TR")

    static func buildSummary(from history: [CaseSession], target: Int, now: Date = Date()) -> WeeklyGoalSummary {
        let calendar = isoCalendar
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return .empty
        }

        let weekStart = calendar.startOfDay(for: weekInterval.start)
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart

        let completedEvents = history.compactMap { session -> (CaseSession, Date)? in
            guard isCompletedSession(session), let date = sessionDate(session) else { return nil }
            return (session, date)
        }

        let thisWeekEvents = completedEvents
            .filter { event in
                event.1 >= weekStart && event.1 < (calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekEnd)
            }
            .sorted { $0.1 > $1.1 }

        let thisWeekCases = thisWeekEvents.map { $0.0 }
        let completedCount = thisWeekCases.count

        let dayKeys = Set(thisWeekEvents.map { dayKey(for: $0.1) })

        var previousWeeks: [WeeklyWeekSnapshot] = []
        var consecutive = 0

        for offset in 0..<8 {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: weekStart) else { continue }
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let nextStart = calendar.date(byAdding: .day, value: 7, to: start) ?? end
            let count = completedEvents.reduce(into: 0) { partial, event in
                if event.1 >= start && event.1 < nextStart {
                    partial += 1
                }
            }

            previousWeeks.append(
                WeeklyWeekSnapshot(
                    id: dayKey(for: start),
                    weekStart: start,
                    weekEnd: end,
                    completedCount: count,
                    target: max(1, target)
                )
            )

            if count >= max(1, target) {
                if offset == consecutive {
                    consecutive += 1
                }
            }
        }

        return WeeklyGoalSummary(
            weekStart: weekStart,
            weekEnd: weekEnd,
            completedCount: completedCount,
            target: max(1, target),
            thisWeekCases: thisWeekCases,
            previousWeeks: previousWeeks,
            consecutiveCompletedWeeks: consecutive,
            solvedDayKeysThisWeek: dayKeys
        )
    }

    static func solvedToday(_ summary: WeeklyGoalSummary, now: Date = Date()) -> Bool {
        summary.solvedDayKeysThisWeek.contains(dayKey(for: now))
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = trLocale
        formatter.timeZone = .current
        formatter.calendar = isoCalendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func sessionDate(_ session: CaseSession) -> Date? {
        parseDate(session.endedAt) ?? parseDate(session.updatedAt) ?? parseDate(session.startedAt)
    }

    static func isCompletedSession(_ session: CaseSession) -> Bool {
        if session.score != nil { return true }
        let status = session.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: trLocale)
        return status == "ready" || status == "completed"
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let date = isoFractional.date(from: raw) { return date }
        if let date = isoBasic.date(from: raw) { return date }
        return postgres.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static let postgres: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        return formatter
    }()

    private static var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = trLocale
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

actor WeeklyGoalNotificationManager {
    static let shared = WeeklyGoalNotificationManager()

    private let center = UNUserNotificationCenter.current()

    func configureNotifications(summary: WeeklyGoalSummary) async {
        let prefs = NotificationPreferenceState.load()
        if !prefs.hasAnyEnabled {
            await clearManagedPendingRequests()
            return
        }

        let authorized = await ensureAuthorizationIfNeeded()
        guard authorized else { return }

        await clearManagedPendingRequests()
        if prefs.dailyReminder {
            await scheduleWeekdayReminders(summary: summary)
        }
        if prefs.weeklySummary {
            await scheduleSundaySummary(summary: summary)
        }
        if prefs.challengeReminder {
            await scheduleDailyChallengeReminder()
        }
        await notifyIfGoalReached(summary: summary)
    }

    func shouldShowPermissionPrimer() async -> Bool {
        let settings = await notificationSettings()
        return settings.authorizationStatus == .notDetermined
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorizationExplicitly() async -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    private func ensureAuthorizationIfNeeded() async -> Bool {
        let settings = await notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func clearManagedPendingRequests() async {
        let ids = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                let managed = requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix("drkynox.weekly.") }
                continuation.resume(returning: managed)
            }
        }

        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func scheduleWeekdayReminders(summary: WeeklyGoalSummary) async {
        let calendar = Calendar.current
        let now = Date()

        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let isWeekday = weekday >= 2 && weekday <= 6
            guard isWeekday else { continue }

            let dayKey = WeeklyGoalCalculator.dayKey(for: date)
            if dayOffset == 0, summary.solvedDayKeysThisWeek.contains(dayKey) {
                continue
            }

            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = 20
            components.minute = 0

            guard let triggerDate = calendar.date(from: components), triggerDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Dr.Kynox"
            content.body = "Bugün henüz vaka çözmedin. Haftalık hedefin için 1 vaka tamamla."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "drkynox.weekly.daily.\(dayKey)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private func scheduleSundaySummary(summary: WeeklyGoalSummary) async {
        let calendar = Calendar.current
        let now = Date()

        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = 1
        components.hour = 20
        components.minute = 0

        guard var sundayDate = calendar.date(from: components) else { return }
        if sundayDate <= now {
            sundayDate = calendar.date(byAdding: .weekOfYear, value: 1, to: sundayDate) ?? sundayDate
        }

        let done = summary.completedCount
        let target = summary.target
        let body: String
        if done >= target {
            body = "🎉 Bu haftaki hedefi tamamladın! Harika iş çıkardın."
        } else {
            body = "Bu haftayı \(done)/\(target) tamamladın, çok yaklaştın!"
        }

        let content = UNMutableNotificationContent()
        content.title = "Haftalık Özet"
        content.body = body
        content.sound = .default

        let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: sundayDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: "drkynox.weekly.sunday.summary",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private func scheduleDailyChallengeReminder() async {
        let calendar = Calendar.current
        let now = Date()

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0

        guard var triggerDate = calendar.date(from: components) else { return }
        if triggerDate <= now {
            triggerDate = calendar.date(byAdding: .day, value: 1, to: triggerDate) ?? triggerDate
        }

        let content = UNMutableNotificationContent()
        content.title = "Günün Vakası Hazır"
        content.body = "Bugünün ortak vakası yenilendi. Kısa bir vaka ile serini koru."
        content.sound = .default

        let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: "drkynox.weekly.challenge.daily",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private func notifyIfGoalReached(summary: WeeklyGoalSummary) async {
        guard summary.isCompleted else { return }

        let weekKey = WeeklyGoalCalculator.dayKey(for: summary.weekStart)
        let lastNotified = UserDefaults.standard.string(forKey: WeeklyGoalStorage.goalReachedWeekKey)
        if lastNotified == weekKey { return }

        let content = UNMutableNotificationContent()
        content.title = "Hedef Tamamlandı"
        content.body = "🎉 Bu haftaki hedefe ulaştın!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "drkynox.weekly.goal.reached.\(weekKey)",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
        UserDefaults.standard.set(weekKey, forKey: WeeklyGoalStorage.goalReachedWeekKey)
    }
}
