import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI

#if canImport(ElevenLabs)
import ElevenLabs
#endif

extension AgentConversationViewModel {
    var hasBackgroundAudioCapability: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("audio")
    }

    func prepareVoiceAudioSession() throws {
        guard activeMode == .voice else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
        logDebug("[EL] AVAudioSession category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        logDebug("[EL] AVAudioSession otherAudioPlaying=\(session.isOtherAudioPlaying)")
        logDebug("[EL] Mic permission=\(session.recordPermission.rawValue)")
    }

    func deactivateVoiceAudioSessionIfNeeded() {
        guard activeMode == .voice else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logWarning("[audio] deactivate failed error=\(String(reflecting: error))")
        }
    }

    func installVoiceAudioObserversIfNeeded() {
        guard activeMode == .voice else { return }
        if audioInterruptionObserver == nil {
            audioInterruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioInterruption(notification)
                }
            }
        }
        if audioRouteChangeObserver == nil {
            audioRouteChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioRouteChange(notification)
                }
            }
        }
    }

    func removeVoiceAudioObservers() {
        if let token = audioInterruptionObserver {
            NotificationCenter.default.removeObserver(token)
            audioInterruptionObserver = nil
        }
        if let token = audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(token)
            audioRouteChangeObserver = nil
        }
    }

    func handleAudioInterruption(_ notification: Notification) {
        guard activeMode == .voice else { return }
        guard let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }
        switch type {
        case .began:
            statusLine = "Ses kesintisi algılandı."
            logInfo("[audio] interruption began")
            if connectionState == .connected, !isMicMuted {
                Task { try? await self.setMuted(true) }
            }
        case .ended:
            let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            logInfo("[audio] interruption ended options=\(options.rawValue)")
            guard options.contains(.shouldResume) else {
                statusLine = "Ses kesintisi bitti. Devam etmek için tekrar konuş."
                return
            }
            do {
                try prepareVoiceAudioSession()
                statusLine = "Ses oturumu geri yüklendi."
            } catch {
                errorText = "Ses kesintisi sonrası oturum geri yüklenemedi: \(error.localizedDescription)"
            }
        @unknown default:
            break
        }
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard activeMode == .voice else { return }
        guard let userInfo = notification.userInfo,
              let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return
        }
        logDebug("[audio] route change reason=\(reason.rawValue)")
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .routeConfigurationChange:
            do {
                try prepareVoiceAudioSession()
                if connectionState == .connected {
                    statusLine = "Ses aygıtı değişti. Oturum güncellendi."
                }
            } catch {
                errorText = "Ses aygıtı değişiminden sonra oturum güncellenemedi: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    func startNetworkMonitorIfNeeded() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathStatus(path.status)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
        lastNetworkStatus = nil
        lastNetworkLossAt = nil
        lastNetworkRecoveryAt = nil
    }

    func handleNetworkPathStatus(_ status: NWPath.Status) {
        let previous = lastNetworkStatus
        lastNetworkStatus = status
        let now = Date()
        if previous == status {
            return
        }
        logInfo("[network] status=\(String(describing: status)) previous=\(String(describing: previous))")
        if status != .satisfied {
            lastNetworkLossAt = now
            if connectionState == .connected || connectionState == .connecting {
                statusLine = "İnternet bağlantısı kesildi. Bağlantı geri geldiğinde yeniden deneyebilirsin."
            }
            return
        }
        if previous == .unsatisfied || previous == .requiresConnection {
            lastNetworkRecoveryAt = now
            if connectionState == .failed || connectionState == .ended {
                errorText = "İnternet bağlantısı geri geldi. Oturumu yeniden başlatabilirsin."
            } else if connectionState == .connected {
                statusLine = "İnternet bağlantısı geri geldi."
            }
        }
    }

    func didNetworkTransitionRecently(within seconds: TimeInterval = 20) -> Bool {
        let now = Date()
        if let lastNetworkLossAt, now.timeIntervalSince(lastNetworkLossAt) <= seconds {
            return true
        }
        if let lastNetworkRecoveryAt, now.timeIntervalSince(lastNetworkRecoveryAt) <= seconds {
            return true
        }
        return false
    }

    #if canImport(ElevenLabs)
    func unexpectedEndDiagnostic(_ reason: EndReason) -> String {
        if endRequestedByUser {
            return "user_requested"
        }
        if let source = lastLocalEndSource, localEndCounter > 0 {
            return "local_end:\(source)"
        }
        switch reason {
        case .userEnded:
            if didNetworkTransitionRecently() {
                return "network_transition_or_keepalive_timeout"
            }
            return "sdk_userEnded_mapping_or_agent_end_call"
        case .agentNotConnected:
            return "agent_not_connected"
        case .remoteDisconnected:
            if didNetworkTransitionRecently() {
                return "network_transition"
            }
            return "remote_disconnected"
        }
    }
    #endif

    func markLocalEnd(source: String) {
        localEndCounter += 1
        lastLocalEndSource = source
#if canImport(ElevenLabs)
        let conversationState = conversation.map { String(describing: $0.state) } ?? "nil"
#else
        let conversationState = "unavailable"
#endif
        logInfo(
            "[LOCAL_END] #\(localEndCounter) source=\(source) mode=\(activeMode.rawValue) conn=\(connectionState) convo=\(conversationState) net=\(String(describing: lastNetworkStatus))"
        )
    }

    func buildSavePayload(score: ScoreResponse?,
                                  status: String,
                                  endedAt: Date,
                                  transcript: [ConversationLine]) -> SaveCasePayload {
        SaveCasePayload(
            sessionId: config.id,
            mode: activeMode.rawValue,
            status: status,
            startedAt: Self.iso8601.string(from: startedAt),
            endedAt: Self.iso8601.string(from: endedAt),
            durationMin: max(1, Int(endedAt.timeIntervalSince(startedAt) / 60)),
            messageCount: transcript.count,
            difficulty: config.difficulty,
            caseContext: .init(
                title: score?.caseTitle ?? config.displayTitle,
                specialty: config.specialty,
                subtitle: config.displaySubtitle,
                challengeId: config.challengeId,
                challengeType: config.challengeType,
                expectedDiagnosis: score?.trueDiagnosis ?? config.expectedDiagnosis
            ),
            transcript: transcript,
            score: score,
            textRuntime: activeMode == .text
                ? .init(
                    didReachActiveState: didReachActiveState,
                    disconnectDiagnostic: lastDisconnectDiagnostic
                )
                : nil,
            toolResults: nil,
            testResults: nil
        )
    }

    func flushConversationMessages() async {
#if canImport(ElevenLabs)
        guard let conversation else { return }
        let sdkMessages = conversation.messages
        guard !sdkMessages.isEmpty else { return }
        let mapped = sdkMessages.compactMap { raw -> Message? in
            let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let source = raw.role == .user ? "user" : "ai"
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "flush-\(UUID().uuidString)"
                : raw.id
            return Message(id: id, source: source, text: content, timestamp: raw.timestamp)
        }
        messages = dedupe(mapped)
        refreshTranscriptBuffer()
        isAwaitingReply = messages.last?.source == "user"
#endif
    }

    func normalizedTranscript(_ lines: [ConversationLine]) -> [ConversationLine] {
        lines.compactMap { line in
            let text = line.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ConversationLine(source: canonicalSource(line.source), message: text, timestamp: line.timestamp)
        }
    }

    func refreshTranscriptBuffer() {
        let normalized = normalizedTranscript(messages.map { $0.transcriptLine })
        guard !normalized.isEmpty else { return }
        if normalized.count >= transcriptBuffer.count {
            transcriptBuffer = normalized
        }
    }

    func refreshUsageCounters() {
        // Karakter/mesaj sayaçları post-call webhook üzerinden toplandığı için
        // istemci tarafında local sayaç tutulmuyor.
    }

    func dedupe(_ input: [Message]) -> [Message] {
        let sorted = input.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }

        var output: [Message] = []
        var seenById = Set<String>()
        var seenNearText: [String: Date] = [:]

        for item in sorted {
            if seenById.contains(item.id) {
                continue
            }
            seenById.insert(item.id)

            let fingerprint = "\(item.source)|\(normalize(item.text))"
            if let last = seenNearText[fingerprint], abs(item.timestamp.timeIntervalSince(last)) < nearTextDuplicateWindowSeconds {
                continue
            }
            seenNearText[fingerprint] = item.timestamp
            output.append(item)
        }
        return output
    }

    func appendLocalMessage(source: String, text: String, id: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        messages = dedupe(messages + [Message(id: id, source: source, text: clean, timestamp: Date())])
        refreshTranscriptBuffer()
        refreshUsageCounters()
    }

    func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
