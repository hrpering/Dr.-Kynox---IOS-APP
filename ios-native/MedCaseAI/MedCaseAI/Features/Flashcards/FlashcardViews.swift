import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct FlashcardsHubView: View {
    @EnvironmentObject private var state: AppState

    @State private var items: [CodeBlueFavoriteCard] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var totalCount = 0
    @State private var showQuickCase = false
    @State private var deletingId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard

                if loading {
                    VStack(spacing: 10) {
                        ShimmerView().frame(height: 110)
                        ShimmerView().frame(height: 110)
                        ShimmerView().frame(height: 110)
                    }
                } else if items.isEmpty {
                    emptyStateCard
                } else {
                    ForEach(items) { item in
                        favoriteRow(item)
                    }

                    if hasMore {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if loadingMore {
                                    ProgressView()
                                }
                                Text(loadingMore ? "Yükleniyor..." : "Daha Fazla Yükle")
                                    .font(AppFont.bodyMedium)
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(loadingMore)
                    }
                }

                if !errorText.isEmpty {
                    ErrorStateCard(message: errorText) {
                        Task { await reload() }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 10)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Favori Kartlar")
        .refreshable {
            await reload()
        }
        .task {
            await reload()
        }
        .fullScreenCover(isPresented: $showQuickCase) {
            NavigationStack {
                CodeBlueSessionView()
                    .environmentObject(state)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hızlı Vaka Favorileri")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Toplam \(totalCount) kart")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Image(systemName: "star.square.on.square.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColor.warning)
            }

            Text("15sn vaka akışında cevap sonrası işaretlediğin ön/arka kartlar burada saklanır.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Button {
                showQuickCase = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                    Text("15sn Hızlı Vaka Başlat")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(AppFont.bodyMedium)
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(DSPrimaryButtonStyle())
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [AppColor.warningLight, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.warning.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Henüz favori kartın yok")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
            Text("15sn hızlı vaka çözerken cevap sonrası kartı favoriye eklediğinde burada görünür.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Button("15sn Hızlı Vaka Başlat") {
                showQuickCase = true
                Haptic.selection()
            }
            .appPrimaryButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func favoriteRow(_ item: CodeBlueFavoriteCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.specialty.isEmpty ? "Genel" : SpecialtyOption.label(for: item.specialty))
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(item.difficulty.isEmpty ? "-" : item.difficulty)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Button {
                    Task { await delete(item) }
                } label: {
                    if deletingId == item.id {
                        ProgressView()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .disabled(deletingId == item.id)
                .buttonStyle(.plain)
                .foregroundStyle(AppColor.error)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ön Yüz")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primaryDark)
                Text(item.front)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Arka Yüz")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.success)
                Text(item.back)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
            }

            if let createdAt = item.createdAt, !createdAt.isEmpty {
                Text("Eklenme: \(prettyDate(createdAt))")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func prettyDate(_ iso: String) -> String {
        guard let date = parseISODate(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    private func parseISODate(_ raw: String) -> Date? {
        if let value = Self.isoWithFraction.date(from: raw) {
            return value
        }
        return Self.isoStandard.date(from: raw)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func reload() async {
        if loading { return }
        loading = true
        defer { loading = false }

        do {
            let response = try await state.fetchCodeBlueFavorites(limit: 20, cursor: nil)
            items = response.items
            nextCursor = response.nextCursor
            hasMore = response.hasMore == true
            totalCount = response.totalCount ?? response.items.count
            errorText = ""
        } catch {
            errorText = error.localizedDescription
            items = []
            nextCursor = nil
            hasMore = false
            totalCount = 0
        }
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        guard hasMore, let cursor = nextCursor, !cursor.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }

        do {
            let response = try await state.fetchCodeBlueFavorites(limit: 20, cursor: cursor)
            let existingIds = Set(items.map(\.id))
            let newItems = response.items.filter { !existingIds.contains($0.id) }
            items.append(contentsOf: newItems)
            nextCursor = response.nextCursor
            hasMore = response.hasMore == true
            totalCount = response.totalCount ?? max(totalCount, items.count)
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ item: CodeBlueFavoriteCard) async {
        guard deletingId == nil else { return }
        deletingId = item.id
        defer { deletingId = nil }
        do {
            _ = try await state.deleteCodeBlueFavorite(favoriteId: item.id)
            items.removeAll { $0.id == item.id }
            totalCount = max(0, totalCount - 1)
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct CodeBlueReviewState {
    let sessionId: String
    let questionIndex: Int
    let question: CodeBlueQuestion
    let answer: CodeBlueAnswerResult
    let sessionCompleted: Bool
    let summary: CodeBlueSummary?
}

struct CodeBlueSessionView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var loading = false
    @State private var submitting = false
    @State private var errorText = ""
    @State private var session: CodeBlueSessionState?
    @State private var question: CodeBlueQuestion?
    @State private var completionSummary: CodeBlueSummary?
    @State private var reviewState: CodeBlueReviewState?
    @State private var favoriteSavedQuestionIndexes = Set<Int>()
    @State private var timeoutSubmittedForToken: String?
    @State private var now = Date()
    @State private var countdownDeadline: Date?

    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            headerCard

            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Hızlı vaka hazırlanıyor...")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = completionSummary {
                completionCard(summary)
            } else if let reviewState {
                reviewCard(reviewState)
            } else if let question {
                questionCard(question)
            } else {
                VStack(spacing: 8) {
                    Text("Aktif soru bulunamadı")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Oturumu yenileyerek tekrar deneyebilirsin.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("15sn Hızlı Vaka")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Kapat") {
                    dismiss()
                }
                .foregroundStyle(AppColor.primary)
            }
        }
        .task {
            await startOrResumeSession()
        }
        .onChange(of: scenePhase) { value in
            if value == .active {
                Task { await restoreSessionAndResolveTimeoutIfNeeded() }
            }
        }
        .onReceive(ticker) { _ in
            now = Date()
            if countdownDeadline == nil {
                syncCountdownDeadline()
            }
            tickTimerAndResolveTimeoutIfNeeded()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Code Blue")
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text(progressLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColor.surfaceAlt)
                    .clipShape(Capsule())
            }

            Text("Süre yalnızca sunucu saatine göre ilerler. Arka plan veya telefon çağrısı sırasında durmaz.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let question, completionSummary == nil, reviewState == nil {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .foregroundStyle(remainingSeconds > 0 ? AppColor.warning : AppColor.error)
                    Text(timerLabel)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(remainingSeconds > 0 ? AppColor.textPrimary : AppColor.error)
                    Spacer()
                    Text(question.difficulty)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                ProgressView(value: remainingProgress)
                    .tint(remainingSeconds > 0 ? AppColor.warning : AppColor.error)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progressLabel: String {
        guard let session else { return "--" }
        let current = min(session.total, session.index + 1)
        return "\(current)/\(session.total)"
    }

    private var remainingSeconds: Int {
        if let deadline = countdownDeadline {
            let ms = max(0, Int((deadline.timeIntervalSince(now) * 1000).rounded()))
            return Int(ceil(Double(ms) / 1000.0))
        }
        return max(0, question?.timeLimit ?? 15)
    }

    private var timerLabel: String {
        "Kalan süre: \(remainingSeconds) sn"
    }

    private var remainingProgress: Double {
        let total = max(1, question?.timeLimit ?? 15)
        return max(0, min(1, Double(remainingSeconds) / Double(total)))
    }

    private func syncCountdownDeadline() {
        if let remainingMs = session?.timeRemainingMs, remainingMs > 0 {
            countdownDeadline = now.addingTimeInterval(Double(remainingMs) / 1000.0)
            return
        }

        if let expiresAt = session?.currentQuestionExpiresAt,
           let expiresDate = parseISODate(expiresAt) {
            countdownDeadline = expiresDate
            return
        }

        if let question {
            countdownDeadline = now.addingTimeInterval(Double(max(1, question.timeLimit)))
            return
        }

        countdownDeadline = nil
    }

    private func questionCard(_ question: CodeBlueQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.question)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(4)

            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    Task { await submitAnswer(selectedOptionIndex: index, timedOut: false) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(["A", "B", "C", "D"][index])
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppColor.primaryDark)
                            .frame(width: 22, height: 22)
                            .background(AppColor.primaryLight)
                            .clipShape(Circle())
                        Text(option)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppColor.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(submitting)
                .opacity(submitting ? 0.65 : 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func reviewCard(_ review: CodeBlueReviewState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soru Sonucu")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            Text(review.question.question)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let back = review.answer.back {
                if let outcome = back.outcomeMessage, !outcome.isEmpty {
                    resultLine(title: "Sonuç", value: outcome)
                }
                if let status = back.statusText, !status.isEmpty {
                    resultLine(title: "Durum", value: status)
                }
                if let takeaway = back.clinicalTakeaway, !takeaway.isEmpty {
                    resultLine(title: "Klinik çıkarım", value: takeaway)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await saveFavoriteIfNeeded(review) }
                } label: {
                    Text(favoriteSavedQuestionIndexes.contains(review.questionIndex) ? "Favorilere Kaydedildi" : "Kartı Favoriye Ekle")
                        .font(AppFont.bodyMedium)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(favoriteSavedQuestionIndexes.contains(review.questionIndex) || submitting)

                Button {
                    Task { await proceedAfterReview(review) }
                } label: {
                    Text(review.sessionCompleted ? "Oturumu Tamamla" : "Sonraki Soru")
                        .font(AppFont.bodyMedium)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(submitting)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func completionCard(_ summary: CodeBlueSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Oturum Tamamlandı")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)

            HStack(spacing: 10) {
                statPill(title: "Doğru", value: "\(summary.correctCount ?? 0)")
                statPill(title: "Yanlış", value: "\(summary.wrongCount ?? 0)")
                statPill(title: "Timeout", value: "\(summary.timeoutCount ?? 0)")
            }

            Text("Skor: \(Int((summary.scorePercent ?? 0).rounded()))")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            HStack(spacing: 10) {
                Button("Yeni 15sn Oturum Başlat") {
                    Task { await startOrResumeSession() }
                }
                .buttonStyle(DSPrimaryButtonStyle())

                Button("Kapat") {
                    dismiss()
                }
                .buttonStyle(DSSecondaryButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func resultLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
            Text(value)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(4)
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColor.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func startOrResumeSession() async {
        if loading { return }
        loading = true
        defer { loading = false }

        completionSummary = nil
        reviewState = nil
        timeoutSubmittedForToken = nil

        do {
            let response = try await state.startCodeBlueSession()
            applySessionResponse(response)
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func restoreSessionAndResolveTimeoutIfNeeded() async {
        guard !loading else { return }
        guard let sessionId = session?.id, !sessionId.isEmpty else { return }
        do {
            let response = try await state.restoreCodeBlueSession(sessionId: sessionId)
            applySessionResponse(response)
            if response.session?.needsTimeoutResolution == true,
               response.question != nil,
               reviewState == nil,
               completionSummary == nil {
                await submitAnswer(selectedOptionIndex: nil, timedOut: true)
            }
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func submitAnswer(selectedOptionIndex: Int?, timedOut: Bool) async {
        guard !submitting else { return }
        guard let session, let question else { return }

        submitting = true
        defer { submitting = false }

        do {
            let response = try await state.answerCodeBlue(
                sessionId: session.id,
                questionIndex: session.index,
                questionToken: question.questionToken,
                selectedOptionIndex: selectedOptionIndex,
                timedOut: timedOut,
                clientRequestId: UUID().uuidString
            )

            let review = CodeBlueReviewState(
                sessionId: session.id,
                questionIndex: session.index,
                question: question,
                answer: response.result ?? CodeBlueAnswerResult(outcome: nil, isCorrect: nil, elapsedMs: nil, back: nil),
                sessionCompleted: response.sessionCompleted == true,
                summary: response.summary
            )
            reviewState = review
            if review.sessionCompleted {
                completionSummary = review.summary
            }
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func proceedAfterReview(_ review: CodeBlueReviewState) async {
        if review.sessionCompleted {
            completionSummary = review.summary
            reviewState = nil
            question = nil
            return
        }
        reviewState = nil
        await restoreSessionAndResolveTimeoutIfNeeded()
    }

    private func saveFavoriteIfNeeded(_ review: CodeBlueReviewState) async {
        guard !favoriteSavedQuestionIndexes.contains(review.questionIndex) else { return }
        do {
            _ = try await state.saveCodeBlueFavorite(
                sessionId: review.sessionId,
                questionIndex: review.questionIndex
            )
            favoriteSavedQuestionIndexes.insert(review.questionIndex)
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func tickTimerAndResolveTimeoutIfNeeded() {
        guard reviewState == nil, completionSummary == nil else { return }
        guard let questionToken = question?.questionToken else { return }
        guard remainingSeconds <= 0 else { return }
        guard timeoutSubmittedForToken != questionToken else { return }

        timeoutSubmittedForToken = questionToken
        Task {
            await submitAnswer(selectedOptionIndex: nil, timedOut: true)
        }
    }

    private func applySessionResponse(_ response: CodeBlueSessionResponse) {
        if response.sessionCompleted == true {
            completionSummary = response.summary
            session = response.session
            question = nil
            countdownDeadline = nil
            return
        }

        if let newSession = response.session {
            session = newSession
        }
        if let newQuestion = response.question {
            question = newQuestion
            timeoutSubmittedForToken = nil
        }
        syncCountdownDeadline()
    }

    private func parseISODate(_ raw: String) -> Date? {
        if let value = Self.isoWithFraction.date(from: raw) {
            return value
        }
        return Self.isoStandard.date(from: raw)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
