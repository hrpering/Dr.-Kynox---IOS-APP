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
                                .background(AppColor.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(AppColor.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .fullScreenCover(item: $selectedSession) { item in
                HistorySessionDetailView(item: item)
                    .environmentObject(state)
            }
        }
    }
}

struct HistorySessionDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let item: CaseSession

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Vaka Detayı")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        state.selectedMainTab = "home"
                        dismiss()
                    }
                        .foregroundStyle(AppColor.primary)
                }
            }
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
}

