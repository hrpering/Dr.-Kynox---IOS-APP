import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

extension CaseSessionView {
    var topCaseHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activeHeadline)
                        .font(AppFont.title2)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(SpecialtyOption.label(for: config.specialty))
                        .font(AppFont.caption)
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
                Badge(text: config.difficulty, tint: AppColor.primaryDark, background: .white.opacity(0.9))
            }

            HStack(spacing: 7) {
                sessionHeaderMetric(title: "Mod", value: (config.mode == .voice && !isTextFallbackMode) ? "Sesli" : "Yazılı")
                sessionHeaderMetric(title: "Mesaj", value: "\(vm.messages.count)")
                sessionHeaderMetric(title: "Durum", value: hasStarted ? "Aktif" : "Hazırlık")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [AppColor.primaryDark, AppColor.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.elevated)
    }

    var statusStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)

                Text(statusText)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }

            Spacer()

            Text(hasStarted ? "Canlı" : "Beklemede")
                .font(AppFont.caption)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(statusBackground)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private func sessionHeaderMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(.white.opacity(0.75))
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
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
                        MessageBubble(
                            row: row,
                            accessories: accessories(for: row),
                            onAccessoryTap: handleMessageAccessoryTap
                        )
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
                                resetStartFlowForRetry()
                                attemptInitialAutoStart(trigger: .retry)
                            } else {
                                vm.errorText = ""
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
        VStack(spacing: 12) {
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
        .padding(.vertical, showVoicePermissionPreflight ? 16 : 34)
    }

    var textComposer: some View {
        let textCharacterLimit = 300
        let remainingCharacters = max(0, textCharacterLimit - textInput.count)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                TextField("Mesajını yaz", text: $textInput, axis: .vertical)
                    .font(AppFont.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .lineLimit(1...4)
                    .focused($isComposerFocused)
                    .frame(minHeight: 42, maxHeight: 110, alignment: .topLeading)
                    .background(AppColor.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: textInput) { newValue in
                        guard newValue.count > textCharacterLimit else { return }
                        textInput = String(newValue.prefix(textCharacterLimit))
                    }

                Button {
                    let text = textInput
                    Task {
                        guard !isSendingTextMessage else { return }
                        guard canSendText else {
                            vm.errorText = "Oturum şu an kapanıyor, lütfen bekle."
                            Haptic.error()
                            return
                        }
                        let clean = String(text.prefix(textCharacterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        if !hasStarted || vm.connectionState == .idle || vm.connectionState == .ended || vm.connectionState == .failed {
                            vm.errorText = "Önce vakayı başlatın."
                            Haptic.error()
                            return
                        }
                        isSendingTextMessage = true
                        defer { isSendingTextMessage = false }
                        do {
                            try await vm.sendMessage(clean)
                            await MainActor.run {
                                textInput = ""
                                isComposerFocused = false
                            }
                        } catch {
                            vm.errorText = error.localizedDescription
                            Haptic.error()
                        }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppColor.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(
                    textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || vm.isEnding
                        || wasSessionEnded
                        || isSendingTextMessage
                )
                .accessibilityLabel("Gönder")
                .accessibilityHint("Mesajı vakaya gönderir")
            }

            Text("Kalan karakter: \(remainingCharacters)")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder
    var bottomControlArea: some View {
        VStack(spacing: 8) {
            if !hasStarted {
                if showVoicePermissionPreflight {
                    VStack(spacing: 8) {
                        Button {
                            Task {
                                await requestMicrophoneIfNeeded()
                                if micPermission == .granted {
                                    vm.errorText = ""
                                    attemptInitialAutoStart(trigger: .permissionGranted)
                                } else {
                                    startPhase = .waitingPermission
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
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(AppColor.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            isTextFallbackMode = true
                            vm.errorText = ""
                            startPhase = .idle
                            attemptInitialAutoStart(trigger: .modeFallback)
                            Haptic.selection()
                        } label: {
                            Text("Şimdilik yazılı moda geç")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.primaryDark)
                                .frame(maxWidth: .infinity, minHeight: 42)
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
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .background(AppColor.surface)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AppColor.border).frame(height: 1)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Vaka hazırlanıyor, bağlantı kuruluyor...")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .background(AppColor.surface)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AppColor.border).frame(height: 1)
                    }
                }
            } else {
                if config.mode == .text || isTextFallbackMode {
                    textComposer
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                } else {
                    voiceControls
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }

                if config.mode == .voice, micPermission != .granted {
                    warningBanner
                        .padding(.horizontal, 12)
                }

                if !(config.mode == .text || isTextFallbackMode) || !isKeyboardVisible {
                    Button {
                        requestEndSessionConfirmation()
                    } label: {
                        Text("Vaka Sonlandır")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.error)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppColor.errorLight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppColor.error.opacity(0.35), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                }
            }
        }
        .padding(.bottom, 6)
        .background(AppColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(AppColor.border).frame(height: 1)
        }
    }

    var voiceControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
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
                        .frame(width: 48, height: 48)
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
                        .frame(width: 66, height: 66)
                        .overlay(
                            Image(systemName: vm.isMicMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 24, weight: .semibold))
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
                        .frame(width: 48, height: 48)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppColor.primaryLight)
                    .frame(width: 40, height: 40)
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

            VStack(alignment: .leading, spacing: 5) {
                preflightBenefit("Mikrofon yalnızca vaka sırasında kullanılır.")
                preflightBenefit("İstediğinde yazılı moda geçebilirsin.")
            }
        }
        .padding(10)
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
            switch startPhase {
            case .idle:
                return "Vaka hazırlanıyor..."
            case .waitingPermission:
                return "Mikrofon izni bekleniyor"
            case .starting:
                return "Bağlanıyor..."
            case .started:
                return "Bağlantı doğrulanıyor..."
            case .failed:
                return "Bağlantı kurulamadı"
            }
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

    @MainActor
    func observeMicrophonePermission(_ permission: AVAudioSession.RecordPermission, reason: String) {
        let previous = lastObservedMicPermission
        micPermission = permission
        lastObservedMicPermission = permission
        guard previous != permission else { return }
        AppLog.log(
            "[mic-permission] reason=\(reason) old=\(String(describing: previous?.rawValue)) new=\(permission.rawValue)",
            level: .debug,
            category: .caseSession
        )
    }

    @MainActor
    @discardableResult
    func refreshMicrophonePermission(reason: String) -> AVAudioSession.RecordPermission {
        let permission = AVAudioSession.sharedInstance().recordPermission
        observeMicrophonePermission(permission, reason: reason)
        return permission
    }

    func requestMicrophoneIfNeeded() async {
        let granted = await requestMicrophoneAccess()
        let resolvedPermission = granted ? AVAudioSession.RecordPermission.granted : AVAudioSession.sharedInstance().recordPermission
        await MainActor.run {
            observeMicrophonePermission(resolvedPermission, reason: "request_result")
        }
    }

    @MainActor
    func handleSceneActivePermissionRecheck() {
        guard startPhase == .waitingPermission else { return }
        guard config.mode == .voice && !isTextFallbackMode else { return }
        let permission = refreshMicrophonePermission(reason: "scene_active_recheck")
        guard permission == .granted else { return }
        vm.errorText = ""
        attemptInitialAutoStart(trigger: .sceneActivePermissionGrant)
    }

    @MainActor
    func attemptInitialAutoStart(trigger: AutoStartTrigger) {
        guard !hasStarted, !isStartingSession else { return }
        guard startSessionTask == nil else { return }
        guard startPhase != .starting, startPhase != .started else { return }
        if startPhase == .failed, trigger != .retry {
            return
        }

        vm.setTextOnlyOverride(config.mode == .voice && isTextFallbackMode)

        if config.mode == .voice && !isTextFallbackMode {
            let permission = refreshMicrophonePermission(reason: "auto_start_\(trigger.rawValue)")
            guard permission == .granted else {
                startPhase = .waitingPermission
                if vm.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.errorText = "Sesli mod için mikrofon izni gerekiyor."
                }
                return
            }
        }

        vm.errorText = ""
        startPhase = .starting
        triggerStartSession()
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
            let permission = refreshMicrophonePermission(reason: "start_session")
            guard permission == .granted else {
                startPhase = .waitingPermission
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
        vm.isTextSendReady &&
            !vm.isConnecting &&
            !vm.isEnding &&
            !wasSessionEnded
    }

    func finalizeCase() async {
        if wasSessionEnded { return }
        wasSessionEnded = true
        activeToolSheetRoute = nil
        let snapshotBeforeEnd = vm.stableTranscript
        finishedTranscript = snapshotBeforeEnd
        finishedToolResults = vm.exportCaseToolResults()
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

    func resetStartFlowForRetry() {
        isComposerFocused = false
        activeToolSheetRoute = nil
        showEndSessionConfirmation = false
        startSessionTask?.cancel()
        startSessionTask = nil
        isStartingSession = false
        startPhase = .idle
        userRequestedEnd = false
        wasSessionEnded = false
        hasStarted = false
        finishedTranscript = []
        finishedToolResults = []
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

    func accessories(for row: AgentConversationViewModel.Message) -> [MessageBubbleAccessory] {
        vm.messageAccessoriesByMessageId[row.id] ?? []
    }

    func handleMessageAccessoryTap(_ accessory: MessageBubbleAccessory) {
        switch accessory.action {
        case .openToolResult(let toolCallId):
            guard vm.resultsByToolCallId[toolCallId] != nil else {
                vm.errorText = "Sonuçlar henüz hazır değil."
                Haptic.error()
                return
            }
            activeToolSheetRoute = .tool(toolCallId: toolCallId)
            Haptic.selection()
        case .openImagingResults(let anchorToolCallId):
            guard !imagingSheetItems(anchorToolCallId: anchorToolCallId).isEmpty else {
                vm.errorText = "Görüntüleme sonuçları henüz hazır değil."
                Haptic.error()
                return
            }
            activeToolSheetRoute = .imaging(anchorToolCallId: anchorToolCallId)
            Haptic.selection()
        }
    }

    func selectedToolSheetPayload(toolCallId: String) -> (descriptor: ToolDescriptor, payload: ToolResultPayload)? {
        guard let toolName = vm.toolCallNameMap[toolCallId],
              let descriptor = ToolDescriptor.byName[toolName],
              let payload = vm.resultsByToolCallId[toolCallId] else {
            return nil
        }
        return (descriptor: descriptor, payload: payload)
    }

    func imagingSheetItems(anchorToolCallId: String) -> [ImagingSheetItem] {
        guard let messageId = vm.toolCallMessageIdMap[anchorToolCallId] else { return [] }
        let toolCallIds = vm.toolCallMessageIdMap
            .filter { $0.value == messageId }
            .map(\.key)
            .sorted()
        return toolCallIds.compactMap { toolCallId in
            guard let toolName = vm.toolCallNameMap[toolCallId],
                  let descriptor = ToolDescriptor.byName[toolName],
                  descriptor.category == .imaging,
                  let payload = vm.resultsByToolCallId[toolCallId],
                  case .imaging(let imaging) = payload else {
                return nil
            }
            return ImagingSheetItem(toolCallId: toolCallId, descriptor: descriptor, result: imaging)
        }
    }

    func imagingInitialSegment(anchorToolCallId: String) -> ImagingResultSegment {
        guard let toolName = vm.toolCallNameMap[anchorToolCallId],
              let descriptor = ToolDescriptor.byName[toolName],
              let segment = descriptor.imagingSegment else {
            return .all
        }
        return segment
    }
}

struct ImagingSheetItem: Identifiable {
    let toolCallId: String
    let descriptor: ToolDescriptor
    let result: ImagingToolResult
    var id: String { toolCallId }
}

struct ToolResultSheetView: View {
    let config: CaseLaunchConfig
    let descriptor: ToolDescriptor
    let payload: ToolResultPayload
    let onContinue: () -> Void

    var body: some View {
        switch payload {
        case .panel(let result):
            PanelToolResultsSheetView(config: config, descriptor: descriptor, result: result, onContinue: onContinue)
        case .vitals(let result):
            VitalsToolResultsSheetView(config: config, descriptor: descriptor, result: result, onContinue: onContinue)
        case .imaging(let result):
            CombinedImagingResultsSheetView(
                config: config,
                items: [ImagingSheetItem(toolCallId: "single-\(descriptor.toolName)", descriptor: descriptor, result: result)],
                initialSegment: result.segment,
                onContinue: onContinue
            )
        }
    }
}

struct PanelToolResultsSheetView: View {
    let config: CaseLaunchConfig
    let descriptor: ToolDescriptor
    let result: PanelToolResult
    let onContinue: () -> Void

    var body: some View {
        ToolSheetScaffold(config: config, onContinue: onContinue) {
            ToolSheetHeaderCard(config: config)
            VStack(alignment: .leading, spacing: 10) {
                ToolSectionTitle(icon: descriptor.iconSystemName, tint: descriptor.tint, title: result.title)
                if result.metrics.isEmpty {
                    Text("Sonuç metrikleri bulunamadı.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(result.metrics) { metric in
                            PanelMetricCard(metric: metric)
                        }
                    }
                }
            }
            .toolCardStyle()
            ToolSummaryCard(text: result.verbalSummary)
        }
    }
}

struct VitalsToolResultsSheetView: View {
    let config: CaseLaunchConfig
    let descriptor: ToolDescriptor
    let result: VitalsToolResult
    let onContinue: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ToolSheetScaffold(config: config, onContinue: onContinue) {
            ToolSheetHeaderCard(config: config)
            VStack(alignment: .leading, spacing: 10) {
                ToolSectionTitle(icon: descriptor.iconSystemName, tint: descriptor.tint, title: result.title)
                if result.metrics.isEmpty {
                    Text("Vital bulgu verisi bulunamadı.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(result.metrics) { metric in
                            VitalsMetricCard(metric: metric)
                        }
                    }
                }
            }
            .toolCardStyle()
            ToolSummaryCard(text: result.verbalSummary)
        }
    }
}

struct CombinedImagingResultsSheetView: View {
    let config: CaseLaunchConfig
    let items: [ImagingSheetItem]
    let initialSegment: ImagingResultSegment
    let onContinue: () -> Void

    @State private var selectedSegment: ImagingResultSegment = .all

    var body: some View {
        ToolSheetScaffold(config: config, onContinue: onContinue) {
            ToolSheetHeaderCard(config: config)
            segmentSelector
            if filteredItems.isEmpty {
                Text("Görüntüleme bulgusu bulunamadı.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, 8)
            } else {
                ForEach(filteredItems) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        ToolSectionTitle(icon: item.descriptor.iconSystemName, tint: item.descriptor.tint, title: item.descriptor.displayTitle)
                        if !item.result.metadata.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(item.result.metadata) { metadata in
                                    Text("\(metadata.title): \(metadata.value)")
                                        .font(AppFont.caption)
                                        .foregroundStyle(AppColor.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(AppColor.surfaceAlt)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        if item.result.findings.isEmpty {
                            Text("Bulgular bulunamadı.")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(item.result.findings) { finding in
                                    ImagingFindingCard(finding: finding)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Radiologist Report")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                            Text(item.result.impression.isEmpty ? "İzlenim bulunamadı." : item.result.impression)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                        }
                        .padding(10)
                        .background(AppColor.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .toolCardStyle()
                }
            }
            ToolSummaryCard(text: combinedSummaryText)
        }
        .onAppear {
            selectedSegment = initialSegment
        }
    }

    var filteredItems: [ImagingSheetItem] {
        if selectedSegment == .all {
            return items
        }
        return items.filter { $0.result.segment == selectedSegment }
    }

    var combinedSummaryText: String {
        items
            .map(\.result.verbalSummary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    var segmentSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableSegments) { segment in
                    Button {
                        selectedSegment = segment
                    } label: {
                        Text(segment.title)
                            .font(AppFont.caption)
                            .foregroundStyle(selectedSegment == segment ? AppColor.primary : AppColor.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(selectedSegment == segment ? AppColor.primaryLight : AppColor.surfaceAlt)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selectedSegment == segment ? AppColor.primary.opacity(0.3) : AppColor.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
        }
        .padding(8)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var availableSegments: [ImagingResultSegment] {
        var segments: [ImagingResultSegment] = [.all]
        let fromItems = Set(items.map(\.result.segment))
        segments.append(contentsOf: ImagingResultSegment.allCases.filter { fromItems.contains($0) })
        return segments
    }
}

struct ToolSheetScaffold<Content: View>: View {
    let config: CaseLaunchConfig
    let onContinue: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            Button {
                onContinue()
            } label: {
                HStack(spacing: 8) {
                    Text("Vakaya Devam")
                        .font(AppFont.bodyMedium)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .background(AppColor.surface)
        }
        .background(AppColor.background.ignoresSafeArea())
    }
}

struct ToolSheetHeaderCard: View {
    let config: CaseLaunchConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.primary)
                .frame(width: 34, height: 34)
                .background(AppColor.primaryLight)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(config.toolSheetPatientLine)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Text(config.toolSheetCaseLine)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ToolSectionTitle: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
    }
}

struct PanelMetricCard: View {
    let metric: PanelMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(metric.title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: metric.status.iconSystemName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(metric.status.accentColor)
                    .clipShape(Circle())
            }
            if let reference = metric.referenceRange, !reference.isEmpty {
                Text("Referans: \(reference)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.valueText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(metric.status.accentColor)
                if !metric.unit.isEmpty {
                    Text(metric.unit)
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
        .padding(12)
        .background(metric.status.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(metric.status.accentColor.opacity(metric.status.severityScore == 0 ? 0.24 : 0.52), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct VitalsMetricCard: View {
    let metric: VitalsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName(for: metric.id))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(metric.status.accentColor)
                Spacer(minLength: 0)
                Image(systemName: metric.status.iconSystemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(metric.status.accentColor)
                    .clipShape(Circle())
            }
            Text(metric.title)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
            Text(metric.valueText)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.textPrimary)
            if !metric.unit.isEmpty {
                Text(metric.unit)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metric.status.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(metric.status.accentColor.opacity(metric.status.severityScore == 0 ? 0.22 : 0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func iconName(for key: String) -> String {
        switch key {
        case "blood_pressure":
            return "heart.fill"
        case "heart_rate":
            return "waveform.path.ecg"
        case "respiratory_rate":
            return "lungs.fill"
        case "oxygen_saturation":
            return "drop.fill"
        case "temperature":
            return "thermometer.medium"
        case "gcs":
            return "brain.head.profile"
        case "pain_score":
            return "exclamationmark.circle"
        default:
            return "cross.case"
        }
    }
}

struct ImagingFindingCard: View {
    let finding: ImagingFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(finding.title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: finding.status.iconSystemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(finding.status.accentColor)
                    .clipShape(Circle())
            }
            Text(finding.detail)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .padding(10)
        .background(finding.status.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(finding.status.accentColor.opacity(0.42), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ToolSummaryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.primary)
                Text("Clinical Insights")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }
            Text(summaryText)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.primary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var summaryText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Özet bulunamadı." : trimmed
    }
}

extension View {
    func toolCardStyle() -> some View {
        self
            .padding(12)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension CaseLaunchConfig {
    var toolSheetPatientLine: String {
        let gender = patientGender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let age = patientAge.map { "\($0)Y" } ?? ""
        let fragments = [gender, age].filter { !$0.isEmpty }
        if fragments.isEmpty {
            return "Hasta: Bilgi paylaşılmadı"
        }
        return "Hasta: \(fragments.joined(separator: ", "))"
    }

    var toolSheetCaseLine: String {
        let challenge = challengeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !challenge.isEmpty {
            return "Case #\(challenge)"
        }
        return "Case #\(String(id.prefix(8)).uppercased())"
    }
}
