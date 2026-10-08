import SwiftUI
import AppKit

// MARK: - Model

private struct ConvoyObstacle: Identifiable {
    enum Kind { case cone, pothole }
    let id = UUID()
    var x: CGFloat
    let kind: Kind

    var width: CGFloat { kind == .cone ? 22 : 54 }
    /// Drawn size only. The collision test uses `width` x (`clearance` - 4)
    /// — the -4 is the forgiveness pass's vertical grace — so a future edit
    /// here moves the art, never the collision test.
    var height: CGFloat { kind == .cone ? 28 : 10 }
    /// How high the truck must be to clear it (potholes are shallow but wide).
    var clearance: CGFloat { kind == .cone ? 28 : 20 }
}

private struct ConvoyProp: Identifiable {
    let id = UUID()
    var x: CGFloat
    let w: CGFloat
    let h: CGFloat
    let radius: CGFloat
}

private struct ConvoyPuff: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var r: CGFloat
    var life: CGFloat
}

private enum ConvoyTuning {
    static let truckWidth: CGFloat = 72
    static let truckHeight: CGFloat = 48
    /// Distance from the field's LEFT edge to the truck. Classic runner
    /// orientation by Joshua's field call (2026-08-26): the truck reads as
    /// travelling RIGHT and hazards enter from the right — an earlier pass
    /// reversed the world to match the left-facing logo art, and it read
    /// backwards. The sprite is mirrored instead (ConvoyTruckSprite).
    /// (Original note: the mascot art faces
    /// left (TruckAnimations.swift: "The truck faces left, so everything
    /// trails to the right"), so it drives leftward and the runway is the
    /// space to its left — see `truckX`.
    static let truckInset: CGFloat = 96
    /// Playtested 2026-08-28 (Joshua: "kinda unforgiving"): the old 24
    /// reached ~3.7 pt past the drawn ink (half-width 20.3) on each side, so
    /// clean-looking dodges died. Now ~3 pt INSIDE the art per side (~84% of
    /// the visible truck) — the runner-genre convention that a death must
    /// look like a hit.
    static let hitHalfWidth: CGFloat = 17
    static let roadHeight: CGFloat = 40
    static let gravity: CGFloat = 2300           // pt/sec^2
    static let jumpVelocity: CGFloat = 780       // pt/sec
    /// Release-cut floor: letting go early clips the rise, which shortens the
    /// hop and buys a faster landing. Recovery control only — a quick tap
    /// still peaks around 92 pt, far above either clearance, so this never
    /// changes WHAT a hop can clear.
    static let minJumpVelocity: CGFloat = 430
    static let baseSpeed: CGFloat = 250          // pt/sec
    static let maxSpeed: CGFloat = 560
    static let speedRamp: CGFloat = 0.011        // speed gained per pt travelled
    static let metersPerPoint: CGFloat = 1.0 / 8.0
    static let farFactor: CGFloat = 0.22
    static let nearFactor: CGFloat = 0.52
    static let dashSpacing: CGFloat = 46
    static let puffInterval: CGFloat = 0.075

    /// One hop, ground to ground. Every gap floor below is a multiple of this,
    /// so a one-hop-per-obstacle schedule provably exists at ANY speed.
    static let airtime: CGFloat = 2 * ConvoyTuning.jumpVelocity / ConvoyTuning.gravity   // 0.678 s
    static let gapSecondsEasy: CGFloat = ConvoyTuning.airtime * 1.90   // ~1.29 s at baseSpeed
    /// Playtest 2026-08-28: the old 1.30 floor left ~0.20 s of ground time
    /// between mandatory hops at max speed — relentless rather than fast.
    /// 1.55 keeps the ramp real (~0.37 s to react) without going easy.
    static let gapSecondsHard: CGFloat = ConvoyTuning.airtime * 1.55   // ~1.05 s at maxSpeed
    static let gapSpread: CGFloat = 1.45                               // upper bound = lower x this
    /// Grace window before the first obstacle so a run never opens with a cone
    /// already halfway down the runway.
    static let firstGapSeconds: CGFloat = 1.6

    // logo.png is a 1024^2 PNG whose ink occupies x 0.0771-0.9219, y 0.241-0.757
    // (alpha bbox; the ground line agrees with TruckAnimations' TG.ground = 0.757).
    // `.fit` of that square into 72x48 draws 48x48, so the tyres sit 36.3 pt down
    // the frame and the visible truck is 40.5 pt wide — neither is `truckWidth`.
    static let spriteSide: CGFloat = ConvoyTuning.truckHeight              // 48
    static let inkWidth: CGFloat = ConvoyTuning.spriteSide * (0.9219 - 0.0771)   // 40.5
    static let tyreInset: CGFloat = ConvoyTuning.spriteSide * 0.757        // 36.3 from frame top
    static let apex: CGFloat = ConvoyTuning.jumpVelocity * ConvoyTuning.jumpVelocity
        / (2 * ConvoyTuning.gravity)                                       // 132.3
}

// MARK: - Sprite

private struct ConvoyTruckSprite: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let img = ConvoyTruckSprite.image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "truck.box.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Semantics.destination)
            }
        }
        // Mirrored: the logo art faces left, but Convoy runs the classic
        // runner direction (truck travels right). Flip the ART, never the
        // world — a right-to-left world read backwards (Joshua, 2026-08-26).
        .scaleEffect(x: -1, y: 1)
        .frame(width: ConvoyTuning.truckWidth, height: ConvoyTuning.truckHeight)
    }
}

// MARK: - Primary view

struct ConvoyView: View {
    /// Set by ArcadeSheet when the app deactivates or the window hides. The
    /// view STAYS MOUNTED and gates its loop and its input on this, so an app
    /// switch can never wipe a run (Opus games review, CRITICAL: the old
    /// structural if/else destroyed every @State while the copy promised
    /// "Return to Dumptruck to keep playing").
    let paused: Bool

    @AppStorage("arcade.convoy.best") private var best: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var obstacles: [ConvoyObstacle] = []
    @State private var farProps: [ConvoyProp] = []
    @State private var nearProps: [ConvoyProp] = []
    @State private var puffs: [ConvoyPuff] = []

    @State private var truckLift: CGFloat = 0        // pt above the road
    @State private var vy: CGFloat = 0
    @State private var travelled: CGFloat = 0
    @State private var meters: Int = 0
    @State private var gameOver = false
    @State private var fieldSize: CGSize = .zero
    @State private var dashPhase: CGFloat = 0
    @State private var puffClock: CGFloat = 0
    @State private var lastTick: Date? = nil
    @State private var ticker: Timer? = nil

    /// Seconds until the next obstacle. Rolled ONCE per spawn — see
    /// `scrollObstacles` for why a per-frame draw was wrong.
    @State private var spawnCountdown: CGFloat = ConvoyTuning.firstGapSeconds

    /// The record to beat, snapshotted when the run starts. `best` is
    /// committed continuously (pause, dismiss, death), so reading it live
    /// would make the header pill mirror the score and "new best" always true.
    @State private var runBest: Int = 0
    @State private var isNewBest = false

    /// Live mirror of `reduceMotion`, readable from `step()`. A bare
    /// @Environment read inside the Timer closure is captured with the view
    /// value at ticker-creation time and freezes there; @State goes through a
    /// box, so it stays live.
    @State private var calmMotion = false

    @State private var diedAt: Date? = nil
    @State private var jumpBufferedAt: Date? = nil
    @State private var holding = false

    @State private var impactFlash: Double = 0
    @State private var deathShake: CGFloat = 0
    @State private var shakePhase: CGFloat = 0
    @State private var pendingGameOverSound = false

    @State private var flashMilestone: Int? = nil
    @State private var flashUntil: CGFloat = 0

    @FocusState private var focused: Bool

    /// The truck drives RIGHT (mirrored sprite), so it sits near the left
    /// edge and everything it meets enters from the right — the classic
    /// runner read. Width-independent, so it is on screen before the
    /// GeometryReader has reported a size.
    private var truckX: CGFloat { ConvoyTuning.truckInset }

    var body: some View {
        VStack(spacing: 0) {
            header
            field
        }
        .frame(minWidth: 460, minHeight: 360)
        // controlBackgroundColor, not underPage: the mid-gray put every
        // glyph between 1.10:1 and 1.38:1 in light mode (2026-08-28 audit).
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // `.handled` even while paused, and for every arrow, never
        // `.ignored`: an ignored left/right arrow walked up to the sheet's
        // segmented picker, switched games, and wiped the run (Joshua,
        // 2026-09-28; GravelDrop's handlers explain the same trap).
        .onKeyPress(keys: [.space, .upArrow, .return], phases: .down) { _ in
            if !paused { press() }
            return .handled
        }
        .onKeyPress(keys: [.space, .upArrow, .return], phases: .up) { _ in
            if !paused { releaseCut() }
            return .handled
        }
        // Held-key repeats and the arrows Convoy has no use for: swallowed.
        .onKeyPress(keys: [.space, .upArrow, .return], phases: .repeat) { _ in .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow],
                    phases: [.down, .repeat, .up]) { _ in .handled }
        .onAppear {
            calmMotion = reduceMotion
            restart()
            // The sheet is still attaching when this fires; defer like
            // ArcadeSheet's own window-resolution hop, or the assignment
            // lands before the view joins the responder chain and "SPACE to
            // hop" is dead until the player clicks the field.
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear {
            stopTicker()
            // Picker switch and sheet dismissal are the likely ends of a
            // session — far likelier than dying — so bank the run here too.
            commitBest()
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                stopTicker()
                commitBest()
            } else {
                lastTick = Date()
                startTicker()
                focused = true
            }
        }
        .onChange(of: reduceMotion) { _, new in
            calmMotion = new
            // Emission stops inside updatePuffs; clear here so nothing is
            // left hanging frozen mid-air when the setting flips.
            if new { puffs.removeAll() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Label("\(meters) m", systemImage: "road.lanes")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Semantics.runningText)
                .monospacedDigit()
            Text("BEST \(runBest) m")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let m = flashMilestone {
                Text("\(m) m")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Semantics.runningText)
                    .monospacedDigit()
                    .transition(reduceMotion
                                ? AnyTransition.identity
                                : AnyTransition.scale.combined(with: .opacity))
            }
            Spacer()
            Text("SPACE to hop")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: Playfield

    private var field: some View {
        GeometryReader { geo in
            let ground = geo.size.height - ConvoyTuning.roadHeight
            let liftT = min(1, truckLift / ConvoyTuning.apex)

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Semantics.source.opacity(0.10), Semantics.destination.opacity(0.14)],
                    startPoint: .top, endPoint: .bottom
                )

                // Parallax: distant hills, then nearer crates. Both layers are
                // lifted OFF the road line — anything resting on it at cone
                // scale reads as a hazard, and the far layer is raised more
                // because a camera above the ground plane projects distant
                // bases higher, not lower.
                ForEach(farProps) { p in
                    RoundedRectangle(cornerRadius: p.radius)
                        .fill(Semantics.source.opacity(0.13))
                        .frame(width: p.w, height: p.h)
                        .position(x: p.x + p.w / 2, y: ground - 18 - p.h / 2)
                }
                ForEach(nearProps) { p in
                    RoundedRectangle(cornerRadius: p.radius)
                        .fill(Semantics.destination.opacity(0.24))
                        .frame(width: p.w, height: p.h)
                        .position(x: p.x + p.w / 2, y: ground - 10 - p.h / 2)
                }

                roadway(width: geo.size.width, ground: ground)

                // Contact shadow: the only fixed reference the player has for
                // "am I high enough". Static, so it stays under Reduce Motion.
                Ellipse()
                    .fill(Color.black.opacity(0.30 * (1 - 0.72 * Double(liftT))))
                    .frame(width: ConvoyTuning.inkWidth * (1 - 0.30 * liftT), height: 6)
                    .position(x: truckX, y: ground + 2)

                ForEach(puffs) { puff in
                    Circle()
                        .fill(Color.secondary.opacity(Double(max(0, puff.life)) * 0.22))
                        .frame(width: puff.r * 2, height: puff.r * 2)
                        .position(x: puff.x, y: puff.y)
                }

                ForEach(obstacles) { ob in
                    obstacleView(ob, ground: ground)
                }

                // Seat the sprite by the ARTWORK's ground line, not the frame
                // centre: the logo's tyres sit at unit y 0.757 of a square that
                // `.fit` renders 48x48 inside a 72x48 frame, so centring left
                // the truck hovering ~10 pt over its own road.
                ConvoyTruckSprite()
                    .rotationEffect(.degrees(truckTilt))
                    .offset(x: reduceMotion ? 0 : deathShake * 5 * sin(shakePhase * 46),
                            y: reduceMotion ? 0 : deathShake * 3 * sin(shakePhase * 37))
                    .position(x: truckX,
                              y: ground - truckLift - ConvoyTuning.tyreInset
                                 + ConvoyTuning.truckHeight / 2)

                Rectangle()
                    .fill(Semantics.danger.opacity(impactFlash * 0.4))
                    .allowsHitTesting(false)

                // Let the hit land before the panel covers it.
                if gameOver && impactFlash < 0.35 { gameOverPanel }
            }
            .clipped()
            .contentShape(Rectangle())
            // One gesture, not a tap PLUS a drag: two would contend for the
            // same click. `onEnded` is what makes a short click a short hop.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !paused else { return }
                        if !holding {
                            holding = true
                            focused = true       // a click on the field restores keyboard control
                            press()
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        releaseCut()
                    }
            )
            .onAppear { fieldSize = geo.size }
            .onChange(of: geo.size) { _, new in fieldSize = new }
        }
    }

    private func roadway(width: CGFloat, ground: CGFloat) -> some View {
        let count = dashCount(width: width)
        // Gate the dashes at RENDER, not in the sim, so `dashPhase` stays
        // coherent and toggling Reduce Motion back off resumes seamlessly.
        let phase = reduceMotion ? 0 : dashPhase
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: ConvoyTuning.roadHeight)
                .position(x: width / 2, y: ground + ConvoyTuning.roadHeight / 2)
            Rectangle()
                .fill(Color.primary.opacity(0.22))
                .frame(height: 1.5)
                .position(x: width / 2, y: ground)
            // Keyed by INDEX, not by the moving x: `dashPhase` changes every
            // tick, so keying on the x gave all ~13 capsules a new identity
            // 60x/s and SwiftUI rebuilt them instead of repositioning them.
            // Neutral ink, not warning orange — inside Convoy, orange means
            // "cone", i.e. the thing that ends the run.
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 20, height: 3)
                    .position(x: CGFloat(i) * ConvoyTuning.dashSpacing
                                 - ConvoyTuning.dashSpacing + phase,
                              y: ground + ConvoyTuning.roadHeight * 0.45)
            }
        }
    }

    /// Stable dash count: `dashPhase` stays in [0, dashSpacing), so one extra
    /// dash at each end covers the wrap and the count depends only on `width`.
    /// The surplus dash is off-screen and already clipped by `.clipped()`.
    private func dashCount(width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int(((width + 2 * ConvoyTuning.dashSpacing)
                    / ConvoyTuning.dashSpacing).rounded(.up)) + 1
    }

    private func obstacleView(_ ob: ConvoyObstacle, ground: CGFloat) -> some View {
        Group {
            switch ob.kind {
            case .cone:
                Image(systemName: "cone.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Semantics.warning)
                    // cone.fill is near-square, so `.fit` is width-constrained
                    // here and leaves ~3 pt of slack in a 28 pt frame.
                    // `.bottom` seats it on the road instead of floating it.
                    .frame(width: ob.width, height: ob.height, alignment: .bottom)
                    .position(x: ob.x, y: ground - ob.height / 2)
            case .pothole:
                // Fixed black fill + a fixed LIGHT rim: `Color.primary` resolves
                // to black in light mode, which drew a dark rim on a dark fill —
                // invisible exactly where the read matters. `strokeBorder` keeps
                // the stroke inside `ob.width` rather than straddling it.
                Ellipse()
                    .fill(Color.black.opacity(0.45))
                    .overlay { Ellipse().strokeBorder(Color.white.opacity(0.20), lineWidth: 1) }
                    .frame(width: ob.width, height: ob.height * 1.6)
                    .position(x: ob.x, y: ground + ob.height * 0.5)
            }
        }
    }

    private var truckTilt: Double {
        // Decorative — the hop reads fine without it, and the house rule is a
        // dignified static fallback (MicroAnimations.swift rule 6).
        guard !reduceMotion else { return 0 }
        let t = Double(max(-1, min(1, vy / ConvoyTuning.jumpVelocity)))
        // Nose-up on ascent. The hood is at screen-RIGHT (mirrored sprite)
        // and positive rotation is CLOCKWISE — which drives a right-side
        // point DOWN — so raising the hood takes the negative sign.
        return -t * 16
    }

    private var gameOverPanel: some View {
        VStack(spacing: 10) {
            Text("RUN ENDED")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Semantics.dangerText)
            Text("\(meters) m" + (isNewBest ? "  ·  new best" : ""))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Restart") { restart() }
                .buttonStyle(.borderedProminent)
                .tint(Semantics.running)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Input

    private func press() {
        guard !paused else { return }
        if gameOver {
            // A runner trains the player to mash the hop key, so the press
            // arriving 30-100 ms after the crash used to wipe the score panel
            // before it could be read. Fail OPEN if `diedAt` is somehow nil so
            // the panel can never become undismissable.
            if let d = diedAt, Date().timeIntervalSince(d) < 0.5 { return }
            restart()
            return
        }
        jumpBufferedAt = Date()          // only ever set for live-run presses
        if truckLift <= 0.5 { hop() }
    }

    private func hop() {
        vy = ConvoyTuning.jumpVelocity
        jumpBufferedAt = nil             // consume, so one press = one hop
        ArcadeSounds.jump.play(volume: 0.3)   // Pref.soundEffects gate lives inside play()
    }

    /// Releasing early clips the rise. On the ground `vy == 0` and while
    /// descending `vy < 0`, so neither case can be boosted by this, and a
    /// key-up arriving after a restart is a no-op.
    private func releaseCut() {
        guard !paused, !gameOver else { return }
        if vy > ConvoyTuning.minJumpVelocity { vy = ConvoyTuning.minJumpVelocity }
    }

    // MARK: Loop

    private func startTicker() {
        stopTicker()
        // Never run a loop behind the pause overlay: restart() and .onAppear
        // both route through here.
        guard !paused else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            // This timer is installed exclusively on RunLoop.main below.
            // Assert that executor directly instead of enqueueing 60 Tasks/s;
            // queued tasks could otherwise outlive a dismissed arcade sheet.
            MainActor.assumeIsolated {
                let now = Date()
                let dt = min(0.05, now.timeIntervalSince(lastTick ?? now))
                lastTick = now
                step(CGFloat(dt))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    private func step(_ dt: CGFloat) {
        let w = fieldSize.width
        guard w > 0 else { return }

        // Death FX decay sits OUTSIDE the game-over guard so the impact can
        // play out after the crash; `shakePhase` must accumulate here because
        // `travelled` freezes behind the guard below.
        if impactFlash > 0 { impactFlash = max(0, impactFlash - Double(dt) * 2.5) }
        if deathShake > 0 { deathShake = max(0, deathShake - dt * 3.0); shakePhase += dt }
        if pendingGameOverSound, impactFlash < 0.35 {
            pendingGameOverSound = false
            ArcadeSounds.gameOver.play()
        }
        if gameOver {
            // The RUN ENDED panel is static. Once the impact has finished,
            // nothing needs a tick until restart(), which owns starting the
            // ticker again (matching GravelDrop). Leaving it running was an
            // idle 60 Hz main-run-loop wakeup for as long as the panel was up.
            if impactFlash == 0, deathShake == 0, !pendingGameOverSound { stopTicker() }
            return
        }

        let speed = min(ConvoyTuning.maxSpeed, ConvoyTuning.baseSpeed + travelled * ConvoyTuning.speedRamp)
        travelled += speed * dt
        let previousMeters = meters
        meters = Int(travelled * ConvoyTuning.metersPerPoint)
        // Milestone beat. Derived from `previousMeters`, so it is stateless
        // across restarts — no high-water mark can survive a run and silence
        // the next one.
        if meters > 0, meters / 250 > previousMeters / 250 {
            Haptics.generic()                     // "a milestone passed"
            ArcadeSounds.match.play(volume: 0.2)
            // Expires in TRAVELLED DISTANCE, not on a DispatchQueue hop, so it
            // lives and dies with the ticker that stopTicker() invalidates.
            flashUntil = travelled + 260
            withAnimation(milestoneAnimation) {
                flashMilestone = (meters / 250) * 250
            }
        } else if flashMilestone != nil, travelled > flashUntil {
            // Cleared off the same ticker that stopTicker() invalidates, so no
            // pending work can outlive a dismissed sheet.
            withAnimation(milestoneAnimation) { flashMilestone = nil }
        }
        // The world scrolls LEFT (post-0.4.1 flip): the mirrored truck drives
        // rightward, so everything ahead of it sweeps past toward the left
        // edge. Dashes travel LEFT with the world; phase stays in
        // (-spacing, 0] and the surplus dash at each end covers the wrap
        // (see dashCount).
        dashPhase = (dashPhase - speed * dt).truncatingRemainder(dividingBy: ConvoyTuning.dashSpacing)

        // Hop physics.
        vy -= ConvoyTuning.gravity * dt
        truckLift += vy * dt
        if truckLift <= 0 {
            truckLift = 0
            vy = 0
            // A press that arrived just before touchdown still counts, so a
            // marginally early input is not swallowed.
            if let b = jumpBufferedAt, Date().timeIntervalSince(b) < 0.12 { hop() }
        }

        scrollProps(dt: dt, speed: speed, width: w)
        scrollObstacles(dt: dt, speed: speed, width: w)
        updatePuffs(dt: dt, speed: speed)

        // Collision.
        let anchor = truckX
        let left = anchor - ConvoyTuning.hitHalfWidth
        let right = anchor + ConvoyTuning.hitHalfWidth
        for ob in obstacles {
            let oLeft = ob.x - ob.width / 2
            let oRight = ob.x + ob.width / 2
            // -4: vertical grace to match the narrowed horizontal box
            // (2026-08-28 forgiveness pass) — a tyre grazing the cone tip
            // reads as a clear, not a crash.
            if oRight > left, oLeft < right, truckLift < ob.clearance - 4 {
                gameOver = true
                isNewBest = meters > runBest && meters > 0
                commitBest()
                diedAt = Date()
                impactFlash = 1
                deathShake = calmMotion ? 0 : 1
                pendingGameOverSound = true      // the thud lands first, the sting follows
                ArcadeSounds.bad.play()
                Haptics.level()                  // "hit a wall"
                return
            }
            // Cleared it this frame, and only just. Stateless: the trailing
            // edge (now the RIGHT edge — the world moves left) crosses the
            // truck exactly once. Placed AFTER the death test so a fatal
            // frame never also chimes.
            let advance = speed * dt
            if oRight < anchor, oRight + advance >= anchor, truckLift < ob.clearance + 24 {
                ArcadeSounds.flip.play(volume: 0.5)
            }
        }
    }

    private func scrollProps(dt: CGFloat, speed: CGFloat, width: CGFloat) {
        // Reduce Motion: freeze the parallax. `topUpProps` self-terminates once
        // each layer reaches the left edge, so a still horizon leaks nothing.
        if !calmMotion {
            for i in farProps.indices { farProps[i].x -= speed * ConvoyTuning.farFactor * dt }
            for i in nearProps.indices { nearProps[i].x -= speed * ConvoyTuning.nearFactor * dt }
        }
        farProps.removeAll { $0.x + $0.w < -40 }
        nearProps.removeAll { $0.x + $0.w < -40 }
        topUpProps(width: width)
    }

    /// Fills both parallax layers out past the RIGHT edge, which is where
    /// props enter from. Called from restart() as well as the loop: appending
    /// at most one prop per frame meant every restart began on a blank field
    /// and assembled its backdrop over ~10 frames, with the first hill popping
    /// into existence mid-screen instead of entering from the edge.
    private func topUpProps(width: CGFloat) {
        guard width > 0 else { return }
        var farRight = farProps.map { $0.x + $0.w }.max() ?? -30
        while farRight < width + 30 {
            let w = CGFloat.random(in: 90...170)
            let x = farRight + CGFloat.random(in: 40...130)
            farProps.append(ConvoyProp(x: x, w: w,
                                       h: CGFloat.random(in: 40...86), radius: w / 2.2))
            farRight = x + w
        }
        // Deliberately long and low: at the old 26-54 x 16-38 the crates were
        // cone-sized silhouettes on the ground line, i.e. false hazards in
        // peripheral vision during a fast run.
        var nearRight = nearProps.map { $0.x + $0.w }.max() ?? -30
        while nearRight < width + 30 {
            let w = CGFloat.random(in: 34...62)
            let x = nearRight + CGFloat.random(in: 110...300)
            nearProps.append(ConvoyProp(x: x, w: w,
                                        h: CGFloat.random(in: 8...18), radius: 3))
            nearRight = x + w
        }
        // Both loops advance the edge by at least 130 (far) / 144 (near) pt
        // per iteration, so they terminate for any finite width.
    }

    private func scrollObstacles(dt: CGFloat, speed: CGFloat, width: CGFloat) {
        for i in obstacles.indices { obstacles[i].x -= speed * dt }
        obstacles.removeAll { $0.x < -70 }

        // Spacing is counted in SECONDS OF TRAVEL — never in points, never off
        // the obstacle array, never off `width`. The old `min(gap, width * 0.5)`
        // pinned spacing to a constant width/2 + 40 pt: 1.06 s at baseSpeed
        // decaying to 0.47 s at maxSpeed, i.e. under `airtime`, so past ~1600 m
        // no jump schedule survived and window size acted as a difficulty
        // slider. The draw is also rolled ONCE per spawn: this runs 60x/s, so a
        // per-frame draw made the realized gap an order statistic (measured
        // median 0.93 s against a declared 1.0-1.8 s range), not a uniform one.
        spawnCountdown -= dt
        guard spawnCountdown <= 0 else { return }
        obstacles.append(ConvoyObstacle(x: width + 40, kind: Bool.random() ? .cone : .pothole))

        // Ramp the floor toward (never below) `airtime` so speed buys real
        // pressure; with a FLAT gap in seconds the ramp would be purely
        // cosmetic, since the obstacle rate never changes.
        let p = min(1, max(0, (speed - ConvoyTuning.baseSpeed)
                            / (ConvoyTuning.maxSpeed - ConvoyTuning.baseSpeed)))
        let lo = ConvoyTuning.gapSecondsEasy
               + (ConvoyTuning.gapSecondsHard - ConvoyTuning.gapSecondsEasy) * p
        spawnCountdown = CGFloat.random(in: lo...(lo * ConvoyTuning.gapSpread))
    }

    private func updatePuffs(dt: CGFloat, speed: CGFloat) {
        let ground = fieldSize.height - ConvoyTuning.roadHeight
        // The truck faces RIGHT, so its exhaust is emitted behind it — to the
        // LEFT — and trails further left with the world. Emission is gated on
        // Reduce Motion; the decay loop below still runs so in-flight puffs
        // retire cleanly rather than freezing on screen.
        if !calmMotion, truckLift <= 0.5 {
            puffClock += dt
            if puffClock >= ConvoyTuning.puffInterval {
                puffClock = 0
                puffs.append(ConvoyPuff(x: truckX - CGFloat.random(in: 22...32),
                                        y: ground - CGFloat.random(in: 0...5),
                                        r: CGFloat.random(in: 3...6),
                                        life: 1))
            }
        }
        for i in puffs.indices {
            puffs[i].x -= speed * 0.85 * dt
            puffs[i].y -= 9 * dt
            puffs[i].r += 13 * dt
            puffs[i].life -= 2.1 * dt
        }
        // Puffs drift LEFT with the world (post-0.4.1 flip), so the
        // off-screen cull watches the LEFT edge.
        puffs.removeAll { $0.life <= 0 || $0.x < -30 }
    }

    /// Nil under Reduce Motion — the milestone still appears and still clears,
    /// it just does not scale in (MicroAnimations.swift rule 6).
    private var milestoneAnimation: Animation? {
        calmMotion ? nil : Animation.easeOut(duration: 0.2)
    }

    // MARK: Score

    /// `meters` only ever increases within a run, so committing early can never
    /// overwrite `best` with a smaller number and `isNewBest` (compared against
    /// the run-start snapshot) stays honest. The old code wrote `best` first
    /// and then rendered `meters >= best`, which read "new best" on every run.
    private func commitBest() {
        if meters > best { best = meters }
    }

    // MARK: Reset

    private func restart() {
        obstacles.removeAll()
        farProps.removeAll()
        nearProps.removeAll()
        puffs.removeAll()
        truckLift = 0
        vy = 0
        travelled = 0
        meters = 0
        dashPhase = 0
        puffClock = 0
        gameOver = false
        isNewBest = false
        runBest = best
        diedAt = nil
        jumpBufferedAt = nil
        holding = false
        impactFlash = 0
        deathShake = 0
        shakePhase = 0
        pendingGameOverSound = false
        flashMilestone = nil
        flashUntil = 0
        spawnCountdown = ConvoyTuning.firstGapSeconds
        // No-op on the very first open (fieldSize is still .zero because the
        // view's .onAppear fires before the GeometryReader's), and the first
        // step frame then fills the backdrop in one pass.
        topUpProps(width: fieldSize.width)
        lastTick = Date()
        focused = true
        // restart() owns the ticker, matching GravelDrop — the two siblings
        // must not disagree about who restarts it. startTicker() begins with
        // stopTicker(), so this is idempotent.
        startTicker()
    }
}
