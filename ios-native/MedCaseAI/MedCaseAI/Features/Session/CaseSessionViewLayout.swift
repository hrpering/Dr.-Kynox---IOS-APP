import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

extension CaseSessionView {
    var topCaseHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(activeHeadline)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Text(SpecialtyOption.label(for: config.specialty))
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer()
            Badge(text: config.difficulty, tint: AppColor.primary, background: AppColor.primaryLight)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var statusStrip: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)

            Text(statusText)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(statusBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !hasStarted {
                        startPanel
                    } else if vm.messages.isEmpty {
                        VStack(spacing: 10) {
                            if vm.isConnecting {
                                ProgressView()
                            }
                            Text(vm.isConnecting ? "Bağlantı kuruluyor..." : "Transkript burada görünecek")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    }

                    ForEach(vm.messages) { row in
                        MessageBubble(row: row)
                            .id(row.id)
                    }

                    if hasStarted && !(config.mode == .text || isTextFallbackMode) && (vm.isAwaitingReply || vm.agentState == .thinking) {
                        HStack {
                            TypingIndicatorView()
                            Spacer()
                        }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    }

                    if !vm.errorText.isEmpty {
                        ErrorStateCard(message: vm.errorText) {
                            if vm.connectionState == .ended || vm.connectionState == .failed {
                                resetSessionForRetry()
                                triggerStartSession()
                            } else {
                                vm.errorText = ""
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                isComposerFocused = false
            }
            .onChange(of: vm.messages.count) { _ in
                guard let last = vm.messages.last else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    var startPanel: some View {
        VStack(spacing: 16) {
            if showVoicePermissionPreflight {
                voicePermissionPreflightCard
            } else if let preview = firstAgentPreview {
                Text(preview)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, showVoicePermissionPreflight ? 20 : 48)
    }

    var textComposer: some View {
        HStack(spacing: 8) {
            TextField("Mesajını yaz", text: $textInput, axis: .vertical)
                .font(AppFont.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .frame(minHeight: 44, maxHeight: 120, alignment: .topLeading)
                .background(AppColor.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                let text = textInput
                textInput = ""
                Task {
                    guard canSendText else {
                        vm.errorText = "Oturum şu an kapanıyor, lütfen bekle."
                        Haptic.error()
                        return
                    }
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    if !hasStarted || vm.connectionState == .idle || vm.connectionState == .ended || vm.connectionState == .failed {
                        vm.errorText = "Önce vakayı başlatın."
                        textInput = text
                        Haptic.error()
                        return
                    }
                    do {
                        try await vm.sendMessage(clean)
                        isComposerFocused = false
                    } catch {
                        vm.errorText = error.localizedDescription
                        textInput = text
                        Haptic.error()
                    }
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppColor.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isEnding || wasSessionEnded)
            .accessibilityLabel("Gönder")
            .accessibilityHint("Mesajı vakaya gönderir")
        }
    }

    @ViewBuilder
    var bottomControlArea: some View {
        VStack(spacing: 10) {
            if !hasStarted {
                if showVoicePermissionPreflight {
                    VStack(spacing: 8) {
                        Button {
                            Task {
                                await requestMicrophoneIfNeeded()
                                if micPermission == .granted {
                                    vm.errorText = ""
                                } else {
                                    vm.errorText = "Sesli mod için mikrofon izni gerekiyor."
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                Text("Mikrofon İzni Ver")
                                    .font(AppFont.bodyMedium)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppColor.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            isTextFallbackMode = true
                            vm.errorText = ""
                            Haptic.selection()
                        } label: {
                            Text("Şimdilik yazılı moda geç")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.primaryDark)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(AppColor.primaryLight.opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(AppColor.primary.opacity(0.24), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Şimdilik yazılı moda geç")
                        .accessibilityHint("Mikrofon izni vermeden yazılı vaka oturumuna geçer")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(AppColor.surface)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AppColor.border).frame(height: 1)
                    }
                } else {
                    Button {
                        triggerStartSession()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: (config.mode == .voice && !isTextFallbackMode) ? "mic.fill" : "text.bubble.fill")
                            Text("Vaka başlat")
                                .font(AppFont.bodyMedium)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppColor.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isStartingSession || startSessionTask != nil || vm.isConnecting)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(AppColor.surface)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AppColor.border).frame(height: 1)
                    }
                }
            } else {
                if config.mode == .text || isTextFallbackMode {
                    textComposer
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                } else {
                    voiceControls
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                if config.mode == .voice, micPermission != .granted {
                    warningBanner
                        .padding(.horizontal, 14)
                }

                if !(config.mode == .text || isTextFallbackMode) || !isKeyboardVisible {
                    Button {
                        requestEndSessionConfirmation()
                    } label: {
                        Text("Vaka Sonlandır")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.error)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppColor.errorLight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppColor.error.opacity(0.35), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.bottom, 8)
        .background(AppColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(AppColor.border).frame(height: 1)
        }
    }

    var voiceControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        do {
                            try await vm.setMuted(true)
                            Haptic.selection()
                        } catch {
                            vm.errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(AppColor.surfaceAlt)
                        .overlay(Circle().stroke(AppColor.border, lineWidth: 1))
                        .clipShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!vm.isConnected || vm.isMutingInFlight || vm.isMicMuted)
                .accessibilityLabel("Sessize al")
                .accessibilityHint("Mikrofonu geçici olarak kapatır")

                Button {
                    Task {
                        do {
                            if vm.isMicMuted {
                                await requestMicrophoneIfNeeded()
                                guard micPermission == .granted else {
                                    vm.errorText = "Mikrofon izni olmadan sesli mod kullanılamaz."
                                    Haptic.error()
                                    return
                                }
                            }
                            try await vm.setMuted(!vm.isMicMuted)
                            Haptic.selection()
                        } catch {
                            vm.errorText = error.localizedDescription
                            Haptic.error()
                        }
                    }
                } label: {
                    Circle()
                        .fill(vm.isMicMuted ? AppColor.textTertiary : AppColor.primary)
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: vm.isMicMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .scaleEffect(isMicPulsing && !reduceMotion ? 1.04 : 1.0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: isMicPulsing
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!vm.isConnected || vm.isMutingInFlight)
                .accessibilityLabel(vm.isMicMuted ? "Mikrofonu Aç" : "Mikrofonu Kapat")
                .accessibilityHint("Sesli konuşmayı başlatır veya durdurur")

                Button {
                    requestEndSessionConfirmation()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColor.error)
                        .frame(width: 52, height: 52)
                        .background(AppColor.errorLight)
                        .overlay(Circle().stroke(AppColor.error.opacity(0.35), lineWidth: 1))
                        .clipShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Vakayı Bitir")
                .accessibilityHint("Görüşmeyi bitirip sonuç ekranına geçer")
            }

            Text(vm.isMicMuted ? "Mikrofon kapalı" : "Mikrofon açık, konuşabilirsin")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            if vm.isMutingInFlight {
                Text("Mikrofon güncelleniyor...")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }

#if targetEnvironment(simulator)
            Text("Simülatörde ses bağlantısı kararsız olabilir. En sağlıklı test gerçek cihazda yapılır.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
#endif
        }
        .onAppear {
            isMicPulsing = !reduceMotion && !vm.isMicMuted
        }
        .onChange(of: vm.isMicMuted) { muted in
            isMicPulsing = !reduceMotion && !muted
        }
        .onChange(of: reduceMotion) { shouldReduceMotion in
            isMicPulsing = !shouldReduceMotion && !vm.isMicMuted
        }
        .onDisappear {
            isMicPulsing = false
        }
    }

    var warningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.warning)

            Text("Mikrofon erişimi kapalı")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textPrimary)

            Spacer()

            Button("Ayarları Aç") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(AppFont.caption)
            .foregroundStyle(AppColor.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppColor.warningLight)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.warning.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var showVoicePermissionPreflight: Bool {
        config.mode == .voice && !isTextFallbackMode && micPermission != .granted
    }

    var voicePermissionPreflightCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(AppColor.primaryLight)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppColor.primary)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sesli mod için mikrofon izni")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Sesli vakada gerçek hasta simülasyonuna yakın akış yaşarsın.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                preflightBenefit("Mikrofon yalnızca vaka sırasında kullanılır.")
                preflightBenefit("İstediğinde yazılı moda geçebilirsin.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func preflightBenefit(_ text: String) -> some View {
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

    var statusIcon: Image {
        if config.mode == .text || isTextFallbackMode {
            if vm.isAwaitingReply || vm.agentState == .thinking {
                return Image(systemName: "ellipsis.bubble.fill")
            }
            if vm.isConnecting {
                return Image(systemName: "hourglass")
            }
            return Image(systemName: "keyboard")
        }

        switch vm.agentState {
        case .listening: return Image(systemName: "circle.fill")
        case .thinking: return Image(systemName: "brain.head.profile")
        case .speaking: return Image(systemName: "speaker.wave.2.fill")
        case .ended: return Image(systemName: "checkmark.circle.fill")
        case .unknown: return Image(systemName: "hourglass")
        }
    }

    var statusText: String {
        if !hasStarted {
            return "Dr.Kynox hazır. Vakayı başlatmak için butona bas."
        }
        if config.mode == .text || isTextFallbackMode {
            if vm.isConnecting { return "Bağlanıyor..." }
            if vm.isAwaitingReply || vm.agentState == .thinking { return "Yanıt hazırlanıyor..." }
            if vm.agentState == .speaking { return "Yanıt geliyor..." }
            if vm.agentState == .ended { return "Oturum bitti" }
            return "Sıra sende"
        }
        if vm.isMicMuted, vm.agentState == .listening {
            return "Mikrofon kapalı"
        }
        switch vm.agentState {
        case .listening: return "Dinliyor..."
        case .thinking: return "Düşünüyor..."
        case .speaking: return "Konuşuyor..."
        case .ended: return "Oturum bitti"
        case .unknown:
            if vm.isConnecting { return "Bağlanıyor..." }
            return vm.statusLine.isEmpty ? "Hazır" : vm.statusLine
        }
    }

    var statusColor: Color {
        if !hasStarted {
            return AppColor.primary
        }
        if config.mode == .text || isTextFallbackMode {
            if vm.agentState == .ended { return AppColor.textSecondary }
            if vm.isAwaitingReply || vm.agentState == .thinking { return AppColor.primary }
            return AppColor.success
        }
        if vm.isMicMuted, vm.agentState == .listening {
            return AppColor.textSecondary
        }
        switch vm.agentState {
        case .listening: return AppColor.success
        case .thinking: return AppColor.primary
        case .speaking: return AppColor.warning
        case .ended: return AppColor.textSecondary
        case .unknown: return AppColor.textSecondary
        }
    }

    var statusBackground: Color {
        if !hasStarted {
            return AppColor.primaryLight
        }
        if config.mode == .text || isTextFallbackMode {
            if vm.agentState == .ended { return AppColor.surfaceAlt }
            if vm.isAwaitingReply || vm.agentState == .thinking { return AppColor.primaryLight }
            return AppColor.successLight
        }
        if vm.isMicMuted, vm.agentState == .listening {
            return AppColor.surfaceAlt
        }
        switch vm.agentState {
        case .listening: return AppColor.successLight
        case .thinking: return AppColor.primaryLight
        case .speaking: return AppColor.warningLight
        case .ended: return AppColor.surfaceAlt
        case .unknown: return AppColor.surfaceAlt
        }
    }

    func requestMicrophoneIfNeeded() async {
        let granted = await requestMicrophoneAccess()
        micPermission = granted ? .granted : .denied
    }

    func syncMicrophonePermissionStatus() {
        guard config.mode == .voice else { return }
        guard !hasRequestedInitialMic else { return }
        hasRequestedInitialMic = true
        micPermission = AVAudioSession.sharedInstance().recordPermission
        if micPermission != .granted {
            vm.errorText = "Sesli moda geçmek için mikrofon izni gerekiyor."
        }
    }

    @MainActor
    func triggerStartSession() {
        guard startSessionTask == nil else {
            print("[startSession] trigger ignored - task already in flight")
            return
        }
        startSessionTask = Task { @MainActor in
            defer { startSessionTask = nil }
            await startSession()
        }
    }

    @MainActor
    func startSession() async {
        guard !hasStarted, !isStartingSession else {
            print("[startSession] skip hasStarted=\(hasStarted) isStartingSession=\(isStartingSession) state=\(vm.connectionState)")
            return
        }
        isStartingSession = true
        defer { isStartingSession = false }
        print("[startSession] begin state=\(vm.connectionState)")
        vm.setTextOnlyOverride(config.mode == .voice && isTextFallbackMode)
        if config.mode == .voice && !isTextFallbackMode {
            await requestMicrophoneIfNeeded()
            guard micPermission == .granted else {
                vm.errorText = "Sesli mod için mikrofon izni gerekiyor."
                Haptic.error()
                print("[startSession] abort microphone permission denied")
                return
            }
        }
        hasStarted = true
        userRequestedEnd = false
        print("[startSession] calling connect")
        await vm.connect(using: state)
    }

    var canSendText: Bool {
        !vm.isConnecting &&
            !vm.isEnding &&
            !wasSessionEnded
    }

    func finalizeCase() async {
        if wasSessionEnded { return }
        wasSessionEnded = true
        let snapshotBeforeEnd = vm.stableTranscript
        finishedTranscript = snapshotBeforeEnd
        if finishedTranscript.isEmpty, !vm.messages.isEmpty {
            finishedTranscript = vm.messages.map {
                ConversationLine(
                    source: $0.source,
                    message: $0.text,
                    timestamp: Int($0.timestamp.timeIntervalSince1970 * 1000)
                )
            }
        }

        showResultFlow = true
        Task {
            await vm.end()
        }
    }

    func markUserRequestedEnd() {
        userRequestedEnd = true
        vm.markUserRequestedEnd()
    }

    func resetSessionForRetry() {
        isComposerFocused = false
        showEndSessionConfirmation = false
        startSessionTask?.cancel()
        startSessionTask = nil
        isStartingSession = false
        userRequestedEnd = false
        wasSessionEnded = false
        hasStarted = false
        finishedTranscript = []
        vm.cleanup()
    }

    func requestEndSessionConfirmation() {
        guard hasStarted else { return }
        guard !vm.isEnding, !wasSessionEnded else { return }
        showEndSessionConfirmation = true
    }

    func confirmEndSession() {
        guard !vm.isEnding, !wasSessionEnded else { return }
        isComposerFocused = false
        markUserRequestedEnd()
        Task { await finalizeCase() }
    }

    var activeHeadline: String {
        let trimmedTitle = config.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let specialtyLabel = SpecialtyOption.label(for: config.specialty)
        if specialtyLabel.isEmpty || specialtyLabel == "Tümü" {
            return "Klinik vaka"
        }
        return "\(specialtyLabel) vakası"
    }

    var firstAgentPreview: String? {
        if let preview = config.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return preview
        }
        if let complaint = config.chiefComplaint?.trimmingCharacters(in: .whitespacesAndNewlines), !complaint.isEmpty {
            return complaint
        }
        return nil
    }
}
