import SwiftUI

/// Dependency-free throughput sparkline: a filled area + line over the last
/// ~60 one-second samples, scaled to the session's own peak.
struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(samples.max() ?? 1, 1)
            let w = geo.size.width
            let h = geo.size.height
            let step = samples.count > 1 ? w / CGFloat(samples.count - 1) : w
            let points: [CGPoint] = samples.enumerated().map { i, s in
                CGPoint(x: CGFloat(i) * step,
                        y: h * (1 - CGFloat(min(s / peak, 1))))
            }
            if points.count > 1 {
                Path { p in
                    p.move(to: CGPoint(x: points[0].x, y: h))
                    for pt in points { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: points[points.count - 1].x, y: h))
                    p.closeSubpath()
                }
                .fill(Semantics.running.opacity(0.15))
                Path { p in
                    p.move(to: points[0])
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Semantics.running,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                           lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
