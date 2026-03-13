import SwiftUI
import AVFoundation

struct OnboardingIntroStep: View {
    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeroIllustration()
                .frame(height: 246)
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
        .padding(.top, 8)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Adım 5/5")
                    .font(AppFont.h3)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text("TAMAMLANDI")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.success)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppColor.successLight)
                    .clipShape(Capsule())
            }

            Capsule()
                .fill(AppColor.success)
                .frame(height: 12)

            Text("Tebrikler!")
                .font(AppFont.h1)
                .foregroundStyle(AppColor.textPrimary)
            Text("Kurulum başarıyla tamamlandı.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)

            VStack(spacing: 10) {
                HowItWorksCompactRow(
                    icon: "stethoscope",
                    title: "Bölümünü seç",
                    subtitle: "Uzmanlık alanına en uygun vakaları belirle.",
                    tint: AppColor.primary
                )
                HowItWorksCompactRow(
                    icon: "figure.walk",
                    title: "Vakayı yönet",
                    subtitle: "Simülasyon üzerinde gerçekçi tedavi adımlarını uygula.",
                    tint: AppColor.warning
                )
                HowItWorksCompactRow(
                    icon: "chart.bar.fill",
                    title: "Skorunu gör",
                    subtitle: "Performans analizini ve mesleki gelişimini anlık takip et.",
                    tint: AppColor.success
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct HowItWorksCompactRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ConversationScreenshotCard: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Örnek konuşma ekranı")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Label("Demo", systemImage: "play.circle.fill")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primary)
            }

            VStack(spacing: 8) {
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
        .padding(12)
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
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AppColor.primaryLight)
                .clipShape(Capsule())
                .padding(9)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Örnek Vaka Konuşması")
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.textPrimary)

                    Text("Dr. Kynox solda, senin mesajların sağda görünür. Gerçek vakada akış bu yapıyla ilerler.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)

                    VStack(spacing: 10) {
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
                .padding(16)
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
        VStack(alignment: .leading, spacing: 14) {
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
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        .background(AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .background(AppColor.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

struct OnboardingLanguageCountryStep: View {
    @Binding var selectedLanguageCode: String
    @Binding var selectedCountryCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dil ve Ülke Seçimi")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text("Uygulama metinleri, agent çıktıları ve skor geri bildirimi bu dile göre gösterilir.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Uygulama Dili")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Picker("Uygulama Dili", selection: $selectedLanguageCode) {
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

            VStack(alignment: .leading, spacing: 6) {
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

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(AppColor.primary)
                Text("BCP-47 dil kodu kullanılır. Arapça/İbranice için arayüz sağdan sola hizalanır.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            selectedLanguageCode = AppLanguage.normalizeBCP47(selectedLanguageCode, fallback: "tr")
            let normalizedCountry = AppCountry.normalize(selectedCountryCode)
            selectedCountryCode = normalizedCountry.isEmpty ? "TR" : normalizedCountry
        }
    }
}

struct OnboardingLevelStep: View {
    @Binding var selectedTrack: UserTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
                    .background(selectedTrack == track ? AppColor.primaryLight : AppColor.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .stroke(selectedTrack == track ? AppColor.primary : AppColor.border, lineWidth: selectedTrack == track ? 2 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
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
    private let examGridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sana özel çalışma planı oluşturalım")
                .font(AppFont.title)
                .foregroundStyle(AppColor.textPrimary)

            VStack(spacing: 8) {
                HStack {
                    Text("İlerleme Durumu")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Spacer()
                    Text("%60")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textPrimary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppColor.border.opacity(0.45))
                        Capsule()
                            .fill(AppColor.success)
                            .frame(width: max(0, geo.size.width * 0.60))
                    }
                }
                .frame(height: 8)
            }

            sectionHeader(icon: "target", title: "Hedef sınav")

            LazyVGrid(columns: examGridColumns, spacing: 10) {
                ForEach(StudyExamTarget.allCases, id: \.self) { target in
                    let isSelected = selectedExamTarget == target
                    Button {
                        selectedExamTarget = target
                        Haptic.selection()
                    } label: {
                        Text(displayTitle(for: target))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(isSelected ? AppColor.primaryDark : AppColor.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(isSelected ? AppColor.primaryLight : AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .stroke(isSelected ? AppColor.primary.opacity(0.45) : AppColor.border, lineWidth: isSelected ? 1.5 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            sectionHeader(icon: "calendar", title: "Sınava ne kadar var?")

            VStack(spacing: 10) {
                ForEach(StudyExamWindow.allCases, id: \.self) { window in
                    let isSelected = selectedExamWindow == window
                    Button {
                        selectedExamWindow = window
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .stroke(isSelected ? AppColor.primary : AppColor.border, lineWidth: 2)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .fill(AppColor.primary)
                                        .frame(width: 10, height: 10)
                                        .opacity(isSelected ? 1 : 0)
                                )

                            Text(window.title)
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(isSelected ? AppColor.primaryLight.opacity(0.7) : AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .stroke(isSelected ? AppColor.primary.opacity(0.45) : AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Günde kaç dakika?")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("\(dailyStudyMinutes) dk")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(AppColor.primaryLight)
                        .clipShape(Capsule())
                }

                Slider(value: Binding(
                    get: { Double(dailyStudyMinutes) },
                    set: { dailyStudyMinutes = Int($0.rounded()) }
                ), in: 15...300, step: 15)
                .tint(AppColor.primary)

                HStack {
                    Text("15 dk")
                    Spacer()
                    Text("300 dk")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
            }
            .padding(14)
            .background(AppColor.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

            Text("Ayarlarınızı daha sonra değiştirebilirsiniz.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AppColor.primaryLight)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.primary)
                )
            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
    }

    private func displayTitle(for target: StudyExamTarget) -> String {
        switch target {
        case .tus: return "TUS"
        case .ydus: return "YDUS"
        case .usmleStep2: return "USMLE"
        case .europe: return "DUS"
        case .rotation: return "Genel Pratik"
        }
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
