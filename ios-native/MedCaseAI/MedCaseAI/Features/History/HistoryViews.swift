import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSession: CaseSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    historySummaryCard

                    if state.caseHistory.isEmpty {
                        if state.isBusy {
                            VStack(spacing: 10) {
                                ShimmerView().frame(height: 76)
                                ShimmerView().frame(height: 76)
                                ShimmerView().frame(height: 76)
                            }
                        } else {
                            Text("Henüz vaka geçmişi yok.")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppColor.surfaceElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                        .stroke(AppColor.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                                .appShadow(AppShadow.card)
                        }
                    } else {
                        ForEach(state.caseHistory) { item in
                            Button {
                                selectedSession = item
                            } label: {
                                HistoryCard(item: item)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Vaka Geçmişi")
            .refreshable {
                await state.refreshDashboard()
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { selectedSession != nil },
                    set: { isPresented in
                        if !isPresented {
                            selectedSession = nil
                        }
                    }
                )
            ) {
                Group {
                    if let item = selectedSession {
                        HistorySessionDetailView(item: item)
                            .environmentObject(state)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var historySummaryCard: some View {
        HStack(spacing: 10) {
            summaryPill(title: "Toplam", value: "\(state.caseHistory.count)")
            summaryPill(title: "Skorlu", value: "\(scoredCaseCount)")
            summaryPill(title: "Ortalama", value: averageScoreText)
        }
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private var scoredCaseCount: Int {
        state.caseHistory.filter { $0.score != nil }.count
    }

    private var averageScoreText: String {
        let values = state.caseHistory.compactMap { $0.score?.overallScore }
        guard !values.isEmpty else { return "--" }
        let avg = values.reduce(0, +) / Double(values.count)
        return "\(Int(avg.rounded()))"
    }
}

struct HistorySessionDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let item: CaseSession
    @State private var showSessionArtifacts = false
    @State private var detail: CaseSessionDetailResponse?
    @State private var loadingArtifacts = false
    @State private var artifactsError = ""

    var body: some View {
        Group {
            if let score = item.score {
                ResultsView(
                    result: score,
                    config: historyConfig,
                    transcript: item.transcript ?? [],
                    sessionId: item.sessionId,
                    onClose: {
                        state.selectedMainTab = "home"
                        dismiss()
                    },
                    onRetry: {
                        state.generatorReplayContext = GeneratorReplayContext(
                            specialty: historyConfig.specialty,
                            difficulty: historyConfig.difficulty
                        )
                        state.selectedMainTab = "generator"
                        dismiss()
                    }
                )
            } else if item.status == "pending" || item.status == "pending_score" {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Skor ve geri bildirim hazırlanıyor...")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                    Button("Yenile") {
                        Task { await state.refreshDashboard(showBusy: false) }
                    }
                    .appSecondaryButton()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.background.ignoresSafeArea())
            } else {
                VStack(spacing: 12) {
                    Text("Bu oturum için skor henüz yok.")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                    Button("Kapat") {
                        dismiss()
                    }
                    .appPrimaryButton()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.background.ignoresSafeArea())
            }
        }
        .sheet(isPresented: $showSessionArtifacts) {
            NavigationStack {
                HistorySessionArtifactsView(
                    item: item,
                    detail: detail,
                    isLoading: loadingArtifacts,
                    errorText: artifactsError,
                    onRetry: {
                        Task { await loadArtifacts(force: true) }
                    }
                )
            }
        }
        .navigationTitle("Vaka Detayı")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Kayıtlar") {
                    showSessionArtifacts = true
                    Task { await loadArtifacts(force: false) }
                }
                .foregroundStyle(AppColor.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Kapat") {
                    state.selectedMainTab = "home"
                    dismiss()
                }
                    .foregroundStyle(AppColor.primary)
            }
        }
        .task {
            await loadArtifacts(force: false)
        }
    }

    private var historyConfig: CaseLaunchConfig {
        let mode = CaseLaunchConfig.Mode(rawValue: item.mode.lowercased()) ?? .text
        return CaseLaunchConfig(
            id: item.sessionId,
            mode: mode,
            challengeType: item.caseContext?.challengeType ?? "history",
            challengeId: item.caseContext?.challengeId,
            title: item.caseContext?.title,
            summary: item.caseContext?.subtitle,
            specialty: item.specialty,
            difficulty: item.difficulty ?? item.difficultyLabel,
            chiefComplaint: nil,
            patientGender: nil,
            patientAge: nil,
            expectedDiagnosis: item.caseContext?.expectedDiagnosis
        )
    }

    private func loadArtifacts(force: Bool) async {
        if loadingArtifacts { return }
        if !force, detail != nil { return }
        loadingArtifacts = true
        artifactsError = ""
        defer { loadingArtifacts = false }

        do {
            detail = try await state.fetchCaseDetail(sessionId: item.sessionId)
        } catch {
            artifactsError = error.localizedDescription
            if detail == nil {
                detail = nil
            }
        }
    }
}

private struct HistorySessionArtifactsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case tools = "Toollar"
        case tests = "Testler"

        var id: String { rawValue }
    }

    let item: CaseSession
    let detail: CaseSessionDetailResponse?
    let isLoading: Bool
    let errorText: String
    let onRetry: () -> Void

    @State private var selectedTab: Tab = .transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Sekme", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                if isLoading && detail == nil {
                    ProgressView("Yükleniyor...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    contentView
                }

                if !errorText.isEmpty {
                    ErrorStateCard(message: errorText, retry: onRetry)
                }
            }
            .padding(16)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle("Kayıt Detayı")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .transcript:
            transcriptSection
        case .tools:
            toolsSection(detail?.tools ?? [])
        case .tests:
            toolsSection(detail?.testResults ?? [])
        }
    }

    private var transcriptEntries: [CaseSessionTranscriptEntry] {
        if let rows = detail?.transcript, !rows.isEmpty {
            return rows
        }
        let fallback = item.transcript ?? []
        return fallback.enumerated().map { index, line in
            CaseSessionTranscriptEntry(
                lineIndex: index,
                source: line.source,
                message: line.message,
                timestampMs: line.timestamp,
                createdAt: nil
            )
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if transcriptEntries.isEmpty {
                Text("Transcript kaydı bulunamadı.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                ForEach(transcriptEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.source.uppercased())
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                        Text(entry.message)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineSpacing(4)
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
            }
        }
    }

    private func toolsSection(_ rows: [CaseSessionToolResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("Bu bölüm için kayıt bulunamadı.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(row.title ?? row.toolName ?? "Tool Sonucu")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if let status = row.status, !status.isEmpty {
                                Text(status.uppercased())
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textSecondary)
                            }
                        }
                        if let summary = row.summary, !summary.isEmpty {
                            Text(summary)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineSpacing(4)
                        }
                        if !row.metrics.isEmpty {
                            Divider().foregroundStyle(AppColor.border)
                            ForEach(row.metrics) { metric in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(metric.metricLabel ?? metric.metricKey)
                                        .font(AppFont.caption)
                                        .foregroundStyle(AppColor.textSecondary)
                                    Spacer()
                                    Text(metric.valueText ?? "-")
                                        .font(AppFont.bodyMedium)
                                        .foregroundStyle(AppColor.textPrimary)
                                }
                            }
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
            }
        }
    }
}
