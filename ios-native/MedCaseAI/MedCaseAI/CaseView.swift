import SwiftUI

struct CaseView: View {
    private static let iso8601Formatter = ISO8601DateFormatter()

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = ConversationViewModel()
    @State private var isStarted = false
    @State private var isConnecting = false
    @State private var textInputText = ""
    @State private var isEndConversationConfirmationPresented = false

    let mode: ConversationViewModel.ConversationMode
    let difficulty: String
    let specialty: String
    let challengeType: String
    let challengeId: String?
    let expectedDiagnosis: String?

    init(mode: ConversationViewModel.ConversationMode,
         difficulty: String,
         specialty: String,
         challengeType: String = "random",
         challengeId: String? = nil,
         expectedDiagnosis: String? = nil) {
        self.mode = mode
        self.difficulty = difficulty
        self.specialty = specialty
        self.challengeType = challengeType
        self.challengeId = challengeId
        self.expectedDiagnosis = expectedDiagnosis
    }

    var body: some View {
        Group {
            if !isStarted {
                startScreen
            } else {
                if isConnecting || vm.connectionState == .connecting {
                    connectingView
                } else {
                    conversationScreen
                }
            }
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Vaka başlat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.attach(appState: state)
        }
        .onDisappear {
            Task { await vm.cleanup() }
        }
        .confirmationDialog(
            "Vakayı bitir?",
            isPresented: $isEndConversationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Vakayı bitir", role: .destructive) {
                Task { await vm.endConversation() }
            }
            Button("İptal", role: .cancel) { }
        } message: {
            Text("Bu işlem konuşmayı sonlandırır ve mevcut içerik skorlamaya gönderilir.")
        }
    }

    private var startScreen: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(SpecialtyOption.label(for: specialty))
                    .font(AppFont.title)
                    .foregroundStyle(AppColor.textPrimary)
                Text(difficulty)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            }

            Button("Vaka başlat") {
                vm.mode = mode
                vm.difficulty = difficulty
                vm.specialty = specialty
                vm.challengeType = challengeType
                vm.challengeId = challengeId
                vm.expectedDiagnosis = expectedDiagnosis

                isStarted = true
                isConnecting = true

                Task {
                    await createSession()
                    await vm.connect()
                    isConnecting = false
                }
            }
            .appPrimaryButton()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Agent'a bağlanıyor...")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var conversationScreen: some View {
        VStack(spacing: 0) {
            statusBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.messages) { msg in
                            CaseMessageBubble(message: msg)
                                .id(msg.id)
                        }

                        if vm.isScoring {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Skor hazırlanıyor...")
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textSecondary)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: vm.messages.count) { _ in
                    if let last = vm.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if mode == .voice {
                voiceControls
            } else {
                textInput
            }

            if let error = vm.errorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .onChange(of: vm.connectionState) { newState in
            if newState == .ended, vm.isScoreCompleted {
                dismiss()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            Spacer()

            Button("Bitir") {
                requestEndConversation()
            }
            .font(AppFont.caption)
            .foregroundStyle(AppColor.error)
            .disabled(!canEndConversation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColor.surface)
        .overlay(
            Rectangle()
                .fill(AppColor.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var voiceControls: some View {
        HStack(spacing: 32) {
            Button {
                Task { await vm.toggleMute() }
            } label: {
                Image(systemName: vm.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(vm.isMuted ? AppColor.error : AppColor.textPrimary)
            }
            .frame(width: 52, height: 52)
            .background(AppColor.surface)
            .clipShape(Circle())
            .overlay(Circle().stroke(AppColor.border, lineWidth: 1))

            ZStack {
                Circle()
                    .fill(agentStateColor)
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            Button {
                requestEndConversation()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(AppColor.error)
            }
            .frame(width: 52, height: 52)
            .disabled(!canEndConversation)
        }
        .padding(.vertical, 16)
        .background(AppColor.surface)
    }

    private var canEndConversation: Bool {
        vm.connectionState == .connected && !vm.isScoring
    }

    private func requestEndConversation() {
        guard canEndConversation else { return }
        isEndConversationConfirmationPresented = true
    }

    private var textInput: some View {
        HStack(spacing: 10) {
            TextField("Mesajını yaz...", text: $textInputText)
                .font(AppFont.body)
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                let msg = textInputText
                textInputText = ""
                Task { await vm.sendTextMessage(msg) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(textInputText.isEmpty ? AppColor.textTertiary : AppColor.primary)
            }
            .disabled(textInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .background(AppColor.surface)
    }

    private var statusColor: Color {
        switch vm.connectionState {
        case .connected: return AppColor.success
        case .connecting: return AppColor.warning
        case .ended: return AppColor.textTertiary
        case .disconnected: return AppColor.error
        }
    }

    private var statusText: String {
        switch vm.agentState {
        case .listening: return "Dinliyor..."
        case .speaking: return "Konuşuyor..."
        case .thinking: return "Düşünüyor..."
        case .idle:
            switch vm.connectionState {
            case .connecting: return "Bağlanıyor..."
            case .ended:
                return vm.isScoring ? "Skor hazırlanıyor..." : "Vaka tamamlandı"
            case .connected: return "Hazır"
            case .disconnected: return "Bağlı değil"
            }
        }
    }

    private var agentStateColor: Color {
        switch vm.agentState {
        case .listening: return AppColor.primary
        case .speaking: return AppColor.success
        case .thinking: return AppColor.warning
        case .idle: return AppColor.textTertiary
        }
    }

    private func createSession() async {
        let session = vm.startSession()

        let payload = SaveCasePayload(
            sessionId: session.id.uuidString,
            mode: mode == .voice ? "voice" : "text",
            status: "active",
            startedAt: Self.iso8601Formatter.string(from: session.startedAt),
            endedAt: nil,
            durationMin: 0,
            messageCount: 0,
            difficulty: difficulty,
            caseContext: .init(
                title: challengeType == "daily" ? "Günün Vaka Meydan Okuması" : "Rastgele Klinik Vaka",
                specialty: specialty,
                subtitle: "Oturum başlatıldı",
                challengeId: challengeId,
                challengeType: challengeType,
                expectedDiagnosis: expectedDiagnosis
            ),
            transcript: [],
            score: nil
        )
        await state.saveCase(payload: payload)
    }
}

private struct CaseMessageBubble: View {
    let message: DisplayMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }

            Text(message.content)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(message.role == "user" ? AppColor.primaryLight : AppColor.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(message.role == "user" ? AppColor.primary.opacity(0.25) : AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
