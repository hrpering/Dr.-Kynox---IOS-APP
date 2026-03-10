import SwiftUI

struct WeakAreaSpecialtyDetailView: View {
    let item: WeakAreaSpecialtyStat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard
                sectionHeader(title: "Detay Skor Grafiği")
                ForEach(item.dimensions) { dimension in
                    dimensionRow(dimension)
                }
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(item.specialtyLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.specialtyLabel)
                    .font(AppFont.title2)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Badge(text: item.recommendedDifficulty, tint: AppColor.warning, background: AppColor.warningLight)
            }
            Text("Sen \(Int(item.userAverageScore.rounded())) · Genel \(Int(item.globalAverageScore.rounded()))")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .lineSpacing(4)

            if let weak = item.weakestDimensionLabel {
                Text("Zayıf metrik: \(weak)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.primaryDark)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dimensionRow(_ item: WeakAreaSpecialtyDimension) -> some View {
        let userRatio = max(0, min(1, item.userAverageScore / 100))
        let globalRatio = max(0, min(1, item.globalAverageScore / 100))
        let tint: Color = {
            if item.userAverageScore >= 70 { return AppColor.success }
            if item.userAverageScore >= 50 { return AppColor.warning }
            return AppColor.error
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.label)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Spacer()
                Text("\(Int(item.userAverageScore.rounded()))")
                    .font(AppFont.caption)
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.surfaceAlt)
                    Capsule()
                        .fill(AppColor.textTertiary.opacity(0.55))
                        .frame(width: proxy.size.width * globalRatio)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * userRatio)
                }
            }
            .frame(height: 8)

            Text("Sen \(Int(item.userAverageScore.rounded())) · Genel \(Int(item.globalAverageScore.rounded()))")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

