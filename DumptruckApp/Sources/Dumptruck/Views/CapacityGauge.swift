import SwiftUI

/// Discrete level cells — a fuel gauge, deliberately NOT a bar. These used to
/// be ProgressViews, and in a copying app a continuous filled bar reads as
/// transfer progress (alpha field feedback: "looks like a progress bar"),
/// especially with real progress lanes rendering one column away. Segments
/// read as a level. The caption below each gauge carries the exact numbers;
/// the cells are hidden from accessibility so VoiceOver hears only the facts.
struct SegmentedLevelGauge: View {
    let fraction: Double  // 0...1 of the container used/occupied
    let tint: Color
    private let cells = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    // Neutral track, not a tint of the same hue: the tinted
                    // track failed the 3:1 non-text boundary in light mode
                    // (1.76:1 for destination) and implied partial fill.
                    .fill(filled(index) ? tint
                          : Color(nsColor: .quaternaryLabelColor))
                    .frame(height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func filled(_ index: Int) -> Bool {
        Double(index) + 0.5 < max(0, min(1, fraction)) * Double(cells)
    }
}

/// Free-space gauge (agy audit rank 2): the engine refuses an offload that
/// cannot fit, but the operator should SEE capacity before pressing Start —
/// and watch it drain during the day. `needed` (the staged card's TOTAL
/// bytes) turns the gauge amber when free space is below a FULL card; the
/// wording never claims a continuation cannot fit (it may need far less —
/// the engine checks exact absent bytes at Start).
struct CapacityGauge: View {
    let free: Int64
    let total: Int64
    let needed: Int64?

    private var belowFullCard: Bool { needed.map { free < $0 } ?? false }

    var body: some View {
        if total > 0 {
            let usedFrac = Double(total - free) / Double(total)
            VStack(alignment: .leading, spacing: 2) {
                SegmentedLevelGauge(
                    fraction: usedFrac,
                    tint: belowFullCard ? Semantics.warning
                          : (Double(free) / Double(total) < 0.1
                             ? Semantics.warning : Semantics.destination))
                Text(belowFullCard
                     ? "\(bytesString(free)) free · full card is \(bytesString(needed ?? 0))"
                     : "\(bytesString(free)) free of \(bytesString(total))")
                    .font(belowFullCard ? Typo.safety.monospacedDigit()
                                        : Typo.evidence.monospacedDigit())
                    .foregroundStyle(belowFullCard ? Semantics.warningText : .secondary)
            }
            .help(belowFullCard
                  ? "Free space is below the card's full size. This is not an exact requirement: continuations may need far less, and the engine checks the exact absent bytes at Start."
                  : "How full this volume is — not transfer progress")
        }
    }
}

/// Source-side fullness gauge: how much card there is to MOVE. Free space on
/// a camera card is meaningless to a DIT; bytes-to-move predicts the next 40
/// minutes.
struct FullnessGauge: View {
    let free: Int64
    let total: Int64

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                SegmentedLevelGauge(
                    fraction: Double(total - free) / Double(total),
                    tint: Semantics.source)
                Text("\(bytesString(total - free)) on card")
                    .font(Typo.evidence.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("How much footage is on the card — not transfer progress")
        }
    }
}
