import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
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

    private let difficultyChoices: [GeneratorDifficultyChoice] = [
        .init(
            id: "Random",
            title: "Rastgele",
            trailingLabel: "Karma",
            description: "Sürpriz bir deneyim için tüm seviyelerden vakalar",
            icon: "shuffle",
            iconTint: Color(hex: "#0EA5E9"),
            iconBackground: Color(hex: "#0EA5E9"),
            cardBackground: Color(hex: "#F0F9FF")
        ),
        .init(
            id: "Kolay",
            title: "Kolay",
            trailingLabel: "12 Vaka",
            description: "Dönem 3-4: Temel semptom ve tanı yaklaşımı",
            icon: "staroflife.fill",
            iconTint: AppColor.success,
            iconBackground: Color(hex: "#D1FAE5"),
            cardBackground: AppColor.surface
        ),
        .init(
            id: "Orta",
            title: "Orta",
            trailingLabel: "24 Vaka",
            description: "İntörn: Ayırıcı tanı ve tedavi planlama",
            icon: "waveform.path.ecg",
            iconTint: AppColor.warning,
            iconBackground: Color(hex: "#FEF3C7"),
            cardBackground: AppColor.surface
        ),
        .init(
            id: "Zor",
            title: "Zor",
            trailingLabel: "8 Vaka",
            description: "Asistan/Uzman: Komplike vakalar ve nadir durumlar",
            icon: "bolt.heart.fill",
            iconTint: AppColor.error,
            iconBackground: Color(hex: "#FFE4E6"),
            cardBackground: AppColor.surface
        )
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
                subtitle: "Vaka başlatma için klinik odağını seç."
            )

            HStack(spacing: 8) {
                generatorMetric(icon: "square.stack.3d.forward.dottedline", title: "Bölüm", value: specialty.isEmpty ? "Seçilmedi" : selectedSpecialtyLabel)
                generatorMetric(icon: "waveform.path.ecg", title: "Vaka Tipi", value: specialty == "Random" ? "Çoklu branş" : "Odaklı")
            }

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
            .frame(minHeight: 44)
            .background(AppColor.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            LazyVStack(spacing: 8) {
                ForEach(filteredSpecialtyRows) { item in
                    Button {
                        specialty = item.value
                        Haptic.selection()
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(specialty == item.value ? AppColor.primary : AppColor.surfaceAlt)
                                .frame(width: 6, height: 40)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(item.label)
                                        .font(AppFont.bodyMedium)
                                        .foregroundStyle(specialty == item.value ? AppColor.primaryDark : AppColor.textPrimary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                    if specialty == item.value {
                                        Text("Aktif")
                                            .font(AppFont.caption)
                                            .foregroundStyle(AppColor.primaryDark)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(AppColor.primaryLight)
                                            .clipShape(Capsule())
                                    }
                                }

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
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(specialty == item.value ? AppColor.primaryLight : AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(specialty == item.value ? AppColor.primary : AppColor.border, lineWidth: specialty == item.value ? 2 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColor.primary.opacity(0.28), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .appShadow(AppShadow.card)
            }
        } bottom: {
            Button {
                path.append(.difficulty)
            } label: {
                Text(specialty.isEmpty ? "Önce bölüm seç" : "Zorluk seç")
                    .appPrimaryButtonLabel()
            }
            .frame(minHeight: 50)
            .buttonStyle(PressableButtonStyle())
            .disabled(specialty.isEmpty)
            .opacity(specialty.isEmpty ? 0.45 : 1)
            .accessibilityLabel("Zorluk seç")
            .accessibilityHint("Zorluk seçim ekranına gider")
        }
        .navigationTitle("Bölüm Seç")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var difficultyStep: some View {
        selectionPageScaffold {
            difficultyTopBar

            VStack(alignment: .leading, spacing: 10) {
                Text("Seçili Bölüm Özeti")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedSpecialtyLabel)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Text(selectedSpecialtyFocusLine)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    difficultySummaryIllustration
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "#EEF7F7"))
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Vaka Zorluğu")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)

                LazyVStack(spacing: 10) {
                    ForEach(difficultyChoices) { choice in
                        difficultyChoiceCard(choice)
                    }
                }
            }
        } bottom: {
            Button {
                path.append(.mode(specialty: specialty, difficulty: difficulty))
            } label: {
                HStack(spacing: 8) {
                    Text("Mod Seç")
                        .font(AppFont.bodyMedium)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color(hex: "#0EA5E9"))
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: Color(hex: "#0EA5E9").opacity(0.22), radius: 6, x: 0, y: 4)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Mod seç")
            .accessibilityHint("Seçilen bölüm ve zorluk ile mod seçim ekranına geçer")
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var difficultyTopBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Circle()
                    .fill(AppColor.surface)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColor.textPrimary)
                    )
            }
            .buttonStyle(PressableButtonStyle())

            Text("Zorluk Seç")
                .font(AppFont.h3)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
        }
    }

    @ViewBuilder
    private var difficultySummaryIllustration: some View {
        if UIImage(named: "DifficultySummaryIcon") != nil {
            Image("DifficultySummaryIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.white, lineWidth: 2)
                )
                .appShadow(AppShadow.low)
        } else {
            Circle()
                .fill(AppColor.surface)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "stethoscope")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(AppColor.primary)
                )
        }
    }

    private func difficultyChoiceCard(_ choice: GeneratorDifficultyChoice) -> some View {
        let isSelected = difficulty == choice.id

        return Button {
            difficulty = choice.id
            Haptic.selection()
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(choice.iconBackground)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: choice.icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(choice.id == "Random" ? .white : choice.iconTint)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(choice.title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(AppColor.textPrimary)
                        Spacer(minLength: 8)
                        if choice.id == "Random" {
                            Text(choice.trailingLabel)
                                .font(AppFont.caption)
                                .foregroundStyle(Color(hex: "#0EA5E9"))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#0EA5E9").opacity(0.12))
                                .clipShape(Capsule())
                        } else {
                            Text(choice.trailingLabel)
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textTertiary)
                        }
                    }

                    Text(choice.description)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: choice.id == "Orta" ? 82 : 94, alignment: .leading)
            .background(isSelected ? choice.cardBackground : AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(isSelected ? choice.iconTint.opacity(0.46) : AppColor.border, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(choice.title)
        .accessibilityHint("Zorluk seviyesini \(choice.title) olarak seçer")
    }

    private func selectionPageScaffold<Content: View, Bottom: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(AppColor.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            BottomCTADock {
                bottom()
            }
        }
    }

    private func stepHeader(step: String, title: String, subtitle: String) -> some View {
        HeroHeader(
            eyebrow: "Adım \(step)",
            title: title,
            subtitle: subtitle,
            icon: "slider.horizontal.3",
            metrics: [
                HeroMetricItem(title: "Bölüm", value: selectedSpecialtyLabel, icon: "cross.case"),
                HeroMetricItem(title: "Zorluk", value: difficulty.isEmpty ? "Seçilmedi" : difficulty, icon: "speedometer"),
                HeroMetricItem(title: "Akış", value: "3 Aşama", icon: "list.number")
            ]
        ) {
            Text(selectedSpecialtyFocusLine)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
                .lineLimit(2)
        }
    }

    private func generatorMetric(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.primaryDark)
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Text(value)
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        let trimmed = specialty.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Bölüm seçtiğinde klinik odak ipucu burada görünür."
        }
        return SpecialtyOption.focusHint(for: specialty)
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

private struct GeneratorDifficultyChoice: Identifiable {
    let id: String
    let title: String
    let trailingLabel: String
    let description: String
    let icon: String
    let iconTint: Color
    let iconBackground: Color
    let cardBackground: Color
}
