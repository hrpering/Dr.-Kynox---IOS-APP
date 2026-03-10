import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry
#if canImport(Supabase)
import Supabase
#endif

struct AuthFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Screen {
        case welcome
        case signIn
        case signUp
        case checkEmail
    }

    private enum EmailFlow {
        case signupVerification
        case passwordReset
    }

    @State private var screen: Screen = .welcome
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var infoText = ""
    @State private var errorText = ""
    @State private var isResendingVerification = false
    @State private var resendCooldownUntil: Date?
    @State private var resendCountdownNow: Date = Date()
    @State private var signInRedirectDeadline: Date?
    @State private var pendingVerificationEmail = ""
    @State private var emailFlow: EmailFlow = .signupVerification
    @State private var verificationCode = ""
    @State private var verificationCompleted = false
    @State private var resetCodeVerified = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var legalSheetItem: LegalSheetItem?
    @FocusState private var focusedField: Field?

    private enum Field {
        case otp
        case newPassword
        case confirmPassword
        case email
        case password
    }

    private var isSignUp: Bool { screen == .signUp }
    private var isPasswordResetFlow: Bool { emailFlow == .passwordReset }
    private var transition: AnyTransition { reduceMotion ? .opacity : .move(edge: .trailing) }
    private let otpMinLength = 6
    private let otpMaxLength = 8
    private let resendCooldownSeconds: TimeInterval = 120
    private let signInRedirectSeconds: TimeInterval = 3
    private let resendTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                ZStack {
                    AppColor.background.ignoresSafeArea()

                    if screen == .welcome {
                        VStack {
                            Spacer(minLength: 0)
                            welcomeCard
                                .transition(transition)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                    } else if screen == .checkEmail {
                        ScrollView {
                            VStack(spacing: 18) {
                                checkEmailCard
                                    .transition(transition)
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(20)
                            .padding(.bottom, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .keyboardAdaptive()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 16) {
                                    authForm
                                        .transition(transition)
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                                .padding(20)
                                .padding(.bottom, 8)
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .safeAreaInset(edge: .bottom) {
                                authBottomDock
                            }
                            .onChange(of: focusedField) { field in
                                guard let anchor = fieldAnchorId(for: field) else { return }
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(anchor, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .onChange(of: state.statusMessage) { newValue in
                    let message = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    let lowered = message.lowercased(with: Locale(identifier: "tr_TR"))
                    if lowered.contains("e-posta doğrulandı") {
                        verificationCompleted = true
                        infoText = "E-posta doğrulandı."
                        errorText = ""
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            screen = .checkEmail
                        }
                        startSignInRedirectCountdown()
                        state.statusMessage = ""
                        return
                    }
                    infoText = message
                    errorText = ""
                    state.statusMessage = ""
                }
                .toolbar {
                    if screen != .welcome {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                    errorText = ""
                                    focusedField = nil
                                    if screen == .checkEmail {
                                        clearAuthFieldsForSignIn()
                                        screen = .signIn
                                    } else {
                                        screen = .welcome
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .foregroundStyle(AppColor.textPrimary)
                            }
                            .accessibilityLabel("Geri")
                            .accessibilityHint("Hoş geldin ekranına döner")
                        }

                        ToolbarItemGroup(placement: .keyboard) {
                            if focusedField != nil {
                                Button(
                                    focusedField == .otp
                                    ? "Doğrula"
                                    : (focusedField == .newPassword || focusedField == .confirmPassword
                                       ? "Şifreyi Güncelle"
                                    : (focusedField == .password ? (isSignUp ? "Hesap Oluştur" : "Giriş Yap") : "İleri")
                                      )
                                ) {
                                    if focusedField == .otp {
                                        Task { await verifyEmailCode() }
                                    } else if focusedField == .newPassword || focusedField == .confirmPassword {
                                        Task { await completePasswordReset() }
                                    } else {
                                        advanceAuthFocus()
                                    }
                                }
                                Spacer()
                                Button("Kapat") {
                                    focusedField = nil
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $legalSheetItem) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .onReceive(resendTicker) { now in
            resendCountdownNow = now

            if let until = resendCooldownUntil, until <= now {
                resendCooldownUntil = nil
            }

            if let redirectUntil = signInRedirectDeadline, redirectUntil <= now {
                signInRedirectDeadline = nil
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    clearAuthFieldsForSignIn()
                    screen = .signIn
                }
            }
        }
        .onAppear {
            UISoundEngine.shared.preloadIfNeeded()
            refreshAmbientForScreen()
        }
        .onDisappear {
            UISoundEngine.shared.stopAmbient()
        }
        .onChange(of: screen) { _ in
            refreshAmbientForScreen()
        }
    }

    private var welcomeCard: some View {
        VStack(spacing: 18) {
            IntroMotionCard(variant: .short)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Text("Dr.Kynox")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.textPrimary)

            Text("Klinik pratiğinin yapay zeka asistanı")
                .font(AppFont.title)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Text("Gerçek klinik vakalar üzerinde düşün.\nTanı koy, test iste, yönetim planı oluştur.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            VStack(spacing: 10) {
                FeatureHighlightRow(
                    icon: "mic.fill",
                    title: "Sesli etkileşim",
                    subtitle: "Doğal konuşma ile vaka yönetimi",
                    tint: AppColor.primary
                )
                FeatureHighlightRow(
                    icon: "waveform.path.ecg",
                    title: "Gerçek zamanlı geri bildirim",
                    subtitle: "Karar zincirini adım adım gör",
                    tint: AppColor.success
                )
                FeatureHighlightRow(
                    icon: "chart.bar.xaxis",
                    title: "İlerleme takibi",
                    subtitle: "Skorlarını ve gelişimini izle",
                    tint: AppColor.warning
                )
            }
            .padding(14)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    errorText = ""
                    infoText = ""
                    emailFlow = .signupVerification
                    verificationCompleted = false
                    resetCodeVerified = false
                    focusedField = nil
                    screen = .signUp
                }
            } label: {
                Text("Vaka başlat")
                    .appPrimaryButtonLabel()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Vaka başlat")
            .accessibilityHint("Kayıt ekranına geçer")

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    errorText = ""
                    infoText = ""
                    emailFlow = .signupVerification
                    verificationCompleted = false
                    resetCodeVerified = false
                    focusedField = nil
                    screen = .signIn
                }
            } label: {
                Text("Hesabım var")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primaryDark)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 168, minHeight: 44)
                    .background(AppColor.primaryLight.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppColor.primary.opacity(0.45), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Hesabım var")
            .accessibilityHint("Giriş ekranına geçer")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func refreshAmbientForScreen() {
        if screen == .welcome {
            UISoundEngine.shared.startAmbientIfNeeded()
        } else {
            UISoundEngine.shared.stopAmbient()
        }
    }

    private var legalQuickLinks: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                legalMiniLink(title: "Gizlilik", page: .privacy)
                legalMiniLink(title: "Koşullar", page: .terms)
                legalMiniLink(title: "KVKK", page: .kvkk)
            }
            HStack(spacing: 12) {
                legalMiniLink(title: "Açık Rıza", page: .consent)
                legalMiniLink(title: "Tıbbi Reddi", page: .medicalDisclaimer)
                legalMiniLink(title: "Destek", page: .support)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func legalMiniLink(title: String, page: LegalPageLink) -> some View {
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
        .accessibilityHint("Yasal metin sayfasını açar")
    }

    private var checkEmailCard: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(AppColor.primaryLight)
                    .frame(width: 132, height: 132)
                Image(systemName: verificationCompleted ? "checkmark.seal.fill" : (isPasswordResetFlow ? "key.fill" : "envelope"))
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(verificationCompleted ? AppColor.success : AppColor.primary)
            }
            .padding(.top, 8)

            Text(
                verificationCompleted
                ? "E-posta doğrulandı"
                : (isPasswordResetFlow ? (resetCodeVerified ? "Yeni şifreni belirle" : "Şifre sıfırlama kodu") : "E-postanı kontrol et")
            )
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(
                verificationCompleted
                    ? "Hesabın aktifleştirildi. Şimdi giriş ekranına geçip e-posta ve şifrenle tekrar giriş yap."
                    : (isPasswordResetFlow
                       ? (resetCodeVerified
                          ? "Kod doğrulandı. Güvenli bir yeni şifre belirleyip devam et."
                          : "Şifre sıfırlama kodunu \(pendingVerificationEmail.isEmpty ? "e-posta adresine" : pendingVerificationEmail) gönderdik.")
                       : "Doğrulama kodunu \(pendingVerificationEmail.isEmpty ? "e-posta adresine" : pendingVerificationEmail) gönderdik. Gelen kutunu ve spam klasörünü kontrol et.")
            )
            .font(AppFont.body)
            .foregroundStyle(AppColor.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)

            if verificationCompleted, let remaining = signInRedirectRemaining {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(remaining) saniye sonra giriş ekranına yönlendiriliyorsun")
                        .lineLimit(1)
                }
                .font(AppFont.caption)
                .foregroundStyle(AppColor.primaryDark)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(AppColor.primaryLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.primary.opacity(0.22), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !verificationCompleted && (!isPasswordResetFlow || !resetCodeVerified) {
                authInputTitle("Doğrulama kodu")
                otpCodeInput

                Button {
                    Task { await verifyEmailCode() }
                } label: {
                    HStack(spacing: 8) {
                        if state.isBusy {
                            ProgressView().tint(.white)
                        }
                        Text("Kodu Doğrula")
                            .font(AppFont.bodyMedium)
                    }
                    .appPrimaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isBusy || verificationCode.count < otpMinLength)
                .accessibilityLabel("Kodu doğrula")
                .accessibilityHint("E-postana gelen doğrulama kodunu onaylar")

                HStack(spacing: 10) {
                    Image(systemName: "clock")
                    Text("Kod sınırlı süre için geçerli")
                        .lineLimit(1)
                }
                .font(AppFont.caption)
                .foregroundStyle(AppColor.warning)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(AppColor.warningLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.warning.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if isPasswordResetFlow && resetCodeVerified {
                authInputTitle("Yeni şifre")
                HStack(spacing: 8) {
                    Group {
                        if showPassword {
                            TextField("En az 8 karakter", text: $newPassword)
                        } else {
                            SecureField("En az 8 karakter", text: $newPassword)
                        }
                    }
                    .font(AppFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .newPassword)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .confirmPassword }

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField == .newPassword ? AppColor.primary : AppColor.border, lineWidth: focusedField == .newPassword ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                authInputTitle("Yeni şifre (tekrar)")
                SecureField("En az 8 karakter", text: $confirmPassword)
                    .font(AppFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(focusedField == .confirmPassword ? AppColor.primary : AppColor.border, lineWidth: focusedField == .confirmPassword ? 2 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focusedField, equals: .confirmPassword)
                    .submitLabel(.go)
                    .onSubmit { Task { await completePasswordReset() } }

                Button {
                    Task { await completePasswordReset() }
                } label: {
                    HStack(spacing: 8) {
                        if state.isBusy {
                            ProgressView().tint(.white)
                        }
                        Text("Şifreyi Güncelle")
                            .font(AppFont.bodyMedium)
                    }
                    .appPrimaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isBusy || newPassword.count < 8 || confirmPassword.count < 8)
            }

            if !verificationCompleted {
                let isResendDisabled = isResendingVerification || state.isBusy || isResendCooldownActive || (isPasswordResetFlow && resetCodeVerified)
                Button {
                    Task {
                        if isPasswordResetFlow {
                            await resendPasswordResetCodeIfNeeded()
                        } else {
                            await resendVerificationEmailIfNeeded()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isResendingVerification {
                            ProgressView()
                                .tint(isResendDisabled ? AppColor.textTertiary : AppColor.primary)
                        }
                        Text(resendButtonTitle)
                            .font(AppFont.bodyMedium)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(isResendDisabled ? AppColor.surfaceAlt.opacity(0.7) : AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isResendDisabled ? AppColor.border.opacity(0.6) : AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(isResendDisabled ? AppColor.textTertiary : AppColor.primaryDark)
                .opacity(isResendDisabled ? 0.62 : 1)
                .disabled(isResendDisabled)
            }

            if !infoText.isEmpty {
                Text(infoText)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.success)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    signInRedirectDeadline = nil
                    clearAuthFieldsForSignIn()
                    screen = .signIn
                }
            } label: {
                Text("Giriş Ekranına Dön")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var otpCodeInput: some View {
        let digits = Array(verificationCode.prefix(otpMaxLength))
        let activeIndex = min(digits.count, max(otpMaxLength - 1, 0))

        return ZStack {
            TextField("", text: $verificationCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .otp)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundColor(.clear)
                .tint(.clear)
                .opacity(0.05)
                .onChange(of: verificationCode) { newValue in
                    let onlyDigits = newValue.filter(\.isNumber)
                    if onlyDigits != newValue {
                        verificationCode = onlyDigits
                    } else if onlyDigits.count > otpMaxLength {
                        verificationCode = String(onlyDigits.prefix(otpMaxLength))
                    }
                }
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                ForEach(0..<otpMaxLength, id: \.self) { index in
                    let isFilled = index < digits.count
                    let isFocused = focusedField == .otp && index == activeIndex

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isFilled ? AppColor.primaryLight : AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isFocused ? AppColor.primary : AppColor.border, lineWidth: isFocused ? 2 : 1)
                        )
                        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                        .overlay(
                            Text(isFilled ? String(digits[index]) : "")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = .otp
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Doğrulama kodu")
        .accessibilityValue("\(verificationCode.count) hane girildi")
        .accessibilityHint("E-postadaki doğrulama kodunu gir")
    }

    private var authForm: some View {
        VStack(spacing: 14) {
            StethoscopeBadge()
                .accessibilityHidden(true)

            Text(isSignUp ? "Hesap oluştur" : "Giriş yap")
                .font(AppFont.largeTitle)
                .foregroundStyle(AppColor.textPrimary)

            Text(isSignUp ? "Klinik pratiğine başlamak için hesap oluştur." : "Kaldığın yerden devam etmek için giriş yap.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Text("Hızlı giriş seçenekleri")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                socialButton(icon: "applelogo", title: "Apple ile Giriş")
                socialButton(icon: "g.circle", title: "Google ile Giriş")
            }

            HStack(spacing: 10) {
                Rectangle()
                    .fill(AppColor.border)
                    .frame(height: 1)
                Text("veya e-posta ile")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Rectangle()
                    .fill(AppColor.border)
                    .frame(height: 1)
            }

            authInputTitle("E-posta")
            TextField(
                "",
                text: $email,
                prompt: Text("ornek@mail.com")
                    .foregroundColor(AppColor.textTertiary)
            )
                .font(AppFont.body)
                .foregroundColor(AppColor.textPrimary)
                .keyboardType(.emailAddress)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField == .email ? AppColor.primary : AppColor.border, lineWidth: focusedField == .email ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($focusedField, equals: .email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.emailAddress)
                .tint(AppColor.primary)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .id("auth-email")

            authInputTitle("Şifre")
            HStack(spacing: 8) {
                Group {
                    if showPassword {
                        TextField("En az 8 karakter", text: $password)
                    } else {
                        SecureField("En az 8 karakter", text: $password)
                    }
                }
                .font(AppFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .password)
                .submitLabel(isSignUp ? .join : .go)
                .onSubmit {
                    Task { await submit() }
                }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPassword ? "Şifreyi gizle" : "Şifreyi göster")
                .accessibilityHint("Şifre metnini görünür veya gizli yapar")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focusedField == .password ? AppColor.primary : AppColor.border, lineWidth: focusedField == .password ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .id("auth-password")

            if !isSignUp {
                HStack {
                    Spacer()
                    Button {
                        Task { await sendPasswordReset() }
                    } label: {
                        if state.isBusy {
                            ProgressView()
                        } else {
                            Text("Şifremi unuttum")
                                .font(AppFont.bodyMedium)
                        }
                    }
                    .foregroundStyle(AppColor.primary)
                    .frame(minHeight: 44)
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Şifremi unuttum")
                    .accessibilityHint("Şifre sıfırlama e-postası gönderir")
                }
            }

            if !infoText.isEmpty {
                Text(infoText)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.success)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !errorText.isEmpty {
                ErrorStateCard(message: errorText) {
                    errorText = ""
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var authBottomActions: some View {
        VStack(spacing: 10) {
            if isSignUp {
                signupLegalLinks
            }

            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if state.isBusy {
                        ProgressView().tint(.white)
                    }
                    Text(isSignUp ? "Hesap oluştur" : "Giriş yap")
                        .font(AppFont.bodyMedium)
                }
                .appPrimaryButtonLabelStyle()
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(state.isBusy)
            .accessibilityLabel(isSignUp ? "Hesap oluştur" : "Giriş yap")
            .accessibilityHint("Bilgilerle oturum açar")

            Button(isSignUp ? "Zaten hesabın var mı? Giriş yap" : "Hesabın yok mu? Kayıt ol") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    screen = isSignUp ? .signIn : .signUp
                    infoText = ""
                    errorText = ""
                    emailFlow = .signupVerification
                    verificationCompleted = false
                    resetCodeVerified = false
                    focusedField = nil
                }
            }
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.top, 4)
    }

    private var authBottomDock: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppColor.border)

            authBottomActions
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .background(AppColor.background)
    }

    private var signupLegalLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hesap oluşturarak")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            HStack(spacing: 10) {
                signupLegalInlineLink(title: "Kullanım Koşulları", page: .terms)
                Text("ve")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                signupLegalInlineLink(title: "Gizlilik Politikası", page: .privacy)
                Text("metinlerini kabul etmiş olursun.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signupLegalInlineLink(title: String, page: LegalPageLink) -> some View {
        Button {
            guard let url = LegalLinkResolver.url(for: page) else { return }
            legalSheetItem = LegalSheetItem(title: page.title, url: url)
            Haptic.selection()
        } label: {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.primaryDark)
                .underline(true, color: AppColor.primaryDark)
                .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Yasal metin sayfasını açar")
    }

    private func fieldAnchorId(for field: Field?) -> String? {
        switch field {
        case .email: return "auth-email"
        case .password: return "auth-password"
        case .otp: return "auth-otp"
        case .newPassword: return "auth-new-password"
        case .confirmPassword: return "auth-confirm-password"
        case .none: return nil
        }
    }

    private func submit() async {
        focusedField = nil
        errorText = ""
        infoText = ""
        emailFlow = .signupVerification
        verificationCompleted = false
        resetCodeVerified = false

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            errorText = "E-posta zorunlu."
            Haptic.error()
            return
        }

        guard password.count >= 8 else {
            errorText = "Şifre en az 8 karakter olmalı."
            Haptic.error()
            return
        }

        do {
            if isSignUp {
                let outcome = try await state.signUp(
                    email: normalizedEmail,
                    password: password
                )
                if case .emailVerificationRequired = outcome {
                    pendingVerificationEmail = normalizedEmail
                    emailFlow = .signupVerification
                    verificationCode = ""
                    resetCodeVerified = false
                    newPassword = ""
                    confirmPassword = ""
                    infoText = "Doğrulama kodu gönderildi. Gelen kutunu ve spam klasörünü kontrol et."
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        screen = .checkEmail
                    }
                    // Supabase signup maili gecikirse tek seferlik fallback gönder.
                    try? await state.resendVerificationEmail(email: normalizedEmail, fullName: nil)
                    resendCooldownUntil = Date().addingTimeInterval(resendCooldownSeconds)
                    resendCountdownNow = Date()
                    password = ""
                    showPassword = false
                }
            } else {
                try await state.signIn(email: normalizedEmail, password: password)
            }
            Haptic.success()
        } catch {
            if !isSignUp, isAccountNotFoundError(error) {
                errorText = "Bu e-posta için hesap bulunamadı. Yeni hesap oluşturabilirsin."
                infoText = ""
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    screen = .signUp
                }
                password = ""
                showPassword = false
                focusedField = .password
                Haptic.error()
                return
            }
            if !isSignUp, isEmailVerificationRequiredError(error) {
                pendingVerificationEmail = normalizedEmail
                emailFlow = .signupVerification
                verificationCode = ""
                resetCodeVerified = false
                newPassword = ""
                confirmPassword = ""
                infoText = ""
                errorText = ""
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    screen = .checkEmail
                }
                resendCooldownUntil = Date().addingTimeInterval(resendCooldownSeconds)
                resendCountdownNow = Date()
                Haptic.error()
                return
            }
            Haptic.error()
            errorText = error.localizedDescription
        }
    }

    private func advanceAuthFocus() {
        switch focusedField {
        case .email:
            focusedField = .password
        case .otp:
            focusedField = nil
            Task { await verifyEmailCode() }
        case .newPassword:
            focusedField = .confirmPassword
        case .confirmPassword:
            focusedField = nil
            Task { await completePasswordReset() }
        case .password:
            focusedField = nil
            Task { await submit() }
        case .none:
            break
        }
    }

    private func sendPasswordReset() async {
        errorText = ""
        infoText = ""
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            errorText = "Önce e-posta adresini gir."
            Haptic.error()
            return
        }
        do {
            try await state.sendPasswordReset(email: normalizedEmail)
            pendingVerificationEmail = normalizedEmail
            emailFlow = .passwordReset
            verificationCode = ""
            verificationCompleted = false
            resetCodeVerified = false
            newPassword = ""
            confirmPassword = ""
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                screen = .checkEmail
            }
            infoText = "Şifre sıfırlama kodu gönderildi."
            resendCooldownUntil = Date().addingTimeInterval(resendCooldownSeconds)
            resendCountdownNow = Date()
            Haptic.success()
        } catch {
            errorText = error.localizedDescription
            Haptic.error()
        }
    }

    private func resendVerificationEmailIfNeeded() async {
        if isResendingVerification { return }
        guard !isResendCooldownActive else { return }
        errorText = ""
        infoText = ""

        let sourceEmail = pendingVerificationEmail.isEmpty ? email : pendingVerificationEmail
        let normalizedEmail = sourceEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            errorText = "Önce e-posta adresini gir."
            Haptic.error()
            return
        }

        isResendingVerification = true
        defer { isResendingVerification = false }

        do {
            try await state.resendVerificationEmail(email: normalizedEmail, fullName: nil)
            pendingVerificationEmail = normalizedEmail
            infoText = "Doğrulama kodu tekrar gönderildi."
            resendCooldownUntil = Date().addingTimeInterval(resendCooldownSeconds)
            resendCountdownNow = Date()
            Haptic.success()
        } catch {
            errorText = error.localizedDescription
            Haptic.error()
        }
    }

    private func isEmailVerificationRequiredError(_ error: Error) -> Bool {
#if canImport(Supabase)
        let metadata = authErrorMetadata(error)
        return metadata.errorCode == ErrorCode.emailNotConfirmed.rawValue
#else
        _ = error
        return false
#endif
    }

    private func isAccountNotFoundError(_ error: Error) -> Bool {
#if canImport(Supabase)
        let metadata = authErrorMetadata(error)
        return metadata.errorCode == ErrorCode.userNotFound.rawValue || metadata.statusCode == 404
#else
        _ = error
        return false
#endif
    }

#if canImport(Supabase)
    private struct AuthErrorPayload: Decodable {
        let code: String?
        let errorCode: String?
    }

    private func authErrorMetadata(_ error: Error) -> (errorCode: String?, statusCode: Int?) {
        guard let authError = error as? AuthError else {
            return (nil, nil)
        }

        switch authError {
        case let .api(_, errorCode, underlyingData, underlyingResponse):
            let decoded = try? JSONDecoder().decode(AuthErrorPayload.self, from: underlyingData)
            let resolvedCode = decoded?.errorCode ?? decoded?.code ?? errorCode.rawValue
            return (resolvedCode, underlyingResponse.statusCode)
        default:
            return (authError.errorCode.rawValue, nil)
        }
    }
#endif

    private var resendCooldownRemaining: Int {
        guard let until = resendCooldownUntil else { return 0 }
        let remaining = Int(ceil(until.timeIntervalSince(resendCountdownNow)))
        return max(0, remaining)
    }

    private var isResendCooldownActive: Bool {
        resendCooldownRemaining > 0
    }

    private var resendButtonTitle: String {
        if isResendingVerification {
            return "Gönderiliyor..."
        }
        if isResendCooldownActive {
            return "Tekrar gönder (\(resendCooldownRemaining) sn)"
        }
        return isPasswordResetFlow ? "Şifre sıfırlama kodunu tekrar gönder" : "Doğrulama kodunu tekrar gönder"
    }

    private var signInRedirectRemaining: Int? {
        guard let until = signInRedirectDeadline else { return nil }
        let remaining = Int(ceil(until.timeIntervalSince(resendCountdownNow)))
        return max(0, remaining)
    }

    private func startSignInRedirectCountdown() {
        signInRedirectDeadline = Date().addingTimeInterval(signInRedirectSeconds)
        resendCountdownNow = Date()
    }

    private func verifyEmailCode() async {
        errorText = ""
        infoText = ""

        let sourceEmail = pendingVerificationEmail.isEmpty ? email : pendingVerificationEmail
        let normalizedEmail = sourceEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEmail.isEmpty else {
            errorText = "Önce e-posta adresini gir."
            Haptic.error()
            return
        }

        guard cleanCode.count >= otpMinLength else {
            errorText = "Doğrulama kodunu eksiksiz gir."
            Haptic.error()
            return
        }

        do {
            if isPasswordResetFlow {
                try await state.verifyPasswordResetOTP(email: normalizedEmail, code: cleanCode)
                resetCodeVerified = true
                infoText = "Kod doğrulandı. Yeni şifreni belirle."
            } else {
                try await state.verifyEmailOTP(email: normalizedEmail, code: cleanCode)
                verificationCompleted = true
                infoText = "E-posta doğrulandı."
                startSignInRedirectCountdown()
            }
            Haptic.success()
        } catch {
            errorText = "Kod doğrulanamadı. Kodu kontrol edip tekrar dene."
            Haptic.error()
        }
    }

    private func completePasswordReset() async {
        errorText = ""
        infoText = ""

        guard isPasswordResetFlow else { return }
        guard resetCodeVerified else {
            errorText = "Önce doğrulama kodunu onayla."
            Haptic.error()
            return
        }
        guard newPassword.count >= 8 else {
            errorText = "Yeni şifre en az 8 karakter olmalı."
            Haptic.error()
            return
        }
        guard newPassword == confirmPassword else {
            errorText = "Yeni şifreler eşleşmiyor."
            Haptic.error()
            return
        }

        do {
            try await state.completePasswordReset(newPassword: newPassword)
            verificationCompleted = true
            infoText = "Şifren güncellendi."
            Haptic.success()
            startSignInRedirectCountdown()
        } catch {
            errorText = error.localizedDescription
            Haptic.error()
        }
    }

    private func resendPasswordResetCodeIfNeeded() async {
        if isResendingVerification { return }
        guard !isResendCooldownActive else { return }
        errorText = ""
        infoText = ""

        let sourceEmail = pendingVerificationEmail.isEmpty ? email : pendingVerificationEmail
        let normalizedEmail = sourceEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            errorText = "Önce e-posta adresini gir."
            Haptic.error()
            return
        }

        isResendingVerification = true
        defer { isResendingVerification = false }

        do {
            try await state.sendPasswordReset(email: normalizedEmail)
            pendingVerificationEmail = normalizedEmail
            infoText = "Şifre sıfırlama kodu tekrar gönderildi."
            resendCooldownUntil = Date().addingTimeInterval(resendCooldownSeconds)
            resendCountdownNow = Date()
            Haptic.success()
        } catch {
            errorText = error.localizedDescription
            Haptic.error()
        }
    }

    private func clearAuthFieldsForSignIn() {
        signInRedirectDeadline = nil
        pendingVerificationEmail = ""
        emailFlow = .signupVerification
        verificationCode = ""
        resetCodeVerified = false
        newPassword = ""
        confirmPassword = ""
        email = ""
        password = ""
        showPassword = false
        verificationCompleted = false
        focusedField = nil
    }

    private func authInputTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    private func socialButton(icon: String, title: String) -> some View {
        Button {
            infoText = "\(title) yakında aktif olacak."
            Haptic.selection()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.primary.opacity(0.24), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }
}
