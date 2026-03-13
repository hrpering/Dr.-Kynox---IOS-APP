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
    func submit() async {
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

    func advanceAuthFocus() {
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

    func sendPasswordReset() async {
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

    func resendVerificationEmailIfNeeded() async {
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

    func isEmailVerificationRequiredError(_ error: Error) -> Bool {
#if canImport(Supabase)
        let metadata = authErrorMetadata(error)
        return metadata.errorCode == ErrorCode.emailNotConfirmed.rawValue
#else
        _ = error
        return false
#endif
    }

    func isAccountNotFoundError(_ error: Error) -> Bool {
#if canImport(Supabase)
        let metadata = authErrorMetadata(error)
        return metadata.errorCode == ErrorCode.userNotFound.rawValue || metadata.statusCode == 404
#else
        _ = error
        return false
#endif
    }

#if canImport(Supabase)
    struct AuthErrorPayload: Decodable {
        let code: String?
        let errorCode: String?
    }

    func authErrorMetadata(_ error: Error) -> (errorCode: String?, statusCode: Int?) {
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

    var resendCooldownRemaining: Int {
        guard let until = resendCooldownUntil else { return 0 }
        let remaining = Int(ceil(until.timeIntervalSince(resendCountdownNow)))
        return max(0, remaining)
    }

    var isResendCooldownActive: Bool {
        resendCooldownRemaining > 0
    }

    var resendButtonTitle: String {
        if isResendingVerification {
            return "Gönderiliyor..."
        }
        if isResendCooldownActive {
            return "Tekrar gönder (\(resendCooldownRemaining) sn)"
        }
        return isPasswordResetFlow ? "Şifre sıfırlama kodunu tekrar gönder" : "Doğrulama kodunu tekrar gönder"
    }

    var signInRedirectRemaining: Int? {
        guard let until = signInRedirectDeadline else { return nil }
        let remaining = Int(ceil(until.timeIntervalSince(resendCountdownNow)))
        return max(0, remaining)
    }

    func startSignInRedirectCountdown() {
        signInRedirectDeadline = Date().addingTimeInterval(signInRedirectSeconds)
        resendCountdownNow = Date()
    }

    func verifyEmailCode() async {
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

    func completePasswordReset() async {
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

    func resendPasswordResetCodeIfNeeded() async {
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

    func clearAuthFieldsForSignIn() {
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

    func authInputTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    func socialButton(icon: String, title: String) -> some View {
        Button {
            infoText = "\(title) yakında aktif olacak."
            Haptic.selection()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColor.surfaceAlt)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                    )
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            .font(AppFont.bodyMedium)
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }
}
