import SwiftUI
import AppKit

// MARK: - MicroAnimations.swift
//
// Tasteful, performance-disciplined micro-animations for Dumptruck (macOS 14+).
// Follows the DIT dual-personality design: clinical restraint in safety areas,
// authentic dump-truck charm in the fun/arcade layers.
//
// Rules enforced across all components:
// 1. Never obscure, delay, or fabricate safety state.
// 2. No attention-grabbing infinite loops in safety zones (one-shots or slow subtle breathing only).
// 3. Durations strictly within 0.2s – 0.8s for one-shot transitions.
// 4. All semantic colors sourced from Semantics / SemanticColors tokens.
// 5. The word "dump" appears nowhere in safety-adjacent labels.
// 6. Reduce Motion (@Environment(\.accessibilityReduceMotion)) honored everywhere with a dignified static fallback.
// 7. No background Timer leaks — driven by TimelineView (visibility-gated) or SwiftUI state animators.
// 8. Standalone and self-contained; no external assets required.

// MARK: - Shared Visibility Gate
// Drives `paused:` on TimelineViews. Three booleans and one notification
// subscription that SwiftUI tears down on disappear (mirrors TruckAnimations.swift).
private struct VisibilityGate: ViewModifier {
    @Binding var awake: Bool
    @State private var onScreen = false
    @State private var sceneActive = true
    @State private var windowVisible = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen = true
                sceneActive = (scenePhase == .active)
                push()
            }
            .onDisappear {
                onScreen = false
                push()
            }
            .onChange(of: scenePhase) { _, phase in
                sceneActive = (phase == .active)
                push()
            }
            .onReceive(NotificationCenter.default
                .publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                    windowVisible = NSApp.windows.contains {
                        $0.isVisible && $0.occlusionState.contains(.visible)
                    }
                    push()
                }
    }

    private func push() {
        let next = onScreen && sceneActive && windowVisible
        if next != awake { awake = next }
    }
}

private extension View {
    func visibilityGate(_ awake: Binding<Bool>) -> some View {
        modifier(VisibilityGate(awake: awake))
    }
}

// MARK: - 1. ManifestSealView
//
// Intended mount: FlowColumn.swift -> JobHeaderBand -> sealingChecklist / sealingStep
// Replaces the generic "circle.dotted" / "checkmark.circle.fill" icon with an
// authentic embossed notary seal that breathes quietly while SHA-256 manifests
// are written and stamps firmly into place once the report is sealed.

struct ManifestSealView: View {
    enum SealState: Equatable, Sendable {
        case idle       // Standby / pending (subtle hairline boundary)
        case sealing    // Actively hashing manifests (quiet amber breathing pulse, mechanical notched rim)
        case sealed     // Report written & sealed (crisp green stamped seal with embossed checkmark)
    }

    var state: SealState
    var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stampTrigger = false
    @State private var pulsePhase: Double = 0.0
    @State private var awake = false

    init(state: SealState, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    init(isSealing: Bool, isSealed: Bool, size: CGFloat = 16) {
        if isSealed {
            self.state = .sealed
        } else if isSealing {
            self.state = .sealing
        } else {
            self.state = .idle
        }
        self.size = size
    }

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                idleSeal
            case .sealing:
                if reduceMotion {
                    staticSealingSeal
                } else {
                    animatedSealingSeal
                }
            case .sealed:
                if reduceMotion {
                    staticSealedSeal
                } else {
                    animatedSealedSeal
                }
            }
        }
        .frame(width: size, height: size)
        .visibilityGate($awake)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onChange(of: state) { oldState, newState in
            if newState == .sealed && oldState != .sealed && !reduceMotion {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                    stampTrigger = true
                }
            } else {
                stampTrigger = false
            }
        }
    }

    // MARK: Idle View

    private var idleSeal: some View {
        Circle()
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.0, dash: [2, 2]))
            .frame(width: size, height: size)
    }

    // MARK: Sealing View (Amber Breathing Pulse)

    private var staticSealingSeal: some View {
        ZStack {
            NotchedSealShape(teeth: 12, insetDepth: 1.2)
                .stroke(Semantics.warningText, lineWidth: 1.2)
            Circle()
                .fill(Semantics.warningText)
                .frame(width: size * 0.38, height: size * 0.38)
        }
    }

    private var animatedSealingSeal: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !awake || reduceMotion)) { tl in
            let time = tl.date.timeIntervalSinceReferenceDate
            let breath = (sin(time * 3.14) + 1.0) / 2.0 // 0.0 ... 1.0 over ~2.0s
            let innerScale = 0.30 + 0.12 * breath
            let outerAlpha = 0.55 + 0.40 * breath

            ZStack {
                // Subtle ambient glow
                Circle()
                    .fill(Semantics.warning.opacity(0.12 * breath))
                    .frame(width: size * 1.3, height: size * 1.3)

                // Mechanical notched rim
                NotchedSealShape(teeth: 12, insetDepth: 1.2)
                    .stroke(Semantics.warningText.opacity(outerAlpha), lineWidth: 1.2)
                    .frame(width: size, height: size)

                // Concentric inner breathing pulse
                Circle()
                    .fill(Semantics.warningText.opacity(0.85 + 0.15 * breath))
                    .frame(width: size * innerScale, height: size * innerScale)
            }
        }
    }

    // MARK: Sealed View (Solid Green Stamped Checkmark)

    private var staticSealedSeal: some View {
        ZStack {
            NotchedSealShape(teeth: 14, insetDepth: 1.0)
                .fill(Semantics.successText)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(Color.white)
        }
    }

    private var animatedSealedSeal: some View {
        ZStack {
            // Embossed outer ring
            NotchedSealShape(teeth: 14, insetDepth: 1.0)
                .fill(Semantics.successText)
                .overlay(
                    NotchedSealShape(teeth: 14, insetDepth: 1.0)
                        .stroke(Color.black.opacity(0.15), lineWidth: 0.8)
                )

            // Crisp stamped white checkmark
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.2), radius: 0.5, x: 0, y: 0.5)
        }
        .scaleEffect(stampTrigger ? 1.0 : 1.18)
        .onAppear {
            if !stampTrigger {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                    stampTrigger = true
                }
            }
        }
    }

    private var accessibilityDescription: String {
        switch state {
        case .idle: return "Manifest sealing not started"
        case .sealing: return "Sealing manifests in progress"
        case .sealed: return "Manifests sealed and verified"
        }
    }
}

/// A precision notched/cogged seal rim representing an archival embossed notary stamp.
private struct NotchedSealShape: Shape {
    let teeth: Int
    let insetDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2.0
        let innerRadius = max(0, outerRadius - insetDepth)
        var path = Path()

        let totalPoints = teeth * 2
        for i in 0..<totalPoints {
            let angle = (Double(i) * .pi / Double(teeth)) - (.pi / 2.0)
            let radius = (i % 2 == 0) ? outerRadius : innerRadius
            let pt = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            if i == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 2. VolumeArrivalPulse
//
// Intended mount: ConnectedShelf.swift -> ShelfTile
// A one-shot 0.35s soft border glow beacon when a newly mounted volume tile
// appears on the center Connected shelf (which replaced the rails' Available
// sections in the 2026-08-26 facelift).

struct VolumeArrivalPulse: ViewModifier {
    var trigger: AnyHashable?
    var color: Color
    var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowOpacity: Double = 0.0
    @State private var glowSpread: CGFloat = 0.0

    init(
        trigger: AnyHashable? = nil,
        color: Color = Semantics.source,
        cornerRadius: CGFloat = 8
    ) {
        self.trigger = trigger
        self.color = color
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color.opacity(glowOpacity), lineWidth: 1.5)
                    .padding(-glowSpread)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(color.opacity(glowOpacity * 0.45), lineWidth: 3.0)
                    .blur(radius: 2.0)
                    .padding(-glowSpread)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .onAppear {
                firePulse()
            }
            .onChange(of: trigger) { _, _ in
                firePulse()
            }
    }

    private func firePulse() {
        guard !reduceMotion else { return }
        glowOpacity = 0.85
        glowSpread = 0.0
        withAnimation(.easeOut(duration: 0.35)) {
            glowOpacity = 0.0
            glowSpread = 1.5
        }
    }
}

extension View {
    /// Applies a 0.35s soft border glow pulse to signal volume arrival.
    func volumeArrivalPulse(
        trigger: AnyHashable? = nil,
        color: Color = Semantics.source,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(VolumeArrivalPulse(trigger: trigger, color: color, cornerRadius: cornerRadius))
    }
}

// MARK: - 3. MilestoneTicksOverlay
//
// Intended mount: FlowColumn.swift -> LaneTrack & JobHeaderBand runningBody progress bars
// Faint tick marks at 25%, 50%, and 75% across the progress track that brighten
// crisply once the verified fraction passes each threshold.

struct MilestoneTicksOverlay: View {
    var fraction: Double
    var milestones: [Double]
    var tickWidth: CGFloat
    var tickInset: CGFloat
    var activeColor: Color
    var inactiveColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        fraction: Double,
        milestones: [Double] = [0.25, 0.50, 0.75],
        tickWidth: CGFloat = 1.5,
        tickInset: CGFloat = 1.0,
        activeColor: Color = Color.white.opacity(0.90),
        inactiveColor: Color = Color.primary.opacity(0.18)
    ) {
        self.fraction = min(max(fraction, 0), 1)
        self.milestones = milestones
        self.tickWidth = tickWidth
        self.tickInset = tickInset
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let tickH = max(1.0, h - (tickInset * 2.0))

            ZStack(alignment: .leading) {
                ForEach(milestones, id: \.self) { m in
                    let isPassed = fraction >= m
                    let posX = max(tickWidth / 2.0, min(w - tickWidth / 2.0, w * CGFloat(m)))

                    RoundedRectangle(cornerRadius: tickWidth / 2.0)
                        .fill(isPassed ? activeColor : inactiveColor)
                        .frame(width: tickWidth, height: tickH)
                        .position(x: posX, y: h / 2.0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isPassed)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 4. EjectGlideView & Modifier
//
// Intended mount: SourcesRail.swift -> SourceCard (staged source card on successful eject)
// Smoothly glides the card 20pt leading-edge and dissolves opacity over 0.35s
// when a source volume is safely dismounted.

struct EjectGlideContainer<Content: View>: View {
    var isEjecting: Bool
    var onComplete: (() -> Void)?
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offsetLeading: CGFloat = 0.0
    @State private var opacity: Double = 1.0
    @State private var completed = false
    @State private var task: Task<Void, Never>?

    init(
        isEjecting: Bool,
        onComplete: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isEjecting = isEjecting
        self.onComplete = onComplete
        self.content = content()
    }

    var body: some View {
        content
            .offset(x: offsetLeading)
            .opacity(opacity)
            .onChange(of: isEjecting) { _, ejecting in
                if ejecting && !completed {
                    runGlide()
                } else if !ejecting {
                    restoreRow()
                }
            }
            .onAppear {
                if isEjecting && !completed {
                    runGlide()
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
    }

    private func runGlide() {
        task?.cancel()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) {
                opacity = 0.0
            }
            task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                completed = true
                onComplete?()
            }
        } else {
            withAnimation(.easeIn(duration: 0.35)) {
                offsetLeading = -24.0
                opacity = 0.0
            }
            task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                completed = true
                onComplete?()
            }
        }
    }

    private func restoreRow() {
        task?.cancel()
        task = nil
        completed = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            offsetLeading = 0
            opacity = 1
        }
    }
}

extension View {
    /// Applies a smooth left-glide and fade transition upon clean volume ejection.
    func ejectGlide(
        isEjecting: Bool,
        onComplete: (() -> Void)? = nil
    ) -> some View {
        EjectGlideContainer(isEjecting: isEjecting, onComplete: onComplete) {
            self
        }
    }
}

/// Standalone visual representation of an ejecting card indicator.
struct EjectGlideBadge: View {
    var isEjecting: Bool
    var onComplete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offsetLeading: CGFloat = 0.0
    @State private var opacity: Double = 1.0
    @State private var task: Task<Void, Never>?

    init(isEjecting: Bool = true, onComplete: (() -> Void)? = nil) {
        self.isEjecting = isEjecting
        self.onComplete = onComplete
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eject.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Semantics.successText)
            Text("Ejected")
                .font(Typo.evidence)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .offset(x: offsetLeading)
        .opacity(opacity)
        .onAppear {
            guard isEjecting else { return }
            task?.cancel()
            let dur = reduceMotion ? 0.12 : 0.38
            withAnimation(.easeIn(duration: dur)) {
                offsetLeading = reduceMotion ? 0 : -20.0
                opacity = 0.0
            }
            task = Task { @MainActor in
                try? await Task.sleep(for: .seconds(dur))
                guard !Task.isCancelled else { return }
                onComplete?()
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
        .accessibilityLabel("Volume ejected")
    }
}

// MARK: - 5. TopUpPourView
//
// Intended mount: FlowColumn.swift -> BenchCard continuation banner (lines 172-186)
// A charming, lightweight continuation visual showing a truck bed with an
// existing verified gravel stratum (solid green/gold) receiving fresh incoming
// top-up gravel (indigo) to represent a URSA / cinema camera roll continuation.

struct TopUpPourView: View {
    var existingFraction: Double   // Fraction of card verified on prior shoot (e.g. 0.40)
    var targetFraction: Double     // Total fraction including new continuation (e.g. 0.85)
    var isPouring: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var awake = false

    init(
        existingFraction: Double = 0.40,
        targetFraction: Double = 0.85,
        isPouring: Bool = true
    ) {
        self.existingFraction = min(max(existingFraction, 0.05), 0.90)
        self.targetFraction = min(max(targetFraction, self.existingFraction + 0.05), 1.0)
        self.isPouring = isPouring
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if reduceMotion {
                staticBedView(width: w, height: h)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !awake || !isPouring)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    animatedBedView(width: w, height: h, time: t)
                }
            }
        }
        .frame(minWidth: 48, idealWidth: 96, maxWidth: 140, minHeight: 24, idealHeight: 32, maxHeight: 40)
        .visibilityGate($awake)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Card continuation: \(Int(existingFraction * 100))% previously verified, adding remaining footage")
    }

    // MARK: Static Dignified Fallback

    private func staticBedView(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Bed frame outline
            TruckBedOutlineShape()
                .stroke(Color.primary.opacity(0.35), lineWidth: 1.2)

            // Existing verified base fill
            BedFillClipShape(fraction: existingFraction)
                .fill(Semantics.success.opacity(0.35))
                .overlay(
                    BedFillClipShape(fraction: existingFraction)
                        .stroke(Semantics.successText.opacity(0.6), lineWidth: 1.0)
                )

            // New continuation allocation stratum
            BedTopUpClipShape(startFraction: existingFraction, endFraction: targetFraction)
                .fill(Semantics.running.opacity(0.28))

            // Verified check badge in the base stratum
            Image(systemName: "checkmark")
                .font(.system(size: max(7, height * 0.22), weight: .bold))
                .foregroundStyle(Semantics.successText)
                .position(x: width * 0.45, y: height * 0.72)
        }
    }

    // MARK: Animated Pouring Bed View

    private func animatedBedView(width: CGFloat, height: CGFloat, time: Double) -> some View {
        let fillProgress = min(1.0, (sin(time * 1.5) + 1.0) / 2.0)
        let currentTotal = existingFraction + (targetFraction - existingFraction) * fillProgress

        return ZStack(alignment: .bottomLeading) {
            // 1. Bed structure outline
            TruckBedOutlineShape()
                .stroke(Color.primary.opacity(0.35), lineWidth: 1.2)

            // 2. Existing verified base layer (calm green)
            BedFillClipShape(fraction: existingFraction)
                .fill(Semantics.success.opacity(0.32))
                .overlay(
                    BedFillClipShape(fraction: existingFraction)
                        .stroke(Semantics.successText.opacity(0.55), lineWidth: 0.8)
                )

            // 3. Dynamic incoming top-up layer (indigo)
            BedTopUpClipShape(startFraction: existingFraction, endFraction: currentTotal)
                .fill(Semantics.running.opacity(0.30))

            // 4. Little checkmark badge pinned on existing stratum
            Image(systemName: "checkmark")
                .font(.system(size: max(7, height * 0.22), weight: .bold))
                .foregroundStyle(Semantics.successText)
                .position(x: width * 0.42, y: height * 0.72)

            // 5. Flowing incoming gravel particles Canvas
            Canvas { ctx, size in
                drawPourParticles(ctx, size: size, time: time)
            }
            .allowsHitTesting(false)
        }
    }

    private func drawPourParticles(_ ctx: GraphicsContext, size: CGSize, time: Double) {
        let streamOrigin = CGPoint(x: size.width * 0.78, y: size.height * 0.06)
        let count = 5

        for i in 0..<count {
            let offset = Double(i) * 0.22
            let cycle = (time * 2.2 + offset).truncatingRemainder(dividingBy: 1.0)
            let u = cycle // 0.0 ... 1.0

            let startX = streamOrigin.x + CGFloat(sin(Double(i) * 1.7)) * 2.0
            let startY = streamOrigin.y
            let targetX = size.width * (0.50 + CGFloat(i) * 0.05)
            let targetY = size.height * 0.58

            // Parabolic fall trajectory
            let px = startX + (targetX - startX) * CGFloat(u)
            let py = startY + (targetY - startY) * CGFloat(u * u)
            let radius = CGFloat(1.4 + Double(i % 3) * 0.4)
            let alpha = u < 0.85 ? 0.85 : (1.0 - (u - 0.85) / 0.15) * 0.85

            let rect = CGRect(x: px - radius, y: py - radius, width: radius * 2.0, height: radius * 2.0)
            ctx.fill(Path(ellipseIn: rect), with: .color(Semantics.running.opacity(alpha)))
        }
    }
}

/// Outer contour of a dump truck bed (open top, forward hook, sloped tailgate).
private struct TruckBedOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()

        // Bed hook over cab (left) -> rear tailgate (right) -> belly -> floor
        p.move(to: CGPoint(x: w * 0.18, y: h * 0.25))
        p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.25)) // Top rail
        p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.78)) // Tailgate slope
        p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.78)) // Bed bottom floor
        p.addLine(to: CGPoint(x: w * 0.20, y: h * 0.38)) // Front bulkhead
        p.addLine(to: CGPoint(x: w * 0.14, y: h * 0.38)) // Cab hook lower edge
        p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.25)) // Cab hook upper edge
        p.closeSubpath()

        // Add 2 rear wheels under the bed for authentic truck profile
        let r = h * 0.16
        let yWheel = h * 0.84
        p.addEllipse(in: CGRect(x: w * 0.32 - r, y: yWheel - r, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: w * 0.72 - r, y: yWheel - r, width: r * 2, height: r * 2))

        return p
    }
}

/// Clip path for the bottom-most stratum of verified gravel in the bed.
private struct BedFillClipShape: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let f = CGFloat(min(max(fraction, 0), 1))

        let floorY = h * 0.76
        let topY = floorY - (h * 0.48 * f)

        var p = Path()
        p.move(to: CGPoint(x: w * 0.23, y: topY))
        p.addLine(to: CGPoint(x: w * 0.88, y: topY))
        p.addLine(to: CGPoint(x: w * 0.92, y: floorY))
        p.addLine(to: CGPoint(x: w * 0.25, y: floorY))
        p.closeSubpath()
        return p
    }
}

/// Clip path for the upper incoming continuation stratum in the bed.
private struct BedTopUpClipShape: Shape {
    let startFraction: Double
    let endFraction: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let sf = CGFloat(min(max(startFraction, 0), 1))
        let ef = CGFloat(min(max(endFraction, sf), 1))

        guard ef > sf else { return Path() }

        let floorY = h * 0.76
        let bottomY = floorY - (h * 0.48 * sf)
        let topY = floorY - (h * 0.48 * ef)

        var p = Path()
        p.move(to: CGPoint(x: w * 0.21, y: topY))
        p.addLine(to: CGPoint(x: w * 0.86, y: topY))
        p.addLine(to: CGPoint(x: w * 0.88, y: bottomY))
        p.addLine(to: CGPoint(x: w * 0.23, y: bottomY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 6. Interactive Developer Gallery
//
// Manual test harness for tuning and inspecting all micro-animations in one view.

struct MicroAnimationsGallery: View {
    @State private var sealState: ManifestSealView.SealState = .sealing
    @State private var progress: Double = 0.42
    @State private var arrivalTrigger = UUID()
    @State private var isEjecting = false
    @State private var topUpLevel: Double = 0.35

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dumptruck Micro-Animations")
                .font(.headline)

            Divider()

            // 1. ManifestSealView
            VStack(alignment: .leading, spacing: 6) {
                Text("1. ManifestSealView (FlowColumn sealing checklist row)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ManifestSealView(state: .idle, size: 20)
                    ManifestSealView(state: .sealing, size: 20)
                    ManifestSealView(state: .sealed, size: 20)
                    ManifestSealView(state: sealState, size: 20)

                    Picker("State", selection: $sealState) {
                        Text("Idle").tag(ManifestSealView.SealState.idle)
                        Text("Sealing").tag(ManifestSealView.SealState.sealing)
                        Text("Sealed").tag(ManifestSealView.SealState.sealed)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            Divider()

            // 2. VolumeArrivalPulse
            VStack(alignment: .leading, spacing: 6) {
                Text("2. VolumeArrivalPulse (Rail Available rows)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "sdcard.fill").foregroundStyle(Semantics.sourceText)
                        Text("CAM_A_ROLL04").font(.caption.monospaced())
                    }
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .volumeArrivalPulse(trigger: arrivalTrigger, color: Semantics.source)

                    Button("Trigger Mount Pulse") {
                        arrivalTrigger = UUID()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            // 3. MilestoneTicksOverlay
            VStack(alignment: .leading, spacing: 6) {
                Text("3. MilestoneTicksOverlay (JobHeaderBand & LaneTrack)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Semantics.running)
                            .frame(width: 280 * progress)
                        MilestoneTicksOverlay(fraction: progress)
                    }
                    .frame(width: 280, height: 8)

                    Slider(value: $progress, in: 0...1)
                        .frame(width: 280)
                }
            }

            Divider()

            // 4. EjectGlideView
            VStack(alignment: .leading, spacing: 6) {
                Text("4. EjectGlideView (SourceCard on clean eject)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    HStack {
                        Image(systemName: "sdcard.fill").foregroundStyle(Semantics.sourceText)
                        Text("SONY_FX6_A01").font(.caption.monospaced())
                    }
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .ejectGlide(isEjecting: isEjecting) {
                        isEjecting = false
                    }

                    Button(isEjecting ? "Ejecting..." : "Test Eject Glide") {
                        isEjecting = true
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            // 5. TopUpPourView
            VStack(alignment: .leading, spacing: 6) {
                Text("5. TopUpPourView (BenchCard continuation banner)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    TopUpPourView(existingFraction: topUpLevel, targetFraction: 0.85, isPouring: true)
                        .frame(width: 110, height: 36)
                        .background(Semantics.running.opacity(Semantics.wash), in: RoundedRectangle(cornerRadius: 8))

                    Slider(value: $topUpLevel, in: 0.1...0.8) {
                        Text("Existing")
                    }
                    .frame(width: 140)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
