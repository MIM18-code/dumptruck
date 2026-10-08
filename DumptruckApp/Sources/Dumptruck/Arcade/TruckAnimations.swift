import SwiftUI
import AppKit

//  TruckAnimations.swift
//  Two reusable truck animations built on the shipped hand-drawn logo
//  (Resources/logo.png, the raster of assets/dumptruck_logo_handdrawn.svg)
//  plus pure-SwiftUI shapes and Canvas particles. No third-party code,
//  no network, no NSImage work off the main actor.
//
//    TruckDrivingView(speed:load:)     ambient loop while a transfer RUNS
//    TruckDumpView(onComplete:)        one-shot ~2.5s COMPLETION
//
//  (TruckSadView, the one-shot FAILURE mascot, was removed with the
//  2026-08-26 facelift: a cartoon never shares a frame with an alarm.)
//
//  Both pause their TimelineView when the view disappears, when the
//  window is occluded, when the scene is not active, and when Reduce Motion
//  is on. The one-shot's completion timer is cancelled in .onDisappear, and
//  it clamps to its resting frame once finished, so a pause that outlives
//  the timer can never leave a mascot frozen mid-flight.
//
//  Both are .accessibilityHidden — they are decoration. The verdict is
//  announced by VerdictBadge and the proof line; the fun layer never becomes
//  a second source of safety truth.

// MARK: - Palette (sampled from dumptruck_logo_handdrawn.svg)

private enum Ink {
    // The mascot's outline and body ARE the brand pair — reference the Brand
    // tokens so a logo recolor can't silently strand the sprite on old values
    // (2026-08-28 color audit found these duplicated by value).
    static let line   = Brand.ink                                      // #2A2118
    static let body   = Brand.amber                                    // #F2B03B
    static let bodyLo = Color(red: 0.878, green: 0.604, blue: 0.173)   // #E09A2C
    static let cream  = Color(red: 0.992, green: 0.953, blue: 0.863)   // #FDF3DC
    static let tyre   = Color(red: 0.200, green: 0.161, blue: 0.122)   // #33291F
    static let lamp   = Color(red: 0.769, green: 0.333, blue: 0.184)   // #C4552F
    static let dust   = Color(red: 0.72,  green: 0.66,  blue: 0.55)
    static let smoke  = Color(red: 0.55,  green: 0.55,  blue: 0.57)
    static let gravel = Color(red: 0.56,  green: 0.51,  blue: 0.45)

    /// One of four pebble tones, picked by a 0…1 noise value.
    static func pebble(_ v: Double) -> Color {
        switch v {
        case ..<0.25: return Color(red: 0.43, green: 0.39, blue: 0.35)
        case ..<0.50: return Color(red: 0.66, green: 0.61, blue: 0.54)
        case ..<0.75: return Color(red: 0.74, green: 0.70, blue: 0.64)
        default:      return Color(red: 0.50, green: 0.47, blue: 0.44)
        }
    }
}

// MARK: - Geometry of the artwork, in unit coordinates of the 1024² logo square
//
//  Landmarks are the SVG's own path coordinates put through that file's
//  transform="translate(-24,-52) rotate(-1.2 512 512)" and divided by 1024,
//  then checked against the rasterised logo (hub centres and the art's bounding
//  box agree to within a pixel). The two wheels do not share a centre-line:
//  the whole drawing is tilted 1.2°, which is the point of it.

private enum TG {
    static let frontWheel = CGPoint(x: 0.2929, y: 0.6392)
    static let rearWheel  = CGPoint(x: 0.7327, y: 0.6279)
    static let wheelR: CGFloat = 0.1235          // tyre + ink stroke + a hair
    static let hubR: CGFloat   = 0.0398
    static let ground: CGFloat = 0.757           // where the tyres meet the road
    static let engine  = CGPoint(x: 0.175, y: 0.487)   // top of the hood
    static let spout   = CGPoint(x: 0.918, y: 0.560)   // tailgate bottom corner
    static let bedHinge = UnitPoint(x: 0.905, y: 0.578)

    /// Outline of the bed (hook + front wall + top rail + tailgate + belly),
    /// cut between the cab's rear wall (ends 0.399) and the bed's front wall
    /// (starts 0.410), and stopped just above the chassis band (starts 0.582).
    static let bed: [CGPoint] = [
        CGPoint(x: 0.3500, y: 0.230),
        CGPoint(x: 0.9850, y: 0.399),
        CGPoint(x: 0.9850, y: 0.580),
        CGPoint(x: 0.4045, y: 0.580),
        CGPoint(x: 0.4045, y: 0.281),
        CGPoint(x: 0.3500, y: 0.281)
    ]

    /// The load heaped in the open bed. The top rail's upper ink edge was
    /// measured on the raster (y 0.247 at x 0.40, 0.397 at x 0.88); the heap
    /// is drawn BEHIND the art, so everything below the rail is hidden by the
    /// bed wall and only the mound above it shows.
    static let loadFront: CGFloat = 0.430
    static let loadBack: CGFloat  = 0.893
    static let loadMaxHeight: CGFloat = 0.13
    static func railTop(_ x: CGFloat) -> CGFloat { 0.247 + (x - 0.40) * 0.311 }
    /// Mound surface for a heap of height `h` (unit lengths).
    static func loadSurface(_ x: CGFloat, height h: CGFloat) -> CGFloat {
        let u = min(max((x - loadFront) / (loadBack - loadFront), 0), 1)
        let lumps = 1 + 0.07 * sin(Double(u) * 19 + 0.6) + 0.05 * sin(Double(u) * 41)
        let bump = pow(sin(Double(u) * .pi), 0.75) * lumps
        return railTop(x) + 0.012 - h * CGFloat(bump)
    }
}

// MARK: - Layout: fit the *drawn* content, not the artwork's empty margins
//
//  The logo's ink only occupies x 0.078–0.921, y 0.241–0.757 of its square, so
//  fitting the square wastes half the height. Instead we fit a stage box that
//  holds the truck plus the room the animations need: headroom for the raised
//  bed, a lane on the right for the dumped pile, and a strip under the tyres
//  for road dust. Nothing any of these views draws leaves that box, so it
//  never clips, at any aspect ratio.

private struct TruckLayout {
    /// Where the full 1024² artwork square lands. Its transparent margins may
    /// hang outside the view; nothing is drawn in them.
    let art: CGRect

    /// stage, in artwork-unit coordinates
    private static let sx: CGFloat = 0.06, sy: CGFloat = 0.05
    private static let sw: CGFloat = 1.03, sh: CGFloat = 0.74

    init(in size: CGSize) {
        let scale = max(1, min(size.width / Self.sw, size.height / Self.sh))
        let ox = (size.width  - Self.sw * scale) / 2
        let oy = (size.height - Self.sh * scale) / 2
        art = CGRect(x: ox - Self.sx * scale, y: oy - Self.sy * scale,
                     width: scale, height: scale)
    }

    /// unit point in artwork space → view point
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: art.minX + x * art.width, y: art.minY + y * art.height)
    }
    /// unit length → points
    func len(_ v: CGFloat) -> CGFloat { v * art.width }
}

// MARK: - The artwork itself

private enum TruckAsset {
    /// logo.png is copied into Contents/Resources by make_app.sh. Loaded once.
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// The truck, filling its frame. Falls back to a hand-shaped SwiftUI drawing
/// when the bundle has no logo.png (unit tests, `swift run` outside the .app).
private struct TruckArt: View {
    @ViewBuilder
    var body: some View {
        if let img = TruckAsset.logo {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            FallbackTruck()
        }
    }
}

private struct FallbackTruck: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
                Path(CGRect(x: x0 * w, y: y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h))
            }
            let stroke = StrokeStyle(lineWidth: w * 0.015, lineCap: .round, lineJoin: .round)

            var cab = Path()
            cab.move(to: p(0.13, 0.70))
            cab.addLine(to: p(0.13, 0.51))
            cab.addLine(to: p(0.25, 0.49))
            cab.addLine(to: p(0.26, 0.35))
            cab.addLine(to: p(0.40, 0.34))
            cab.addLine(to: p(0.41, 0.70))
            cab.closeSubpath()

            var bed = Path()
            bed.move(to: p(0.42, 0.29))
            bed.addLine(to: p(0.93, 0.42))
            bed.addLine(to: p(0.93, 0.58))
            bed.addLine(to: p(0.42, 0.58))
            bed.closeSubpath()

            let frame = rect(0.12, 0.58, 0.95, 0.648)

            for shape in [frame, bed, cab] {
                ctx.fill(shape, with: .color(Ink.body))
                ctx.stroke(shape, with: .color(Ink.line), style: stroke)
            }
            ctx.fill(rect(0.29, 0.385, 0.39, 0.465), with: .color(Ink.cream))
            ctx.stroke(rect(0.29, 0.385, 0.39, 0.465), with: .color(Ink.line),
                       style: StrokeStyle(lineWidth: w * 0.011))

            let lampR = w * 0.021, lamp = p(0.125, 0.509)
            let lampBox = CGRect(x: lamp.x - lampR, y: lamp.y - lampR,
                                 width: lampR * 2, height: lampR * 2)
            ctx.fill(Path(ellipseIn: lampBox), with: .color(Ink.lamp))
            ctx.stroke(Path(ellipseIn: lampBox), with: .color(Ink.line),
                       style: StrokeStyle(lineWidth: w * 0.009))

            for c in [TG.frontWheel, TG.rearWheel] {
                let o = p(c.x, c.y)
                func circle(_ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: o.x - r * w, y: o.y - r * w,
                                           width: r * 2 * w, height: r * 2 * w))
                }
                ctx.fill(circle(TG.wheelR - 0.008), with: .color(Ink.tyre))
                ctx.stroke(circle(TG.wheelR - 0.008), with: .color(Ink.line), style: stroke)
                ctx.fill(circle(TG.hubR), with: .color(Ink.cream))
                ctx.stroke(circle(TG.hubR), with: .color(Ink.line),
                           style: StrokeStyle(lineWidth: w * 0.011))
                ctx.fill(circle(0.014), with: .color(Ink.line))
            }
        }
    }
}

// MARK: - Masks used to hinge the bed
//
//  The logo is one flat raster, so tipping the bed means splitting it:
//    · body   = everything except the bed, with the rear wheel added back
//    · bed    = the bed polygon, hinged at the tailgate
//  and — because the rear tyre is drawn *in front of* the bed's belly —
//  the bed layer is masked a second time AFTER rotating, in screen space, so
//  the raised bed is correctly occluded by the wheel instead of dragging a
//  lens of tyre pixels up with it.

private func bedPath(in r: CGRect) -> Path {
    var p = Path()
    for (i, u) in TG.bed.enumerated() {
        let q = CGPoint(x: r.minX + u.x * r.width, y: r.minY + u.y * r.height)
        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
    }
    p.closeSubpath()
    return p
}

private func rearWheelPath(in r: CGRect) -> Path {
    let c = CGPoint(x: r.minX + TG.rearWheel.x * r.width, y: r.minY + TG.rearWheel.y * r.height)
    let rr = TG.wheelR * r.width
    return Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
}

private struct BedShape: Shape {
    func path(in r: CGRect) -> Path { bedPath(in: r) }
}

/// Everything but the bed — the rear wheel is punched back in so the tyre
/// stays whole when the bed lifts away from it.
private struct BodyMinusBedShape: Shape {
    func path(in r: CGRect) -> Path {
        Path(r).subtracting(bedPath(in: r).subtracting(rearWheelPath(in: r)))
    }
}

private struct WheelHoleShape: Shape {
    func path(in r: CGRect) -> Path { Path(r).subtracting(rearWheelPath(in: r)) }
}

/// Flat colour behind the bed raster, so the wheel-shaped hole cut out of the
/// bed layer reads as painted bed instead of a bite of background. Sized to the
/// wheel's lens only (x 0.61–0.86, y 0.51–0.58) with margin, so it can never
/// spill past the tailgate or above the top rail. Colours are the logo's own.
private struct BellyPatch: View {
    var body: some View {
        Canvas { ctx, size in
            func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
                Path(CGRect(x: x0 * size.width, y: y0 * size.height,
                            width: (x1 - x0) * size.width, height: (y1 - y0) * size.height))
            }
            ctx.fill(rect(0.590, 0.450, 0.880, 0.535), with: .color(Ink.body))
            ctx.fill(rect(0.590, 0.535, 0.880, 0.573), with: .color(Ink.bodyLo))
            ctx.fill(rect(0.590, 0.566, 0.880, 0.581), with: .color(Ink.line))
            // the bed's rear rib, which the wheel would otherwise bite in half
            ctx.fill(rect(0.7485, 0.450, 0.7555, 0.547), with: .color(Ink.line.opacity(0.85)))
        }
    }
}

// MARK: - Small maths helpers

private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
private func frac(_ v: Double) -> Double { v - floor(v) }
private func easeOut(_ v: Double) -> Double { 1 - pow(1 - clamp01(v), 3) }
private func easeInOut(_ v: Double) -> Double {
    let t = clamp01(v)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

/// Deterministic per-particle noise — same frame every run, no allocation.
private func rnd(_ i: Int, _ salt: Int) -> Double {
    var h = UInt64(truncatingIfNeeded: i &* 0x9E3779B1) &+ UInt64(truncatingIfNeeded: salt &* 0x85EBCA6B)
    h ^= h >> 30; h = h &* 0xBF58476D1CE4E5B9
    h ^= h >> 27; h = h &* 0x94D049BB133111EB
    h ^= h >> 31
    return Double(h & 0xFF_FFFF) / Double(0xFF_FFFF)
}

private func rotate(_ p: CGPoint, about c: CGPoint, degrees: Double) -> CGPoint {
    let a = degrees * .pi / 180                 // positive = clockwise on screen
    let dx = p.x - c.x, dy = p.y - c.y
    return CGPoint(x: c.x + dx * CGFloat(cos(a)) - dy * CGFloat(sin(a)),
                   y: c.y + dx * CGFloat(sin(a)) + dy * CGFloat(cos(a)))
}

/// A hand-drawn-looking checkmark, centred, `size` tall, in unit-free points.
private func checkPath(at c: CGPoint, size: CGFloat, degrees: Double) -> Path {
    let pts = [CGPoint(x: -0.42, y: 0.02), CGPoint(x: -0.13, y: 0.33), CGPoint(x: 0.44, y: -0.34)]
    let a = degrees * .pi / 180
    var p = Path()
    for (i, u) in pts.enumerated() {
        let x = u.x * size, y = u.y * size
        let q = CGPoint(x: c.x + x * CGFloat(cos(a)) - y * CGFloat(sin(a)),
                        y: c.y + x * CGFloat(sin(a)) + y * CGFloat(cos(a)))
        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
    }
    return p
}

// MARK: - Shared "is this thing on screen" gate

/// Drives `paused:` on every TimelineView here. Cheap: three booleans and one
/// notification subscription that SwiftUI tears down on disappear.
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

// MARK: - 1. TruckDrivingView — ambient loop for a RUNNING transfer

/// Gentle suspension bounce, road dust drifting back from the wheels, a few
/// speed lines streaming past, and a bed that fills as the card comes aboard:
/// gravel and data bits drop in from above and heap up in the bed.
/// It used to be an empty truck bobbing along (Joshua, 2026-09-28: "maybe
/// it's collecting gravel or bytes"). Loopable, ~30fps, ~60 particles.
///
/// - Parameter speed: 0…1. Scales bounce rate/amplitude, dust emission rate and
///   drift, speed-line density, and how thick the pour into the bed is. Feed
///   it the transfer's throughput, normalised (e.g. `min(1, MB/s / 400)`).
///   At 0 nothing pours: no bytes, no gravel.
/// - Parameter load: 0…1, the share of the card already aboard. Sets the
///   heap's height. Decoration only; the numbers stay in the text.
struct TruckDrivingView: View {
    var speed: Double = 0.6
    var load: Double = 0

    @State private var epoch = Date()
    @State private var awake = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = clamp01(speed)
        let l = clamp01(load)
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !awake || reduceMotion)) { tl in
                let t = reduceMotion ? 0 : tl.date.timeIntervalSince(epoch)
                let layout = TruckLayout(in: geo.size)

                // suspension: a primary bob plus a faster harmonic, and a hair
                // of body roll pivoting on the rear axle
                let f = 1.15 + 1.85 * s
                let amp = 0.004 + 0.011 * s
                let bob = reduceMotion ? 0
                    : (sin(2 * .pi * f * t) * amp + sin(2 * .pi * f * 2.17 * t + 0.7) * amp * 0.35)
                let roll = reduceMotion ? 0 : sin(2 * .pi * f * t + 1.1) * (0.25 + 0.75 * s)

                ZStack {
                    Canvas { ctx, size in
                        guard !reduceMotion else { return }
                        drawRoadFX(ctx, TruckLayout(in: size), t: t, s: s)
                    }
                    .allowsHitTesting(false)

                    // The load rides the truck: heap and pour share its bob
                    // and roll, and the heap sits behind the art so the bed
                    // wall hides everything below the rail.
                    ZStack {
                        Canvas { ctx, size in
                            drawLoad(ctx, size: size, load: l, t: t, s: s,
                                     pouring: !reduceMotion)
                        }
                        .allowsHitTesting(false)
                        TruckArt()
                    }
                    .frame(width: layout.art.width, height: layout.art.height)
                    .rotationEffect(.degrees(roll),
                                    anchor: UnitPoint(x: TG.rearWheel.x, y: TG.rearWheel.y))
                    .offset(y: layout.len(CGFloat(bob)))
                    .position(x: layout.art.midX, y: layout.art.midY)
                }
            }
        }
        .visibilityGate($awake)
        .onAppear { epoch = Date() }
        .accessibilityHidden(true)
    }
}

/// Speed lines, ground streaks and wheel dust. The truck faces left, so
/// everything trails to the right.
private func drawRoadFX(_ ctx: GraphicsContext, _ L: TruckLayout, t: Double, s: Double) {
    let linePeriod = 0.95 - 0.50 * s
    for j in 0..<7 {
        let ph = frac(t / linePeriod + rnd(j, 11))
        let onGround = j >= 4
        let y = CGFloat(onGround ? 0.772 + 0.012 * rnd(j, 12)
                                 : 0.310 + 0.400 * rnd(j, 13))
        let x0 = CGFloat(onGround ? 0.95 * ph : 0.20 + 0.75 * ph)
        let len = CGFloat(0.05 + 0.09 * rnd(j, 14) + 0.07 * s)
        let alpha = sin(.pi * ph) * (onGround ? 0.10 + 0.28 * s : 0.07 + 0.26 * s)

        var p = Path()
        p.move(to: L.pt(x0, y))
        p.addLine(to: L.pt(x0 + len, y))
        ctx.stroke(p, with: .color(Color.primary.opacity(alpha)),
                   style: StrokeStyle(lineWidth: L.len(onGround ? 0.010 : 0.007), lineCap: .round))
    }

    let puffPeriod = 1.25 - 0.55 * s
    for i in 0..<8 {
        let ph = frac(t / puffPeriod + rnd(i, 21))
        let origin = (i % 2 == 0) ? TG.rearWheel.x : TG.frontWheel.x
        let jitter = CGFloat(rnd(i, 22) - 0.5) * 0.03
        let x = origin + jitter + CGFloat(ph) * CGFloat(0.09 + 0.20 * s)
        let y = TG.ground - 0.004 - CGFloat(ph) * CGFloat(0.030 + 0.050 * rnd(i, 23))
        let r = CGFloat(0.010 + 0.038 * ph) * CGFloat(0.7 + 0.6 * rnd(i, 24))
        let alpha = pow(1 - ph, 1.7) * min(1, ph * 8) * (0.20 + 0.28 * s)

        let a = L.pt(x, y), ra = L.len(r)
        ctx.fill(Path(ellipseIn: CGRect(x: a.x - ra, y: a.y - ra, width: ra * 2, height: ra * 2)),
                 with: .color(Ink.dust.opacity(alpha)))
        let b = L.pt(x + r * 0.9, y + r * 0.35), rb = ra * 0.62
        ctx.fill(Path(ellipseIn: CGRect(x: b.x - rb, y: b.y - rb, width: rb * 2, height: rb * 2)),
                 with: .color(Ink.dust.opacity(alpha * 0.8)))
    }
}

/// The load, in the ART's own unit square (the Canvas is exactly the art's
/// frame). A heap of gravel with data bits mixed in, and while bytes move,
/// pebbles and bits dropping in from above the frame to land on it.
/// Reduce Motion keeps the heap (it is the progress picture) and drops the
/// pour.
private func drawLoad(_ ctx: GraphicsContext, size: CGSize, load: Double,
                      t: Double, s: Double, pouring: Bool) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
    // The heap hides behind logo.png's opaque bed wall. FallbackTruck (no
    // bundle art) has no such wall, so it hauls nothing.
    guard TruckAsset.logo != nil else { return }
    let unit = size.width
    // A gentle curve so the first fifth of a copy already shows a mound at
    // the job card's ~56 pt art size.
    let height = TG.loadMaxHeight * CGFloat(pow(load, 0.6))

    func piece(_ i: Int, at c: CGPoint, radius r: CGFloat, alpha: Double) {
        if i % 5 == 0 {
            // A byte in the gravel: a small rounded square in the running tint.
            let side = r * 0.8
            let box = CGRect(x: c.x - side, y: c.y - side, width: side * 2, height: side * 2)
            ctx.fill(Path(roundedRect: box, cornerRadius: side * 0.35),
                     with: .color(Semantics.running.opacity(0.75 * alpha)))
        } else {
            let box = CGRect(x: c.x - r * 1.2, y: c.y - r, width: r * 2.4, height: r * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(Ink.pebble(rnd(i, 54)).opacity(alpha)))
        }
    }

    if height > 0.004 {
        var mound = Path()
        let steps = 32
        mound.move(to: pt(TG.loadFront, TG.railTop(TG.loadFront) + 0.05))
        for k in 0...steps {
            let x = TG.loadFront + (TG.loadBack - TG.loadFront) * CGFloat(k) / CGFloat(steps)
            mound.addLine(to: pt(x, TG.loadSurface(x, height: height)))
        }
        mound.addLine(to: pt(TG.loadBack, TG.railTop(TG.loadBack) + 0.05))
        mound.closeSubpath()
        ctx.fill(mound, with: .color(Ink.gravel))
        ctx.stroke(mound, with: .color(Ink.line.opacity(0.55)),
                   style: StrokeStyle(lineWidth: unit * 0.008, lineJoin: .round))

        // Pebbles and bits embedded in the heap. Fixed slots: the heap only
        // grows, so a pebble never jumps as the load rises.
        for i in 0..<40 {
            let x = TG.loadFront + 0.02 + (TG.loadBack - TG.loadFront - 0.04) * CGFloat(rnd(i, 51))
            let top = TG.loadSurface(x, height: height)
            let base = TG.railTop(x) + 0.01
            guard base - top > 0.014 else { continue }
            let y = top + 0.012 + (base - top - 0.012) * CGFloat(rnd(i, 52))
            let r = CGFloat(0.010 + 0.009 * rnd(i, 53)) * unit
            piece(i, at: pt(x, y), radius: r, alpha: 1)
        }
    }

    guard pouring, s > 0.01 else { return }
    let period = 0.95 - 0.45 * s
    for i in 0..<12 {
        // Thicker pour at higher throughput.
        guard rnd(i, 40) < 0.25 + 0.75 * s else { continue }
        let cycle = t / period + rnd(i, 41)
        let ph = frac(cycle)
        let lap = Int(floor(cycle))
        let land = TG.loadFront + 0.06
            + (TG.loadBack - TG.loadFront - 0.12) * CGFloat(rnd(i &* 131 &+ lap, 43))
        // From the top edge of the stage, drifting a little aft as it falls
        // (the truck is driving left), accelerating into the heap.
        let startX = land + 0.03 + 0.03 * CGFloat(rnd(i, 44))
        let startY: CGFloat = 0.05
        let endY = TG.loadSurface(land, height: height) - 0.006
        let x = startX + (land - startX) * CGFloat(ph)
        let y = startY + (endY - startY) * CGFloat(ph * ph)
        let r = CGFloat(0.010 + 0.007 * rnd(i, 45)) * unit
        let alpha = min(1, (1 - ph) * 8) * min(1, ph * 6)
        piece(i, at: pt(x, y), radius: r, alpha: alpha)
    }
}

// MARK: - 2. TruckDumpView — one-shot COMPLETION (~2.5s)

/// The bed hinges up on the tailgate and pours a stream of green checkmarks
/// into a neat pile, then settles back. Fires once per view identity, so drive
/// it with `.id(job.id)` (or any token that changes when a job completes).
///
/// - Parameter checkCount: how many checkmarks land in the pile (default 15).
/// - Parameter onComplete: called once, on the main actor, at ~2.5s.
struct TruckDumpView: View {
    var checkCount: Int = 15
    var onComplete: (() -> Void)? = nil

    static let duration: Double = 2.5

    @State private var epoch = Date()
    @State private var awake = false
    @State private var finished = false
    @State private var timer: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                    paused: !awake || finished || reduceMotion)) { tl in
                // `paused:` pins tl.date at the instant it paused (measured), so a
                // one-shot that finished while occluded would render its mid-flight
                // frame forever — bed stuck at 22°, checkmarks hanging in the air —
                // and the call site's `.id(job.id)` never re-runs it. Clamp to the
                // resting frame the moment `finished` latches, exactly as the
                // reduce-motion path already proves is renderable.
                let p = (reduceMotion || finished) ? Self.duration
                                                   : tl.date.timeIntervalSince(epoch)
                let layout = TruckLayout(in: geo.size)

                let tilt = bedTilt(p)

                ZStack {
                    DumpBody(layout: layout, tilt: tilt, bob: CGFloat(bodyBob(p)))
                    Canvas { ctx, size in
                        drawPour(ctx, TruckLayout(in: size),
                                 p: p, tilt: tilt, count: max(1, checkCount))
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .visibilityGate($awake)
        .onAppear {
            epoch = Date()
            finished = false
            timer?.cancel()
            let wait = reduceMotion ? 0.35 : Self.duration
            timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                finished = true
                onComplete?()
            }
        }
        .onDisappear {
            timer?.cancel()
            timer = nil
        }
        // Decoration only — the verdict is announced by VerdictBadge and the
        // inline proof line, both read from Job.verdict. A label here would be a
        // second, independent source of verdict truth that no longer tracks the
        // job, so the mascot stays hidden the way TruckDrivingView is. The call
        // site's own .accessibilityHidden is belt-and-braces, not the contract.
        .accessibilityHidden(true)
    }

    /// 0 → 22° up over 0.7s, a held quiver with gravel-shift harmonic at the top, back down by 2.30s.
    private func bedTilt(_ p: Double) -> Double {
        if reduceMotion { return 0 }
        let top = 22.0
        switch p {
        case ..<0.15:  return 0
        case ..<0.85:  return top * easeOut((p - 0.15) / 0.70)
        case ..<1.85:
            let quiver = sin((p - 0.85) * 5.0) * 0.45
            let gravelShift = sin((p - 0.85) * 12.0) * 0.15 * max(0, 1.0 - (p - 0.85))
            return top + quiver + gravelShift
        case ..<2.30:  return top * (1 - easeInOut((p - 1.85) / 0.45))
        default:       return 0
        }
    }

    /// A squat as it braces, and a small settle once the bed comes home.
    private func bodyBob(_ p: Double) -> Double {
        if reduceMotion { return 0 }
        if p < 0.18 { return sin(p / 0.18 * .pi) * 0.009 }
        if p >= 2.28 && p < 2.50 {
            let u = (p - 2.28) / 0.22
            return sin(u * .pi * 2) * 0.007 * (1 - u)
        }
        return 0
    }
}

/// Truck with a hinged bed. Falls back to the plain artwork while level, so we
/// only pay for the three masks during the actual tip.
private struct DumpBody: View {
    let layout: TruckLayout
    let tilt: Double
    let bob: CGFloat

    var body: some View {
        Group {
            if tilt < 0.05 {
                TruckArt()
            } else {
                ZStack {
                    TruckArt()
                        .mask { BodyMinusBedShape().fill() }

                    ZStack {
                        BellyPatch()
                        TruckArt().mask { WheelHoleShape().fill() }
                    }
                    .mask { BedShape().fill() }
                    .rotationEffect(.degrees(tilt), anchor: TG.bedHinge)
                    // second mask lands in *screen* space: the raised bed is
                    // occluded by the rear tyre, as it should be.
                    .mask { WheelHoleShape().fill() }
                }
            }
        }
        .frame(width: layout.art.width, height: layout.art.height)
        .offset(y: layout.len(bob))
        .position(x: layout.art.midX, y: layout.art.midY)
    }
}

/// Checkmarks leaving the tailgate on a parabola and stacking into a pile,
/// plus the pile's ground shadow and a puff of dust on the first landings.
private func drawPour(_ ctx: GraphicsContext, _ L: TruckLayout,
                      p: Double, tilt: Double, count: Int) {
    let rows = [6, 5, 4, 3]
    let markSize = L.len(0.052)
    let stroke = StrokeStyle(lineWidth: L.len(0.011), lineCap: .round, lineJoin: .round)
    let firstSpawn = 0.62, gap = 0.055, flight = 0.62

    // the tailgate corner rides the bed as it hinges (barely — it is the hinge)
    let spout = rotate(TG.spout,
                       about: CGPoint(x: TG.bedHinge.x, y: TG.bedHinge.y),
                       degrees: tilt)

    var landed = 0
    for i in 0..<count {
        let spawn = firstSpawn + Double(i) * gap
        guard p >= spawn else { continue }
        let u = clamp01((p - spawn) / flight)
        if u >= 1 { landed += 1 }

        // slot in the pile
        var idx = i, row = 0
        while row < rows.count - 1 && idx >= rows[row] { idx -= rows[row]; row += 1 }
        let n = rows[min(row, rows.count - 1)]
        let slot = CGPoint(
            x: 0.985 + (CGFloat(idx) - CGFloat(n - 1) / 2) * 0.036
                     + CGFloat(rnd(i, 31) - 0.5) * 0.010,
            y: TG.ground - 0.018 - CGFloat(row) * 0.030)

        let lift = CGFloat(0.02 + 0.03 * rnd(i, 32))
        let x = spout.x + (slot.x - spout.x) * CGFloat(u)
        let y = spout.y + (slot.y - spout.y) * CGFloat(u * u) - lift * CGFloat(sin(.pi * u))

        // pop on landing, then rest at a jaunty angle
        let settle = clamp01((p - spawn - flight) / 0.12)
        let scale: CGFloat = u < 1 ? 1.0 : CGFloat(1.22 - 0.22 * easeOut(settle))
        let angle = u < 1 ? u * 220 * (rnd(i, 33) > 0.5 ? 1.0 : -1.0)
                          : (rnd(i, 34) - 0.5) * 34

        ctx.stroke(checkPath(at: L.pt(x, y), size: markSize * scale, degrees: angle),
                   with: .color(Semantics.success.opacity(u < 1 ? 0.95 : 1.0)),
                   style: stroke)
    }

    guard landed > 0 else { return }
    let spread = CGFloat(min(1.0, Double(landed) / Double(max(count, 1))))
    let c = L.pt(0.985, TG.ground + 0.006)
    let w = L.len(0.075 + 0.075 * spread), h = L.len(0.016)
    ctx.fill(Path(ellipseIn: CGRect(x: c.x - w, y: c.y - h / 2, width: w * 2, height: h)),
             with: .color(Ink.line.opacity(0.16)))

    // dust kicked up by whatever landed in the last third of a second
    for i in 0..<count {
        let landAt = firstSpawn + Double(i) * gap + flight
        let age = p - landAt
        guard age >= 0, age < 0.35 else { continue }
        let ph = age / 0.35
        let r = L.len(CGFloat(0.010 + 0.030 * ph))
        let o = L.pt(0.985 + CGFloat(rnd(i, 35) - 0.5) * 0.10,
                     TG.ground - 0.010 - CGFloat(ph) * 0.030)
        ctx.fill(Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: r * 2, height: r * 2)),
                 with: .color(Ink.dust.opacity((1 - ph) * 0.30)))
    }
}

// MARK: - Manual gallery (handy while tuning; not referenced by the app)

struct TruckAnimationGallery: View {
    @State private var run = 0

    var body: some View {
        VStack(spacing: 12) {
            TruckDrivingView(speed: 0.85, load: 0.6).frame(height: 150)
            TruckDumpView { }.id("dump\(run)").frame(height: 150)
            Button("Replay one-shots") { run += 1 }
        }
        .padding()
        .frame(width: 380)
    }
}
