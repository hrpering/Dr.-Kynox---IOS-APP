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
                VStack(alignment: .leading, spacing: 12) {
                    profileHeader

                    MetricBand(
                        items: [
                            .init(title: "Vaka", value: "\(state.caseHistory.count)"),
                            .init(title: "Skor", value: averageScore),
                            .init(title: "Seri", value: "\(streakDays)")
                        ]
                    )

                    SectionCard(title: "Çalışma", subtitle: "Hedef ve performans alanları") {
                        NavigationLink {
                            ProfilePerformanceView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "chart.bar.fill",
                                title: "Performans",
                                subtitle: "Skor trendi, grafik ve rozetler",
                                tint: AppColor.primary
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            WeeklyGoalDetailView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "target",
                                title: "Haftalık Hedef",
                                subtitle: "Hedef ve haftalık ilerleme",
                                tint: AppColor.success
                            )
                        }
                        .buttonStyle(PressableButtonStyle())

                        NavigationLink {
                            StudyPlanDetailView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "doc.text.fill",
                                title: "Study Plan",
                                subtitle: "Sınav odağı ve çalışma döngüsü",
                                tint: AppColor.warning
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    SectionCard(title: "Hesap", subtitle: "Kişiselleştirme ve güvenlik") {
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
                            ProfileThemePreferencesView()
                                .environmentObject(state)
                        } label: {
                            profileRowButton(
                                icon: "paintbrush.fill",
                                title: "Tema",
                                subtitle: "Sistem, açık veya koyu görünüm seçimi",
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

                    SectionCard(title: "Destek ve Yasal", subtitle: "Yardım, geri bildirim ve metinler") {
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
                }
                .padding(14)
                .padding(.bottom, 12)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Profil")
            .sheet(isPresented: $showFeedbackSheet) {
                UserFeedbackSheet()
                    .environmentObject(state)
            }
        }
    }

    private var profileHeader: some View {
        HeroHeader(
            eyebrow: readableRole,
            title: state.profile?.fullName.isEmpty == false ? (state.profile?.fullName ?? "") : "Kullanıcı",
            subtitle: targetExamLabel,
            icon: "person.crop.circle.fill"
        ) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(initials)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                Text("Klinik profil ve ayarların burada yönetilir.")
                    .font(AppFont.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(3)
                Spacer()
            }
        }
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
