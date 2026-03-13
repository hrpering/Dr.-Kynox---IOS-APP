import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct ProfileView: View {
    @EnvironmentObject private var state: AppState
    @State private var showFeedbackSheet = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    profileTopBar

                    VStack(spacing: 16) {
                        profileHeaderCard
                        accountSection
                        supportSection
                        logoutButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .background(AppColor.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showFeedbackSheet) {
                UserFeedbackSheet()
                    .environmentObject(state)
            }
        }
    }

    private var profileTopBar: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(AppColor.surface)
                    .frame(width: 32, height: 32)
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
            }
            .opacity(0.92)

            Spacer()

            Text("Profil")
                .font(AppFont.h3)
                .foregroundStyle(AppColor.textPrimary)

            Spacer()

            Circle()
                .fill(Color.clear)
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(AppColor.surface.opacity(0.82))
    }

    private var profileHeaderCard: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(AppColor.surfaceAlt)
                    .frame(width: 112, height: 112)

                Group {
                    if UIImage(named: "ProfileRefAvatar") != nil {
                        Image("ProfileRefAvatar")
                            .resizable()
                            .scaledToFill()
                    } else {
                        Text(initials)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColor.primaryDark)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())

                Circle()
                    .fill(AppColor.success)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                    )
            }
            .padding(.top, 2)

            Text(state.profile?.fullName.isEmpty == false ? (state.profile?.fullName ?? "") : "Kullanıcı")
                .font(AppFont.h2)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(readableRole)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)

            Text("Premium Üye")
                .font(AppFont.secondary)
                .foregroundStyle(AppColor.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(AppColor.primaryLight)
                .clipShape(Capsule())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Hesap")

            VStack(spacing: 0) {
                NavigationLink {
                    ProfileLanguagePreferencesView()
                        .environmentObject(state)
                } label: {
                    profileRowButton(
                        icon: "globe",
                        iconTint: AppColor.primary,
                        iconBackground: AppColor.primaryLight,
                        title: "Dil ve Bölge",
                        trailingText: preferredLanguageLabel
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                NavigationLink {
                    ProfileNotificationPreferencesView()
                        .environmentObject(state)
                } label: {
                    profileRowButton(
                        icon: "bell.fill",
                        iconTint: Color(hex: "#F97316"),
                        iconBackground: Color(hex: "#FFEDD5"),
                        title: "Bildirimler"
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                NavigationLink {
                    ProfileAudioPreferencesView()
                } label: {
                    profileRowButton(
                        icon: "mic.fill",
                        iconTint: Color(hex: "#475569"),
                        iconBackground: Color(hex: "#E2E8F0"),
                        title: "Ses / Mikrofon Tercihleri"
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                NavigationLink {
                    ProfileSubscriptionView()
                } label: {
                    profileRowButton(
                        icon: "creditcard.fill",
                        iconTint: AppColor.success,
                        iconBackground: AppColor.successLight,
                        title: "Abonelik"
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                NavigationLink {
                    ProfileAccountView()
                        .environmentObject(state)
                } label: {
                    profileRowButton(
                        icon: "person.crop.circle.badge.exclamationmark",
                        iconTint: AppColor.error,
                        iconBackground: AppColor.errorLight,
                        title: "Hesap ve Veri"
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
            .background(AppColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .appShadow(AppShadow.low)
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Destek ve Yasal")

            VStack(spacing: 0) {
                NavigationLink {
                    ProfileSupportView()
                        .environmentObject(state)
                } label: {
                    profileRowButton(
                        icon: "lifepreserver.fill",
                        iconTint: AppColor.primary,
                        iconBackground: AppColor.primaryLight,
                        title: "Yardım Merkezi"
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                Button {
                    showFeedbackSheet = true
                    Haptic.selection()
                } label: {
                    profileRowButton(
                        icon: "bubble.left.and.bubble.right.fill",
                        iconTint: AppColor.warning,
                        iconBackground: AppColor.warningLight,
                        title: "Geri Bildirim"
                    )
                }
                .buttonStyle(PressableButtonStyle())

                rowDivider

                NavigationLink {
                    ProfileLegalView()
                        .environmentObject(state)
                } label: {
                    profileRowButton(
                        icon: "doc.text.fill",
                        iconTint: Color(hex: "#475569"),
                        iconBackground: Color(hex: "#E2E8F0"),
                        title: "Gizlilik / Koşullar"
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
            .background(AppColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .appShadow(AppShadow.low)
        }
    }

    private var logoutButton: some View {
        NavigationLink {
            ProfileAccountView()
                .environmentObject(state)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                Text("Çıkış Yap")
                    .font(AppFont.bodyMedium)
            }
            .foregroundStyle(AppColor.error)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppColor.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppFont.secondary)
            .foregroundStyle(AppColor.textTertiary)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(AppColor.border)
            .padding(.leading, 72)
    }

    private func profileRowButton(icon: String,
                                  iconTint: Color,
                                  iconBackground: Color,
                                  title: String,
                                  trailingText: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 40, height: 40)
                .background(iconBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            Text(title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let trailingText {
                Text(trailingText)
                    .font(AppFont.secondary)
                    .foregroundStyle(AppColor.textSecondary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var preferredLanguageLabel: String {
        let normalized = AppLanguage.normalizeBCP47(state.profile?.preferredLanguageCode, fallback: "tr")
        return AppLanguage.supported.first(where: { $0.code == normalized })?.nativeName ?? "Türkçe"
    }

    private var initials: String {
        let name = state.profile?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return "DK"
        }
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }.joined()
        return letters.uppercased()
    }

    private var readableRole: String {
        let raw = (state.profile?.role ?? "").lowercased()
        if raw.contains("intern") || raw.contains("resident") || raw.contains("asistan") {
            return "İntörn / Asistan"
        }
        if raw.contains("student") || raw.contains("öğrenci") {
            return "Tıp Öğrencisi"
        }
        if raw.contains("uzman") {
            return "Uzman"
        }
        return state.profile?.role.isEmpty == false ? (state.profile?.role ?? "Tıp Öğrencisi") : "Tıp Öğrencisi"
    }
}
