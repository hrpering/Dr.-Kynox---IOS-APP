import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct CaseSessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase

    let config: CaseLaunchConfig

    @StateObject var vm: AgentConversationViewModel
    @State var textInput = ""
    @State var showResultFlow = false
    @State var finishedTranscript: [ConversationLine] = []
    @State var wasSessionEnded = false
    @State var userRequestedEnd = false
    @State var hasStarted = false
    @State var isStartingSession = false
    @State var startSessionTask: Task<Void, Never>?
    @State var micPermission: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission
    @State var hasRequestedInitialMic = false
    @State var isTextFallbackMode = false
    @State var isKeyboardVisible = false
    @State var showEndSessionConfirmation = false
    @State var isMicPulsing = false
    @FocusState var isComposerFocused: Bool

    init(config: CaseLaunchConfig) {
        self.config = config
        _vm = StateObject(wrappedValue: AgentConversationViewModel(config: config))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topCaseHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                statusStrip
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                transcriptArea
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle(config.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled(hasStarted)
            .safeAreaInset(edge: .bottom) {
                bottomControlArea
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") {
                        if hasStarted {
                            requestEndSessionConfirmation()
                        } else {
                            vm.cleanup()
                            dismiss()
                        }
                    }
                    .accessibilityLabel(hasStarted ? "Vakayı Kapat" : "Ekranı Kapat")
                    .accessibilityHint(hasStarted ? "Oturumu kapatıp sonuç ekranına geçer" : "Vaka başlatmadan ekranı kapatır")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if config.mode == .voice {
                        Button {
                            isTextFallbackMode.toggle()
                            Haptic.selection()
                        } label: {
                            Label("Metin Modu", systemImage: "keyboard")
                                .font(AppFont.caption)
                        }
                        .accessibilityLabel("Metin Modu")
                        .accessibilityHint("Sesli görüşme sırasında metin girişine geçer")
                    }

                    if hasStarted {
                        Button("Bitir") {
                            requestEndSessionConfirmation()
                        }
                        .foregroundStyle(AppColor.error)
                        .accessibilityLabel("Vakayı Bitir")
                        .accessibilityHint("Görüşmeyi bitirip sonuç ekranına geçer")
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    if hasStarted && (config.mode == .text || isTextFallbackMode) {
                        Spacer()
                        Button("Kapat") {
                            isComposerFocused = false
                        }
                    }
                }
            }
            .onChange(of: vm.connectionState) { newState in
                guard (newState == .ended || newState == .failed) else { return }
                guard !wasSessionEnded else { return }

                if userRequestedEnd {
                    Task { await finalizeCase() }
                    return
                }

                if newState == .ended {
                    Task { await finalizeCase() }
                    return
                }

                hasStarted = false
                if vm.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.errorText = newState == .failed
                        ? "Bağlantı kesildi. Vakayı yeniden başlatabilirsin."
                        : "Oturum tamamlandı. Sonucu görmek için Vakayı Bitir butonunu kullanabilirsin."
                }
            }
            .fullScreenCover(isPresented: $showResultFlow, onDismiss: {
                dismiss()
            }) {
                CaseResultFlowView(
                    config: config,
                    startedAt: vm.startedAt,
                    transcript: finishedTranscript,
                    mode: config.mode
                )
            }
            .onDisappear {
                isComposerFocused = false
                startSessionTask?.cancel()
                startSessionTask = nil
                AppLog.log(
                    "[CaseSessionView] onDisappear hasStarted=\(hasStarted) showResultFlow=\(showResultFlow) userRequestedEnd=\(userRequestedEnd)",
                    level: .debug,
                    category: .caseSession
                )
                if hasStarted, !showResultFlow {
                    vm.cleanup()
                }
            }
            .onChange(of: scenePhase) { phase in
                Task {
                    await vm.handleScenePhaseChange(phase)
                }
            }
            .task {
                syncMicrophonePermissionStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .confirmationDialog(
                "Vakayı bitir?",
                isPresented: $showEndSessionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Vakayı bitir", role: .destructive) {
                    confirmEndSession()
                }
                Button("Devam et", role: .cancel) { }
            } message: {
                Text("Bu işlem görüşmeyi sonlandırır ve sonuç ekranına geçer.")
            }
        }
    }

}
