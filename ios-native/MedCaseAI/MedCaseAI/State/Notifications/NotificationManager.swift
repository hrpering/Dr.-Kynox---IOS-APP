import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    var onStatusMessage: ((String) -> Void)?
    var onDeepLink: ((URL) -> Void)?
    var onAccessTokenResolved: ((String?) -> Void)?
    var userIdProvider: (() -> String?)?

    private let api: APIClient
    private let supabase: SupabaseService
    private let defaults: UserDefaults

    private var cancellables = Set<AnyCancellable>()
    private var pendingPushDeviceToken: String?
    private var lastPushRegistrationToken: String?
    private var lastPushRegistrationEnabled: Bool?
    private var lastPushRegistrationUserId: String?

    private static let pushDeviceTokenKey = "drkynox.push.device_token"

    init(api: APIClient, supabase: SupabaseService, defaults: UserDefaults = .standard) {
        self.api = api
        self.supabase = supabase
        self.defaults = defaults
        self.pendingPushDeviceToken = defaults.string(forKey: Self.pushDeviceTokenKey)
        observePushNotifications()
    }

    func configureWeeklyGoalNotifications(summary: WeeklyGoalSummary) async {
        await WeeklyGoalNotificationManager.shared.configureNotifications(summary: summary)
    }

    func shouldShowNotificationPrimer() async -> Bool {
        await WeeklyGoalNotificationManager.shared.shouldShowPermissionPrimer()
    }

    func fetchNotificationAuthorizationState() async -> NotificationAuthorizationState {
        await WeeklyGoalNotificationManager.shared.authorizationState()
    }

    @discardableResult
    func requestNotificationPermissionAndSchedule(summary: WeeklyGoalSummary) async -> Bool {
        let granted = await WeeklyGoalNotificationManager.shared.requestAuthorizationExplicitly()
        if granted {
            await WeeklyGoalNotificationManager.shared.configureNotifications(summary: summary)
        }
        await syncPushRegistrationIfPossible(force: true)
        return granted
    }

    func onAppDidBecomeActive() async {
        await syncPushRegistrationIfPossible(force: false)
    }

    func syncPushRegistrationIfPossible(force: Bool) async {
        await performPushRegistrationSync(force: force)
    }

    func resetForSignedOut() {
        lastPushRegistrationUserId = nil
    }

    private func observePushNotifications() {
        NotificationCenter.default.publisher(for: .drkynoxDidReceivePushDeviceToken)
            .sink { [weak self] note in
                guard let self else { return }
                let token = (note.userInfo?["token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !token.isEmpty else { return }
                self.pendingPushDeviceToken = token
                self.defaults.set(token, forKey: Self.pushDeviceTokenKey)
                Task {
                    await self.performPushRegistrationSync(force: true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .drkynoxPushRegistrationFailed)
            .sink { [weak self] note in
                guard let self else { return }
                let reason = (note.userInfo?["error"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !reason.isEmpty {
                    self.onStatusMessage?("Push kaydı tamamlanamadı. \(reason)")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .drkynoxPushDeepLinkTapped)
            .sink { [weak self] note in
                guard let self else { return }
                guard let deepLink = (note.userInfo?["deepLink"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: deepLink) else {
                    return
                }
                self.onDeepLink?(url)
            }
            .store(in: &cancellables)
    }

    private func performPushRegistrationSync(force: Bool) async {
        let authState = await fetchNotificationAuthorizationState()
        let notificationsEnabled = authState.isEnabled

        if notificationsEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }

        guard let token = pendingPushDeviceToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return
        }

        let userId = userIdProvider?()
        if !force,
           token == lastPushRegistrationToken,
           notificationsEnabled == lastPushRegistrationEnabled,
           lastPushRegistrationUserId == userId {
            return
        }

        guard let accessToken = try? await supabase.currentAccessToken(),
              !accessToken.isEmpty else {
            return
        }

        do {
            _ = try await api.registerPushDevice(
                accessToken: accessToken,
                deviceToken: token,
                notificationsEnabled: notificationsEnabled,
                apnsEnvironment: currentApnsEnvironment(),
                deviceModel: UIDevice.current.model,
                appVersion: currentAppVersion(),
                locale: Locale.current.identifier,
                timezone: TimeZone.current.identifier
            )
            lastPushRegistrationToken = token
            lastPushRegistrationEnabled = notificationsEnabled
            lastPushRegistrationUserId = userId
            onAccessTokenResolved?(accessToken)
        } catch {
            // Sessizce devam et; sonraki aktiflikte yeniden denenecek.
        }
    }

    private func currentApnsEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private func currentAppVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !short.isEmpty && !build.isEmpty {
            return "\(short) (\(build))"
        }
        if !short.isEmpty {
            return short
        }
        return build
    }
}
