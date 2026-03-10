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
    @State private var selectedTrack: UserTrack = .student
    @State private var selectedExamTarget: StudyExamTarget = .tus
    @State private var selectedExamWindow: StudyExamWindow = .threeToSixMonths
    @State private var dailyStudyMinutes: Int = 75
    @State private var isSaving = false
    @State private var errorText = ""
    @State private var legalSheetItem: LegalSheetItem?
    @State private var introLegalAccepted = false

    private let totalSteps = 6
    private var transition: AnyTransition { reduceMotion ? .opacity : .move(edge: .trailing) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                ZStack {
                    switch step {
                    case 0:
                        OnboardingIntroStep()
                            .transition(transition)
                    case 1:
                        OnboardingHowItWorksStep()
                            .transition(transition)
                    case 2:
                        OnboardingIdentityStep(
                            firstName: $onboardingFirstName,
                            lastName: $onboardingLastName,
                            phoneNumber: $onboardingPhone
                        )
                        .transition(transition)
                    case 3:
                        OnboardingLevelStep(selectedTrack: $selectedTrack)
                            .transition(transition)
                    case 4:
                        OnboardingStudyPlanSetupStep(
                            selectedExamTarget: $selectedExamTarget,
                            selectedExamWindow: $selectedExamWindow,
                            dailyStudyMinutes: $dailyStudyMinutes
                        )
                        .transition(transition)
                    default:
                        OnboardingStudyPlanReadyStep(
                            selectedExamTarget: selectedExamTarget,
                            selectedExamWindow: selectedExamWindow,
                            dailyStudyMinutes: dailyStudyMinutes
                        )
                        .transition(transition)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)

                if step == 0 {
                    onboardingLegalLinks
                }

                Button {
                    guard canAdvanceCurrentStep else {
                        if step == 2 {
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

                if !errorText.isEmpty {
                    ErrorStateCard(message: errorText) {
                        errorText = ""
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(AppColor.background.ignoresSafeArea())
            .sheet(item: $legalSheetItem) { item in
                SafariSheet(url: item.url)
            }
            .task {
                seedIdentityFromProfileIfNeeded()
            }
            .toolbar {
                if step < 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Geç") {
                            Haptic.selection()
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                step = 2
                            }
                        }
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.primary)
                        .disabled(isSaving)
                        .accessibilityLabel("Geç")
                        .accessibilityHint("Onboarding adımlarını atlar")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let totalSpacing = CGFloat(max(0, totalSteps - 1) * 8)
                let rawWidth = (geo.size.width - totalSpacing) / CGFloat(max(totalSteps, 1))
                let segmentWidth = max(1, rawWidth.isFinite ? rawWidth : 1)
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { idx in
                        Capsule()
                            .fill(idx <= step ? AppColor.primary : AppColor.border)
                            .frame(width: segmentWidth, height: 6)
                    }
                }
            }
            .frame(height: 6)

        }
        .padding(.top, 4)
    }

    private var onboardingLegalLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devam etmeden önce metinleri inceleyebilirsin:")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            HStack(spacing: 10) {
                onboardingLegalButton(title: "Tıbbi Red", page: .medicalDisclaimer)
                onboardingLegalButton(title: "Açık Rıza", page: .consent)
            }

            Button {
                introLegalAccepted.toggle()
                Haptic.selection()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: introLegalAccepted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(introLegalAccepted ? AppColor.success : AppColor.textTertiary)
                        .frame(width: 20, height: 20)
                    Text("Tıbbi Sorumluluk Reddi ve Açık Rıza metinlerini okudum, kabul ediyorum.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(introLegalAccepted ? AppColor.success.opacity(0.35) : AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Yasal metinleri kabul et")
            .accessibilityHint("Onboarding adımında devam etmek için gerekli onay")

            if !introLegalAccepted {
                Text("Devam etmek için onay kutusunu işaretle.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.warning)
                    .lineSpacing(3)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                step = 2
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
            onboardingCompleted: true
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
            return introLegalAccepted
        case 2:
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
        case 0: return "Devam et"
        case 1: return "Anladım, Başlayalım"
        case 2: return "Seviyeni Seç"
        case 3: return "Çalışma Planına Geç"
        case 4: return "Planım Hazır"
        case 5: return "Onboarding'i Tamamla"
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

struct OnboardingIntroStep: View {
    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeroIllustration()
                .frame(height: 276)
                .frame(maxWidth: .infinity)

            Text("Klinik pratiğinin yapay zeka asistanı")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Text("Sadece konuş veya yaz. Gerçekçi vaka akışında kararlarını test et, geri bildirimini anında al.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
    }
}

struct OnboardingHeroIllustration: View {
    var body: some View {
        IntroMotionCard(variant: .long)
            .accessibilityHidden(true)
    }
}

struct OnboardingHowItWorksStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nasıl Çalışır")
                .font(AppFont.title)
                .foregroundStyle(AppColor.textPrimary)

            Text("3 kısa adımda vaka akışına girer, sonunda net geri bildirim alırsın.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Örnek konuşma")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("Canlı akış")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.success)
                }

                DemoMessageBubble(
                    sender: "Dr. Kynox",
                    text: "35 yaşında hastada ateş ve halsizlik var. İlk yaklaşımın ne olur?",
                    isAgent: true
                )
                DemoMessageBubble(
                    sender: "Sen",
                    text: "Önce öyküyü derinleştirir, ardından tam kan ve CRP isterim.",
                    isAgent: false
                )
            }
            .padding(10)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                onboardingModePill(
                    icon: "mic.fill",
                    title: "Sesli",
                    subtitle: "Doğal konuşma",
                    tint: AppColor.success,
                    background: AppColor.successLight
                )
                onboardingModePill(
                    icon: "keyboard",
                    title: "Yazılı",
                    subtitle: "Hızlı mesaj",
                    tint: AppColor.primary,
                    background: AppColor.primaryLight
                )
            }

            VStack(spacing: 8) {
                HowItWorksCompactRow(
                    icon: "1.circle.fill",
                    title: "Bölümünü seç",
                    subtitle: "İstediğin klinik alandan başla.",
                    tint: AppColor.primary
                )
                HowItWorksCompactRow(
                    icon: "2.circle.fill",
                    title: "Vakayı yönet",
                    subtitle: "Soru sor, test iste, planını kur.",
                    tint: AppColor.success
                )
                HowItWorksCompactRow(
                    icon: "3.circle.fill",
                    title: "Skorunu gör",
                    subtitle: "Güçlü ve gelişecek alanların çıksın.",
                    tint: AppColor.warning
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func onboardingModePill(icon: String,
                                    title: String,
                                    subtitle: String,
                                    tint: Color,
                                    background: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct HowItWorksCompactRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ConversationScreenshotCard: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Örnek konuşma ekranı")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Label("Demo", systemImage: "play.circle.fill")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primary)
            }

            VStack(spacing: 10) {
                DemoMessageBubble(
                    sender: "Dr. Kynox",
                    text: "35 yaşında erkek hasta, son 3 aydır uyku düzensizliği ve belirgin anksiyete ile başvuruyor.",
                    isAgent: true
                )
                DemoMessageBubble(
                    sender: "Sen",
                    text: "Ayırıcı tanı için tam kan, TSH ve B12 isterim. Ek risk faktörleri var mı?",
                    isAgent: false
                )
                DemoMessageBubble(
                    sender: "Dr. Kynox",
                    text: "İş stresi artmış, iştah azalmış. Laboratuvar sonuçlarını şimdi paylaşıyorum.",
                    isAgent: true
                )
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Text("Dokun ve büyüt")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.primaryDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppColor.primaryLight)
                .clipShape(Capsule())
                .padding(10)
        }
    }
}

struct DemoMessageBubble: View {
    let sender: String
    let text: String
    let isAgent: Bool

    var body: some View {
        HStack {
            if !isAgent { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                Text(sender)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isAgent ? AppColor.primaryDark : AppColor.textSecondary)
                Text(text)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isAgent ? AppColor.surfaceAlt : AppColor.primaryLight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 320, alignment: .leading)
            if isAgent { Spacer(minLength: 32) }
        }
    }
}

struct ConversationDemoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Örnek Vaka Konuşması")
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.textPrimary)

                    Text("Dr. Kynox solda, senin mesajların sağda görünür. Gerçek vakada akış bu yapıyla ilerler.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)

                    VStack(spacing: 12) {
                        DemoMessageBubble(
                            sender: "Dr. Kynox",
                            text: "45 yaşında erkek hasta, göğüs ağrısı ve nefes darlığı ile acile başvuruyor. İlk sorularını alayım.",
                            isAgent: true
                        )
                        DemoMessageBubble(
                            sender: "Sen",
                            text: "Ağrı ne zaman başladı, efora bağlı mı, kola veya çeneye yayılım var mı?",
                            isAgent: false
                        )
                        DemoMessageBubble(
                            sender: "Dr. Kynox",
                            text: "Ağrı 1 saat önce başladı, sol kola yayılıyor. EKG ve troponin istiyor musun?",
                            isAgent: true
                        )
                        DemoMessageBubble(
                            sender: "Sen",
                            text: "Evet, 12 derivasyon EKG, troponin ve vital bulguları hemen görmek istiyorum.",
                            isAgent: false
                        )
                    }
                }
                .padding(20)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ModeHighlightCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let background: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)

            Text(subtitle)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct OnboardingIdentityStep: View {
    @Binding var firstName: String
    @Binding var lastName: String
    @Binding var phoneNumber: String
    @State private var selectedDialCode: String = "+90"
    @State private var localPhoneText: String = ""

    private struct DialCodeOption: Identifiable, Hashable {
        let id: String
        let flag: String
        let name: String
        let dialCode: String
    }

    private let dialCodeOptions: [DialCodeOption] = [
        .init(id: "TR", flag: "🇹🇷", name: "Türkiye", dialCode: "+90"),
        .init(id: "US", flag: "🇺🇸", name: "ABD", dialCode: "+1"),
        .init(id: "GB", flag: "🇬🇧", name: "Birleşik Krallık", dialCode: "+44"),
        .init(id: "DE", flag: "🇩🇪", name: "Almanya", dialCode: "+49"),
        .init(id: "FR", flag: "🇫🇷", name: "Fransa", dialCode: "+33"),
        .init(id: "SA", flag: "🇸🇦", name: "Suudi Arabistan", dialCode: "+966")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kişisel Bilgiler")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text("Vaka geri bildirimini kişiselleştirmek için ad, soyad ve telefon bilgisini ekle.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            identityField(title: "Ad *", placeholder: "Adın", text: $firstName, contentType: .givenName)
            identityField(title: "Soyad *", placeholder: "Soyadın", text: $lastName, contentType: .familyName)

            VStack(alignment: .leading, spacing: 6) {
                Text("Telefon *")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)

                HStack(spacing: 8) {
                    Menu {
                        ForEach(dialCodeOptions) { option in
                            Button("\(option.flag) \(option.name) (\(option.dialCode))") {
                                selectedDialCode = option.dialCode
                                let digits = digitsOnly(localPhoneText)
                                localPhoneText = formatLocalDigits(digits, dialCode: selectedDialCode)
                                syncPhoneBinding()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedDialCodeDisplay)
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(minWidth: 108, minHeight: 52, alignment: .leading)
                        .background(AppColor.surfaceAlt)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())

                    TextField(localPhonePlaceholder, text: $localPhoneText)
                        .font(AppFont.body)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 52)
                        .background(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: localPhoneText) { newValue in
                            let digits = digitsOnly(newValue)
                            let clipped = String(digits.prefix(maxLocalDigits(for: selectedDialCode)))
                            let formatted = formatLocalDigits(clipped, dialCode: selectedDialCode)
                            if formatted != newValue {
                                localPhoneText = formatted
                            }
                            syncPhoneBinding()
                        }
                }

                Text("Ülke kodu ile birlikte gir. Örn: \(selectedDialCode) \(localPhonePlaceholder)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColor.success)
                Text("Bilgiler yalnızca profil ve iletişim amacıyla kullanılır.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            .padding(.top, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            seedFromPhoneBindingIfNeeded()
        }
    }

    private func identityField(title: String,
                               placeholder: String,
                               text: Binding<String>,
                               keyboard: UIKeyboardType = .default,
                               contentType: UITextContentType? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            TextField(placeholder, text: text)
                .font(AppFont.body)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var selectedDialCodeDisplay: String {
        if let option = dialCodeOptions.first(where: { $0.dialCode == selectedDialCode }) {
            return "\(option.flag) \(option.dialCode)"
        }
        return selectedDialCode
    }

    private var localPhonePlaceholder: String {
        selectedDialCode == "+90" ? "5XX XXX XX XX" : "XXX XXX XXXX"
    }

    private func seedFromPhoneBindingIfNeeded() {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("+") {
            let numeric = String(compact.dropFirst().filter(\.isNumber))
            let sorted = dialCodeOptions.sorted { $0.dialCode.count > $1.dialCode.count }
            if let match = sorted.first(where: { numeric.hasPrefix($0.dialCode.dropFirst()) }) {
                selectedDialCode = match.dialCode
                let dialDigitsCount = match.dialCode.dropFirst().count
                let local = String(numeric.dropFirst(dialDigitsCount))
                localPhoneText = formatLocalDigits(local, dialCode: selectedDialCode)
                return
            }
        }

        let fallbackDigits = digitsOnly(trimmed)
        localPhoneText = formatLocalDigits(fallbackDigits, dialCode: selectedDialCode)
        syncPhoneBinding()
    }

    private func syncPhoneBinding() {
        let digits = digitsOnly(localPhoneText)
        if digits.isEmpty {
            phoneNumber = ""
            return
        }
        phoneNumber = "\(selectedDialCode) \(formatLocalDigits(digits, dialCode: selectedDialCode))"
    }

    private func digitsOnly(_ value: String) -> String {
        String(value.filter(\.isNumber))
    }

    private func maxLocalDigits(for dialCode: String) -> Int {
        switch dialCode {
        case "+90":
            return 10
        case "+1":
            return 10
        default:
            return 12
        }
    }

    private func formatLocalDigits(_ rawDigits: String, dialCode: String) -> String {
        var digits = rawDigits
        if dialCode == "+90", digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
        }
        digits = String(digits.prefix(maxLocalDigits(for: dialCode)))
        if digits.isEmpty { return "" }

        let grouping: [Int]
        switch dialCode {
        case "+90":
            grouping = [3, 3, 2, 2]
        case "+1":
            grouping = [3, 3, 4]
        default:
            grouping = [3, 3, 3, 3]
        }

        var result: [String] = []
        var start = digits.startIndex
        for size in grouping {
            guard start < digits.endIndex else { break }
            let end = digits.index(start, offsetBy: size, limitedBy: digits.endIndex) ?? digits.endIndex
            result.append(String(digits[start..<end]))
            start = end
        }
        return result.joined(separator: " ")
    }
}

struct OnboardingLevelStep: View {
    @Binding var selectedTrack: UserTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seviyeni Seç")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text("Kime yönelik olduğunu netleştir; içerik akışı buna göre kişiselleşsin.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            ForEach(UserTrack.allCases, id: \.self) { track in
                Button {
                    selectedTrack = track
                    Haptic.selection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: track.icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(track.color)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(AppFont.title2)
                                .foregroundStyle(AppColor.textPrimary)
                            Text(track.subtitle)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if selectedTrack == track {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(AppColor.primary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
                    .background(selectedTrack == track ? AppColor.primaryLight : AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selectedTrack == track ? AppColor.primary : AppColor.border, lineWidth: selectedTrack == track ? 2 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
    }
}

struct OnboardingStudyPlanSetupStep: View {
    @Binding var selectedExamTarget: StudyExamTarget
    @Binding var selectedExamWindow: StudyExamWindow
    @Binding var dailyStudyMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sana özel çalışma planı oluşturalım")
                .font(AppFont.title)
                .foregroundStyle(AppColor.textPrimary)

            Text("Hedef sınavını, sınava kalan süreni ve günlük ayırabileceğin zamanı seç.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Text("Hedef sınav")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            VStack(spacing: 10) {
                ForEach(StudyExamTarget.allCases, id: \.self) { target in
                    let isSelected = selectedExamTarget == target
                    Button {
                        selectedExamTarget = target
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: target.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(target.accent)
                                .frame(width: 32, height: 32)
                                .background(target.accentBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.title)
                                    .font(AppFont.bodyMedium)
                                    .foregroundStyle(AppColor.textPrimary)
                                Text(target.subtitle)
                                    .font(AppFont.caption)
                                    .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                                    .lineSpacing(3)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(target.accent)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(AppColor.textTertiary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? target.accentBackground.opacity(0.9) : AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isSelected ? target.accent : AppColor.border, lineWidth: isSelected ? 2 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            Text("Sınava ne kadar var?")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .padding(.top, 2)

            HStack(spacing: 10) {
                ForEach(StudyExamWindow.allCases, id: \.self) { window in
                    Button {
                        selectedExamWindow = window
                        Haptic.selection()
                    } label: {
                        VStack(spacing: 3) {
                            Text(window.title)
                                .font(AppFont.bodyMedium)
                            Text(window.detail)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedExamWindow == window ? AppColor.primaryDark : AppColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(selectedExamWindow == window ? AppColor.primaryLight : AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selectedExamWindow == window ? AppColor.primary : AppColor.border, lineWidth: selectedExamWindow == window ? 2 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Günde kaç dakika ayırabilirsin?")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("\(dailyStudyMinutes) dk")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.primaryDark)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(AppColor.primaryLight)
                        .clipShape(Capsule())
                }

                Slider(value: Binding(
                    get: { Double(dailyStudyMinutes) },
                    set: { dailyStudyMinutes = Int($0.rounded()) }
                ), in: 15...180, step: 15)
                .tint(AppColor.primary)

                HStack {
                    Text("15 dk")
                    Spacer()
                    Text("180 dk")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
            }
            .padding(12)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct OnboardingStudyPlanReadyStep: View {
    let selectedExamTarget: StudyExamTarget
    let selectedExamWindow: StudyExamWindow
    let dailyStudyMinutes: Int

    private var cadence: StudyCadence { selectedExamWindow.recommendedCadence }
    private var dailyCaseGoal: Int { max(1, dailyStudyMinutes / 25) }
    private var weeklyCaseGoal: Int { max(3, dailyCaseGoal * 5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planın hazır")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text("Seçimlerine göre kişisel çalışma planın oluşturuldu. Devam ettiğinde hedeflerin profiline kaydedilecek.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            VStack(alignment: .leading, spacing: 10) {
                planRow(icon: "target", title: "Hedef sınav", value: selectedExamTarget.title)
                planRow(icon: "calendar", title: "Kalan süre", value: selectedExamWindow.title)
                planRow(icon: "timer", title: "Günlük süre", value: "\(dailyStudyMinutes) dakika")
                planRow(icon: "bolt.fill", title: "Plan modu", value: cadence.title)
            }
            .padding(14)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(cadence.color.opacity(0.20))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(cadence.color)
                        )
                    Text("Önerilen tempo: \(cadence.title)")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                }

                Text(cadence.subtitle)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)

                Text("Başlangıç hedefin: günde yaklaşık \(dailyCaseGoal) vaka adımı, haftada \(weeklyCaseGoal) vaka.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            .padding(14)
            .background(AppColor.primaryLight.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func planRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.primary)
                .frame(width: 28, height: 28)
                .background(AppColor.primaryLight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct OnboardingMicPermissionStep: View {
    let requestMicAction: () -> Void
    let skipMicAction: () -> Void
    let isSaving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 12) {
                Circle()
                    .fill(AppColor.primaryLight)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(AppColor.primary)
                    )

                Text("Sesli vaka için mikrofon gerekiyor")
                    .font(AppFont.title)
                    .foregroundStyle(AppColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Sesli vakada gerçek hasta simülasyonuna yakın akış yaşarsın.")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    micBenefitRow(text: "Mikrofon yalnızca vaka sırasında kullanılır.")
                    micBenefitRow(text: "İstediğinde yazılı moda geçebilirsin.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Sesiniz kaydedilmez, saklanmaz, üçüncü taraflarla paylaşılmaz.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)

                Button(action: requestMicAction) {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.white) }
                        Text("İzin Ver")
                            .font(AppFont.bodyMedium)
                    }
                    .appPrimaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isSaving)
                .accessibilityLabel("İzin Ver")
                .accessibilityHint("Mikrofon izni ister")

                Button(action: skipMicAction) {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(AppColor.primary) }
                        Text("Şimdi değil, metin modunda dene")
                            .appSecondaryButtonLabelStyle()
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isSaving)
                .accessibilityLabel("Şimdi değil, metin modunda dene")
                .accessibilityHint("Onboarding tamamlanır ve metin modu kullanılabilir")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func micBenefitRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.success)
            Text(text)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
    }
}

struct OnboardingWidgetStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Widget ile hızlı erişim")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text("Ana ekran ve kilit ekranı widget'ı ile günün vakasını anında gör, tek dokunuşla uygulamaya dön.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            VStack(alignment: .leading, spacing: 10) {
                widgetGuideRow(number: "1", text: "Ana ekranda boş bir alana uzun bas.")
                widgetGuideRow(number: "2", text: "Sol üstteki + butonuna dokun.")
                widgetGuideRow(number: "3", text: "Listeden Dr.Kynox Widget'ı seç.")
                widgetGuideRow(number: "4", text: "Ana ekran veya kilit ekranına ekleyip kaydet.")
            }
            .padding(12)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                WidgetPreviewCard(title: "Ana Ekran", icon: "rectangle.grid.2x2.fill")
                WidgetPreviewCard(title: "Kilit Ekranı", icon: "lock.rectangle.stack.fill")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func widgetGuideRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(AppFont.caption)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(AppColor.primary)
                .clipShape(Circle())
            Text(text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
    }
}

struct WidgetPreviewCard: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(AppColor.primary)
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColor.primaryLight)
                .frame(height: 70)
                .overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Günün Vakası")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.primary)
                        Text("Kardiyoloji • Orta")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .padding(8),
                    alignment: .topLeading
                )
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

