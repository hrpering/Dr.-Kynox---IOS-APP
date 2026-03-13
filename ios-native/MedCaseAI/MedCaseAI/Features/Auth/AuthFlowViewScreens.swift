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
                .frame(height: 228)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            HeroHeader(
                eyebrow: "Dr.Kynox",
                title: "Klinik pratiğinin yapay zeka asistanı",
                subtitle: "Gerçek klinik vakalar üzerinde düşün. Tanı koy, test iste, yönetim planı oluştur.",
                icon: "stethoscope",
                metrics: [
                    HeroMetricItem(title: "Etkileşim", value: "Sesli + Yazılı", icon: "waveform"),
                    HeroMetricItem(title: "Kapsam", value: "Gerçek Vakalar", icon: "cross.case"),
                    HeroMetricItem(title: "Takip", value: "Anlık Geri Bildirim", icon: "chart.line.uptrend.xyaxis")
                ]
            )

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
            .background(AppColor.surface)
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
                    .appSecondaryButtonLabel()
                    .frame(minHeight: 44)
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
        VStack(spacing: 7) {
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
        .padding(.top, 2)
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
        let heroTitle = verificationCompleted
            ? "E-posta doğrulandı"
            : (isPasswordResetFlow ? (resetCodeVerified ? "Yeni şifreni belirle" : "Şifre sıfırlama kodu") : "E-postanı kontrol et")
        let heroSubtitle = verificationCompleted
            ? "Hesabın aktifleştirildi. Şimdi giriş ekranına geçip e-posta ve şifrenle tekrar giriş yap."
            : (isPasswordResetFlow
               ? (resetCodeVerified
                  ? "Kod doğrulandı. Güvenli bir yeni şifre belirleyip devam et."
                  : "Şifre sıfırlama kodunu \(pendingVerificationEmail.isEmpty ? "e-posta adresine" : pendingVerificationEmail) gönderdik.")
               : "Doğrulama kodunu \(pendingVerificationEmail.isEmpty ? "e-posta adresine" : pendingVerificationEmail) gönderdik. Gelen kutunu ve spam klasörünü kontrol et.")

        return VStack(spacing: 14) {
            HeroHeader(
                eyebrow: isPasswordResetFlow ? "Şifre Kurtarma" : "E-posta Doğrulama",
                title: heroTitle,
                subtitle: heroSubtitle,
                icon: verificationCompleted ? "checkmark.seal.fill" : (isPasswordResetFlow ? "key.fill" : "envelope"),
                metrics: [
                    HeroMetricItem(title: "Akış", value: isPasswordResetFlow ? "Şifre Sıfırla" : "Kayıt", icon: "shuffle"),
                    HeroMetricItem(title: "Durum", value: verificationCompleted ? "Tamamlandı" : "Kod Bekleniyor", icon: "checkmark.circle"),
                    HeroMetricItem(title: "Kod", value: "\(verificationCode.count)/\(otpMaxLength)", icon: "number")
                ]
            )

            if verificationCompleted, let remaining = signInRedirectRemaining {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(remaining) saniye sonra giriş ekranına yönlendiriliyorsun")
                        .lineLimit(1)
                }
                .font(AppFont.caption)
                .foregroundStyle(AppColor.primaryDark)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
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
                .padding(.vertical, 8)
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
                .frame(minHeight: 48)
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
                    .frame(minHeight: 48)
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
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
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
                        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
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
            HeroHeader(
                eyebrow: isSignUp ? "Yeni Hesap" : "Tekrar Hoş Geldin",
                title: isSignUp ? "Hesap oluştur" : "Giriş yap",
                subtitle: isSignUp ? "Klinik pratiğine başlamak için hesap oluştur." : "Kaldığın yerden devam etmek için giriş yap.",
                icon: "stethoscope",
                metrics: [
                    HeroMetricItem(title: "Akış", value: isSignUp ? "Kayıt" : "Giriş", icon: "arrow.triangle.branch"),
                    HeroMetricItem(title: "Doğrulama", value: "E-posta", icon: "envelope"),
                    HeroMetricItem(title: "Güvenlik", value: "Aktif", icon: "lock.shield")
                ]
            )

            Text("Hızlı giriş seçenekleri")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
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
                .frame(minHeight: 48)
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
            .frame(minHeight: 48)
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
                    .frame(minHeight: 42)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
    }

    var authBottomActions: some View {
        VStack(spacing: 8) {
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
            .frame(maxWidth: .infinity, minHeight: 42)
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.top, 2)
    }

    var authBottomDock: some View {
        BottomCTADock {
            authBottomActions
        }
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
