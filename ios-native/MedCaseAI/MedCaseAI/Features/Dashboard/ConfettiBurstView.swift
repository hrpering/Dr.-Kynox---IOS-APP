import SwiftUI

struct ConfettiBurstView: View {
    private let colors: [Color] = [AppColor.primary, AppColor.success, AppColor.warning, AppColor.error]
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<28, id: \.self) { idx in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colors[idx % colors.count])
                        .frame(width: 7, height: 11)
                        .rotationEffect(.degrees(Double((idx * 37) % 360)))
                        .position(
                            x: animate
                                ? CGFloat.random(in: 14...(proxy.size.width - 14))
                                : proxy.size.width / 2,
                            y: animate
                                ? proxy.size.height + CGFloat.random(in: 20...180)
                                : proxy.size.height * 0.2
                        )
                        .opacity(animate ? 0.03 : 0.95)
                        .animation(
                            .easeOut(duration: 1.35).delay(Double(idx) * 0.02),
                            value: animate
                        )
                }
            }
            .onAppear {
                animate = true
            }
        }
        .ignoresSafeArea()
    }
}

