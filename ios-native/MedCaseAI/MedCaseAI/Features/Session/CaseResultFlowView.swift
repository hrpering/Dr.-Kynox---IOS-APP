import SwiftUI

struct CaseResultFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: CaseLaunchConfig
    let startedAt: Date
    let transcript: [ConversationLine]
    let mode: CaseLaunchConfig.Mode

    @State private var isLoading = true
    @State private var result: ScoreResponse?
    @State private var noData = false
    @State private var pendingScore = false
    @State private var errorText = ""
    @State private var loadingMessageIndex = 0
    @State private var loadingFactIndex = 0
    @State private var pendingStartedAt: Date?
    @State private var scoringTranscript: [ConversationLine] = []
    @State private var loadingTickerTask: Task<Void, Never>?
    private static let iso8601 = ISO8601DateFormatter()

    private let loadingMessages = [
        "Performansın analiz ediliyor...",
        "Klinik karar zincirin değerlendiriliyor...",
        "Geri bildirim önerileri hazırlanıyor...",
        "Neredeyse bitti..."
    ]

    private let loadingFacts = [
        "İpucu: Acil vakalarda ilk 60 saniye doğru önceliklendirme skoru en çok etkiler.",
        "İpucu: Kısa ve net anamnez soruları ayırıcı tanıyı hızlandırır.",
        "İpucu: Kırmızı bayrakları erken sorgulamak puanı doğrudan yükseltir."
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ScoringLoadingView(
                        primaryText: loadingMessages[loadingMessageIndex],
                        secondaryText: loadingFacts[loadingFactIndex]
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if noData {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.badge.exclamationmark.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(AppColor.warning)
                        Text("Deneme oturumu kaydedildi")
                            .font(AppFont.title2)
                            .foregroundStyle(AppColor.textPrimary)
                        Text("Bu oturum değerlendirme için yetersiz veri içeriyor. Bir tur daha yaparsan daha net skor ve tanı geri bildirimi oluşur.")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                        VStack(spacing: 10) {
                            Button("Bir Tur Daha Dene") {
                                state.generatorReplayContext = GeneratorReplayContext(
                                    specialty: config.specialty,
                                    difficulty: config.difficulty
                                )
                                state.selectedMainTab = "generator"
                                dismiss()
                            }
                            .appPrimaryButton()

                            Button("Ana Sayfa") {
                                state.selectedMainTab = "home"
                                dismiss()
                            }
                            .appSecondaryButton()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pendingScore {
                    VStack(spacing: 14) {
                        ScoringLoadingView(
                            primaryText: loadingMessages[loadingMessageIndex],
                            secondaryText: loadingFacts[loadingFactIndex]
                        )
                            .frame(height: 200)
                        Text("Skor hazırlanıyor. Birkaç saniye sürebilir.")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                            .multilineTextAlignment(.center)
                        if shouldShowRefreshButton {
                            Button("Yenile") {
                                pendingScore = false
                                isLoading = true
                                Task { await runScoringFlow(force: true) }
                            }
                            .appSecondaryButton()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result {
                    ResultsView(
                        result: result,
                        config: config,
                        transcript: scoringTranscript.isEmpty ? transcript : scoringTranscript,
                        sessionId: config.id,
                        onClose: {
                            state.selectedMainTab = "home"
                            dismiss()
                        },
                        onRetry: {
                            state.generatorReplayContext = GeneratorReplayContext(
                                specialty: config.specialty,
                                difficulty: config.difficulty
                            )
                            state.selectedMainTab = "generator"
                            dismiss()
                        }
                    )
                } else {
                    VStack(spacing: 12) {
                        ErrorStateCard(message: errorText.isEmpty ? "Sonuç üretilemedi." : errorText) {
                            Task { await runScoringFlow(force: true) }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Vaka sonucu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        state.selectedMainTab = "home"
                        dismiss()
                    }
                        .foregroundStyle(AppColor.primary)
                }
            }
            .task {
                await runScoringFlow()
            }
            .onAppear {
                updateLoadingTickerState()
            }
            .onChange(of: isLoading) { _ in
                updateLoadingTickerState()
            }
            .onChange(of: pendingScore) { _ in
                updateLoadingTickerState()
            }
            .onDisappear {
                stopLoadingTicker()
            }
        }
    }

    private func updateLoadingTickerState() {
        if isLoading || pendingScore {
            startLoadingTickerIfNeeded()
        } else {
            stopLoadingTicker()
        }
    }

    private func startLoadingTickerIfNeeded() {
        guard loadingTickerTask == nil else { return }
        loadingTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_300_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard isLoading || pendingScore else { break }
                loadingMessageIndex = (loadingMessageIndex + 1) % loadingMessages.count
                loadingFactIndex = (loadingFactIndex + 1) % loadingFacts.count
            }
            loadingTickerTask = nil
        }
    }

    private func stopLoadingTicker() {
        loadingTickerTask?.cancel()
        loadingTickerTask = nil
    }

    private func runScoringFlow(force: Bool = false) async {
        if !isLoading && !force { return }
        isLoading = true
        pendingScore = false
        pendingStartedAt = nil

        let endedAt = Date()
        var cleanTranscript = normalizedTranscript(from: transcript)

        if let existing = findSavedCase(),
           let existingScore = existing.score {
            scoringTranscript = normalizedTranscript(from: existing.transcript ?? transcript)
            result = existingScore
            noData = false
            errorText = ""
            isLoading = false
            return
        }

        scoringTranscript = cleanTranscript

        if !isTranscriptSufficient(cleanTranscript) {
            for _ in 0..<2 {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {}
                await state.refreshDashboard(showBusy: false)
                if let existing = findSavedCase() {
                    if let existingScore = existing.score {
                        result = existingScore
                        noData = false
                        errorText = ""
                        isLoading = false
                        return
                    }
                    let serverTranscript = normalizedTranscript(from: existing.transcript ?? [])
                    if serverTranscript.count > cleanTranscript.count {
                        cleanTranscript = serverTranscript
                        scoringTranscript = cleanTranscript
                    }
                    if isTranscriptSufficient(cleanTranscript) { break }
                }
            }
        }

        if !isTranscriptSufficient(cleanTranscript) {
            let payload = buildSavePayload(score: nil, endedAt: endedAt, status: "no_data", transcript: cleanTranscript)
            await state.saveCase(payload: payload)
            noData = true
            isLoading = false
            return
        }

        do {
            let diagnosis = config.expectedDiagnosis ?? ""
            let wrapupLine = diagnosis.isEmpty ? "" : "Vaka doğru tanısı: \(diagnosis)."
            let score = try await state.scoreConversation(mode: mode.rawValue, transcript: cleanTranscript, wrapup: wrapupLine)
            let payload = buildSavePayload(score: score, endedAt: endedAt, status: "ready", transcript: cleanTranscript)
            await state.saveCase(payload: payload)
            result = score
            errorText = ""
            isLoading = false
        } catch {
            let payload = buildSavePayload(score: nil, endedAt: endedAt, status: "pending", transcript: cleanTranscript)
            await state.saveCase(payload: payload)
            if let lateScore = await pollReadyScore(maxAttempts: 8, delayMs: 1000) {
                result = lateScore
                errorText = ""
                isLoading = false
                return
            }
            errorText = "Skor hazırlanıyor, lütfen birazdan tekrar dene."
            pendingScore = true
            pendingStartedAt = Date()
            isLoading = false
        }
    }

    private var shouldShowRefreshButton: Bool {
        guard let pendingStartedAt else { return false }
        return Date().timeIntervalSince(pendingStartedAt) >= 8
    }

    private func pollReadyScore(maxAttempts: Int, delayMs: Int) async -> ScoreResponse? {
        guard maxAttempts > 0 else { return nil }
        for _ in 0..<maxAttempts {
            do {
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            } catch {}
            await state.refreshDashboard(showBusy: false)
            if let score = findSavedCase()?.score {
                return score
            }
        }
        return nil
    }

    private func findSavedCase() -> CaseSession? {
        state.caseHistory.first {
            $0.sessionId == config.id || $0.id == config.id
        }
    }

    private func normalizedTranscript(from raw: [ConversationLine]) -> [ConversationLine] {
        raw.compactMap { line -> ConversationLine? in
            let text = line.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ConversationLine(
                source: canonicalSource(line.source),
                message: text,
                timestamp: line.timestamp
            )
        }
    }

    private func isTranscriptSufficient(_ transcript: [ConversationLine]) -> Bool {
        let userLines = transcript.filter { canonicalSource($0.source) == "user" }
        let userMessageCount = userLines.count
        let userCharacterCount = userLines.reduce(0) { partial, line in
            partial + line.message.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        return userMessageCount >= 2 && userCharacterCount >= 80
    }

    private func buildSavePayload(score: ScoreResponse?,
                                  endedAt: Date,
                                  status: String,
                                  transcript: [ConversationLine]) -> SaveCasePayload {
        let duration = max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
        return SaveCasePayload(
            sessionId: config.id,
            mode: mode.rawValue,
            status: status,
            startedAt: Self.iso8601.string(from: startedAt),
            endedAt: Self.iso8601.string(from: endedAt),
            durationMin: duration,
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
            textRuntime: nil
        )
    }
}
