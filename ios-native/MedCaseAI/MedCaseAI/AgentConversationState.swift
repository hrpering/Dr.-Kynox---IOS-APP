import Foundation

extension AgentConversationViewModel {
    var isConnecting: Bool { connectionState == .connecting }
    var isConnected: Bool { connectionState == .connected }
    var isEnding: Bool { connectionState == .ending }

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
