import SwiftUI

struct InAppBroadcastBanner: View {
    let banner: InAppBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.title)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(2)
                    Text(banner.body)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(3)
                }
                Spacer(minLength: 6)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(AppColor.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Duyuruyu kapat")
            }

            if banner.deepLink?.isEmpty == false {
                HStack {
                    Button {
                        onOpen()
                        onDismiss()
                    } label: {
                        Text("Aç")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.primaryDark)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Uygulama duyurusu")
    }
}

