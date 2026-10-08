import SwiftUI

/// The two-sided workbench: SOURCES | FLOW | DESTINATIONS. A custom HStack —
/// not NavigationSplitView (collapses the SOURCES column first under width
/// pressure and ships a toolbar button that hides a rail mid-job), not
/// HSplitView (divider double-click collapses a pane to zero, no persistence
/// hook). Rails never auto-hide: a rail that vanishes takes the lock icons
/// and eject controls with it. ⌥⌘J "Focus on Jobs" collapses both rails to
/// 56pt icon spines — explicit, reversible, never automatic (this is also
/// the laptop-width answer to the "two rails cost horizontal room" concern).
struct WorkbenchLayout<S: View, C: View, D: View>: View {
    @AppStorage("railWidth.sources")      private var sourceWidth = 288.0
    @AppStorage("railWidth.destinations") private var destWidth   = 288.0
    @AppStorage("focusJobs")              private var focusJobs   = false

    @ViewBuilder var sources: S
    @ViewBuilder var center: C
    @ViewBuilder var destinations: D

    static var railMin: Double { 232 }
    static var railMax: Double { 420 }
    static var centerMin: Double { 440 }
    static var spineWidth: Double { 56 }

    var body: some View {
        GeometryReader { geo in
            let widths = effectiveWidths(total: geo.size.width)
            HStack(spacing: 0) {
                sources
                    .frame(width: focusJobs ? Self.spineWidth : widths.source)
                    // Rails sit a step below the stage. ORDER MATTERS: each
                    // .background goes BEHIND the previous one, so the tint
                    // must come first or the material paints over it — the
                    // old (.bar, then black 0.14) stack measured #F8F8F8,
                    // identical to the cards on it, and the documented recess
                    // never rendered (2026-08-28 color audit). 0.06 is the
                    // ceiling: at 0.08 destinationText drops under AA on the
                    // composite. underPageBackgroundColor stays rejected
                    // (~#A1A1A1 light, tokens below 2.5:1).
                    .background(Color.black.opacity(0.06))
                    .background(.bar)
                RailDivider(width: $sourceWidth, edge: .leading,
                            bound: bound(total: geo.size.width, other: widths.dest))
                    .disabled(focusJobs)
                center
                    .frame(maxWidth: .infinity)
                RailDivider(width: $destWidth, edge: .trailing,
                            bound: bound(total: geo.size.width, other: widths.source))
                    .disabled(focusJobs)
                destinations
                    .frame(width: focusJobs ? Self.spineWidth : widths.dest)
                    .background(Color.black.opacity(0.06))
                    .background(.bar)
            }
        }
    }

    /// Widest this rail may become before the center hits its floor.
    private func bound(total: Double, other: Double) -> ClosedRange<Double> {
        let ceiling = max(Self.railMin,
                          min(Self.railMax, total - other - Self.centerMin - 16))
        return Self.railMin...ceiling
    }

    /// Persisted rail preferences may have been chosen on a 1600pt window.
    /// When that window returns to the supported 940pt minimum, scale only the
    /// preference *above* each rail's floor so the center still receives its
    /// promised 440pt. The stored preferences are untouched and return when
    /// the window grows again.
    private func effectiveWidths(total: Double) -> (source: Double, dest: Double) {
        let s = min(max(sourceWidth, Self.railMin), Self.railMax)
        let d = min(max(destWidth, Self.railMin), Self.railMax)
        let dividerBudget = 16.0
        let railBudget = max(Self.railMin * 2,
                             total - Self.centerMin - dividerBudget)
        let extraBudget = max(0, railBudget - Self.railMin * 2)
        let sExtra = s - Self.railMin
        let dExtra = d - Self.railMin
        let requestedExtra = sExtra + dExtra
        guard requestedExtra > extraBudget, requestedExtra > 0 else { return (s, d) }
        let scale = extraBudget / requestedExtra
        return (Self.railMin + sExtra * scale,
                Self.railMin + dExtra * scale)
    }
}

/// Shared motion helper for the rails: endpoints sliding between AVAILABLE and
/// IN THIS JOB animate, unless the operator asked the system for less motion —
/// in which case the same state change lands instantly with no transition.
enum RailMotion {
    @discardableResult
    static func run<T>(reduceMotion: Bool, _ body: () -> T) -> T {
        reduceMotion ? body() : withAnimation(.snappy) { body() }
    }
}

/// 1pt hairline, 8pt grab area, clamped drag, resize cursor.
struct RailDivider: View {
    @Binding var width: Double
    let edge: HorizontalEdge
    let bound: ClosedRange<Double>
    @State private var start: Double?
    /// True while the drag is pinned against a clamp bound — so the wall is
    /// felt once on arrival, not re-tapped on every frame of the same drag.
    @State private var hitEdge = false
    @Environment(\.isEnabled) private var isEnabled

    private static let step = 16.0

    var body: some View {
        Divider()
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 3.5)
            .contentShape(Rectangle())
            .onHover { inside in
                // §8: a disabled divider must not promise a drag it will not
                // perform (focusJobs pins both rails to 56pt spines).
                if inside && isEnabled { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            .onChange(of: isEnabled) { _, nowEnabled in
                if !nowEnabled { NSCursor.arrow.set() }   // cursor set while hovered, then disabled
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                let base = start ?? width
                if start == nil { start = width }
                let delta = edge == .leading ? g.translation.width : -g.translation.width
                let requested = base + delta
                width = min(max(requested, bound.lowerBound), bound.upperBound)
                let atEdge = requested < bound.lowerBound || requested > bound.upperBound
                if atEdge != hitEdge {
                    if atEdge { Haptics.level() }
                    hitEdge = atEdge
                }
            }.onEnded { _ in
                start = nil
                hitEdge = false
            })
            .accessibilityElement()
            .accessibilityLabel(edge == .leading ? "Sources rail width"
                                                 : "Destinations rail width")
            .accessibilityValue("\(Int(width.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(width + Self.step, bound.upperBound)
                case .decrement: width = max(width - Self.step, bound.lowerBound)
                @unknown default: break
                }
            }
    }
}
