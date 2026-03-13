import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch state.route {
            case .loading:
                LoadingScreen()
            case .auth:
                AuthFlowView()
            case .onboarding:
                OnboardingView()
            case .home:
                MainTabView()
            }
        }
        .background(AppColor.background.ignoresSafeArea())
        .tint(AppColor.primary)
        .onAppear {
            UISoundEngine.shared.preloadIfNeeded()
            state.updateSystemColorScheme(colorScheme)
            trackRouteChange(state.route)
        }
        .onChange(of: state.route) { route in
            trackRouteChange(route)
        }
        .onChange(of: colorScheme) { scheme in
            state.updateSystemColorScheme(scheme)
        }
        .onOpenURL { url in
            state.handleDeepLink(url)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await state.onAppDidBecomeActive()
            }
        }
    }

    private func trackRouteChange(_ route: AppState.Route) {
        SentryRuntime.addBreadcrumb { crumb in
            crumb.category = "navigation"
            crumb.type = "navigation"
            crumb.level = .info
            crumb.message = "route_changed"
            crumb.data = ["route": route.sentryName]
        }
        SentryRuntime.configureScope { scope in
            scope.setTag(value: route.sentryName, key: "app.route")
        }
    }
}

private extension AppState.Route {
    var sentryName: String {
        switch self {
        case .loading:
            return "loading"
        case .auth:
            return "auth"
        case .onboarding:
            return "onboarding"
        case .home:
            return "home"
        }
    }
}

private struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: 14) {
            HeroHeader(
                eyebrow: "Loading",
                title: "Dr.Kynox",
                subtitle: "Klinik çalışma alanın hazırlanıyor",
                icon: "bolt.heart.fill"
            ) {
                IntroMotionCard(variant: .short)
                    .frame(height: 196)
                    .frame(maxWidth: .infinity)

                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }
}
