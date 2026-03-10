import SwiftUI
import Sentry

@main
struct MedCaseAIApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationBridge.self) private var pushNotificationBridge
    @StateObject private var appState = AppState()

    init() {
        // NOTE: Sentry init is temporarily skipped in this build profile due SDK symbol mismatch.
        // Existing breadcrumb/event calls remain in place.
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
