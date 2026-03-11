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
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    enum Screen {
        case welcome
        case signIn
        case signUp
        case checkEmail
    }

    enum EmailFlow {
        case signupVerification
        case passwordReset
    }

    @State var screen: Screen = .welcome
    @State var email = ""
    @State var password = ""
    @State var showPassword = false
    @State var infoText = ""
    @State var errorText = ""
    @State var isResendingVerification = false
    @State var resendCooldownUntil: Date?
    @State var resendCountdownNow: Date = Date()
    @State var signInRedirectDeadline: Date?
    @State var pendingVerificationEmail = ""
    @State var emailFlow: EmailFlow = .signupVerification
    @State var verificationCode = ""
    @State var verificationCompleted = false
    @State var resetCodeVerified = false
    @State var newPassword = ""
    @State var confirmPassword = ""
    @State var legalSheetItem: LegalSheetItem?
    @FocusState var focusedField: Field?

    enum Field {
        case otp
        case newPassword
        case confirmPassword
        case email
        case password
    }

    var isSignUp: Bool { screen == .signUp }
    var isPasswordResetFlow: Bool { emailFlow == .passwordReset }
    var transition: AnyTransition { reduceMotion ? .opacity : .move(edge: .trailing) }
    let otpMinLength = 6
    let otpMaxLength = 8
    let resendCooldownSeconds: TimeInterval = 120
    let signInRedirectSeconds: TimeInterval = 3
    let resendTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

}
