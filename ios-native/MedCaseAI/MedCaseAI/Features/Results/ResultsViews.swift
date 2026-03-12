import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct ResultsView: View {
    let result: ScoreResponse
    let config: CaseLaunchConfig
    let transcript: [ConversationLine]
    let sessionId: String?
    let onClose: () -> Void
    let onRetry: () -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetailed = false
    @State private var animatedScore = 0.0
    @State private var generatedFlashcards: [FlashcardDraft] = []
    @State private var isGeneratingFlashcards = false
    @State private var isSavingFlashcards = false
    @State private var flashcardsSaved = false
    @State private var flashcardError = ""
    @State private var previewCardIndex = 0
    @State private var previewIsBack = false
    @State private var strengthsExpanded = true
    @State private var improvementsExpanded = true
    @State private var diagnosisExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                resultHeroCard
                scoreCard
                whatHappenedCard
                summarySection

                Button {
                    showDetailed = true
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detaylı geri bildirim")
                                .font(AppFont.bodyMedium)
                            Text("10 ölçütlü puan kırılımı ve adım adım öneriler")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(AppColor.primary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppColor.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    .appShadow(AppShadow.card)
                }
                    .buttonStyle(PressableButtonStyle())

                quickCaseSection
                cblMethodCard
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    onRetry()
                } label: {
                    Text("Bir Tur Daha Dene")
                        .appPrimaryButtonLabel()
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Bir Tur Daha Dene")
                .accessibilityHint("Aynı bölüm ve zorlukla yeni vakaya başlar")

                HStack(spacing: 12) {
                    Button("Ana Sayfa") { onClose() }
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.primaryDark)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppColor.primaryLight)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .buttonStyle(PressableButtonStyle())

                    ShareLink(item: shareText) {
                        Text("Skoru Paylaş")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppColor.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppColor.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(AppColor.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(AppColor.border).frame(height: 1)
            }
        }
        .fullScreenCover(isPresented: $showDetailed) {
            DetailedFeedbackView(result: result, config: config) {
                showDetailed = false
                onClose()
            }
        }
        .onAppear {
            animateScoreGauge()
        }
        .onChange(of: result.overallScore) { _ in
            animateScoreGauge()
        }
    }

    private var quickCaseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(AppColor.primary)
                Text("15sn Hızlı Vaka")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }

            Text("Hızlı karar pratiği için ana sayfadaki 15sn Hızlı Vaka akışına geçebilirsin. Cevap sonrası kartlarını favoriye alıp Analiz sekmesinde görebilirsin.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Button {
                state.selectedMainTab = "home"
                onClose()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text("Ana Sayfadan 15sn Hızlı Vaka Aç")
                }
                .appPrimaryButtonLabelStyle()
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(12)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private var resultHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Vaka tamamlandı")
                    .font(AppFont.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Badge(text: SpecialtyOption.label(for: config.specialty), tint: AppColor.primaryDark, background: .white.opacity(0.92))
                Badge(text: config.difficulty, tint: AppColor.warning, background: .white.opacity(0.92))
            }

            Text(heroSubtitle)
                .font(AppFont.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
                .lineLimit(3)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [AppColor.primaryDark, AppColor.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.elevated)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryDisclosure(
                title: "Güçlü Yönler",
                subtitle: "Ne iyi gitti",
                icon: "checkmark.circle.fill",
                tint: AppColor.success,
                background: AppColor.successLight,
                isExpanded: $strengthsExpanded,
                items: Array(result.strengths.prefix(3))
            )

            summaryDisclosure(
                title: "Gelişim Alanları",
                subtitle: "Ne eksik kaldı",
                icon: "exclamationmark.circle.fill",
                tint: AppColor.warning,
                background: AppColor.warningLight,
                isExpanded: $improvementsExpanded,
                items: Array(result.improvements.prefix(3))
            )

            diagnosisDisclosureCard
        }
    }

    private func summaryDisclosure(title: String,
                                   subtitle: String,
                                   icon: String,
                                   tint: Color,
                                   background: Color,
                                   isExpanded: Binding<Bool>,
                                   items: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.wrappedValue.toggle()
                Haptic.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Text(subtitle)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, id: \.self) { item in
                        Text("• \(item)")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                    }
                }
            }
        }
        .padding(12)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var diagnosisDisclosureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                diagnosisExpanded.toggle()
                Haptic.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cross.case.fill")
                        .foregroundStyle(AppColor.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tanı Özeti")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Text("Nihai tanı durumu")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: diagnosisExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            .buttonStyle(PlainButtonStyle())

            if diagnosisExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    DiagnosisSummaryRow(
                        title: "Doğru tanı",
                        value: displayTrueDiagnosis,
                        accent: AppColor.success,
                        valueColor: AppColor.textPrimary,
                        isSystemHint: isTrueDiagnosisSystemText
                    )
                    DiagnosisSummaryRow(
                        title: "Senin tanın",
                        value: displayUserDiagnosis,
                        accent: AppColor.primary,
                        valueColor: AppColor.textPrimary,
                        isSystemHint: isUserDiagnosisSystemText
                    )
                    if needsDiagnosisNote {
                        Text("Not: Oturum kısa kaldığında tanı alanları netleşmeyebilir.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                    }
                }
            }
        }
        .padding(12)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.primary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var cblMethodCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
            Text("CBL metodolojisiyle değerlendirilmiştir.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var whatHappenedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(AppColor.primary)
                Text("Ne oldu?")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }

            Text(primaryFeedbackSummary)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let firstFocus = result.improvements.first, !firstFocus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.warning)
                        .padding(.top, 2)
                    Text("İlk odak noktası: \(firstFocus)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
            }
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var currentPreviewCard: FlashcardDraft? {
        guard !generatedFlashcards.isEmpty else { return nil }
        let safeIndex = max(0, min(previewCardIndex, generatedFlashcards.count - 1))
        return generatedFlashcards[safeIndex]
    }

    private func flashcardPreviewDeck(_ card: FlashcardDraft) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kart \(previewCardIndex + 1)/\(generatedFlashcards.count)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
                Text("Manuel geçiş")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Text(previewIsBack ? card.back : card.front)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(4)
                Text(previewIsBack ? "Arka yüz" : "Ön yüz")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surfaceAlt)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.25)) {
                    previewIsBack.toggle()
                }
            }

            HStack(spacing: 8) {
                Button {
                    goToPreviousPreviewCard()
                } label: {
                    Label("Önceki", systemImage: "chevron.left")
                        .appSecondaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    advancePreviewCard()
                } label: {
                    Label("Sonraki", systemImage: "chevron.right")
                        .appPrimaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func advancePreviewCard() {
        guard !generatedFlashcards.isEmpty else { return }
        previewCardIndex = (previewCardIndex + 1) % generatedFlashcards.count
        previewIsBack = false
    }

    private func goToPreviousPreviewCard() {
        guard !generatedFlashcards.isEmpty else { return }
        previewCardIndex = (previewCardIndex - 1 + generatedFlashcards.count) % generatedFlashcards.count
        previewIsBack = false
    }

    private func resetPreviewDeck() {
        previewCardIndex = 0
        previewIsBack = false
    }

    private var scoreCard: some View {
        let theme = scoreTheme

        return HStack(spacing: 14) {
            if showsNumericScore {
                ZStack {
                    Circle()
                        .stroke(theme.tint.opacity(0.18), lineWidth: 10)
                        .frame(width: 102, height: 102)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, animatedScore / 100)))
                        .stroke(
                            LinearGradient(
                                colors: [AppColor.primary, theme.tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .frame(width: 102, height: 102)
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(animatedScore.rounded()))")
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreValueColor)
                        Text("/100")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
            } else {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(theme.tint)
                    .frame(width: 102, height: 102)
                    .background(theme.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(theme.title, systemImage: theme.icon)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)

                Text(scoreSubtitle)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(3)

                if !showsNumericScore {
                    Text("Kullanıcı mesajı: \(userMessageCount) · Toplam karakter: \(userCharacterCount)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(theme.background)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diagnosisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cross.case.fill")
                    .foregroundStyle(AppColor.primary)
                Text("Tanı Özeti")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }

            DiagnosisSummaryRow(
                title: "Doğru tanı",
                value: displayTrueDiagnosis,
                accent: AppColor.success,
                valueColor: AppColor.textPrimary,
                isSystemHint: isTrueDiagnosisSystemText
            )

            DiagnosisSummaryRow(
                title: "Senin tanın",
                value: displayUserDiagnosis,
                accent: AppColor.primary,
                valueColor: AppColor.textPrimary,
                isSystemHint: isUserDiagnosisSystemText
            )

            if needsDiagnosisNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(.top, 2)
                    Text("Not: Vaka erken sonlandırıldığında veya konuşma kısa kaldığında tanı alanları boş kalabilir.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var flashcardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(AppColor.primary)
                Text("Hızlı Tekrar Kartları")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                if !generatedFlashcards.isEmpty {
                    Badge(text: "\(generatedFlashcards.count) kart", tint: AppColor.primaryDark, background: AppColor.primaryLight)
                }
            }

            Text("Bu vakadan 4 hızlı tekrar kartı üret.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            HStack(spacing: 6) {
                flashcardTypePill("Tanı")
                flashcardTypePill("Kırmızı bayrak")
                flashcardTypePill("Ayırıcı tanı")
                flashcardTypePill("İlk adım")
            }

            if generatedFlashcards.isEmpty, isGeneratingFlashcards {
                flashcardLoadingCard
            } else if generatedFlashcards.isEmpty {
                Button {
                    Task { await generateFlashcards() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text("4 Hızlı Kart Üret")
                    }
                    .appPrimaryButtonLabelStyle()
                }
                .disabled(isGeneratingFlashcards)
                .buttonStyle(PressableButtonStyle())
            } else {
                if let card = currentPreviewCard {
                    flashcardPreviewDeck(card)
                }

                if !flashcardsSaved {
                    Button {
                        Task { await saveGeneratedFlashcards() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSavingFlashcards {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill")
                            }
                            Text("Kartları Kaydet")
                                .lineLimit(1)
                        }
                        .appPrimaryButtonLabelStyle()
                    }
                    .disabled(isSavingFlashcards)
                    .buttonStyle(PressableButtonStyle())
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppColor.success)
                        Text("Kartlar kaydedildi. Flashcard Merkezi’nden çalışabilirsin.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.successLight.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppColor.success.opacity(0.28), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Button {
                    state.selectedMainTab = "flashcards"
                    onClose()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Kartlara git")
                            .lineLimit(1)
                    }
                    .appSecondaryButtonLabelStyle()
                }
                .buttonStyle(PressableButtonStyle())
            }

            if !flashcardError.isEmpty {
                Text(flashcardError)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .lineSpacing(4)
            }
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func flashcardTypePill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColor.primaryDark)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppColor.primaryLight)
            .overlay(
                Capsule().stroke(AppColor.primary.opacity(0.24), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var flashcardLoadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Dr.Kynox hızlı tekrar kartlarını hazırlıyor...")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
            }
            ShimmerView().frame(height: 56)
            ShimmerView().frame(height: 56)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func generateFlashcards() async {
        guard !isGeneratingFlashcards else { return }
        guard let effectiveSessionId else {
            flashcardError = "Flashcard üretilemedi. Lütfen tekrar dene."
            return
        }

        isGeneratingFlashcards = true
        flashcardError = ""
        defer { isGeneratingFlashcards = false }

        do {
            let response = try await state.generateFlashcards(
                sessionId: effectiveSessionId,
                specialty: config.specialty,
                difficulty: config.difficulty,
                caseTitle: result.caseTitle,
                trueDiagnosis: displayTrueDiagnosis,
                userDiagnosis: displayUserDiagnosis,
                overallScore: result.overallScore,
                scoreLabel: result.label,
                briefSummary: result.briefSummary,
                strengths: result.strengths,
                improvements: result.improvements,
                missedOpportunities: result.missedOpportunities,
                dimensions: result.dimensions,
                nextPracticeSuggestions: result.nextPracticeSuggestions,
                maxCards: 4
            )
            generatedFlashcards = response.cards
            resetPreviewDeck()
            if response.source == "session_saved" {
                flashcardsSaved = true
                state.statusMessage = "Bu vakanın kayıtlı flashcard’ları yüklendi."
            } else {
                flashcardsSaved = false
            }
            flashcardError = ""
        } catch {
            print("Flashcard generate error: \(error)")
            flashcardError = "Flashcard üretilemedi. Lütfen tekrar dene."
        }
    }

    private func saveGeneratedFlashcards() async {
        guard !generatedFlashcards.isEmpty else { return }
        guard !isSavingFlashcards else { return }

        isSavingFlashcards = true
        flashcardError = ""
        defer { isSavingFlashcards = false }

        do {
            _ = try await state.saveFlashcards(
                sessionId: effectiveSessionId,
                cards: generatedFlashcards
            )
            flashcardsSaved = true
            state.statusMessage = "Flashcard’ların koleksiyonuna kaydedildi."
        } catch {
            print("Flashcard save error: \(error)")
            flashcardError = "Flashcard kaydedilemedi. Lütfen tekrar dene."
        }
    }

    private var effectiveSessionId: String? {
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sessionId
        }
        let fallback = config.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private var scoreSubtitle: String {
        if !showsNumericScore {
            return "Bu oturum kısa kaldığı için skor yerine geçici değerlendirme gösteriliyor. Bir tur daha ile daha güvenilir sonuç alırsın."
        }
        if result.overallScore >= 70 {
            return "Klinik karar zincirin güçlü ilerledi. Bu yaklaşımı sürdür."
        }
        if result.overallScore >= 40 {
            return "Temel yaklaşım var. Önceliklendirme ve hız tarafını güçlendirebilirsin."
        }
        return "Bu turda kritik karar akışı eksik kaldı. Bir sonraki denemede anamnez ve öncelik sırasını netleştir."
    }

    private var scoreTheme: (title: String, icon: String, tint: Color, background: Color) {
        if !showsNumericScore {
            return ("Geçici Değerlendirme", "clock.badge.exclamationmark", AppColor.warning, AppColor.warningLight)
        }
        if result.overallScore >= 70 {
            return ("Harika iş!", "checkmark.seal.fill", AppColor.success, AppColor.successLight)
        }
        if result.overallScore >= 40 {
            return ("Gelişme var", "exclamationmark.triangle.fill", AppColor.warning, AppColor.warningLight)
        }
        return ("Tekrar dene", "arrow.counterclockwise.circle.fill", AppColor.error, AppColor.errorLight)
    }

    private var scoreValueColor: Color {
        if !showsNumericScore { return AppColor.warning }
        if result.overallScore >= 70 { return AppColor.success }
        if result.overallScore >= 40 { return AppColor.warning }
        return AppColor.error
    }

    private var primaryFeedbackSummary: String {
        if !result.briefSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result.briefSummary
        }
        if result.overallScore >= 70 {
            return "Vaka akışı boyunca kararlarını doğru sırada verip klinik tabloyu iyi yönettin."
        }
        if result.overallScore >= 40 {
            return "Doğru yaklaşımın temeli var; birkaç kritik noktada netleşme ile sonuç daha da iyileşir."
        }
        return "Bu oturum öğrenme denemesi olarak kaydedildi. Bir sonraki turda anamnez ve kritik karar sırasını daha net kurmaya odaklan."
    }

    private var shareText: String {
        if showsNumericScore {
            return [
                "Dr.Kynox Vaka sonucu",
                "Skor: \(Int(result.overallScore.rounded()))/100",
                "Bölüm: \(SpecialtyOption.label(for: config.specialty))",
                "Zorluk: \(config.difficulty)",
                "Doğru tanı: \(displayTrueDiagnosis)",
                "Benim tanım: \(displayUserDiagnosis)"
            ]
            .joined(separator: "\n")
        }
        return [
            "Dr.Kynox Vaka sonucu",
            "Geçici değerlendirme (kısa oturum)",
            "Bölüm: \(SpecialtyOption.label(for: config.specialty))",
            "Zorluk: \(config.difficulty)",
            "Not: Daha net skor için bir tur daha önerilir."
        ]
        .joined(separator: "\n")
    }

    private var userMessageCount: Int {
        transcript.filter { canonicalSource($0.source) == "user" }.count
    }

    private var userCharacterCount: Int {
        transcript
            .filter { canonicalSource($0.source) == "user" }
            .reduce(0) { partial, line in
                partial + line.message.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
    }

    private var showsNumericScore: Bool {
        userMessageCount >= 2 && userCharacterCount >= 80
    }

    private var heroSubtitle: String {
        if !showsNumericScore {
            return "Bu oturum kısa kaldı; kesin tanı ve güvenilir skor için bir tur daha önerilir."
        }
        return result.briefSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Oturum analiz edildi. Aşağıda güçlü yönler, gelişim alanları ve sonraki adımları görebilirsin."
            : result.briefSummary
    }

    private var displayTrueDiagnosis: String {
        let normalized = result.trueDiagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDiagnosisPlaceholder(normalized) {
            return normalized
        }
        let expected = config.expectedDiagnosis?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expected.isEmpty {
            return expected
        }
        return "Bu oturumda doğrulanmış nihai tanı oluşmadı (erken sonlandırma veya yetersiz veri)."
    }

    private var displayUserDiagnosis: String {
        let normalized = result.userDiagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDiagnosisPlaceholder(normalized) {
            return normalized
        }
        return "Bu oturumda açık bir nihai tanı belirtmedin."
    }

    private var isTrueDiagnosisSystemText: Bool {
        displayTrueDiagnosis == "Bu oturumda doğrulanmış nihai tanı oluşmadı (erken sonlandırma veya yetersiz veri)."
    }

    private var isUserDiagnosisSystemText: Bool {
        displayUserDiagnosis == "Bu oturumda açık bir nihai tanı belirtmedin."
    }

    private var needsDiagnosisNote: Bool {
        isTrueDiagnosisSystemText || isUserDiagnosisSystemText
    }

    private func isDiagnosisPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
        return normalized.isEmpty ||
            normalized.contains("belirtilmedi") ||
            normalized.contains("kesin tani paylasilmadi")
    }

    private func animateScoreGauge() {
        let target = max(0, min(100, result.overallScore))
        guard !reduceMotion else {
            animatedScore = target
            return
        }
        animatedScore = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 1.15)) {
                animatedScore = target
            }
        }
    }
}

struct DetailedFeedbackView: View {
    let result: ScoreResponse
    let config: CaseLaunchConfig
    let onClose: () -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    topSummaryCard

                    if result.dimensions.isEmpty {
                        ErrorStateCard(
                            message: "Detaylı puanlama verisi bu vaka için henüz oluşturulamadı.",
                            retry: nil
                        )
                    } else {
                        ForEach(result.dimensions) { dimension in
                            dimensionCard(dimension)
                        }
                    }
                }
                .padding(16)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Detaylı geri bildirim")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .interactiveDismissDisabled(true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        onClose()
                    }
                    .foregroundStyle(AppColor.primary)
                }
            }
        }
    }

    private var topSummaryCard: some View {
        let theme = scoreTheme(for: result.overallScore / 10)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.caseTitle)
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(2)
                    Text("\(SpecialtyOption.label(for: config.specialty)) · \(config.difficulty)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Toplam Skor")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Text("\(Int(result.overallScore.rounded()))/100")
                        .font(AppFont.title2)
                        .foregroundStyle(theme.tint)
                }
            }

            GeometryReader { proxy in
                let width = max(0, min(proxy.size.width, proxy.size.width * max(0, min(1, result.overallScore / 100))))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColor.surfaceAlt)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.tint.opacity(0.85), theme.tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width)
                }
            }
            .frame(height: 8)
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

    private func dimensionCard(_ dimension: ScoreDimension) -> some View {
        let isExpanded = expanded.contains(dimension.key)
        let theme = scoreTheme(for: dimension.score)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expanded.remove(dimension.key)
                } else {
                    expanded.insert(dimension.key)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.background)
                            .frame(width: 34, height: 34)
                        Image(systemName: dimensionIcon(for: dimension.key))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.tint)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(dimensionTitle(for: dimension.key))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(2)
                        Text(scoreText(for: dimension.score))
                            .font(AppFont.caption)
                            .foregroundStyle(theme.tint)
                    }

                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                }

                GeometryReader { proxy in
                    let width = max(0, min(proxy.size.width, proxy.size.width * max(0, min(1, dimension.score / 10))))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppColor.surfaceAlt)
                        Capsule()
                            .fill(theme.tint)
                            .frame(width: width)
                    }
                }
                .frame(height: 6)

                if isExpanded {
                    Divider()
                        .overlay(theme.tint.opacity(0.15))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(normalizedDetailText(dimension.explanation, fallback: "Bu alan için detaylı açıklama henüz üretilemedi."))
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.tint)
                                .padding(.top, 2)
                            Text(normalizedDetailText(dimension.recommendation, fallback: "Bu alan için ek öneri bulunmuyor."))
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineSpacing(4)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.tint.opacity(isExpanded ? 0.45 : 0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func dimensionTitle(for key: String) -> String {
        switch key {
        case "data_gathering_quality": return "Veri Toplama Kalitesi"
        case "clinical_reasoning_logic": return "Klinik Akıl Yürütme"
        case "differential_diagnosis_depth": return "Ayırıcı Tanı Derinliği"
        case "diagnostic_efficiency": return "Tanısal Verimlilik"
        case "management_plan_quality": return "Yönetim Planı"
        case "safety_red_flags": return "Güvenlik / Kırmızı Bayrak"
        case "decision_timing": return "Karar Zamanlaması"
        case "communication_clarity": return "İletişim"
        case "guideline_consistency": return "Kılavuz Uyumu"
        case "professionalism_empathy": return "Profesyonellik / Empati"
        default: return key
        }
    }

    private func dimensionIcon(for key: String) -> String {
        switch key {
        case "data_gathering_quality": return "list.clipboard.fill"
        case "clinical_reasoning_logic": return "brain.head.profile"
        case "differential_diagnosis_depth": return "square.stack.3d.up.fill"
        case "diagnostic_efficiency": return "magnifyingglass.circle.fill"
        case "management_plan_quality": return "stethoscope"
        case "safety_red_flags": return "shield.lefthalf.filled"
        case "decision_timing": return "timer"
        case "communication_clarity": return "message.fill"
        case "guideline_consistency": return "book.closed.fill"
        case "professionalism_empathy": return "heart.text.square.fill"
        default: return "chart.bar.fill"
        }
    }

    private func scoreTheme(for score: Double) -> (tint: Color, background: Color) {
        if score >= 8 {
            return (AppColor.success, AppColor.successLight)
        }
        if score >= 5 {
            return (AppColor.warning, AppColor.warningLight)
        }
        return (AppColor.error, AppColor.errorLight)
    }

    private func scoreText(for score: Double) -> String {
        let clean = max(0, min(10, score))
        if abs(clean.rounded() - clean) < 0.05 {
            return "\(Int(clean.rounded()))/10"
        }
        return String(format: "%.1f/10", clean)
    }

    private func normalizedDetailText(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
