import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = 0
    @State private var onboardingFirstName = ""
    @State private var onboardingLastName = ""
    @State private var onboardingPhone = ""
    @State private var selectedLanguageCode = "tr"
    @State private var selectedCountryCode = "TR"
    @State private var selectedTrack: UserTrack = .student
    @State private var selectedExamTarget: StudyExamTarget = .tus
    @State private var selectedExamWindow: StudyExamWindow = .threeToSixMonths
    @State private var dailyStudyMinutes: Int = 75
    @State private var isSaving = false
    @State private var errorText = ""
    @State private var legalSheetItem: LegalSheetItem?

    private let totalSteps = 5
    private var transition: AnyTransition { reduceMotion ? .opacity : .move(edge: .trailing) }
    private var completionPercent: Int {
        Int((Double(step + 1) / Double(max(totalSteps, 1)) * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.x1_5) {
                header

                ZStack {
                    switch step {
                    case 0:
                        OnboardingIdentityStep(
                            firstName: $onboardingFirstName,
                            lastName: $onboardingLastName,
                            phoneNumber: $onboardingPhone
                        )
                            .transition(transition)
                    case 1:
                        OnboardingLevelStep(selectedTrack: $selectedTrack)
                            .transition(transition)
                    case 2:
                        OnboardingStudyPlanSetupStep(
                            selectedExamTarget: $selectedExamTarget,
                            selectedExamWindow: $selectedExamWindow,
                            dailyStudyMinutes: $dailyStudyMinutes
                        )
                            .transition(transition)
                    case 3:
                        OnboardingStudyPlanReadyStep(
                            selectedExamTarget: selectedExamTarget,
                            selectedExamWindow: selectedExamWindow,
                            dailyStudyMinutes: dailyStudyMinutes
                        )
                        .transition(transition)
                    default:
                        OnboardingHowItWorksStep()
                            .transition(transition)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
                .appShadow(AppShadow.card)
            }
            .padding(.horizontal, AppSpacing.x2)
            .padding(.top, AppSpacing.x1_5)
            .padding(.bottom, AppSpacing.x1)
            .background(AppColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                onboardingBottomDock
            }
            .sheet(item: $legalSheetItem) { item in
                SafariSheet(url: item.url)
            }
            .task {
                seedIdentityFromProfileIfNeeded()
            }
        }
    }

    private var header: some View {
        HeroHeader(
            eyebrow: "Onboarding",
            title: "Adım \(step + 1) / \(totalSteps)",
            subtitle: onboardingStepSubtitle,
            icon: "person.text.rectangle",
            metrics: [
                HeroMetricItem(title: "Tamamlanma", value: "%\(completionPercent)", icon: "chart.bar.fill"),
                HeroMetricItem(title: "Seviye", value: selectedTrack.title, icon: "graduationcap"),
                HeroMetricItem(title: "Hedef", value: selectedExamTarget.title, icon: "target")
            ]
        ) {
            GeometryReader { geo in
                let totalSpacing = CGFloat(max(0, totalSteps - 1) * 7)
                let rawWidth = (geo.size.width - totalSpacing) / CGFloat(max(totalSteps, 1))
                let segmentWidth = max(1, rawWidth.isFinite ? rawWidth : 1)
                HStack(spacing: 7) {
                    ForEach(0..<totalSteps, id: \.self) { idx in
                        Capsule()
                            .fill(idx <= step ? AppColor.primary : AppColor.border)
                            .frame(width: segmentWidth, height: 5)
                    }
                }
            }
            .frame(height: 5)
        }
    }

    private var onboardingBottomDock: some View {
        BottomCTADock {
            Button {
                guard canAdvanceCurrentStep else {
                    if step == 0 {
                        errorText = "Ad, soyad ve telefon bilgisi zorunlu."
                    }
                    Haptic.error()
                    return
                }
                if step < (totalSteps - 1) {
                    Haptic.selection()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        step = min(step + 1, totalSteps - 1)
                    }
                } else {
                    Task { await completeOnboarding() }
                }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(.white)
                    }
                    Text(onboardingButtonTitle)
                }
                .appPrimaryButtonLabelStyle()
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isSaving || !canAdvanceCurrentStep)
            .opacity((isSaving || !canAdvanceCurrentStep) ? 0.55 : 1)
            .accessibilityLabel(step == totalSteps - 1 ? "Onboarding'i Tamamla" : "Devam et")
            .accessibilityHint(step == totalSteps - 1 ? "Onboarding tamamlanır ve ana sayfaya geçilir" : "Sonraki onboarding adımına geçer")
        } secondary: {
            if !errorText.isEmpty {
                ErrorStateCard(message: errorText) {
                    errorText = ""
                }
            }
        }
    }

    private var onboardingStepSubtitle: String {
        switch step {
        case 0:
            return "Profilini tamamlayarak öğrenme planını kişiselleştir."
        case 1:
            return "Mesleki seviyeni seç ve önerileri doğru zorlukta al."
        case 2:
            return "Hedef sınavını ve günlük çalışma temposunu planla."
        case 3:
            return "Planın hazır. Son detayları gözden geçir."
        default:
            return "Kurulumu tamamla ve vaka pratiğine başla."
        }
    }

    private func onboardingLegalButton(title: String, page: LegalPageLink) -> some View {
        Button {
            guard let url = LegalLinkResolver.url(for: page) else { return }
            legalSheetItem = LegalSheetItem(title: page.title, url: url)
            Haptic.selection()
        } label: {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.primaryDark)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColor.primaryLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppColor.primary.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint("Bilgilendirme sayfasını açar")
    }

    private func completeOnboarding() async {
        if isSaving { return }
        isSaving = true
        errorText = ""

        let firstName = onboardingFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = onboardingLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPhone = normalizePhoneForPayload(onboardingPhone)
        guard !firstName.isEmpty, !lastName.isEmpty, normalizedPhone != nil else {
            isSaving = false
            errorText = "Ad, soyad ve telefon bilgisi zorunlu."
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                step = 0
            }
            Haptic.error()
            return
        }

        let normalizedName = "\(firstName) \(lastName)"
        let studyMode = selectedExamWindow.recommendedCadence
        let enrichedGoals = uniqueStrings(selectedTrack.goals + [
            "Hedef sınav: \(selectedExamTarget.title)",
            "Sınava kalan süre: \(selectedExamWindow.title)",
            "Plan modu: \(studyMode.title)",
            "Günlük çalışma: \(dailyStudyMinutes) dakika"
        ])
        let enrichedInterests = uniqueStrings(selectedTrack.defaultInterests + selectedExamTarget.focusAreas)

        let payload = OnboardingPayload(
            fullName: normalizedName,
            phoneNumber: normalizedPhone ?? "",
            marketingOptIn: state.profile?.marketingOptIn ?? false,
            ageRange: "25-34",
            role: selectedTrack.role,
            goals: enrichedGoals,
            interestAreas: enrichedInterests,
            learningLevel: "\(selectedTrack.learningLevel) · \(studyMode.title)",
            onboardingCompleted: true,
            preferredLanguageCode: AppLanguage.normalizeBCP47(selectedLanguageCode, fallback: "tr"),
            countryCode: AppCountry.normalize(selectedCountryCode).isEmpty ? nil : AppCountry.normalize(selectedCountryCode),
            languageSource: "onboarding"
        )

        do {
            try await state.completeOnboarding(payload: payload)
            Haptic.success()
        } catch {
            Haptic.error()
            errorText = error.localizedDescription
        }

        isSaving = false
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private var canAdvanceCurrentStep: Bool {
        switch step {
        case 0:
            return isIdentityStepValid
        default:
            return true
        }
    }

    private var isIdentityStepValid: Bool {
        let firstName = onboardingFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = onboardingLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !firstName.isEmpty && !lastName.isEmpty && normalizePhoneForPayload(onboardingPhone) != nil
    }

    private func normalizePhoneForPayload(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard !cleaned.isEmpty else { return nil }

        if cleaned.hasPrefix("+") {
            let digits = cleaned.dropFirst().filter(\.isNumber)
            guard digits.count >= 10, digits.count <= 15 else { return nil }
            return "+\(digits)"
        }

        let digits = cleaned.filter(\.isNumber)
        guard digits.count >= 10, digits.count <= 15 else { return nil }
        return "+\(digits)"
    }

    private var onboardingButtonTitle: String {
        switch step {
        case 0: return "Seviyeni Seç"
        case 1: return "Çalışma Planına Geç"
        case 2: return "Planın Hazır"
        case 3: return "Son Adım"
        case 4: return "Onboarding'i Tamamla"
        default: return "Devam et"
        }
    }

    private func seedIdentityFromProfileIfNeeded() {
        guard onboardingFirstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              onboardingLastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fullName = state.profile?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fullName.isEmpty {
            let parts = fullName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = parts.first {
                onboardingFirstName = String(first)
            }
            if parts.count > 1 {
                onboardingLastName = String(parts[1])
            }
        }
        if onboardingPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onboardingPhone = state.profile?.phoneNumber ?? ""
        }
        selectedLanguageCode = AppLanguage.normalizeBCP47(
            state.profile?.preferredLanguageCode ?? Locale.current.identifier,
            fallback: "tr"
        )
        let seedCountry = AppCountry.normalize(state.profile?.countryCode)
        if !seedCountry.isEmpty {
            selectedCountryCode = seedCountry
        } else {
            selectedCountryCode = AppCountry.normalize(Locale.current.region?.identifier).isEmpty
                ? "TR"
                : AppCountry.normalize(Locale.current.region?.identifier)
        }
    }
}

enum UserTrack: String, CaseIterable {
    case student
    case intern
    case resident

    var title: String {
        switch self {
        case .student: return "Tıp Öğrencisi"
        case .intern: return "İntörn / Dönem 5-6"
        case .resident: return "Asistan / Uzman"
        }
    }

    var subtitle: String {
        switch self {
        case .student: return "Dönem 3-4 · Temel tanı ve anamnez"
        case .intern: return "Ayırıcı tanı · Komplikasyon yönetimi"
        case .resident: return "Karmaşık vakalar · Nadir durumlar"
        }
    }

    var color: Color {
        switch self {
        case .student: return AppColor.success
        case .intern: return AppColor.warning
        case .resident: return AppColor.error
        }
    }

    var role: String {
        switch self {
        case .student: return "Tıp Öğrencisi"
        case .intern: return "İntörn"
        case .resident: return "Asistan"
        }
    }

    var learningLevel: String {
        switch self {
        case .student: return "Kolay"
        case .intern: return "Orta"
        case .resident: return "Zor"
        }
    }

    var goals: [String] {
        switch self {
        case .student: return ["Temel anamnez", "Klinik akıl yürütme"]
        case .intern: return ["Ayırıcı tanı", "Karar zamanlaması"]
        case .resident: return ["Kritik vaka yönetimi", "Komplikasyon kontrolü"]
        }
    }

    var defaultInterests: [String] {
        switch self {
        case .student: return ["Kardiyoloji", "Pulmonoloji", "Acil Tıp"]
        case .intern: return ["Acil Tıp", "Nöroloji", "Genel Cerrahi"]
        case .resident: return ["Yoğun Bakım", "Kardiyoloji", "Nöroşirürji"]
        }
    }

    var icon: String {
        switch self {
        case .student: return "graduationcap.fill"
        case .intern: return "stethoscope.circle.fill"
        case .resident: return "cross.case.fill"
        }
    }
}

enum StudyExamTarget: String, CaseIterable {
    case tus
    case ydus
    case usmleStep2
    case europe
    case rotation

    var title: String {
        switch self {
        case .tus: return "TUS"
        case .ydus: return "YDUS"
        case .usmleStep2: return "USMLE Step 2"
        case .europe: return "Avrupa Sınavları"
        case .rotation: return "Genel Pratik / Rotasyon"
        }
    }

    var subtitle: String {
        switch self {
        case .tus: return "Klinik akıl yürütme + yüksek vaka tekrar"
        case .ydus: return "Branş derinliği + ileri karar zinciri"
        case .usmleStep2: return "Zaman baskısı + management önceliği"
        case .europe: return "Guideline odaklı sistematik yaklaşım"
        case .rotation: return "Günlük klinik akış + pratik karar alma"
        }
    }

    var icon: String {
        switch self {
        case .tus: return "book.closed.fill"
        case .ydus: return "cross.case.fill"
        case .usmleStep2: return "globe"
        case .europe: return "eurosign.circle.fill"
        case .rotation: return "stethoscope.circle.fill"
        }
    }

    var accent: Color {
        switch self {
        case .tus: return AppColor.primary
        case .ydus: return AppColor.warning
        case .usmleStep2: return AppColor.success
        case .europe: return AppColor.primaryDark
        case .rotation: return AppColor.success
        }
    }

    var accentBackground: Color {
        switch self {
        case .tus: return AppColor.primaryLight
        case .ydus: return AppColor.warningLight
        case .usmleStep2: return AppColor.successLight
        case .europe: return AppColor.primaryLight.opacity(0.85)
        case .rotation: return AppColor.successLight
        }
    }

    var focusAreas: [String] {
        switch self {
        case .tus: return ["Acil Tıp", "Dahiliye", "Pediatri"]
        case .ydus: return ["Yoğun Bakım", "Kardiyoloji", "Nöroloji"]
        case .usmleStep2: return ["Emergency Medicine", "Internal Medicine", "OB/GYN"]
        case .europe: return ["Kardiyoloji", "Enfeksiyon Hastalıkları", "Pulmonoloji"]
        case .rotation: return ["Genel Cerrahi", "Acil Tıp", "Dahiliye"]
        }
    }
}

enum StudyCadence {
    case intense
    case balanced
    case regular

    var title: String {
        switch self {
        case .intense: return "Yoğun"
        case .balanced: return "Dengeli"
        case .regular: return "Düzenli"
        }
    }

    var subtitle: String {
        switch self {
        case .intense: return "Kısa vadede yüksek tekrar + hızlı geri bildirim"
        case .balanced: return "Sürdürülebilir tempo + sabit ilerleme"
        case .regular: return "Uzun vadeli plan + güçlü kalıcılık"
        }
    }

    var color: Color {
        switch self {
        case .intense: return AppColor.error
        case .balanced: return AppColor.primary
        case .regular: return AppColor.success
        }
    }
}

enum StudyExamWindow: String, CaseIterable {
    case zeroToThreeMonths
    case threeToSixMonths
    case overSixMonths

    var title: String {
        switch self {
        case .zeroToThreeMonths: return "0-3 ay"
        case .threeToSixMonths: return "3-6 ay"
        case .overSixMonths: return "6+ ay"
        }
    }

    var detail: String {
        switch self {
        case .zeroToThreeMonths: return "Sınava yakın dönem"
        case .threeToSixMonths: return "Orta hazırlık dönemi"
        case .overSixMonths: return "Uzun hazırlık dönemi"
        }
    }

    var recommendedCadence: StudyCadence {
        switch self {
        case .zeroToThreeMonths: return .intense
        case .threeToSixMonths: return .balanced
        case .overSixMonths: return .regular
        }
    }
}
