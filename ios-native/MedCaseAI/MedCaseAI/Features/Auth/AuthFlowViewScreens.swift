import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry
#if canImport(Supabase)
import Supabase
#endif

extension AuthFlowView {
    var welcomeCard: some View {
        VStack(spacing: AppSpacing.x2) {
            IntroMotionCard(variant: .short)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Text("Dr.Kynox")
                .font(AppFont.h1)
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

            VStack(spacing: AppSpacing.x1) {
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
            .padding(AppSpacing.cardPadding)
            .background(AppColor.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appShadow(AppShadow.card)
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
                    .padding(.horizontal, AppSpacing.x3)
                    .frame(minWidth: 168, minHeight: 46)
                    .background(AppColor.primaryLight.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .stroke(AppColor.primary.opacity(0.45), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Hesabım var")
            .accessibilityHint("Giriş ekranına geçer")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    func refreshAmbientForScreen() {
        if screen == .welcome {
            UISoundEngine.shared.startAmbientIfNeeded()
        } else {
            UISoundEngine.shared.stopAmbient()
        }
    }

    var legalQuickLinks: some View {
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

    func legalMiniLink(title: String, page: LegalPageLink) -> some View {
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

    var checkEmailCard: some View {
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

    var otpCodeInput: some View {
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

    var authForm: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StethoscopeBadge()
                        .accessibilityHidden(true)
                    Spacer()
                    Text(isSignUp ? "Yeni Hesap" : "Tekrar Hoş Geldin")
                        .font(AppFont.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.18))
                        .clipShape(Capsule())
                }

                Text(isSignUp ? "Hesap oluştur" : "Giriş yap")
                    .font(AppFont.largeTitle)
                    .foregroundStyle(.white)

                Text(isSignUp ? "Klinik pratiğine başlamak için hesap oluştur." : "Kaldığın yerden devam etmek için giriş yap.")
                    .font(AppFont.body)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(4)

                HStack(spacing: 8) {
                    authHeroMetric(title: "Akış", value: isSignUp ? "Kayıt" : "Giriş")
                    authHeroMetric(title: "Doğrulama", value: "E-posta")
                    authHeroMetric(title: "Güvenlik", value: "Aktif")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [AppColor.primaryDark, AppColor.primary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

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

    private func authHeroMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(.white.opacity(0.74))
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var authBottomActions: some View {
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

    var authBottomDock: some View {
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

    var signupLegalLinks: some View {
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

    func signupLegalInlineLink(title: String, page: LegalPageLink) -> some View {
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

    func fieldAnchorId(for field: Field?) -> String? {
        switch field {
        case .email: return "auth-email"
        case .password: return "auth-password"
        case .otp: return "auth-otp"
        case .newPassword: return "auth-new-password"
        case .confirmPassword: return "auth-confirm-password"
        case .none: return nil
        }
    }

}
