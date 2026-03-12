import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var state: AppState
    @State private var specialty = ""
    @State private var specialtySearch = ""
    @State private var difficulty = "Random"
    @State private var path: [GeneratorRoute] = []

    private var filteredSpecialtyRows: [SpecialtySelectionRow] {
        let allRows = [SpecialtySelectionRow(label: "Tümü (Rastgele)", value: "Random", hint: SpecialtyOption.focusHint(for: "Random"))] +
        SpecialtyOption.list.map { SpecialtySelectionRow(label: $0.label, value: $0.value, hint: SpecialtyOption.focusHint(for: $0.value)) }

        let query = specialtySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return allRows
        }

        let locale = Locale(identifier: "tr_TR")
        let normalizedQuery = query.lowercased(with: locale)
        return allRows.filter { row in
            row.label.lowercased(with: locale).contains(normalizedQuery) ||
            row.hint.lowercased(with: locale).contains(normalizedQuery)
        }
    }

    private let randomDifficultyCard = DifficultyCardConfig(
        id: "Random",
        title: "Rastgele Zorluk",
        subtitle: "Kim için: Kararsız kalan kullanıcılar",
        detail: "Ne beklenir: Sistem seviyeyi otomatik atar.",
        count: 0,
        bg: AppColor.surfaceAlt,
        stroke: AppColor.textSecondary
    )

    private let difficultyCards: [DifficultyCardConfig] = [
        .init(id: "Kolay", title: "Kolay", subtitle: "Kim için: Dönem 3-4", detail: "Ne beklenir: Temel anamnez ve ilk yaklaşım", count: 48, bg: AppColor.successLight, stroke: AppColor.success),
        .init(id: "Orta", title: "Orta", subtitle: "Kim için: İntörn / Dönem 5-6", detail: "Ne beklenir: Ayırıcı tanı ve yönetim önceliği", count: 36, bg: AppColor.warningLight, stroke: AppColor.warning),
        .init(id: "Zor", title: "Zor", subtitle: "Kim için: Asistan / Uzman", detail: "Ne beklenir: Nadir durumlar ve kritik kararlar", count: 24, bg: AppColor.errorLight, stroke: AppColor.error)
    ]

    var body: some View {
        NavigationStack(path: $path) {
            specialtyStep
                .navigationDestination(for: GeneratorRoute.self) { route in
                    switch route {
                    case .difficulty:
                        difficultyStep
                    case .mode(let selectedSpecialty, let selectedDifficulty):
                        ModeSelectionPage(
                            flow: ModeSelectionFlow(
                                context: "random",
                                challenge: nil,
                                specialty: selectedSpecialty,
                                difficulty: selectedDifficulty
                            )
                        )
                    }
                }
        }
        .onAppear {
            consumeGeneratorReplayIfNeeded()
        }
        .onChange(of: state.generatorReplayContext) { _ in
            consumeGeneratorReplayIfNeeded()
        }
    }

    private var specialtyStep: some View {
        selectionPageScaffold {
            stepHeader(
                step: "1/3",
                title: "Bölüm seç",
                subtitle: "Klinik odağını seç. Sonraki adımda zorluk seviyesini belirleyeceksin."
            )

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                TextField("Bölüm ara", text: $specialtySearch)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            LazyVStack(spacing: 8) {
                ForEach(filteredSpecialtyRows) { item in
                    Button {
                        specialty = item.value
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label)
                                    .font(AppFont.bodyMedium)
                                    .foregroundStyle(specialty == item.value ? AppColor.primaryDark : AppColor.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Text(item.hint)
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textSecondary)
                                    .lineSpacing(3)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: specialty == item.value ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(specialty == item.value ? AppColor.primary : AppColor.textTertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(specialty == item.value ? AppColor.primaryLight : AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(specialty == item.value ? AppColor.primary : AppColor.border, lineWidth: specialty == item.value ? 2 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            if !specialty.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Seçilen bölüm")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                    Text(selectedSpecialtyLabel)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(selectedSpecialtyFocusLine)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(1)
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
        } bottom: {
            Button {
                path.append(.difficulty)
            } label: {
                Text(specialty.isEmpty ? "Önce bölüm seç" : "Zorluk seç")
                    .appPrimaryButtonLabel()
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(specialty.isEmpty)
            .opacity(specialty.isEmpty ? 0.45 : 1)
            .accessibilityLabel("Zorluk seç")
            .accessibilityHint("Zorluk seçim ekranına gider")
        }
        .navigationTitle("Bölüm seç")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var difficultyStep: some View {
        selectionPageScaffold {
            stepHeader(
                step: "2/3",
                title: "Zorluk seç",
                subtitle: "\(selectedSpecialtyLabel) için zorluk seç. İstersen rastgele bırakabilirsin."
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Bölüm özeti")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                Text(selectedSpecialtyFocusLine)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            LazyVStack(spacing: 10) {
                ForEach([randomDifficultyCard] + difficultyCards) { config in
                    Button {
                        difficulty = config.id
                        Haptic.selection()
                    } label: {
                        DifficultyCard(config: config, isSelected: difficulty == config.id)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(config.title)
                    .accessibilityHint("Zorluk seviyesini \(config.title) olarak seçer")
                }
            }
        } bottom: {
            Button {
                path.append(.mode(specialty: specialty, difficulty: difficulty))
            } label: {
                Text("Mod seç")
                    .appPrimaryButtonLabel()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Mod seç")
            .accessibilityHint("Seçilen bölüm ve zorluk ile mod seçim ekranına geçer")
        }
        .navigationTitle("Zorluk seç")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selectionPageScaffold<Content: View, Bottom: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.x2) {
                content()
            }
            .padding(.horizontal, AppSpacing.x2)
            .padding(.top, AppSpacing.x1)
            .padding(.bottom, AppSpacing.x3)
        }
        .background(AppColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                bottom()
                    .padding(.horizontal, AppSpacing.x2)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
            .background(AppColor.surface)
        }
    }

    private func stepHeader(step: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adım \(step)")
                .font(AppFont.caption)
                .foregroundStyle(Color.white.opacity(0.9))
            Text(title)
                .font(AppFont.title)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(AppFont.body)
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(4)
        }
        .padding(AppSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppColor.primaryDark, AppColor.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppColor.primary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.card)
    }

    private var selectedSpecialtyLabel: String {
        if specialty.isEmpty {
            return "Henüz seçilmedi"
        }
        if specialty == "Random" {
            return "Tümü (Rastgele)"
        }
        return SpecialtyOption.label(for: specialty)
    }

    private var selectedSpecialtyFocusLine: String {
        SpecialtyOption.focusHint(for: specialty)
    }

    private func consumeGeneratorReplayIfNeeded() {
        guard let replay = state.generatorReplayContext else { return }
        state.generatorReplayContext = nil

        specialty = replay.specialty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Random" : replay.specialty
        difficulty = replay.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Random" : replay.difficulty
        path = [.mode(specialty: specialty, difficulty: difficulty)]
    }

    private enum GeneratorRoute: Hashable {
        case difficulty
        case mode(specialty: String, difficulty: String)
    }
}
