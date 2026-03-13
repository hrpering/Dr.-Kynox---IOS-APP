import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let drkynoxDidReceivePushDeviceToken = Notification.Name("drkynox.didReceivePushDeviceToken")
    static let drkynoxPushRegistrationFailed = Notification.Name("drkynox.pushRegistrationFailed")
    static let drkynoxPushDeepLinkTapped = Notification.Name("drkynox.pushDeepLinkTapped")
}

final class PushNotificationBridge: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        NotificationCenter.default.post(
            name: .drkynoxDidReceivePushDeviceToken,
            object: nil,
            userInfo: ["token": token]
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(
            name: .drkynoxPushRegistrationFailed,
            object: nil,
            userInfo: ["error": error.localizedDescription]
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let deepLink = (response.notification.request.content.userInfo["deep_link"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let deepLink, !deepLink.isEmpty else { return }
        NotificationCenter.default.post(
            name: .drkynoxPushDeepLinkTapped,
            object: nil,
            userInfo: ["deepLink": deepLink]
        )
    }
}
