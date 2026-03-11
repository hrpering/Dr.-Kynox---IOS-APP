import SwiftUI

@main
struct MedCaseAIApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationBridge.self) private var pushNotificationBridge
    @StateObject private var appState = AppState()

    init() {
        SentryRuntime.configureIfPossible(serverEnabled: false)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
                .task {
                    await appState.bootstrap()
                }
        }
    }
}
