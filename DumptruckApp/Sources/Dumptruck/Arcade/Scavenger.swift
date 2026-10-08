import SwiftUI
import AppKit

// MARK: - Model

/// What lies around the yard. Each kind is worth a fixed number of points
/// while it rides in the bed; nothing counts until it is dumped at the bay.
private enum ScrapKind: Int, CaseIterable {
    case clip, frame, card, drive

    var symbol: String {
        switch self {
        case .clip: return "film.fill"
        case .frame: return "photo.fill"
        case .card: return "sdcard.fill"
        case .drive: return "externaldrive.fill"
        }
    }

    var points: Int {
        switch self {
        case .clip: return 10
        case .frame: return 15
        case .card: return 25
        case .drive: return 60
        }
    }

    /// Game ART, so the vibrant tokens (SemanticColors.swift's rule of use).
    /// Red and orange are kept for hazards: nothing worth picking up may wear
    /// the colour of the thing that scrambles the load.
    var color: Color {
        switch self {
        case .clip: return Semantics.source
        case .frame: return Semantics.destination
        case .card: return Semantics.running
        case .drive: return Semantics.success
        }
    }
}

private struct ScrapPiece: Identifiable {
    let id = UUID()
    var pos: CGPoint
    let kind: ScrapKind
    /// Seconds left before a rare piece is gone. nil = stays until collected.
    var ttl: CGFloat?
}

/// A corrupted-data bug wandering the yard. Touching one scrambles half the
/// load back out onto the ground.
private struct ScrapBug: Identifiable {
    let id = UUID()
    var pos: CGPoint
    var dir: CGFloat              // heading, radians, screen space (y down)
    var turn: CGFloat = 0         // current turn rate, rad/s
    var turnClock: CGFloat = 0    // seconds until a new turn rate is rolled
}

private struct ScrapPuddle {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat

    func contains(_ p: CGPoint) -> Bool {
        let dx = (p.x - center.x) / rx
        let dy = (p.y - center.y) / ry
        return dx * dx + dy * dy <= 1
    }
}

/// Dust (or a mud splash) kicked up behind the truck. Purely cosmetic; never
/// emitted under Reduce Motion.
private struct ScrapPuff {
    var pos: CGPoint
    var r: CGFloat
    var life: CGFloat             // 1 -> 0
    let mud: Bool
}

/// A "+N" that lifts off a pickup or the bay. Aged by the same tick as the
/// yard, like GravelDrop's pops, so Reduce Motion drops the drift without a
/// second clock.
private struct ScrapPop: Identifiable {
    enum Tone { case gain, bank, loss }
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var life: CGFloat             // 1 -> 0
    let text: String
    let tone: Tone

    /// Text, so the *Text tokens (AA on the yard ground in both modes).
    var color: Color {
        switch tone {
        case .gain: return Semantics.successText
        case .bank: return Semantics.runningText
        case .loss: return Semantics.dangerText
        }
    }
}

/// One piece of the load arcing from the tailgate onto the heap during a
/// dump. `t` runs 0 -> 1; negative values are the stagger before launch.
private struct ScrapFlyer {
    let from: CGPoint
    let to: CGPoint
    var t: CGFloat
    let kind: ScrapKind
}

private enum ScavengerPhase { case ready, playing, over }

private enum ScavengerTuning {
    static let capacity = 8                      // loads per bed; hoisted so the
                                                 // HUD pips, the bed grid and
                                                 // the pickup gate agree.

    // MARK: Truck geometry, measured against the DRAWN INK
    //
    // ScavengerRig draws a top-down truck facing +x inside a 56x32 frame:
    // bed and cab span x 2...54 and y 3...29, the tyres poke out to y 0...32.
    // Every box below is in the truck's LOCAL frame (rotated with it), so a
    // diagonal truck collides like the drawing, not like an axis-aligned box.
    static let truckLength: CGFloat = 56
    static let truckWidth: CGFloat = 32
    static let inkHalfLength: CGFloat = 26
    static let inkHalfWidth: CGFloat = 13

    static let scrapSize: CGFloat = 22
    /// Forgiveness belongs on the catch: a piece is scooped once its glyph
    /// touches the body plus 4 pt (GravelDrop's rule).
    static let pickupHalfLength: CGFloat = ScavengerTuning.inkHalfLength
        + ScavengerTuning.scrapSize / 2 + 4                                   // 41
    static let pickupHalfWidth: CGFloat = ScavengerTuning.inkHalfWidth
        + ScavengerTuning.scrapSize / 2 + 4                                   // 28
    /// ...and never on the damage. The bug's ink is ~7 pt in radius; only its
    /// 3 pt core counts, tested against a body box inset 3 pt, so a hit always
    /// shows the bug well inside the truck.
    static let bugSize: CGFloat = 16
    static let bugRadius: CGFloat = 8
    static let bugCore: CGFloat = 3
    static let damageInset: CGFloat = 3
    static let hitHalfLength: CGFloat = ScavengerTuning.inkHalfLength
        - ScavengerTuning.damageInset + ScavengerTuning.bugCore               // 26
    static let hitHalfWidth: CGFloat = ScavengerTuning.inkHalfWidth
        - ScavengerTuning.damageInset + ScavengerTuning.bugCore               // 13

    /// Truck centre stays this far from the walls (half width plus tyres
    /// plus a hair). The nose may overhang when it faces a wall; the field
    /// is clipped.
    static let wallMargin: CGFloat = 20

    // MARK: Driving
    static let truckSpeed: CGFloat = 180         // pt/s top speed on gravel
    static let mudFactor: CGFloat = 0.4          // top speed multiplier in a puddle
    static let grip: CGFloat = 7                 // velocity blend rate on gravel
    static let mudGrip: CGFloat = 3
    static let arriveRadius: CGFloat = 6         // click-to-drive stop distance
    static let brakeDistance: CGFloat = 48       // eases into a clicked point

    // MARK: Fuel is the round clock
    static let maxFuel: CGFloat = 40             // seconds of driving at 1x drain
    static let baseDrain: CGFloat = 1.0          // per second at kick-off
    static let maxDrain: CGFloat = 2.0
    static let drainRampSeconds: CGFloat = 150   // +1x drain over this long
    static let refuelPerPiece: CGFloat = 2.2
    static let fullLoadRefuel: CGFloat = 6
    static let hitFuel: CGFloat = 4
    static let lowFuel: CGFloat = 0.25           // HUD turns red below this fraction

    // MARK: Dumping
    static let dumpSeconds: CGFloat = 1.0        // bed up, load out, bed down
    static let calmDumpSeconds: CGFloat = 0.35   // Reduce Motion: no tip, short beat
    static let flyerSpeed: CGFloat = 2.2         // t units per second
    static let flyerStagger: CGFloat = 0.15      // t units between launches
    static let pileCap = 18                      // heap sprites kept in the bay

    // MARK: Salvage
    static let maxScrap = 8
    static let seedScrap = 6
    static let spawnInterval: CGFloat = 0.9
    static let driveTTL: CGFloat = 9

    // MARK: Hazards
    static let bugGrace: CGFloat = 6             // seconds before the first bug
    static let bugEvery: CGFloat = 20            // one more bug per this long
    static let maxBugs = 6
    static let bugBaseSpeed: CGFloat = 45
    static let bugSpeedRamp: CGFloat = 0.4       // pt/s gained per second played
    static let bugMaxSpeed: CGFloat = 105
    static let bugSeekRampSeconds: CGFloat = 220 // homing grows to 0.9 over this
    static let bugMaxSeek: CGFloat = 0.9
    static let bugBayGap: CGFloat = 14           // the dump is sanctuary
    static let knockback: CGFloat = 170
    static let invulnerableSeconds: CGFloat = 1.3
    static let basePuddles = 2
    static let puddleEvery: CGFloat = 40
    static let maxPuddles = 5

    // MARK: Juice (bounded)
    static let maxPuffs = 40
    static let maxPops = 12
    static let puffInterval: CGFloat = 0.07

    // MARK: Yard
    static let bayWidth: CGFloat = 104
    static let bayHeight: CGFloat = 78
    static let bayInset: CGFloat = 10
    static let gravelCount = 70

    static let cream = Color(red: 0.992, green: 0.953, blue: 0.863)   // TruckAnimations' Ink.cream
}

/// Deterministic per-index noise in 0...1 for the static gravel texture, so
/// the yard does not reshuffle on every frame and costs no allocation.
private func scavengerNoise(_ i: Int, _ salt: Int) -> CGFloat {
    var h = UInt64(truncatingIfNeeded: i &* 0x9E3779B1) &+ UInt64(truncatingIfNeeded: salt &* 0x85EBCA6B)
    h ^= h >> 30; h = h &* 0xBF58476D1CE4E5B9
    h ^= h >> 27; h = h &* 0x94D049BB133111EB
    h ^= h >> 31
    return CGFloat(h & 0xFF_FFFF) / CGFloat(0xFF_FFFF)
}

// MARK: - Truck sprite

/// The dump truck seen from above, facing +x. Canvas-drawn rather than the
/// logo raster: the logo is a side view, which cannot rotate to a heading,
/// and the top-down bed is where the load has to be seen piling up.
private struct ScavengerRig: View {
    let load: [ScrapKind]
    /// 0 level ... 1 fully raised. Tipping about the rear hinge foreshortens
    /// the bed toward the tailgate when seen from above.
    let bedLift: CGFloat

    var body: some View {
        Canvas { ctx, size in
            ScavengerRig.paint(ctx, size: size, load: load, lift: bedLift)
        }
        .frame(width: ScavengerTuning.truckLength, height: ScavengerTuning.truckWidth)
    }

    private static func paint(_ ctx: GraphicsContext, size: CGSize,
                              load: [ScrapKind], lift: CGFloat) {
        let sx = size.width / ScavengerTuning.truckLength
        let sy = size.height / ScavengerTuning.truckWidth
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(x: x0 * sx, y: y0 * sy, width: (x1 - x0) * sx, height: (y1 - y0) * sy)
        }
        let line = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

        // Contact shadow, offset down-right.
        ctx.fill(Path(roundedRect: box(3, 5, 56, 32), cornerRadius: 5),
                 with: .color(Color.black.opacity(0.16)))

        // Tyres first, so the body overlaps their inner halves.
        for (x0, x1) in [(CGFloat(8), CGFloat(17)), (CGFloat(40), CGFloat(49))] {
            for (y0, y1) in [(CGFloat(0), CGFloat(5)), (CGFloat(27), CGFloat(32))] {
                ctx.fill(Path(roundedRect: box(x0, y0, x1, y1), cornerRadius: 1.5),
                         with: .color(Brand.ink))
            }
        }

        // Bed, hinged at the tailgate (x = 2).
        let bedScale = 1 - 0.3 * max(0, min(1, lift))
        let bed = box(2, 3, 2 + 34 * bedScale, 29)
        let bedPath = Path(roundedRect: bed, cornerRadius: 3)
        ctx.fill(bedPath, with: .color(Brand.amber))
        ctx.stroke(bedPath, with: .color(Brand.ink), style: line)
        let tray = box(5, 6, 5 + 28 * bedScale, 26)
        ctx.fill(Path(roundedRect: tray, cornerRadius: 2), with: .color(Brand.ink.opacity(0.78)))

        // The load: a 4 x 2 grid filling from the cab end toward the
        // tailgate, so the last piece in is the first one out on a dump.
        let cols = 4, rows = 2
        let gap: CGFloat = 1.4
        let cw = (tray.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let ch = (tray.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        if cw > 0, ch > 0 {
            for (i, kind) in load.prefix(cols * rows).enumerated() {
                let col = cols - 1 - i / rows
                let row = i % rows
                let cell = CGRect(x: tray.minX + gap + CGFloat(col) * (cw + gap),
                                  y: tray.minY + gap + CGFloat(row) * (ch + gap),
                                  width: cw, height: ch)
                ctx.fill(Path(roundedRect: cell, cornerRadius: 1.2), with: .color(kind.color))
                ctx.fill(Path(CGRect(x: cell.minX, y: cell.minY,
                                     width: cell.width, height: max(1, cell.height * 0.3))),
                         with: .color(Color.white.opacity(0.28)))
            }
        }
        if lift > 0 {
            // A raised bed is nearer the camera: lift it with light.
            ctx.fill(bedPath, with: .color(Color.white.opacity(0.18 * Double(lift))))
        }

        // Hitch, cab, windscreen, lamps.
        ctx.fill(Path(box(35.5, 13, 38.5, 19)), with: .color(Brand.ink))
        let cab = Path(roundedRect: box(38, 4, 54, 28), cornerRadius: 5)
        ctx.fill(cab, with: .color(Brand.amber))
        ctx.stroke(cab, with: .color(Brand.ink), style: line)
        let screen = Path(roundedRect: box(46, 7, 50.5, 25), cornerRadius: 1.5)
        ctx.fill(screen, with: .color(ScavengerTuning.cream))
        ctx.stroke(screen, with: .color(Brand.ink), lineWidth: 0.8)
        for y in [CGFloat(8), CGFloat(24)] {
            ctx.fill(Path(ellipseIn: box(52.2, y - 1.6, 55.4, y + 1.6)),
                     with: .color(ScavengerTuning.cream))
        }
    }
}

// MARK: - Primary view

struct ScavengerView: View {
    /// ArcadeSheet gates the game on this rather than swapping it out of the
    /// tree, so an app switch never wipes a run (Opus games review, CRITICAL,
    /// the same contract GravelDrop and Convoy keep). Nothing advances, rings
    /// or steers while it is true, and the clock resumes without a jump.
    let paused: Bool

    @AppStorage("arcade.scavenger.best") private var best: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: ScavengerPhase = .ready
    @State private var scraps: [ScrapPiece] = []
    @State private var bugs: [ScrapBug] = []
    @State private var puddles: [ScrapPuddle] = []
    @State private var puffs: [ScrapPuff] = []
    @State private var pops: [ScrapPop] = []
    @State private var flyers: [ScrapFlyer] = []
    /// The heap in the bay. Decoration: grows with every dump, capped.
    @State private var pile: [ScrapKind] = []

    @State private var truckPos: CGPoint = .zero
    @State private var vel: CGVector = .zero
    @State private var heading: CGFloat = 0
    /// Click-to-drive destination. Any arrow press cancels it.
    @State private var target: CGPoint? = nil
    // One flag per direction, never a shared tri-state: a key-agnostic `.up`
    // zeroed the drift when the OPPOSITE key was released while this one was
    // still held (GravelDrop, Opus games review, MAJOR).
    @State private var heldLeft = false
    @State private var heldRight = false
    @State private var heldUp = false
    @State private var heldDown = false

    @State private var load: [ScrapKind] = []
    /// The load in flight during a dump; banked when the bed comes down.
    @State private var pendingBank: [ScrapKind] = []
    @State private var score = 0                 // banked points only
    @State private var trips = 0
    @State private var fuel: CGFloat = ScavengerTuning.maxFuel
    /// Seconds of PLAY, accumulated from the clamped dt. The difficulty
    /// clock, so a pause can never age the run.
    @State private var elapsed: CGFloat = 0
    @State private var dumpTimer: CGFloat = 0
    @State private var invulnerable: CGFloat = 0
    @State private var spawnClock: CGFloat = 0
    @State private var puffClock: CGFloat = 0
    @State private var damageFlash: Double = 0
    @State private var bedBounce: CGFloat = 0
    @State private var endedAt: Date? = nil
    @State private var fieldSize: CGSize = .zero
    /// @Environment read inside the Timer closure freezes at ticker-creation
    /// time; @State goes through a box and stays live (Convoy's pattern).
    @State private var calmMotion = false
    /// The record as it stood when this run began. `best` is committed on
    /// every bank, so comparing against it at the end would always read
    /// "new best" (GravelDrop's rule).
    @State private var bestAtStart = 0
    @State private var lastTick: Date? = nil
    @State private var ticker: Timer? = nil

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            field
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // One handler per direction and phase. `.handled` even while paused,
        // never `.ignored`: an ignored arrow walks up to the sheet's
        // segmented picker and swaps the game out from under the run.
        .onKeyPress(keys: [.leftArrow, KeyEquivalent("a")], phases: [.down, .repeat]) { _ in
            if !paused { heldLeft = true }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, KeyEquivalent("a")], phases: .up) { _ in
            heldLeft = false; return .handled
        }
        .onKeyPress(keys: [.rightArrow, KeyEquivalent("d")], phases: [.down, .repeat]) { _ in
            if !paused { heldRight = true }
            return .handled
        }
        .onKeyPress(keys: [.rightArrow, KeyEquivalent("d")], phases: .up) { _ in
            heldRight = false; return .handled
        }
        .onKeyPress(keys: [.upArrow, KeyEquivalent("w")], phases: [.down, .repeat]) { _ in
            if !paused { heldUp = true }
            return .handled
        }
        .onKeyPress(keys: [.upArrow, KeyEquivalent("w")], phases: .up) { _ in
            heldUp = false; return .handled
        }
        .onKeyPress(keys: [.downArrow, KeyEquivalent("s")], phases: [.down, .repeat]) { _ in
            if !paused { heldDown = true }
            return .handled
        }
        .onKeyPress(keys: [.downArrow, KeyEquivalent("s")], phases: .up) { _ in
            heldDown = false; return .handled
        }
        .onKeyPress(.space) {
            if !paused, phase != .playing { begin() }
            return .handled
        }
        .onAppear {
            bestAtStart = best
            calmMotion = reduceMotion
            if !paused, phase == .playing { startTicker() }
            // Deferred: the sheet is still attaching when onAppear fires, and
            // `.onKeyPress` only reaches the focused view (GravelDrop).
            DispatchQueue.main.async { if !paused { focused = true } }
        }
        .onDisappear { stopTicker() }
        .onChange(of: reduceMotion) { _, new in
            calmMotion = new
            if new {
                // Nothing left hanging mid-air when the setting flips on:
                // in-flight pieces land on the heap at once.
                bedBounce = 0
                puffs.removeAll()
                for f in flyers where pile.count < ScavengerTuning.pileCap { pile.append(f.kind) }
                flyers.removeAll()
            }
        }
        .onChange(of: paused) { _, p in
            // A key held across the app switch never delivers its key-up,
            // and a click target from before the pause is stale.
            heldLeft = false
            heldRight = false
            heldUp = false
            heldDown = false
            target = nil
            if p {
                stopTicker()
                ArcadeSounds.stopAll()
            } else if phase == .playing || effectsPending {
                // startTicker() re-seeds lastTick, so the first tick after a
                // resume cannot see the pause as elapsed time.
                startTicker()
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    // MARK: Derived state

    private var loadValue: Int { load.reduce(0) { $0 + $1.points } }

    private var fuelFraction: CGFloat {
        max(0, min(1, fuel / ScavengerTuning.maxFuel))
    }

    private var drainRate: CGFloat {
        min(ScavengerTuning.maxDrain,
            ScavengerTuning.baseDrain + elapsed / ScavengerTuning.drainRampSeconds)
    }

    private var bugTarget: Int {
        guard elapsed >= ScavengerTuning.bugGrace else { return 0 }
        return min(ScavengerTuning.maxBugs,
                   1 + Int((elapsed - ScavengerTuning.bugGrace) / ScavengerTuning.bugEvery))
    }

    private var bugSpeed: CGFloat {
        min(ScavengerTuning.bugMaxSpeed,
            ScavengerTuning.bugBaseSpeed + elapsed * ScavengerTuning.bugSpeedRamp)
    }

    private var puddleTarget: Int {
        min(ScavengerTuning.maxPuddles,
            ScavengerTuning.basePuddles + Int(elapsed / ScavengerTuning.puddleEvery))
    }

    /// Decorative decay still owed a tick after the run ends.
    private var effectsPending: Bool {
        damageFlash > 0 || bedBounce > 0 || !pops.isEmpty || !puffs.isEmpty || !flyers.isEmpty
    }

    private var bayRect: CGRect { Self.yardBay(for: fieldSize) }

    private static func yardBay(for size: CGSize) -> CGRect {
        CGRect(x: ScavengerTuning.bayInset,
               y: size.height - ScavengerTuning.bayInset - ScavengerTuning.bayHeight,
               width: ScavengerTuning.bayWidth,
               height: ScavengerTuning.bayHeight)
    }

    /// Heap sprite positions inside the bay, bottom row first, bricked.
    private static func pileSlot(_ i: Int, bay: CGRect) -> CGPoint {
        let perRow = 6
        let row = i / perRow, col = i % perRow
        return CGPoint(x: bay.minX + 14 + CGFloat(col) * 9 + (row % 2 == 1 ? 4.5 : 0),
                       y: bay.maxY - 10 - CGFloat(row) * 8)
    }

    /// While dumping, the bed still shows the pieces that have not launched
    /// yet — the last ones in (nearest the tailgate) leave first.
    private var rigLoad: [ScrapKind] {
        guard load.isEmpty, !pendingBank.isEmpty else { return load }
        let waiting = flyers.filter { $0.t < 0 }.count
        return Array(pendingBank.prefix(waiting))
    }

    private var bedLift: CGFloat {
        guard dumpTimer > 0, !reduceMotion else { return 0 }
        let p = 1 - dumpTimer / ScavengerTuning.dumpSeconds
        return max(0, sin(p * .pi))
    }

    private var rigOpacity: Double {
        guard invulnerable > 0 else { return 1 }
        // Reduce Motion: a held dim, not a blink.
        if reduceMotion { return 0.55 }
        return Int(invulnerable * 12) % 2 == 0 ? 0.35 : 1
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("\(score)", systemImage: "shippingbox.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Semantics.successText)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: score)
                .accessibilityLabel("Banked")
                .accessibilityValue("\(score) points")
            bedGauge
            fuelGauge
            Spacer()
            // The record as it stood at kick-off, not the live `best`.
            Text("BEST \(bestAtStart)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("Best score")
                .accessibilityValue("\(bestAtStart)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35))
    }

    /// The bed, repeated in the HUD: one pip per slot in the piece's colour,
    /// and a FULL chip once it is time to head for the dump.
    private var bedGauge: some View {
        let full = load.count >= ScavengerTuning.capacity
        return HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<ScavengerTuning.capacity, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(pipFill(i))
                        .frame(width: 6, height: 10)
                }
            }
            Text(full ? "FULL" : "\(load.count)/\(ScavengerTuning.capacity)")
                .font(.system(size: 11, weight: full ? .bold : .medium, design: .rounded))
                .foregroundStyle(full ? Semantics.runningText : Color.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(full ? Semantics.running.opacity(Semantics.chip) : Color.clear, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Truck bed")
        .accessibilityValue("\(load.count) of \(ScavengerTuning.capacity), worth \(loadValue) points")
    }

    private func pipFill(_ i: Int) -> Color {
        i < load.count ? load[i].color : Color.secondary.opacity(0.25)
    }

    private var fuelGauge: some View {
        let frac = fuelFraction
        let low = frac < ScavengerTuning.lowFuel
        return HStack(spacing: 4) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(low ? Semantics.dangerText : Color.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(fuelColor(frac))
                    .frame(width: 64 * frac)
            }
            .frame(width: 64, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fuel")
        .accessibilityValue("\(Int((frac * 100).rounded())) percent")
    }

    private func fuelColor(_ frac: CGFloat) -> Color {
        if frac < ScavengerTuning.lowFuel { return Semantics.danger }
        if frac < 0.5 { return Semantics.warning }
        return Semantics.success
    }

    // MARK: Playfield

    private var field: some View {
        GeometryReader { geo in
            let bay = Self.yardBay(for: geo.size)
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Brand.amber.opacity(0.08), Semantics.destination.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom
                )
                .accessibilityHidden(true)

                Canvas { ctx, size in
                    paintYard(ctx, size: size)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                Text("DUMP")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                    .position(x: bay.midX, y: bay.minY + 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ForEach(scraps) { piece in
                    scrapGlyph(piece)
                }

                ForEach(bugs) { bug in
                    // ladybug.fill faces up; the heading is measured from +x.
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: ScavengerTuning.bugSize * 0.85, weight: .semibold))
                        .foregroundStyle(Semantics.danger)
                        .frame(width: ScavengerTuning.bugSize, height: ScavengerTuning.bugSize)
                        .rotationEffect(.radians(Double(bug.dir) + .pi / 2))
                        .position(bug.pos)
                        .accessibilityHidden(true)
                }

                ScavengerRig(load: rigLoad, bedLift: bedLift)
                    // Pickup: a small pulse, tick-decayed like GravelDrop's
                    // bedBounce and inert under Reduce Motion.
                    .scaleEffect(1 + bedBounce * 0.08)
                    .rotationEffect(.radians(Double(heading)))
                    .opacity(rigOpacity)
                    .position(truckPos)
                    .accessibilityHidden(true)

                // The load in flight sits ABOVE the truck: it leaves the bed.
                Canvas { ctx, _ in
                    paintFlyers(ctx)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                ForEach(pops) { p in
                    Text(p.text)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(p.color.opacity(Double(min(1, p.life * 1.5))))
                        .fixedSize()
                        .position(x: p.x, y: p.y)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if reduceMotion {
                    // Reduce Motion: a held border, not a full-viewport wash
                    // (GravelDrop, Opus games review, MAJOR).
                    Rectangle()
                        .strokeBorder(Semantics.danger.opacity(damageFlash > 0 ? 0.7 : 0),
                                      lineWidth: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Rectangle()
                        .fill(Semantics.danger.opacity(damageFlash * 0.3))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                switch phase {
                case .ready: readyPanel
                case .over: gameOverPanel
                case .playing: EmptyView()
                }
            }
            // Game art stays inside the yard; it may never paint over the HUD
            // or the sheet's repeated job verdict.
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Belt-and-braces behind the sheet's material overlay:
                        // a paused game must not be steered.
                        guard !paused, phase == .playing else { return }
                        if !focused { focused = true }
                        heldLeft = false
                        heldRight = false
                        heldUp = false
                        heldDown = false
                        target = clampToYard(v.location, margin: ScavengerTuning.wallMargin)
                    }
            )
            .onAppear { syncSize(geo.size) }
            .onChange(of: geo.size) { _, new in syncSize(new) }
        }
    }

    private func scrapGlyph(_ piece: ScrapPiece) -> some View {
        // A rare piece fades over its last three seconds — a fade, not a
        // blink, so it needs no Reduce Motion branch.
        let fade: Double = piece.ttl.map { min(1, Double($0) / 3) } ?? 1
        return ZStack {
            Circle().fill(piece.kind.color.opacity(0.16))
            Circle().strokeBorder(piece.kind.color.opacity(0.45), lineWidth: 1)
            Image(systemName: piece.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(piece.kind.color)
        }
        .frame(width: ScavengerTuning.scrapSize, height: ScavengerTuning.scrapSize)
        .opacity(max(0.3, fade))
        .position(piece.pos)
        // Up to a dozen of these come and go; they are a11y-tree noise.
        .accessibilityHidden(true)
    }

    /// Ground texture, mud, the bay and its heap, dust, and the click target.
    /// One Canvas instead of a view per speck keeps the 60 Hz redraw cheap.
    private func paintYard(_ ctx: GraphicsContext, size: CGSize) {
        for i in 0..<ScavengerTuning.gravelCount {
            let x = scavengerNoise(i, 1) * size.width
            let y = scavengerNoise(i, 2) * size.height
            let r = 1 + scavengerNoise(i, 3) * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Color.primary.opacity(0.07)))
        }

        for p in puddles {
            let rect = CGRect(x: p.center.x - p.rx, y: p.center.y - p.ry,
                              width: p.rx * 2, height: p.ry * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.brown.opacity(0.30)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color.brown.opacity(0.45)), lineWidth: 1.2)
            let sheen = rect.insetBy(dx: p.rx * 0.45, dy: p.ry * 0.5)
                .offsetBy(dx: -p.rx * 0.15, dy: -p.ry * 0.2)
            ctx.fill(Path(ellipseIn: sheen), with: .color(Color.white.opacity(0.10)))
        }

        // The bay wears brand amber: it is the app's own ground, not a
        // warning. Dashed so it reads as a zone, not a wall.
        let bay = Self.yardBay(for: size)
        let bayPath = Path(roundedRect: bay, cornerRadius: 8)
        ctx.fill(bayPath, with: .color(Brand.amber.opacity(0.16)))
        ctx.stroke(bayPath, with: .color(Brand.amber.opacity(0.85)),
                   style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        for (i, kind) in pile.enumerated() {
            let c = Self.pileSlot(i, bay: bay)
            let r = Path(roundedRect: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8),
                         cornerRadius: 1.5)
            ctx.fill(r, with: .color(kind.color.opacity(0.85)))
            ctx.stroke(r, with: .color(Brand.ink.opacity(0.5)), lineWidth: 0.8)
        }

        for puff in puffs {
            let rect = CGRect(x: puff.pos.x - puff.r, y: puff.pos.y - puff.r,
                              width: puff.r * 2, height: puff.r * 2)
            let tint = puff.mud ? Color.brown : Color.secondary
            ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(Double(max(0, puff.life)) * 0.25)))
        }

        // Static marker where a click sent the truck — no pulse, so it is
        // unaffected by Reduce Motion.
        if let t = target, phase == .playing {
            let ring = CGRect(x: t.x - 7, y: t.y - 7, width: 14, height: 14)
            ctx.stroke(Path(ellipseIn: ring), with: .color(Semantics.running.opacity(0.55)), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: ring.insetBy(dx: 5, dy: 5)),
                     with: .color(Semantics.running.opacity(0.55)))
        }
    }

    private func paintFlyers(_ ctx: GraphicsContext) {
        for f in flyers where f.t >= 0 {
            let t = min(1, f.t)
            let x = f.from.x + (f.to.x - f.from.x) * t
            let y = f.from.y + (f.to.y - f.from.y) * t - sin(t * .pi) * 34
            var c = ctx
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(Double(t) * 4))
            let cube = Path(roundedRect: CGRect(x: -4, y: -4, width: 8, height: 8), cornerRadius: 1.5)
            c.fill(cube, with: .color(f.kind.color))
            c.stroke(cube, with: .color(Brand.ink.opacity(0.6)), lineWidth: 0.8)
        }
    }

    private var readyPanel: some View {
        VStack(spacing: 9) {
            Text("SCAVENGER")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Semantics.runningText)
            Text("Scoop up loose footage around the yard and haul it to the dump before the tank runs dry.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ruleRow("shippingbox.fill", Semantics.successText,
                        "Points count once dumped; a full bed of \(ScavengerTuning.capacity) pays ×1.5")
                ruleRow("fuelpump.fill", Color.secondary, "Every dump tops up the tank")
                ruleRow("ladybug.fill", Semantics.dangerText, "Bugs scramble half your load")
                ruleRow("drop.fill", Color.secondary, "Mud slows you down")
            }
            Button("Start") { begin() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Semantics.running)
            Text("arrows, WASD or click to drive  ·  space or return to start")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ruleRow(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var gameOverPanel: some View {
        VStack(spacing: 10) {
            Text("OUT OF FUEL")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Semantics.dangerText)
            Text("\(score) banked  ·  \(trips) \(trips == 1 ? "load" : "loads") dumped"
                 + (score > bestAtStart ? "  ·  new best" : ""))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if loadValue > 0 {
                Text("\(loadValue) left in the bed")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button("Restart") { begin() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Semantics.running)
            Text("space or return to restart")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loop

    private func startTicker() {
        stopTicker()
        // Never run a loop behind the pause overlay: begin() and the
        // paused -> live transition both route through here.
        guard !paused else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            // Installed only on RunLoop.main; execute in place so no queued
            // game tick can fire after the sheet's stopTicker/onDisappear.
            MainActor.assumeIsolated {
                let now = Date()
                let dt = min(0.05, now.timeIntervalSince(lastTick ?? now))
                lastTick = now
                step(CGFloat(dt))
            }
        }
        // Runs while a card hauls, i.e. while the engine saturates the CPU:
        // let the run loop coalesce wakeups. `step` is dt-driven and clamps
        // dt to 0.05, so a coalesced tick changes nothing (GravelDrop).
        t.tolerance = 1.0 / 240.0
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    private func step(_ dt: CGFloat) {
        guard fieldSize.width > 0, fieldSize.height > 0 else { return }
        if damageFlash > 0 { damageFlash = max(0, damageFlash - Double(dt) * 2.5) }
        if bedBounce > 0 { bedBounce = max(0, bedBounce - dt * 6) }
        if invulnerable > 0 { invulnerable = max(0, invulnerable - dt) }
        agePops(dt)
        agePuffs(dt)
        flyFlyers(dt)
        guard phase == .playing else {
            // Nothing left to drive once the effects settle; begin() owns
            // starting the ticker again. No idle 60 Hz wakeups behind a panel.
            if !effectsPending { stopTicker() }
            return
        }

        elapsed += dt
        if dumpTimer > 0 {
            // The bed is up: the truck holds still and the tank does not
            // drain — the dump is a beat of reward, not a tax.
            vel = .zero
            dumpTimer -= dt
            if dumpTimer <= 0 {
                dumpTimer = 0
                finishDump()
            }
        } else {
            fuel -= drainRate * dt
            drive(dt)
        }
        emitDust(dt)
        topUpHazards()
        moveBugs(dt)
        collectScrap(dt)
        spawnScrap(dt)
        if dumpTimer == 0, invulnerable == 0 { checkBugHits() }
        if dumpTimer == 0, !load.isEmpty, bayRect.contains(truckPos) { beginDump() }
        if fuel <= 0 { endRun() }
    }

    // MARK: Driving

    private func drive(_ dt: CGFloat) {
        let ix: CGFloat = (heldRight ? 1 : 0) - (heldLeft ? 1 : 0)
        let iy: CGFloat = (heldDown ? 1 : 0) - (heldUp ? 1 : 0)
        var want = CGVector.zero
        if ix != 0 || iy != 0 {
            target = nil
            let len = (ix * ix + iy * iy).squareRoot()
            want = CGVector(dx: ix / len, dy: iy / len)
        } else if let t = target {
            let dx = t.x - truckPos.x, dy = t.y - truckPos.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < ScavengerTuning.arriveRadius {
                target = nil
            } else {
                let ease = min(1, d / ScavengerTuning.brakeDistance)
                want = CGVector(dx: dx / d * ease, dy: dy / d * ease)
            }
        }

        let inMud = puddles.contains { $0.contains(truckPos) }
        let top = ScavengerTuning.truckSpeed * (inMud ? ScavengerTuning.mudFactor : 1)
        let blend = min(1, dt * (inMud ? ScavengerTuning.mudGrip : ScavengerTuning.grip))
        vel.dx += (want.dx * top - vel.dx) * blend
        vel.dy += (want.dy * top - vel.dy) * blend

        // A wall stops the axis it blocks, so the truck slides along it
        // instead of pressing into it at full speed.
        let next = CGPoint(x: truckPos.x + vel.dx * dt, y: truckPos.y + vel.dy * dt)
        let clamped = clampToYard(next, margin: ScavengerTuning.wallMargin)
        if clamped.x != next.x { vel.dx = 0 }
        if clamped.y != next.y { vel.dy = 0 }
        truckPos = clamped

        // Face the direction of travel, turning quickly but not instantly.
        // This is the truck's heading, not decoration, so it stays under
        // Reduce Motion.
        if vel.dx * vel.dx + vel.dy * vel.dy > 144 {
            let facing = CGFloat(atan2(Double(vel.dy), Double(vel.dx)))
            heading = wrapAngle(heading + wrapAngle(facing - heading) * min(1, dt * 10))
        }
    }

    private func emitDust(_ dt: CGFloat) {
        guard !calmMotion, dumpTimer == 0 else { return }
        guard vel.dx * vel.dx + vel.dy * vel.dy > 3600 else { puffClock = 0; return }
        puffClock += dt
        guard puffClock >= ScavengerTuning.puffInterval else { return }
        puffClock = 0
        let inMud = puddles.contains { $0.contains(truckPos) }
        let back = ScavengerTuning.inkHalfLength - 2
        let rear = CGPoint(x: truckPos.x - cos(heading) * back + CGFloat.random(in: -4...4),
                           y: truckPos.y - sin(heading) * back + CGFloat.random(in: -4...4))
        puffs.append(ScrapPuff(pos: rear, r: CGFloat.random(in: 2.5...4.5), life: 1, mud: inMud))
        trimPuffs()
    }

    private func agePuffs(_ dt: CGFloat) {
        guard !puffs.isEmpty else { return }
        for i in puffs.indices {
            puffs[i].r += 9 * dt
            puffs[i].life -= 2 * dt
        }
        puffs.removeAll { $0.life <= 0 }
    }

    private func trimPuffs() {
        if puffs.count > ScavengerTuning.maxPuffs {
            puffs.removeFirst(puffs.count - ScavengerTuning.maxPuffs)
        }
    }

    // MARK: Salvage

    private func collectScrap(_ dt: CGFloat) {
        let room = ScavengerTuning.capacity - load.count
        var kept: [ScrapPiece] = []
        kept.reserveCapacity(scraps.count)
        var picked: [ScrapPiece] = []
        for var piece in scraps {
            if let ttl = piece.ttl {
                let left = ttl - dt
                if left <= 0 { continue }
                piece.ttl = left
            }
            if picked.count < room, dumpTimer == 0, reaches(piece.pos) {
                picked.append(piece)
                continue
            }
            kept.append(piece)
        }
        scraps = kept
        guard !picked.isEmpty else { return }

        for piece in picked {
            load.append(piece.kind)
            addPop("+\(piece.kind.points)", at: piece.pos, tone: .gain)
        }
        ArcadeSounds.catchGood.play(volume: 0.3)
        if !calmMotion { bedBounce = 1 }
        if load.count >= ScavengerTuning.capacity {
            ArcadeSounds.flip.play(volume: 0.35)
            addPop("BED FULL", at: CGPoint(x: truckPos.x, y: truckPos.y - 26), tone: .bank)
            AccessibilityNotification.Announcement("Bed full. Head to the dump.").post()
        }
    }

    private func spawnScrap(_ dt: CGFloat) {
        spawnClock -= dt
        guard spawnClock <= 0 else { return }
        spawnClock = ScavengerTuning.spawnInterval * CGFloat.random(in: 0.7...1.3)
        guard scraps.count < ScavengerTuning.maxScrap else { return }
        addScrap()
    }

    private func addScrap() {
        guard let spot = openSpot(awayFromTruck: 70, margin: ScavengerTuning.scrapSize) else { return }
        let roll = Double.random(in: 0..<1)
        // 5% drives (rare, expiring), 20% cards, 30% frames, 45% clips.
        let kind: ScrapKind
        switch roll {
        case ..<0.05: kind = .drive
        case ..<0.25: kind = .card
        case ..<0.55: kind = .frame
        default: kind = .clip
        }
        scraps.append(ScrapPiece(pos: spot, kind: kind,
                                 ttl: kind == .drive ? ScavengerTuning.driveTTL : nil))
    }

    // MARK: Hazards

    private func topUpHazards() {
        // At most one of each per frame: a spot that fails its placement
        // tests simply tries again next tick.
        if bugs.count < bugTarget, let spot = bugSpawnSpot() {
            let inward = angle(from: spot, to: CGPoint(x: fieldSize.width / 2, y: fieldSize.height / 2))
            bugs.append(ScrapBug(pos: spot, dir: inward + CGFloat.random(in: -0.6...0.6)))
        }
        if puddles.count < puddleTarget { addPuddle(awayFromTruck: 110) }
    }

    private func addPuddle(awayFromTruck gap: CGFloat) {
        let rx = CGFloat.random(in: 28...46)
        let ry = CGFloat.random(in: 16...26)
        let w = fieldSize.width, h = fieldSize.height
        guard w > rx * 2 + 20, h > ry * 2 + 20 else { return }
        for _ in 0..<8 {
            let c = CGPoint(x: CGFloat.random(in: (rx + 10)...(w - rx - 10)),
                            y: CGFloat.random(in: (ry + 10)...(h - ry - 10)))
            if bayRect.insetBy(dx: -rx - 16, dy: -ry - 16).contains(c) { continue }
            if distance(c, truckPos) < gap { continue }
            if puddles.contains(where: { distance($0.center, c) < 70 }) { continue }
            puddles.append(ScrapPuddle(center: c, rx: rx, ry: ry))
            return
        }
    }

    private func bugSpawnSpot() -> CGPoint? {
        let w = fieldSize.width, h = fieldSize.height
        let r = ScavengerTuning.bugRadius
        guard w > r * 2 + 1, h > r * 2 + 1 else { return nil }
        let keepOut = bayRect.insetBy(dx: -ScavengerTuning.bugBayGap, dy: -ScavengerTuning.bugBayGap)
        for _ in 0..<8 {
            let p: CGPoint
            switch Int.random(in: 0..<4) {
            case 0: p = CGPoint(x: CGFloat.random(in: r...(w - r)), y: r)
            case 1: p = CGPoint(x: CGFloat.random(in: r...(w - r)), y: h - r)
            case 2: p = CGPoint(x: r, y: CGFloat.random(in: r...(h - r)))
            default: p = CGPoint(x: w - r, y: CGFloat.random(in: r...(h - r)))
            }
            // Never on top of the player: a bug appears at the edge of the
            // yard, far enough away to be seen coming.
            if keepOut.contains(p) || distance(p, truckPos) < 160 { continue }
            return p
        }
        return nil
    }

    private func moveBugs(_ dt: CGFloat) {
        guard !bugs.isEmpty else { return }
        let speed = bugSpeed
        // They lose interest in a truck parked at the dump, so the bay never
        // becomes a siege.
        let seek: CGFloat = bayRect.contains(truckPos) || phase != .playing
            ? 0
            : min(ScavengerTuning.bugMaxSeek, elapsed / ScavengerTuning.bugSeekRampSeconds)
        let keepOut = bayRect.insetBy(dx: -ScavengerTuning.bugBayGap, dy: -ScavengerTuning.bugBayGap)
        let r = ScavengerTuning.bugRadius
        let w = fieldSize.width, h = fieldSize.height

        for i in bugs.indices {
            var b = bugs[i]
            b.turnClock -= dt
            if b.turnClock <= 0 {
                b.turn = CGFloat.random(in: -1.8...1.8)
                b.turnClock = CGFloat.random(in: 0.5...1.4)
            }
            var steer = b.turn
            if seek > 0 {
                steer += wrapAngle(angle(from: b.pos, to: truckPos) - b.dir) * seek
            }
            b.dir += steer * dt
            b.pos.x += cos(b.dir) * speed * dt
            b.pos.y += sin(b.dir) * speed * dt

            // Walls reflect.
            if b.pos.x < r { b.pos.x = r; b.dir = .pi - b.dir }
            else if b.pos.x > w - r { b.pos.x = w - r; b.dir = .pi - b.dir }
            if b.pos.y < r { b.pos.y = r; b.dir = -b.dir }
            else if b.pos.y > h - r { b.pos.y = h - r; b.dir = -b.dir }

            // The dump is sanctuary: push straight back out.
            if keepOut.contains(b.pos) {
                b.dir = angle(from: CGPoint(x: keepOut.midX, y: keepOut.midY), to: b.pos)
                b.pos.x += cos(b.dir) * speed * dt * 2
                b.pos.y += sin(b.dir) * speed * dt * 2
            }
            b.dir = wrapAngle(b.dir)
            bugs[i] = b
        }
    }

    private func checkBugHits() {
        guard let i = bugs.firstIndex(where: { bug in
            let l = localOffset(of: bug.pos)
            return abs(l.x) <= ScavengerTuning.hitHalfLength
                && abs(l.y) <= ScavengerTuning.hitHalfWidth
        }) else { return }

        let hitAt = bugs[i].pos
        bugs[i].dir = angle(from: truckPos, to: hitAt)         // the bug bounces off
        let away = angle(from: hitAt, to: truckPos)
        vel = CGVector(dx: cos(away) * ScavengerTuning.knockback,
                       dy: sin(away) * ScavengerTuning.knockback)
        invulnerable = ScavengerTuning.invulnerableSeconds
        damageFlash = 1
        fuel -= ScavengerTuning.hitFuel

        // Scramble: the top half of the load (rounded up) spills back into
        // the yard around the truck — recoverable, but it costs a lap.
        let lost = load.isEmpty ? 0 : (load.count + 1) / 2
        if lost > 0 {
            let spilled = Array(load.suffix(lost))
            load.removeLast(lost)
            for kind in spilled { spill(kind) }
            addPop("−\(lost) scrambled", at: CGPoint(x: truckPos.x, y: truckPos.y - 24), tone: .loss)
        } else {
            addPop("−fuel", at: CGPoint(x: truckPos.x, y: truckPos.y - 24), tone: .loss)
        }
        // `.level()` only — "hit a wall". The fun layer never speaks the
        // safety vocabulary (GravelDrop).
        Haptics.level()
        ArcadeSounds.bad.play()
    }

    private func spill(_ kind: ScrapKind) {
        let keepOut = bayRect.insetBy(dx: -8, dy: -8)
        for _ in 0..<6 {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let d = CGFloat.random(in: 50...90)
            let p = clampToYard(CGPoint(x: truckPos.x + cos(a) * d, y: truckPos.y + sin(a) * d),
                                margin: ScavengerTuning.scrapSize)
            if keepOut.contains(p) { continue }
            scraps.append(ScrapPiece(pos: p, kind: kind,
                                     ttl: kind == .drive ? ScavengerTuning.driveTTL : nil))
            return
        }
    }

    // MARK: Dumping

    private func beginDump() {
        pendingBank = load
        load.removeAll()
        target = nil
        vel = .zero
        let bay = bayRect
        if calmMotion {
            dumpTimer = ScavengerTuning.calmDumpSeconds
            for kind in pendingBank where pile.count < ScavengerTuning.pileCap { pile.append(kind) }
        } else {
            dumpTimer = ScavengerTuning.dumpSeconds
            // Launch from the tailgate, last piece in first out.
            let back = ScavengerTuning.inkHalfLength - 6
            let tailgate = CGPoint(x: truckPos.x - cos(heading) * back,
                                   y: truckPos.y - sin(heading) * back)
            let n = pendingBank.count
            for (i, kind) in pendingBank.enumerated() {
                let order = n - 1 - i
                let slot = Self.pileSlot(min(pile.count + order, ScavengerTuning.pileCap - 1), bay: bay)
                flyers.append(ScrapFlyer(from: tailgate, to: slot,
                                         t: -CGFloat(order) * ScavengerTuning.flyerStagger,
                                         kind: kind))
            }
        }
        ArcadeSounds.jump.play(volume: 0.25)            // the bed going up
    }

    private func flyFlyers(_ dt: CGFloat) {
        guard !flyers.isEmpty else { return }
        var landed: [ScrapKind] = []
        for i in flyers.indices {
            flyers[i].t += ScavengerTuning.flyerSpeed * dt
            if flyers[i].t >= 1 { landed.append(flyers[i].kind) }
        }
        flyers.removeAll { $0.t >= 1 }
        guard !landed.isEmpty else { return }
        for kind in landed where pile.count < ScavengerTuning.pileCap { pile.append(kind) }
        if !calmMotion {
            let bay = bayRect
            let at = Self.pileSlot(max(0, pile.count - 1), bay: bay)
            puffs.append(ScrapPuff(pos: at, r: 3, life: 0.8, mud: false))
            trimPuffs()
        }
    }

    private func finishDump() {
        let count = pendingBank.count
        guard count > 0 else { return }
        let value = pendingBank.reduce(0) { $0 + $1.points }
        let full = count >= ScavengerTuning.capacity
        let bonus = full ? value / 2 : 0
        score += value + bonus
        // Commit the record on the bank, not at the end: closing the sheet
        // mid-run must not discard a record run (GravelDrop, Opus games
        // review, MAJOR).
        if score > best { best = score }
        trips += 1
        fuel = min(ScavengerTuning.maxFuel,
                   fuel + ScavengerTuning.refuelPerPiece * CGFloat(count)
                       + (full ? ScavengerTuning.fullLoadRefuel : 0))
        pendingBank.removeAll()

        let bay = bayRect
        addPop("+\(value)", at: CGPoint(x: bay.midX, y: bay.minY - 8), tone: .bank)
        if full {
            addPop("FULL LOAD +\(bonus)", at: CGPoint(x: bay.midX + 20, y: bay.minY - 24), tone: .bank)
        }
        if !calmMotion { bedBounce = 1 }
        Haptics.generic()                               // "a milestone passed"
        ArcadeSounds.match.play(volume: 0.35)
    }

    // MARK: Pops

    private func addPop(_ text: String, at p: CGPoint, tone: ScrapPop.Tone) {
        pops.append(ScrapPop(x: p.x, y: p.y, life: 1, text: text, tone: tone))
        if pops.count > ScavengerTuning.maxPops {
            pops.removeFirst(pops.count - ScavengerTuning.maxPops)
        }
    }

    private func agePops(_ dt: CGFloat) {
        guard !pops.isEmpty else { return }
        for i in pops.indices {
            // Reduce Motion keeps the "+N" and its fade but drops the drift.
            if !calmMotion { pops[i].y -= 24 * dt }
            pops[i].life -= 1.2 * dt
        }
        pops.removeAll { $0.life <= 0 }
    }

    // MARK: Run lifecycle

    private func begin() {
        guard phase != .playing else { return }
        // A key still being mashed as the tank ran dry must not wipe the
        // result panel before it can be read (Convoy's 0.5 s rule).
        if let e = endedAt, Date().timeIntervalSince(e) < 0.6 { return }
        bugs.removeAll()
        pops.removeAll()
        puffs.removeAll()
        flyers.removeAll()
        pile.removeAll()
        load.removeAll()
        pendingBank.removeAll()
        score = 0
        trips = 0
        fuel = ScavengerTuning.maxFuel
        elapsed = 0
        dumpTimer = 0
        invulnerable = 0
        spawnClock = 0.5
        puffClock = 0
        damageFlash = 0
        bedBounce = 0
        vel = .zero
        heading = 0
        target = nil
        heldLeft = false
        heldRight = false
        heldUp = false
        heldDown = false
        endedAt = nil
        // A second run compares against the record the first may have set.
        bestAtStart = best
        truckPos = CGPoint(x: bayRect.midX, y: bayRect.midY)
        seedField()
        phase = .playing
        // The Start/Restart button's `.defaultAction` shortcut still fires
        // under the sheet's paused overlay; startTicker() refuses to run
        // behind it, and the paused -> live transition starts it instead.
        startTicker()
        focused = true
    }

    private func endRun() {
        fuel = 0
        phase = .over
        endedAt = Date()
        target = nil
        vel = .zero
        ArcadeSounds.gameOver.play()
        // Announced alongside the cue so the end of a run is not gated on
        // Pref.soundEffects. `bestAtStart`, not `best` — the record was
        // already raised on the way here.
        AccessibilityNotification.Announcement(
            "Out of fuel. \(score) points banked."
                + (score > bestAtStart ? " New best." : "")
        ).post()
    }

    /// Fresh salvage and mud. Needs a measured yard; a no-op before the
    /// GeometryReader reports, and syncSize() seeds the ready screen later.
    private func seedField() {
        guard fieldSize.width > 0, fieldSize.height > 0 else { return }
        scraps.removeAll()
        puddles.removeAll()
        for _ in 0..<ScavengerTuning.basePuddles { addPuddle(awayFromTruck: 90) }
        for _ in 0..<ScavengerTuning.seedScrap { addScrap() }
    }

    // MARK: Helpers

    private func syncSize(_ size: CGSize) {
        fieldSize = size
        guard size.width > 0, size.height > 0 else { return }
        let bay = bayRect
        if truckPos == .zero { truckPos = CGPoint(x: bay.midX, y: bay.midY) }
        truckPos = clampToYard(truckPos, margin: ScavengerTuning.wallMargin)
        if let t = target { target = clampToYard(t, margin: ScavengerTuning.wallMargin) }
        // The bay is anchored bottom-left, so a resize can slide it over
        // salvage; nothing may be lying in the dump.
        for i in scraps.indices {
            scraps[i].pos = clampToYard(scraps[i].pos, margin: ScavengerTuning.scrapSize)
        }
        scraps.removeAll { bay.contains($0.pos) }
        for i in bugs.indices {
            bugs[i].pos = clampToYard(bugs[i].pos, margin: ScavengerTuning.bugRadius)
        }
        if phase == .ready, scraps.isEmpty { seedField() }
    }

    private func clampToYard(_ p: CGPoint, margin: CGFloat) -> CGPoint {
        let w = fieldSize.width, h = fieldSize.height
        let x = w > margin * 2 ? min(max(p.x, margin), w - margin) : w / 2
        let y = h > margin * 2 ? min(max(p.y, margin), h - margin) : h / 2
        return CGPoint(x: x, y: y)
    }

    /// A random free spot for salvage: inside the margins, clear of the bay,
    /// and not right under the truck. nil after a few misses (tries again on
    /// the next spawn).
    private func openSpot(awayFromTruck gap: CGFloat, margin: CGFloat) -> CGPoint? {
        let w = fieldSize.width, h = fieldSize.height
        guard w > margin * 2 + 1, h > margin * 2 + 1 else { return nil }
        let keepOut = bayRect.insetBy(dx: -18, dy: -18)
        for _ in 0..<10 {
            let p = CGPoint(x: CGFloat.random(in: margin...(w - margin)),
                            y: CGFloat.random(in: margin...(h - margin)))
            if keepOut.contains(p) || distance(p, truckPos) < gap { continue }
            return p
        }
        return nil
    }

    /// `p` in the truck's local frame: +x toward the cab, +y to its right.
    private func localOffset(of p: CGPoint) -> CGPoint {
        let dx = p.x - truckPos.x, dy = p.y - truckPos.y
        let c = cos(-heading), s = sin(-heading)
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }

    private func reaches(_ p: CGPoint) -> Bool {
        let l = localOffset(of: p)
        return abs(l.x) <= ScavengerTuning.pickupHalfLength
            && abs(l.y) <= ScavengerTuning.pickupHalfWidth
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func angle(from a: CGPoint, to b: CGPoint) -> CGFloat {
        CGFloat(atan2(Double(b.y - a.y), Double(b.x - a.x)))
    }

    /// Into (-pi, pi].
    private func wrapAngle(_ a: CGFloat) -> CGFloat {
        var v = a.truncatingRemainder(dividingBy: 2 * .pi)
        if v > .pi { v -= 2 * .pi }
        if v <= -.pi { v += 2 * .pi }
        return v
    }
}
