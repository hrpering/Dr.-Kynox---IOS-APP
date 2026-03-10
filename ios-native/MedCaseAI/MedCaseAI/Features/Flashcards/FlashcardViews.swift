import SwiftUI
import AVFoundation
import AVKit
import SafariServices
import UIKit
import Sentry

struct FlashcardsHubView: View {
    @EnvironmentObject private var state: AppState
    @State private var loading = false
    @State private var errorText = ""
    @State private var todayCards: [FlashcardItem] = []
    @State private var collectionCards: [FlashcardItem] = []
    @State private var selectedSpecialty: String = "all"
    @State private var selectedType: String = "all"
    @State private var showStudy = false
    @State private var showSampleCards = false

    private var specialties: [String] {
        let values = Set(collectionCards.compactMap { card in
            let value = (card.specialty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
        return ["all"] + values.sorted()
    }

    private var cardTypes: [String] {
        let values = Set(collectionCards.map { $0.cardType })
        return ["all"] + values.sorted()
    }

    private var filteredCollectionCards: [FlashcardItem] {
        collectionCards.filter { card in
            let specialtyMatch = selectedSpecialty == "all" || card.specialty == selectedSpecialty
            let typeMatch = selectedType == "all" || card.cardType == selectedType
            return specialtyMatch && typeMatch
        }
    }

    private var selectedSpecialtyLabel: String {
        selectedSpecialty == "all" ? "Tüm Bölümler" : SpecialtyOption.label(for: selectedSpecialty)
    }

    private var selectedTypeLabel: String {
        selectedType == "all" ? "Tüm Kart Tipleri" : flashcardTypeLabel(selectedType)
    }

    private var specialtyOptions: [(key: String, label: String)] {
        specialties.map { value in
            (value, value == "all" ? "Tüm Bölümler" : SpecialtyOption.label(for: value))
        }
    }

    private var typeOptions: [(key: String, label: String)] {
        cardTypes.map { value in
            (value, value == "all" ? "Tüm Kart Tipleri" : flashcardTypeLabel(value))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    todayReviewCard

                    filterSection

                    if loading {
                        VStack(spacing: 10) {
                            ShimmerView().frame(height: 86)
                            ShimmerView().frame(height: 86)
                            ShimmerView().frame(height: 86)
                        }
                    } else if filteredCollectionCards.isEmpty {
                        if collectionCards.isEmpty {
                            emptyCollectionShowcase
                        } else {
                            noFilterResultCard
                        }
                    } else {
                        ForEach(filteredCollectionCards.prefix(120)) { card in
                            flashcardRow(card)
                        }
                    }

                    if !errorText.isEmpty {
                        ErrorStateCard(message: errorText) {
                            Task { await loadData(force: true) }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 10)
            }
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Kartlar")
            .refreshable {
                await loadData(force: true)
            }
            .task {
                await loadData()
            }
            .fullScreenCover(isPresented: $showStudy) {
                FlashcardStudyView(cards: todayCards) { card, rating in
                    _ = try? await state.reviewFlashcard(cardId: card.id, rating: rating)
                    await loadData(force: true)
                }
                .environmentObject(state)
            }
        }
    }

    private var todayReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bugünkü Tekrar")
                        .font(AppFont.title2)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("\(todayCards.count) kart sırada")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColor.primary)
            }

            Text("Spaced repetition: Bilmiyordum → yarın, Zordu → 3 gün, Kolaydı → 7+ gün.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            Button {
                showStudy = true
            } label: {
                if todayCards.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text("Bugün tekrar yok")
                    }
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppColor.surfaceAlt.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColor.border.opacity(0.9), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("Bugünkü Tekrara Başla")
                        .appPrimaryButtonLabel()
                }
            }
            .disabled(todayCards.isEmpty)
            .buttonStyle(PressableButtonStyle())
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [AppColor.primaryLight, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.primary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Koleksiyon Filtreleri")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)

            HStack(spacing: 10) {
                filterDropdown(
                    title: "Bölüm",
                    selectedLabel: selectedSpecialtyLabel,
                    options: specialtyOptions,
                    selectedKey: selectedSpecialty
                ) { value in
                    selectedSpecialty = value
                }

                filterDropdown(
                    title: "Kart Tipi",
                    selectedLabel: selectedTypeLabel,
                    options: typeOptions,
                    selectedKey: selectedType
                ) { value in
                    selectedType = value
                }
            }
        }
    }

    private func filterDropdown(
        title: String,
        selectedLabel: String,
        options: [(key: String, label: String)],
        selectedKey: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.key) { option in
                Button {
                    onSelect(option.key)
                    Haptic.selection()
                } label: {
                    if option.key == selectedKey {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                HStack(spacing: 6) {
                    Text(selectedLabel)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var emptyCollectionShowcase: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Henüz kartın yok")
                .font(AppFont.title2)
                .foregroundStyle(AppColor.textPrimary)
            Text("Bir vaka çözdüğünde buraya otomatik eklenir.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            HStack(spacing: 10) {
                Button("Vaka başlat") {
                    state.selectedMainTab = "generator"
                    Haptic.selection()
                }
                .appPrimaryButton()

                Button(showSampleCards ? "Örnekleri Gizle" : "Örnek Kartları İncele") {
                    showSampleCards.toggle()
                    Haptic.selection()
                }
                .appSecondaryButton()
            }

            if showSampleCards {
                sampleFlashcardRow(
                    title: "Örnek · Tanı İpucu",
                    front: "Ani göğüs ağrısı + soğuk terleme ilk hangi tanıyı düşündürür?",
                    badge: "Tanı"
                )
                sampleFlashcardRow(
                    title: "Örnek · Kırmızı Bayrak",
                    front: "Dispne + hipotansiyon + taşikardi birlikteliğinde öncelik ne olmalı?",
                    badge: "Kırmızı Bayrak"
                )
            }
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

    private var noFilterResultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bu filtreye uygun kart bulunamadı")
                .font(AppFont.bodyMedium)
                .foregroundStyle(AppColor.textPrimary)
            Text("Filtreleri genişletip tüm kartları görebilirsin.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
            Button("Filtreleri sıfırla") {
                selectedSpecialty = "all"
                selectedType = "all"
                Haptic.selection()
            }
            .font(AppFont.caption)
            .foregroundStyle(AppColor.primaryDark)
            .frame(minHeight: 32)
            .buttonStyle(.plain)
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

    private func sampleFlashcardRow(title: String, front: String, badge: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Badge(text: badge, tint: AppColor.primaryDark, background: AppColor.primaryLight)
            }
            Text(front)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
                .lineLimit(2)
            Text("Örnek kart")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func flashcardRow(_ card: FlashcardItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.title)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Badge(text: card.typeDisplayName, tint: AppColor.primaryDark, background: AppColor.primaryLight)
            }
            Text(card.front)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let specialty = card.specialty, !specialty.isEmpty {
                    Badge(text: SpecialtyOption.label(for: specialty), tint: AppColor.textSecondary, background: AppColor.surfaceAlt)
                }
                Text("Tekrar: \(card.dueLabel)")
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

    private func flashcardTypeLabel(_ value: String) -> String {
        switch value {
        case "diagnosis": return "Tanı"
        case "drug": return "İlaç"
        case "red_flag": return "Kırmızı Bayrak"
        case "differential": return "Ayırıcı Tanı"
        case "management": return "Yönetim"
        case "lab": return "Laboratuvar"
        case "imaging": return "Görüntüleme"
        case "procedure": return "Prosedür"
        default: return "Kavram"
        }
    }

    private func loadData(force: Bool = false) async {
        if loading && !force { return }
        loading = true
        defer { loading = false }
        do {
            async let due = state.fetchFlashcardsToday(limit: 80)
            async let collection = state.fetchFlashcardCollections(limit: 300)
            let (dueCards, all) = try await (due, collection)
            todayCards = dueCards
            collectionCards = all.cards
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct FlashcardStudyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cards: [FlashcardItem]
    let onRate: (FlashcardItem, FlashcardReviewRating) async -> Void

    @State private var queue: [FlashcardItem]
    @State private var isFlipped = false
    @State private var isSubmitting = false

    init(cards: [FlashcardItem],
         onRate: @escaping (FlashcardItem, FlashcardReviewRating) async -> Void) {
        self.cards = cards
        self.onRate = onRate
        _queue = State(initialValue: cards)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let current = queue.first {
                    Text("Kart \(cards.count - queue.count + 1)/\(cards.count)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)

                    FlashcardFlipCard(
                        front: current.front,
                        back: current.back,
                        isFlipped: isFlipped
                    )
                    .onTapGesture {
                        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.35)) {
                            isFlipped.toggle()
                        }
                    }

                    HStack(spacing: 10) {
                        reviewButton(.again, tint: AppColor.error, background: AppColor.errorLight)
                        reviewButton(.hard, tint: AppColor.warning, background: AppColor.warningLight)
                        reviewButton(.easy, tint: AppColor.success, background: AppColor.successLight)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(AppColor.success)
                        Text("Bugünkü tekrar tamamlandı")
                            .font(AppFont.title2)
                            .foregroundStyle(AppColor.textPrimary)
                        Text("Harika. Yeni kartlar sonuç ekranından üretildiğinde burada görünecek.")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .lineSpacing(4)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                }
                Spacer()
            }
            .padding(16)
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle("Bugünkü Tekrar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        dismiss()
                    }
                    .foregroundStyle(AppColor.primary)
                }
            }
        }
    }

    private func reviewButton(_ rating: FlashcardReviewRating,
                              tint: Color,
                              background: Color) -> some View {
        Button {
            guard let current = queue.first else { return }
            Task {
                isSubmitting = true
                await onRate(current, rating)
                if !queue.isEmpty {
                    queue.removeFirst()
                }
                isFlipped = false
                isSubmitting = false
            }
        } label: {
            VStack(spacing: 2) {
                Text(rating.title)
                    .font(AppFont.caption)
                Text(rating.subtitle)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isSubmitting ? 0.7 : 1)
        }
        .disabled(isSubmitting)
        .buttonStyle(PressableButtonStyle())
    }
}

struct FlashcardFlipCard: View {
    let front: String
    let back: String
    let isFlipped: Bool

    var body: some View {
        ZStack {
            flashSurface(
                title: "Ön Yüz",
                text: front,
                tint: AppColor.primary
            )
            .opacity(isFlipped ? 0 : 1)

            flashSurface(
                title: "Arka Yüz",
                text: back,
                tint: AppColor.success
            )
            .opacity(isFlipped ? 1 : 0)
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .frame(maxWidth: .infinity, minHeight: 280)
        .animation(.easeInOut(duration: 0.35), value: isFlipped)
    }

    private func flashSurface(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            Text(text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

