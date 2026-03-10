import SwiftUI

struct WeakAreaRadarChart: View {
    let axes: [WeakAreaScoreMap.Axis]
    let userValues: [Double]
    let globalValues: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = max(axes.count, 3)

            ZStack {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    Path { path in
                        let points = polygonPoints(in: size, count: count, scale: level)
                        guard !points.isEmpty else { return }
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                    }
                    .stroke(AppColor.border.opacity(level == 1 ? 0.85 : 0.45), lineWidth: 1)
                }

                ForEach(0..<count, id: \.self) { idx in
                    Path { path in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let outer = point(in: size, axis: idx, count: count, ratio: 1.0)
                        path.move(to: center)
                        path.addLine(to: outer)
                    }
                    .stroke(AppColor.border.opacity(0.45), lineWidth: 1)
                }

                Path { path in
                    let points = scorePoints(in: size, values: globalValues, count: count)
                    guard !points.isEmpty else { return }
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.closeSubpath()
                }
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .foregroundStyle(AppColor.textTertiary)

                Path { path in
                    let points = scorePoints(in: size, values: userValues, count: count)
                    guard !points.isEmpty else { return }
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.closeSubpath()
                }
                .fill(AppColor.primary.opacity(0.26))

                Path { path in
                    let points = scorePoints(in: size, values: userValues, count: count)
                    guard !points.isEmpty else { return }
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.closeSubpath()
                }
                .stroke(AppColor.primaryDark, lineWidth: 2.2)

                ForEach(Array(axes.enumerated()), id: \.offset) { idx, axis in
                    let labelPoint = point(in: size, axis: idx, count: count, ratio: 1.13)
                    Text(axis.shortLabel ?? axis.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .position(labelPoint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func polygonPoints(in size: CGSize, count: Int, scale: CGFloat) -> [CGPoint] {
        (0..<count).map { idx in
            point(in: size, axis: idx, count: count, ratio: scale)
        }
    }

    private func scorePoints(in size: CGSize, values: [Double], count: Int) -> [CGPoint] {
        (0..<count).map { idx in
            let value = idx < values.count ? values[idx] : 0
            let ratio = CGFloat(max(0, min(100, value)) / 100.0)
            return point(in: size, axis: idx, count: count, ratio: ratio)
        }
    }

    private func point(in size: CGSize, axis: Int, count: Int, ratio: CGFloat) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = -CGFloat.pi / 2 + (CGFloat(axis) * 2 * .pi / CGFloat(max(count, 1)))
        let radius = max(0, min(size.width, size.height) * 0.34) * ratio
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }
}

