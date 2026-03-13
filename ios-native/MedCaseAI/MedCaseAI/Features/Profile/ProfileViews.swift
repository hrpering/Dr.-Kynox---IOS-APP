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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    profileHeader

                    sectionTitle("Hesap")
                    SectionCard(title: "", subtitle: nil) {
                        NavigationLink {
                            ProfileLanguagePreferencesView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "globe",
                                title: "Dil ve Bölge",
                                subtitle: "Uygulama dili, ülke ve RTL ayarları",
                                tint: AppColor.primaryDark
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            ProfileNotificationPreferencesView()
                        } label: {
                            profileRowButton(
                                icon: "bell.fill",
                                title: "Bildirimler",
                                subtitle: "Hatırlatma ve bildirim tercihleri",
                                tint: AppColor.primary
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            ProfileAudioPreferencesView()
                        } label: {
                            profileRowButton(
                                icon: "mic.fill",
                                title: "Ses / Mikrofon Tercihleri",
                                subtitle: "Varsayılan mod ve mikrofon davranışı",
                                tint: AppColor.primaryDark
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            ProfileSubscriptionView()
                        } label: {
                            profileRowButton(
                                icon: "creditcard.fill",
                                title: "Abonelik",
                                subtitle: "Plan, faturalama ve kullanım özeti",
                                tint: AppColor.warning
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            ProfileAccountView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "person.crop.circle.badge.exclamationmark",
                                title: "Hesap ve Veri",
                                subtitle: "Çıkış, veri temizleme ve hesap silme",
                                tint: AppColor.error
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    sectionTitle("Destek ve Yasal")
                    SectionCard(title: "", subtitle: nil) {
                        NavigationLink {
                            ProfileSupportView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "lifepreserver.fill",
                                title: "Yardım Merkezi",
                                subtitle: "Destek ve içerik raporu",
                                tint: AppColor.primary
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            showFeedbackSheet = true
                            Haptic.selection()
                        } label: {
                            profileRowButton(
                                icon: "bubble.left.and.bubble.right.fill",
                                title: "Geri Bildirim",
                                subtitle: "Ürün ve deneyim geri bildirimi gönder",
                                tint: AppColor.success
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            ProfileLegalView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "doc.text.fill",
                                title: "Gizlilik / Koşullar",
                                subtitle: "Yasal metinler ve aydınlatma içerikleri",
                                tint: AppColor.textSecondary
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    NavigationLink {
                        ProfileAccountView()
                            .environmentObject(state)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Çıkış Yap")
                                .font(AppFont.button)
                        }
                        .foregroundStyle(AppColor.error)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(16)
                .padding(.bottom, 14)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Profil")
            .sheet(isPresented: $showFeedbackSheet) {
                UserFeedbackSheet()
                    .environmentObject(state)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased(with: Locale(identifier: "tr_TR")))
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.textTertiary)
            .kerning(2)
            .padding(.top, 4)
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(AppColor.primaryLight)
                    .frame(width: 110, height: 110)
                    .overlay(
                        Text(initials)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColor.primary)
                    )
                Circle()
                    .fill(AppColor.success)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
            }
            .padding(.top, 4)

            Text(state.profile?.fullName.isEmpty == false ? (state.profile?.fullName ?? "") : "Kullanıcı")
                .font(AppFont.h1)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(readableRole)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)

            Text("Premium Üye")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppColor.primaryLight)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func sectionCard<Content: View>(title: String,
                                            subtitle: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private func profileRowButton(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
                .padding(.top, 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private var targetExamLabel: String {
        if state.studyPlan.isConfigured {
            return "Hedef sınav: \(state.studyPlan.examTarget)"
        }
        return "Hedef sınav: Henüz seçilmedi"
    }

    private var averageScore: String {
        let values = state.caseHistory.compactMap { $0.score?.overallScore }
        guard !values.isEmpty else { return "--" }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.0f", avg)
    }

    private var streakDays: Int {
        WeeklyGoalCalculator.currentStreakDays(from: state.caseHistory)
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

    private func miniStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
    }
}
