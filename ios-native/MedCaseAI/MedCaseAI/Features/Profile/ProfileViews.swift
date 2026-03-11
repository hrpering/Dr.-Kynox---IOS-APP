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

                    HStack(spacing: 10) {
                        miniStat(title: "Vaka", value: "\(state.caseHistory.count)")
                        miniStat(title: "Skor", value: averageScore)
                        miniStat(title: "Seri", value: "\(streakDays)")
                    }

                    sectionTitle("Çalışma")
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

                    sectionTitle("Hesap")
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

                    sectionTitle("Destek ve Yasal")
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

    private var profileHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppColor.primaryLight)
                .frame(width: 64, height: 64)
                .overlay(
                    Text(initials)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.primary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(state.profile?.fullName.isEmpty == false ? (state.profile?.fullName ?? "") : "Kullanıcı")
                    .font(AppFont.title)
                    .foregroundStyle(AppColor.textPrimary)
                Text(readableRole)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppColor.primaryLight)
                    .clipShape(Capsule())
                Text(targetExamLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppFont.title2)
            .foregroundStyle(AppColor.textPrimary)
            .padding(.top, 4)
    }

    private func profileRowButton(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
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
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

