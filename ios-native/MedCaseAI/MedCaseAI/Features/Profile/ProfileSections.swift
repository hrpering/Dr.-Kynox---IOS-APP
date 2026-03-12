import SwiftUI

struct ProfileLanguagePreferencesView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedLanguageCode = "tr"
    @State private var selectedCountryCode = "TR"
    @State private var isSaving = false
    @State private var statusText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DSInfoCard(tone: .primary) {
                    Text("Dil ve Bölge")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Agent, skor ve flashcard çıktıları bu dile zorlanır. Arapça/İbranice için RTL aktif olur.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Uygulama dili")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Picker("Uygulama dili", selection: $selectedLanguageCode) {
                        ForEach(AppLanguage.supported) { language in
                            Text("\(language.nativeName) · \(language.englishName)").tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ülke")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Picker("Ülke", selection: $selectedCountryCode) {
                        ForEach(AppCountry.supported) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    Task { await savePreferences() }
                } label: {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView().tint(.white)
                        }
                        Text("Kaydet")
                    }
                    .appPrimaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isSaving)
                .opacity(isSaving ? 0.65 : 1)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Dil ve Bölge")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedLanguageCode = AppLanguage.normalizeBCP47(state.profile?.preferredLanguageCode, fallback: "tr")
            let normalizedCountry = AppCountry.normalize(state.profile?.countryCode)
            selectedCountryCode = normalizedCountry.isEmpty ? "TR" : normalizedCountry
        }
    }

    private func savePreferences() async {
        if isSaving { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await state.updateLanguagePreferences(
                preferredLanguageCode: selectedLanguageCode,
                countryCode: selectedCountryCode,
                source: "profile_edit"
            )
            statusText = "Dil tercihleri güncellendi."
        } catch {
            let message = error.localizedDescription
            let lowered = message.lowercased()
            if lowered.contains("country_code") || lowered.contains("preferred_language_code") || lowered.contains("language_source") {
                statusText = "Sunucu şeması eski görünüyor. Supabase SQL Editor'da `supabase/profiles.sql` dosyasını tekrar çalıştırıp yeniden dene."
            } else {
                statusText = message
            }
        }
    }
}

struct ProfileNotificationPreferencesView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("settings.notifications.daily_reminder") private var dailyReminder = false
    @AppStorage("settings.notifications.weekly_summary") private var weeklySummary = false
    @AppStorage("settings.notifications.challenge_reminder") private var challengeReminder = false
    @State private var authState: NotificationAuthorizationState = .notDetermined
    @State private var authInfoText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DSInfoCard(tone: .primary) {
                    Text("Bildirimler")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Hatırlatma ve özet bildirimlerini buradan yönetebilirsin.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                DSInfoCard(tone: authorizationTone) {
                    Text("Sistem izni: \(authorizationTitle)")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(authorizationSubtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)

                    if !authorizationEnabled {
                        HStack(spacing: 8) {
                            Button("Bildirim İzni İste") {
                                Task { await requestSystemPermission() }
                            }
                            .appPrimaryButton()

                            if authState == .denied {
                                Button("Ayarları Aç") {
                                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                    UIApplication.shared.open(url)
                                }
                                .appSecondaryButton()
                            }
                        }
                    }

                    if !authInfoText.isEmpty {
                        Text(authInfoText)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.warning)
                            .lineSpacing(4)
                    }
                }

                ToggleRow(
                    title: "Günlük Vaka Hatırlatması",
                    subtitle: "Her gün kısa vaka başlatma bildirimi",
                    isOn: $dailyReminder
                )
                .disabled(!authorizationEnabled)
                .opacity(authorizationEnabled ? 1 : 0.56)
                ToggleRow(
                    title: "Haftalık Özet",
                    subtitle: "Skor ve ilerleme özeti bildirimi",
                    isOn: $weeklySummary
                )
                .disabled(!authorizationEnabled)
                .opacity(authorizationEnabled ? 1 : 0.56)
                ToggleRow(
                    title: "Günün Vakası Uyarısı",
                    subtitle: "Yeni daily challenge için bildirim",
                    isOn: $challengeReminder
                )
                .disabled(!authorizationEnabled)
                .opacity(authorizationEnabled ? 1 : 0.56)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Bildirimler")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: dailyReminder) { _ in
            Task { await state.configureWeeklyGoalNotifications() }
        }
        .onChange(of: weeklySummary) { _ in
            Task { await state.configureWeeklyGoalNotifications() }
        }
        .onChange(of: challengeReminder) { _ in
            Task { await state.configureWeeklyGoalNotifications() }
        }
        .task {
            await refreshAuthorizationState()
        }
    }

    private var authorizationEnabled: Bool { authState.isEnabled }

    private var authorizationTitle: String {
        switch authState {
        case .authorized, .provisional, .ephemeral:
            return "Açık"
        case .denied:
            return "Kapalı"
        case .notDetermined:
            return "Beklemede"
        case .unknown:
            return "Bilinmiyor"
        }
    }

    private var authorizationSubtitle: String {
        switch authState {
        case .authorized, .provisional, .ephemeral:
            return "iOS izin verdi. Hatırlatma bildirimleri çalışır."
        case .denied:
            return "Bildirim izni kapalı. Ayarlardan açman gerekiyor."
        case .notDetermined:
            return "Henüz iOS bildirim izni sorulmadı."
        case .unknown:
            return "İzin durumu doğrulanamadı."
        }
    }

    private var authorizationTone: AppSemanticTone {
        switch authState {
        case .authorized, .provisional, .ephemeral:
            return .success
        case .denied:
            return .danger
        default:
            return .warning
        }
    }

    private func refreshAuthorizationState() async {
        let status = await state.fetchNotificationAuthorizationState()
        authState = status
        if !status.isEnabled {
            if dailyReminder || weeklySummary || challengeReminder {
                dailyReminder = false
                weeklySummary = false
                challengeReminder = false
            }
        }
    }

    private func requestSystemPermission() async {
        authInfoText = ""
        let granted = await state.requestNotificationPermissionAndSchedule()
        await refreshAuthorizationState()
        if !granted {
            authInfoText = "Bildirim izni verilmedi. iOS izin penceresinden onaylaman gerekiyor."
        }
    }
}

struct ProfileAudioPreferencesView: View {
    @AppStorage("settings.mode.default") private var defaultMode = "voice"
    @AppStorage("settings.audio.auto_mute_start") private var autoMuteOnStart = false
    @AppStorage("settings.audio.allow_background") private var allowBackgroundAudio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DSInfoCard(tone: .neutral) {
                    Text("Ses / Mikrofon")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Sesli veya yazılı modu varsayılan olarak ayarla.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Varsayılan vaka modu")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)

                    Picker("Varsayılan Mod", selection: $defaultMode) {
                        Text("Sesli Mod").tag("voice")
                        Text("Yazılı Mod").tag("text")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                ToggleRow(
                    title: "Sesli modda başlangıçta sessiz ol",
                    subtitle: "Oturum açıldığında mikrofonu muted başlatır",
                    isOn: $autoMuteOnStart
                )
                ToggleRow(
                    title: "Arka planda ses izni",
                    subtitle: "Uygulama arka plana geçince ses oturumu davranışı",
                    isOn: $allowBackgroundAudio
                )
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Ses / Mikrofon")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileThemePreferencesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DSInfoCard(tone: .primary) {
                    Text("Tema")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Uygulama görünümünü sistem temasına bağlayabilir veya manuel olarak açık/koyu seçebilirsin.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Görünüm Modu")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)

                    Picker("Tema", selection: Binding(
                        get: { state.themeMode },
                        set: { state.updateThemeMode($0) }
                    )) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Tema değişikliği tüm ekranlarda anında uygulanır.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Tema")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileSubscriptionView: View {
    @EnvironmentObject private var state: AppState
    @State private var isLoading = false
    @State private var payload: SubscriptionStatusResponse?
    @State private var errorText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DSInfoCard(tone: .warning) {
                    Text("Abonelik")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Mevcut planın: \(resolvedPlanLabel)")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(resolvedPeriodText)
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if isLoading && payload == nil {
                        ProgressView("Yükleniyor...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(payload?.subscription.features ?? [], id: \.featureKey) { feature in
                            HStack {
                                Text(featureLabel(feature.featureKey))
                                    .font(AppFont.body)
                                    .foregroundStyle(AppColor.textSecondary)
                                Spacer()
                                Text(featureValueText(feature))
                                    .font(AppFont.bodyMedium)
                                    .foregroundStyle(AppColor.textPrimary)
                            }
                        }
                    }
                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.warning)
                    }
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Abonelik")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSubscription()
        }
    }

    private var resolvedPlanLabel: String {
        let code = payload?.subscription.planCode.lowercased() ?? "free"
        switch code {
        case "pro": return "Pro"
        case "basic": return "Basic"
        default: return "Free"
        }
    }

    private var resolvedPeriodText: String {
        if let periodEnd = payload?.subscription.currentPeriodEnd, !periodEnd.isEmpty {
            return "Dönem sonu: \(periodEnd.prefix(10))"
        }
        return "Plan, limit ve kullanım özeti."
    }

    private func featureLabel(_ key: String) -> String {
        switch key {
        case "case_starts": return "Vaka başlatma"
        case "tool_calls": return "Tool kullanım"
        case "premium_analytics": return "Premium analiz"
        case "monthly_characters": return "Aylık karakter"
        default: return key
        }
    }

    private func featureValueText(_ feature: SubscriptionStatusResponse.Subscription.Feature) -> String {
        if feature.isUnlimited == true || feature.limit == nil {
            return "Sınırsız"
        }
        let consumed = feature.consumed ?? 0
        let limit = feature.limit ?? 0
        let remaining = max(0, (feature.remaining ?? (limit - consumed)))
        return "\(consumed)/\(limit) · kalan \(remaining)"
    }

    private func loadSubscription() async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            payload = try await state.fetchSubscriptionStatus()
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(AppColor.primary)
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ProfilePerformanceView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    profileStat(title: "Toplam Vaka", value: "\(state.caseHistory.count)")
                    profileStat(title: "Ortalama Skor", value: averageScore)
                    profileStat(title: "En İyi Bölüm", value: bestSpecialty)
                    profileStat(title: "Günlük Seri", value: "\(streakDays)")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Haftalık İlerleme")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    WeeklyProgressChart(values: recentScores)
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Rozetler")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            BadgePill(title: "İlk Vaka", icon: "sparkles", unlocked: state.caseHistory.count >= 1, accent: AppColor.primary)
                            BadgePill(title: "7 Gün Serisi", icon: "flame.fill", unlocked: streakDays >= 7, accent: AppColor.warning)
                            BadgePill(title: "Mükemmel Skor", icon: "rosette", unlocked: hasExcellentScore, accent: AppColor.success)
                            BadgePill(title: "Disiplinli Hekim", icon: "medal.fill", unlocked: state.weeklyGoalSummary.disciplineBadgeUnlocked, accent: AppColor.primaryDark)
                        }
                        .padding(.horizontal, 1)
                    }
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Performans")
    }

    private func profileStat(title: String, value: String) -> some View {
        let isEmpty = value == "--" || value == "-" || value == "0"
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.title)
                .foregroundStyle(AppColor.textPrimary)
            if isEmpty {
                ProgressView(value: progressValue(for: title))
                    .tint(AppColor.primary)
                    .frame(maxWidth: .infinity, minHeight: 8, alignment: .leading)
                Text("Hedefe \(remainingCount(for: title)) vaka kaldı")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var averageScore: String {
        let values = state.caseHistory.compactMap { $0.score?.overallScore }
        guard !values.isEmpty else { return "--" }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.0f", avg)
    }

    private var bestSpecialty: String {
        let specialties = state.caseHistory.map { $0.specialty }
        let grouped = Dictionary(grouping: specialties, by: { $0 })
        let sorted = grouped.sorted { $0.value.count > $1.value.count }
        return sorted.first.map { SpecialtyOption.label(for: $0.key) } ?? "-"
    }

    private var recentScores: [Double] {
        let scores = state.caseHistory.prefix(7).compactMap { $0.score?.overallScore }
        if scores.isEmpty { return [0, 0, 0, 0, 0, 0, 0] }
        if scores.count < 7 {
            return scores + Array(repeating: 0, count: 7 - scores.count)
        }
        return Array(scores)
    }

    private var hasExcellentScore: Bool {
        state.caseHistory.contains { ($0.score?.overallScore ?? 0) >= 90 }
    }

    private var streakDays: Int {
        WeeklyGoalCalculator.currentStreakDays(from: state.caseHistory)
    }

    private var scoredCaseCount: Int {
        state.caseHistory.filter { $0.score != nil }.count
    }

    private func metricCount(for title: String) -> Int {
        if title == "Ortalama Skor" {
            return scoredCaseCount
        }
        if title == "Günlük Seri" {
            return streakDays
        }
        return state.caseHistory.count
    }

    private func goalTarget(for title: String) -> Int {
        switch title {
        case "Toplam Vaka":
            return 5
        case "Ortalama Skor":
            return 3
        case "En İyi Bölüm":
            return 4
        case "Günlük Seri":
            return 7
        default:
            return 5
        }
    }

    private func remainingCount(for title: String) -> Int {
        max(0, goalTarget(for: title) - metricCount(for: title))
    }

    private func progressValue(for title: String) -> Double {
        let target = max(1, goalTarget(for: title))
        return min(1, Double(metricCount(for: title)) / Double(target))
    }

}

struct ProfileSupportView: View {
    @EnvironmentObject private var state: AppState
    @State private var showReportSheet = false
    @State private var showFeedbackSheet = false
    @State private var legalSheetItem: LegalSheetItem?

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Yardım Merkezi")
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.textPrimary)

                Button {
                    guard let url = LegalLinkResolver.url(for: .support) else { return }
                    legalSheetItem = LegalSheetItem(title: LegalPageLink.support.title, url: url)
                    Haptic.selection()
                } label: {
                    supportRow(icon: LegalPageLink.support.icon, title: LegalPageLink.support.title, tint: AppColor.textPrimary)
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    showReportSheet = true
                } label: {
                    supportRow(icon: "flag.fill", title: "Sorunlu İçeriği Raporla", tint: AppColor.primary)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isBusy)

                Button {
                    showFeedbackSheet = true
                } label: {
                    supportRow(icon: "bubble.left.and.bubble.right.fill", title: "Feedback Gönder", tint: AppColor.success)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isBusy)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Yardım Merkezi")
        .sheet(item: $legalSheetItem) { item in
            SafariSheet(url: item.url).ignoresSafeArea()
        }
        .sheet(isPresented: $showReportSheet) {
            ContentReportSheet(cases: state.caseHistory)
                .environmentObject(state)
        }
        .sheet(isPresented: $showFeedbackSheet) {
            UserFeedbackSheet()
                .environmentObject(state)
        }
    }

    private func supportRow(icon: String, title: String, tint: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title)
                .font(AppFont.bodyMedium)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 50)
        .padding(.horizontal, 14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ProfileLegalView: View {
    @State private var legalSheetItem: LegalSheetItem?
    private var legalItems: [LegalPageLink] { [.privacy, .terms, .kvkk, .consent, .medicalDisclaimer] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(legalItems, id: \.self) { item in
                    Button {
                        guard let url = LegalLinkResolver.url(for: item) else { return }
                        legalSheetItem = LegalSheetItem(title: item.title, url: url)
                        Haptic.selection()
                    } label: {
                        HStack {
                            Image(systemName: item.icon)
                                .foregroundStyle(AppColor.primary)
                            Text(item.title)
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .padding(.horizontal, 14)
                        .background(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Gizlilik / Koşullar")
        .sheet(item: $legalSheetItem) { item in
            SafariSheet(url: item.url).ignoresSafeArea()
        }
    }
}

struct ProfileAccountView: View {
    @EnvironmentObject private var state: AppState
    @State private var showDeleteDataAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showActionErrorAlert = false
    @State private var actionErrorMessage = ""
    @State private var isProcessingDangerAction = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ayarlar")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)

                    settingsRow(icon: "bell", title: "Bildirim tercihleri")
                    settingsRow(icon: "mic", title: "Ses / Metin varsayılanı")
                    settingsRow(icon: "dial.low", title: "Zorluk varsayılanı")
                    settingsRow(icon: "person", title: "Hesap bilgileri")
                }
                .padding(12)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    compactDangerButton(icon: "trash", title: "Verilerimi Sil", tint: AppColor.warning, background: AppColor.warningLight) {
                        showDeleteDataAlert = true
                    }
                    compactDangerButton(icon: "person.crop.circle.badge.xmark", title: "Hesabı Sil", tint: AppColor.error, background: AppColor.errorLight) {
                        showDeleteAccountAlert = true
                    }
                }
                .disabled(isProcessingDangerAction || state.isBusy)

                Button {
                    Haptic.selection()
                    state.signOut()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Çıkış Yap")
                            .font(AppFont.bodyMedium)
                        Spacer()
                    }
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 14)
                    .background(AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isProcessingDangerAction || state.isBusy)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Hesap ve Veri")
        .alert("Veriler silinsin mi?", isPresented: $showDeleteDataAlert) {
            Button("Vazgeç", role: .cancel) {}
            Button("Verilerimi Sil", role: .destructive) {
                runDeleteDataFlow()
            }
        } message: {
            Text("Vaka geçmişin, skorların ve öğrenme ilerlemen kalıcı olarak silinecek.")
        }
        .alert("Hesap kalıcı olarak silinsin mi?", isPresented: $showDeleteAccountAlert) {
            Button("Vazgeç", role: .cancel) {}
            Button("Hesabımı Sil", role: .destructive) {
                runDeleteAccountFlow()
            }
        } message: {
            Text("Bu işlem geri alınamaz. Profilin ve tüm verilerin tamamen silinir.")
        }
        .alert("İşlem Başarısız", isPresented: $showActionErrorAlert) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(actionErrorMessage)
        }
    }

    private func settingsRow(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(AppColor.primary)
            Text(title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(.vertical, 6)
    }

    private func compactDangerButton(
        icon: String,
        title: String,
        tint: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .font(AppFont.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isProcessingDangerAction {
                    ProgressView()
                        .tint(tint)
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func runDeleteDataFlow() {
        if isProcessingDangerAction { return }
        isProcessingDangerAction = true
        Task {
            do {
                try await state.deleteMyData()
            } catch {
                actionErrorMessage = error.localizedDescription
                showActionErrorAlert = true
            }
            isProcessingDangerAction = false
        }
    }

    private func runDeleteAccountFlow() {
        if isProcessingDangerAction { return }
        isProcessingDangerAction = true
        Task {
            do {
                try await state.deleteMyAccount()
            } catch {
                actionErrorMessage = error.localizedDescription
                showActionErrorAlert = true
            }
            isProcessingDangerAction = false
        }
    }
}

struct UserFeedbackSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTopic: String = "genel"
    @State private var messageText: String = ""
    @State private var isSubmitting = false
    @State private var showErrorAlert = false
    @State private var showSuccessAlert = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feedback Konusu")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)

                        Picker("Konu", selection: $selectedTopic) {
                            ForEach(feedbackTopics, id: \.value) { topic in
                                Text(topic.label).tag(topic.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(AppColor.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mesajın")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        TextEditor(text: $messageText)
                            .font(AppFont.body)
                            .lineSpacing(4)
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(AppColor.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("\(trimmedMessage.count)/1600")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }

                    Button {
                        submitFeedback()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSubmitting ? "Gönderiliyor..." : "Feedback Gönder")
                                .font(AppFont.bodyMedium)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .appPrimaryButton()
                    .disabled(isSubmitting || trimmedMessage.count < 8)

                    Text("Gönderdiğin feedback, ürün geliştirme ve kalite iyileştirme amacıyla incelenir.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
                .padding(16)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Feedback Gönder")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .alert("Feedback Alındı", isPresented: $showSuccessAlert) {
                Button("Tamam") { dismiss() }
            } message: {
                Text("Teşekkürler. Mesajın inceleme listesine eklendi.")
            }
            .alert("Feedback Gönderilemedi", isPresented: $showErrorAlert) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var feedbackTopics: [(value: String, label: String)] {
        [
            ("genel", "Genel"),
            ("ui_ux", "UI / UX"),
            ("vaka_kalitesi", "Vaka kalitesi"),
            ("skorlama_geri_bildirim", "Skorlama ve geri bildirim"),
            ("performans_hiz", "Performans / Hız"),
            ("teknik_hata", "Teknik hata"),
            ("ozellik_onerisi", "Özellik önerisi"),
            ("diger", "Diğer")
        ]
    }

    private var trimmedMessage: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitFeedback() {
        if isSubmitting { return }
        let safeMessage = String(trimmedMessage.prefix(1600))
        guard safeMessage.count >= 8 else { return }

        isSubmitting = true
        Task {
            do {
                try await state.submitUserFeedback(topic: selectedTopic, message: safeMessage)
                showSuccessAlert = true
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
            isSubmitting = false
        }
    }
}

struct ContentReportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let cases: [CaseSession]

    @State private var selectedCaseId: String = ""
    @State private var selectedCategory: String = "zararli_icerik"
    @State private var detailsText: String = ""
    @State private var isSubmitting = false
    @State private var showErrorAlert = false
    @State private var showSuccessAlert = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vaka Seç")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)

                        Picker("Vaka", selection: $selectedCaseId) {
                            Text("Vaka seçmeden raporla").tag("")
                            ForEach(cases) { item in
                                Text(item.caseTitle).tag(item.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(AppColor.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sorun Türü")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Picker("Sorun Türü", selection: $selectedCategory) {
                            ForEach(reportCategories, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(AppColor.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sorunu Açıkla")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        TextEditor(text: $detailsText)
                            .font(AppFont.body)
                            .lineSpacing(4)
                            .frame(minHeight: 140)
                            .padding(8)
                            .background(AppColor.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("\(detailsText.trimmingCharacters(in: .whitespacesAndNewlines).count)/1200")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }

                    Button {
                        submitReport()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSubmitting ? "Gönderiliyor..." : "Raporu Gönder")
                                .font(AppFont.bodyMedium)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .appPrimaryButton()
                    .disabled(isSubmitting || trimmedDetails.count < 8)

                    Text("Bu rapor yalnızca moderasyon incelemesi için kullanılır.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
                .padding(16)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("İçerik Raporla")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .alert("Rapor Gönderildi", isPresented: $showSuccessAlert) {
                Button("Tamam") { dismiss() }
            } message: {
                Text("Teşekkürler. Raporun inceleme listesine eklendi.")
            }
            .alert("Rapor Gönderilemedi", isPresented: $showErrorAlert) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var reportCategories: [(value: String, label: String)] {
        [
            ("zararli_icerik", "Zararlı içerik"),
            ("yanlis_vaka", "Yanlış/uyumsuz vaka"),
            ("yanlis_tani_geri_bildirim", "Skor veya tanı geri bildirimi yanlış"),
            ("uygunsuz_dil", "Uygunsuz dil"),
            ("teknik_sorun", "Teknik sorun"),
            ("diger", "Diğer")
        ]
    }

    private var trimmedDetails: String {
        detailsText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedCase: CaseSession? {
        guard !selectedCaseId.isEmpty else { return nil }
        return cases.first(where: { $0.id == selectedCaseId })
    }

    private func submitReport() {
        if isSubmitting { return }
        let details = String(trimmedDetails.prefix(1200))
        guard details.count >= 8 else { return }

        isSubmitting = true
        Task {
            do {
                try await state.submitContentReport(
                    caseSession: selectedCase,
                    category: selectedCategory,
                    details: details
                )
                showSuccessAlert = true
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
            isSubmitting = false
        }
    }
}
