import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct MainTabView: View {
    private enum Tab: String, Hashable {
        case generator
        case history
        case home
        case analysis
        case profile
    }

    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppColor.surface)
        appearance.shadowColor = UIColor(AppColor.border)

        let normal = appearance.stackedLayoutAppearance.normal
        normal.iconColor = UIColor(AppColor.textSecondary)
        normal.titleTextAttributes = [
            .foregroundColor: UIColor(AppColor.textSecondary),
            .font: UIFont.systemFont(ofSize: 11, weight: .medium)
        ]

        let selected = appearance.stackedLayoutAppearance.selected
        selected.iconColor = UIColor(AppColor.primaryDark)
        selected.titleTextAttributes = [
            .foregroundColor: UIColor(AppColor.primaryDark),
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = UIColor(AppColor.primaryDark)
        UITabBar.appearance().unselectedItemTintColor = UIColor(AppColor.textSecondary)
        UITabBar.appearance().selectionIndicatorImage = UIImage()
    }

    private var selectedTab: Binding<Tab> {
        Binding(
            get: {
                switch state.selectedMainTab {
                case "analysis", "flashcards":
                    return .analysis
                default:
                    return Tab(rawValue: state.selectedMainTab) ?? .home
                }
            },
            set: { state.selectedMainTab = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            GeneratorView()
                .tabItem {
                    Label("Vaka", systemImage: "cross.case")
                }
                .tag(Tab.generator)

            HistoryView()
                .tabItem {
                    Label("Geçmiş", systemImage: "list.bullet.rectangle")
                }
                .tag(Tab.history)

            DashboardView {
                state.selectedMainTab = Tab.generator.rawValue
            }
                .tabItem {
                    Label("Ana Sayfa", systemImage: "house")
                }
                .tag(Tab.home)

            AnalysisHubView()
                .tabItem {
                    Label("Analiz", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(Tab.analysis)

            ProfileView()
                .tabItem {
                    Label("Profil", systemImage: "person.crop.circle")
                }
                .tag(Tab.profile)
        }
        .toolbarBackground(AppColor.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .top) {
            if let banner = state.inAppBanner {
                InAppBroadcastBanner(
                    banner: banner,
                    onOpen: {
                        guard let deepLink = banner.deepLink,
                              let url = URL(string: deepLink) else { return }
                        state.handleDeepLink(url)
                    },
                    onDismiss: {
                        Task { await state.dismissInAppBanner(broadcastId: banner.id) }
                    }
                )
                .id(banner.id)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: state.inAppBanner?.id)
        .onAppear {
            Task {
                await state.onAppDidBecomeActive()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await state.refreshInAppBannerIfNeeded(force: false)
            }
        }
    }
}
