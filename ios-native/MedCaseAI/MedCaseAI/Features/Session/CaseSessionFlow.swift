import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

enum ToolResultSheetRoute: Identifiable, Equatable {
    case tool(toolCallId: String)
    case imaging(anchorToolCallId: String)

    var id: String {
        switch self {
        case .tool(let toolCallId):
            return "tool-\(toolCallId)"
        case .imaging(let anchorToolCallId):
            return "imaging-\(anchorToolCallId)"
        }
    }
}

struct CaseSessionView: View {
    enum SessionStartPhase: Equatable {
        case idle
        case waitingPermission
        case starting
        case started
        case failed
    }

    enum AutoStartTrigger: String {
        case initialTask
        case permissionGranted
        case sceneActivePermissionGrant
        case retry
        case modeFallback
    }

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase

    let config: CaseLaunchConfig

    @StateObject var vm: AgentConversationViewModel
    @State var textInput = ""
    @State var showResultFlow = false
    @State var finishedTranscript: [ConversationLine] = []
    @State var finishedToolResults: [SaveCasePayload.ToolResult] = []
    @State var wasSessionEnded = false
    @State var userRequestedEnd = false
    @State var hasStarted = false
    @State var isStartingSession = false
    @State var startSessionTask: Task<Void, Never>?
    @State var micPermission: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission
    @State var startPhase: SessionStartPhase = .idle
    @State var lastObservedMicPermission: AVAudioSession.RecordPermission?
    @State var isTextFallbackMode = false
    @State var isKeyboardVisible = false
    @State var showEndSessionConfirmation = false
    @State var isMicPulsing = false
    @State var isSendingTextMessage = false
    @State var activeToolSheetRoute: ToolResultSheetRoute?
    @FocusState var isComposerFocused: Bool

    init(config: CaseLaunchConfig) {
        self.config = config
        _vm = StateObject(wrappedValue: AgentConversationViewModel(config: config))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                topCaseHeader
                statusStrip

                transcriptArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    .appShadow(AppShadow.card)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
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
                            guard !hasStarted else { return }
                            startPhase = .idle
                            attemptInitialAutoStart(trigger: .modeFallback)
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
                if newState == .connecting || newState == .connected {
                    if hasStarted {
                        startPhase = .started
                    }
                    return
                }
                guard (newState == .ended || newState == .failed) else { return }
                guard !wasSessionEnded else { return }
                activeToolSheetRoute = nil

                if userRequestedEnd || vm.endRequestedByUser {
                    Task { await finalizeCase() }
                    return
                }

                hasStarted = false
                startPhase = .failed
                let existingError = vm.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackError = newState == .failed
                    ? "Bağlantı kesildi. Vakayı yeniden başlatabilirsin."
                    : "Oturum beklenmedik şekilde sonlandı. Vakayı yeniden başlatabilirsin."
                vm.cleanup()
                vm.errorText = existingError.isEmpty ? fallbackError : existingError
            }
            .fullScreenCover(isPresented: $showResultFlow, onDismiss: {
                dismiss()
            }) {
                CaseResultFlowView(
                    config: config,
                    startedAt: vm.startedAt,
                    transcript: finishedTranscript,
                    toolResults: finishedToolResults,
                    mode: config.mode
                )
            }
            .sheet(item: $activeToolSheetRoute, onDismiss: {
                activeToolSheetRoute = nil
            }) { route in
                switch route {
                case .tool(let toolCallId):
                    if let sheetPayload = selectedToolSheetPayload(toolCallId: toolCallId) {
                        ToolResultSheetView(
                            config: config,
                            descriptor: sheetPayload.descriptor,
                            payload: sheetPayload.payload,
                            onContinue: {
                                activeToolSheetRoute = nil
                            }
                        )
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    } else {
                        EmptyView()
                    }
                case .imaging(let anchorToolCallId):
                    let imagingItems = imagingSheetItems(anchorToolCallId: anchorToolCallId)
                    if imagingItems.isEmpty {
                        EmptyView()
                    } else {
                        CombinedImagingResultsSheetView(
                            config: config,
                            items: imagingItems,
                            initialSegment: imagingInitialSegment(anchorToolCallId: anchorToolCallId),
                            onContinue: {
                                activeToolSheetRoute = nil
                            }
                        )
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    }
                }
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
                    if phase == .active {
                        await MainActor.run {
                            handleSceneActivePermissionRecheck()
                        }
                    }
                }
            }
            .task(id: config.id) {
                await MainActor.run {
                    attemptInitialAutoStart(trigger: .initialTask)
                }
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
