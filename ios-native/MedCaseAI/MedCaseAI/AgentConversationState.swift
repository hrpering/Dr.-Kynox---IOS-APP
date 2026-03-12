import Foundation

extension AgentConversationViewModel {
    var isConnecting: Bool { connectionState == .connecting }
    var isConnected: Bool { connectionState == .connected }
    var isEnding: Bool { connectionState == .ending }
#if canImport(ElevenLabs)
    var isTextSendReady: Bool {
        activeMode == .text &&
            connectionState == .connected &&
            isConversationActive &&
            didReachActiveState &&
            conversation != nil
    }
#else
    var isTextSendReady: Bool { false }
#endif

    var transcript: [ConversationLine] {
        messages.map { $0.transcriptLine }
    }

    var stableTranscript: [ConversationLine] {
        let live = normalizedTranscript(messages.map { $0.transcriptLine })
        return live.count >= transcriptBuffer.count ? live : transcriptBuffer
    }

    func setTextOnlyOverride(_ enabled: Bool) {
        launchModeOverride = enabled ? .text : nil
    }
}
