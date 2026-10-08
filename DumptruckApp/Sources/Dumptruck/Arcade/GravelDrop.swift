import SwiftUI
import AppKit

// MARK: - Model

private struct DropItem: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
    let symbol: String
    let corrupted: Bool
}

/// A "+N" that lifts off a caught clip. Purely cosmetic, and aged by the same
/// tick as the field so Reduce Motion can drop the drift without a second
/// clock running behind it.
private struct GravelPop: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var life: CGFloat        // 1 -> 0
    let points: Int
}

private enum GravelDropTuning {
    static let truckWidth: CGFloat = 64          // layout frame, not the art
    static let truckHeight: CGFloat = 40
    static let itemSize: CGFloat = 22
    static let startingLives = 3                 // hoisted: the HUD pip count,
                                                 // the initial value and the
                                                 // restart value must agree.

    // MARK: Collision, measured against the DRAWN INK
    //
    // logo.png is 1024x1024 and TruckSprite draws it `.fit` inside a 64x40
    // frame, so it renders 40x40 CENTRED: the visible truck spans truckX
    // +/- 16.9, never the +/- 32 the frame implies. The shipped box
    // (truckWidth / 2 - catchInset = 26) therefore swallowed clips that were
    // 6pt clear of the art AND took a life for corrupt clips that visibly
    // missed — forgiveness applied to the wrong half of the game (Opus games
    // review, MAJOR). Convoy's hitbox happened to match its art; this one did
    // not. Unit landmarks are the raster's alpha bbox (79,247,944,776)/1024,
    // the same numbers TruckAnimations.swift records above its `TG` enum.
    static let spriteSide: CGFloat = GravelDropTuning.truckHeight
    static let inkLeftU: CGFloat = 0.0771
    static let inkRightU: CGFloat = 0.9219
    static let inkTopU: CGFloat = 0.2412
    static let inkBottomU: CGFloat = 0.7578
    static let inkHalfW: CGFloat = GravelDropTuning.spriteSide
        * (GravelDropTuning.inkRightU - GravelDropTuning.inkLeftU) / 2        // 16.9
    static let inkTopInset: CGFloat = GravelDropTuning.spriteSide
        * GravelDropTuning.inkTopU                                           //  9.6
    static let inkBottomInset: CGFloat = GravelDropTuning.spriteSide
        * (1 - GravelDropTuning.inkBottomU)                                  //  9.7

    // The bed is the RIGHT half of the drawing (TruckAnimations' TG.bed runs
    // from the bed's front wall at 0.4045 to the tailgate at 0.9850), so a
    // good clip has to land IN it. That is the game's identity — you are
    // loading a dump truck, not sliding a symmetric paddle.
    static let bedLoU: CGFloat = 0.4045 - 0.5
    static let bedHiU: CGFloat = 0.9850 - 0.5
    /// Forgiveness on the bed edges — 12, not the shipped 6. The bed window is
    /// 47pt wide at this inset against the old symmetric box's 52pt, so moving
    /// the catch into the bed is not a stealth difficulty spike.
    static let catchInset: CGFloat = 12
    static let bedWindowLo: CGFloat = GravelDropTuning.bedLoU
        * GravelDropTuning.spriteSide - GravelDropTuning.catchInset          // -15.8
    static let bedWindowHi: CGFloat = GravelDropTuning.bedHiU
        * GravelDropTuning.spriteSide + GravelDropTuning.catchInset          // +31.4
    static let bedWindowWidth: CGFloat = GravelDropTuning.bedWindowHi
        - GravelDropTuning.bedWindowLo                                       //  47.2
    static let bedWindowCentre: CGFloat = (GravelDropTuning.bedWindowLo
        + GravelDropTuning.bedWindowHi) / 2                                  //  +7.8
    /// Corrupt clips bite only well inside the ink. Forgiveness belongs on the
    /// catch; a damage box must never be wider than what the player can see.
    static let hitHalf: CGFloat = GravelDropTuning.inkHalfW - 3              //  13.9
    /// `truck.box.fill` (the missing-asset fallback, and the only truck in
    /// `swift run` outside the .app) mirrors the logo — cab on the RIGHT — so
    /// a bed-aligned window is backwards there. Fall back to a symmetric box.
    static let fallbackCatchHalf: CGFloat = GravelDropTuning.inkHalfW
        + GravelDropTuning.itemSize / 2 - 6                                  //  21.9

    static let baseSpeed: CGFloat = 70          // pt/sec at 0 catches
    static let speedPerPoint: CGFloat = 1.6
    static let maxSpeed: CGFloat = 260
    static let baseSpawn: Double = 1.05         // seconds between drops at 0 catches
    static let minSpawn: Double = 0.36
    static let truckSpeed: CGFloat = 320        // pt/sec keyboard glide
    /// Keyboard parity, not difficulty: the mouse path is a 1:1 teleport while
    /// the keyboard is rate-limited, so past the plateau a capped-speed clip
    /// could spawn out of arrow-key reach. Ramps to 430 pt/s, which clears the
    /// playable span inside the fastest clip's flight.
    static let maxTruckSpeed: CGFloat = 430
    static let corruptRate: Double = 0.15
    /// Fall speed caps at ~119 catches and the spawn interval at ~58, so past
    /// that the run is a fixed-difficulty treadmill. Hazard density is the one
    /// dial left that can make the catch risky, and it self-throttles: more
    /// hazards means fewer scorable spawns.
    static let maxCorruptRate: Double = 0.32
    static let corruptRamp: Double = 0.0015
    static let plateauCatches = 120

    /// Combo: catches per multiplier step, and the cap.
    static let comboStep = 8
    static let maxMultiplier = 4

    static let goodSymbols = ["film", "waveform", "photo", "video", "music.note"]
    static let corruptSymbol = "exclamationmark.triangle.fill"
}

// MARK: - Truck sprite

private struct TruckSprite: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let img = TruckSprite.image {
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
        .frame(width: GravelDropTuning.truckWidth, height: GravelDropTuning.truckHeight)
    }
}

// MARK: - Primary view

struct GravelDropView: View {
    /// ArcadeSheet keeps all three games mounted and gates them on this rather
    /// than swapping the view out of the tree: removing the branch destroyed
    /// every `@State` it owned, so a Cmd-Tab wiped the score, lives and field
    /// the sheet's own copy promised to preserve (Opus games review, CRITICAL).
    let paused: Bool

    /// Key bumped to `.v2`: catches now carry a combo multiplier, so scores
    /// run up to 4x the shipped +1-per-clip scale and the old records are not
    /// comparable. A clean slate beats a silently inflated one.
    @AppStorage("arcade.gravelDrop.best.v2") private var best: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [DropItem] = []
    @State private var pops: [GravelPop] = []
    @State private var truckX: CGFloat = 0
    // Two independent flags, not one tri-state: a single `drift` written by a
    // key-agnostic `.up` handler was zeroed when the OPPOSITE arrow was
    // released while this one was still held, and macOS sends no further
    // repeat for the still-held key — the truck froze mid-dodge (Opus games
    // review, MAJOR).
    @State private var heldLeft = false
    @State private var heldRight = false
    @State private var score = 0
    @State private var catches = 0               // difficulty clock — never the
                                                 // multiplied score, so the
                                                 // shipped ramp curve is intact
    @State private var combo = 0
    @State private var lives = GravelDropTuning.startingLives
    @State private var gameOver = false
    @State private var fieldSize: CGSize = .zero
    @State private var spawnClock: Double = 0
    @State private var damageFlash: Double = 0
    /// Squash-and-stretch on the truck when a clip lands in the bed: 1 at
    /// impact, decayed by the tick like damageFlash. The catch is the game's
    /// core loop and the truck itself never reacted — the +N pop floats at
    /// the catch point, but the vehicle taking the load is the reward read.
    @State private var bedBounce: Double = 0
    /// Convoy's pattern: @Environment read inside the Timer closure freezes
    /// at ticker-creation time; @State goes through a box and stays live, so
    /// flipping Reduce Motion mid-run actually stops the bounce.
    @State private var calmMotion = false
    /// The record as it stood when this run began. `best` is now committed the
    /// moment a point is earned, so comparing against it at game over would
    /// read "new best" on every run — and the header pill would just mirror
    /// the live score for the whole record stretch.
    @State private var bestAtStart = 0
    @State private var lastTick: Date? = nil
    @State private var ticker: Timer? = nil

    @FocusState private var focused: Bool

    /// Both arrows held cancels to 0 (deliberate, and conventional).
    private var drift: CGFloat { (heldRight ? 1 : 0) - (heldLeft ? 1 : 0) }

    private var multiplier: Int {
        min(GravelDropTuning.maxMultiplier, 1 + combo / GravelDropTuning.comboStep)
    }

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
        // Kept: a system focus ring around the whole playfield is worse than
        // the problem. The header's "arrows or drag" hint is the cue instead.
        .focusEffectDisabled()
        // Four handlers, each scoped to ONE direction. `.handled` even while
        // paused, never `.ignored`: an ignored arrow walks up to the sheet's
        // segmented picker, which swaps the game and destroys the very run
        // pausing exists to protect.
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
        .onKeyPress(.space) {
            if !paused, gameOver { restart() }
            return .handled
        }
        .onAppear {
            bestAtStart = best
            calmMotion = reduceMotion
            if !paused, !gameOver { startTicker() }
            // `.onKeyPress` only fires on the FOCUSED view, and nothing here
            // ever claimed focus — the arrows silently drove the sheet's
            // segmented picker instead of the truck (Opus games review,
            // MAJOR). Deferred because sheet attachment is not finished when
            // onAppear fires, matching ArcadeSheet's own window-resolution hop.
            DispatchQueue.main.async { if !paused { focused = true } }
        }
        .onDisappear { stopTicker() }
        .onChange(of: reduceMotion) { _, new in
            calmMotion = new
            // Nothing left hanging mid-squash when the setting flips on.
            if new { bedBounce = 0 }
        }
        .onChange(of: paused) { _, p in
            // A key held while the app switched away never delivers its
            // key-up, which would latch the truck into a wall on return.
            heldLeft = false
            heldRight = false
            if p {
                stopTicker()
                // Occlusion / miniaturize is a lifetime boundary the sheet's
                // scenePhase hook does not cover; no arcade note may keep
                // ringing over the paused overlay.
                ArcadeSounds.stopAll()
            } else if !gameOver || damageFlash > 0 {
                // startTicker() re-seeds lastTick, so the first tick after a
                // resume cannot compute dt from a nil clock.
                startTicker()
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Label("\(score)", systemImage: "shippingbox.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Semantics.successText)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: score)
                .accessibilityLabel("Score")
                .accessibilityValue("\(score) clips")
            if multiplier > 1 {
                Text("×\(multiplier)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Semantics.runningText)
                    .monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Semantics.running.opacity(Semantics.chip), in: Capsule())
                    .accessibilityLabel("Score multiplier")
                    .accessibilityValue("\(multiplier) times")
            }
            // The record as it stood at kick-off, not the live `best`: the
            // record is committed on every point now, so `best` would simply
            // track the score for the whole of a record run.
            Text("BEST \(bestAtStart)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("Best score")
                .accessibilityValue("\(bestAtStart)")
            Spacer()
            Text("← → or drag to steer")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .fixedSize()
            HStack(spacing: 3) {
                ForEach(0..<GravelDropTuning.startingLives, id: \.self) { i in
                    Image(systemName: i < lives ? "circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(pipColor(i))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lives")
            .accessibilityValue("\(lives) of \(GravelDropTuning.startingLives)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35))
    }

    /// The pip that just went out carries the damage read-out, so the primary
    /// feedback lands where the state actually lives instead of on a
    /// full-viewport wash.
    private func pipColor(_ i: Int) -> Color {
        if i < lives { return Semantics.warning }
        if i == lives, damageFlash > 0 { return Semantics.danger }
        return Color.secondary.opacity(0.4)
    }

    // MARK: Playfield

    private var field: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Semantics.source.opacity(0.10), Semantics.destination.opacity(0.16)],
                    startPoint: .top, endPoint: .bottom
                )
                .accessibilityHidden(true)

                ForEach(items) { item in
                    Image(systemName: item.symbol)
                        .font(.system(size: GravelDropTuning.itemSize * 0.8, weight: .semibold))
                        .foregroundStyle(item.corrupted ? Semantics.danger : Semantics.source)
                        .frame(width: GravelDropTuning.itemSize, height: GravelDropTuning.itemSize)
                        .position(x: item.x, y: item.y)
                        // A dozen of these appear and vanish per second; they
                        // are the real a11y-tree pollution, not the shapes.
                        .accessibilityHidden(true)
                }

                ForEach(pops) { p in
                    ZStack {
                        if !reduceMotion {
                            Circle()
                                .stroke(Semantics.success.opacity(Double(p.life) * 0.5), lineWidth: 2)
                                .frame(width: 16 + (1 - p.life) * 24,
                                       height: 16 + (1 - p.life) * 24)
                        }
                        Text("+\(p.points)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Semantics.success.opacity(Double(p.life)))
                    }
                    .position(x: p.x, y: p.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                // The bed mouth, drawn at the TRUE catch window so the player
                // can see what the collision test uses. Static — no animation,
                // so Reduce Motion is unaffected.
                if TruckSprite.image != nil {
                    Capsule()
                        .fill(Semantics.destination.opacity(0.28))
                        .frame(width: GravelDropTuning.bedWindowWidth, height: 4)
                        .position(x: truckX + GravelDropTuning.bedWindowCentre,
                                  y: geo.size.height - 6 - GravelDropTuning.truckHeight
                                     + GravelDropTuning.inkTopInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                TruckSprite()
                    // Catch: squash into the suspension and recover (~0.17s,
                    // tick-decayed). Hit: a small wince tilt riding the
                    // existing damageFlash decay — no new state, and inert
                    // under Reduce Motion like the wash it accompanies.
                    .scaleEffect(x: 1 + CGFloat(bedBounce) * 0.05,
                                 y: 1 - CGFloat(bedBounce) * 0.10,
                                 anchor: .bottom)
                    .rotationEffect(.degrees(reduceMotion ? 0 : -damageFlash * 5))
                    .position(x: truckX, y: geo.size.height - GravelDropTuning.truckHeight / 2 - 6)
                    .accessibilityHidden(true)

                if reduceMotion {
                    // Reduce Motion: a held border, not a full-viewport wash.
                    // The wash is driven 1 -> 0 by the 60Hz tick and can fire
                    // three times in a few seconds — exactly the class of
                    // effect the setting exists to suppress, and the rest of
                    // the app treats it as non-negotiable (TruckAnimations,
                    // MicroAnimations, both rails). Opus games review, MAJOR.
                    Rectangle()
                        .strokeBorder(Semantics.danger.opacity(damageFlash > 0 ? 0.7 : 0),
                                      lineWidth: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Rectangle()
                        .fill(Semantics.danger.opacity(damageFlash * 0.35))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if gameOver { gameOverPanel }
            }
            // Sprites spawn at y: -itemSize; keep game art inside the field so
            // it can never paint over the HUD — or, if itemSize grows, the
            // sheet's repeated job verdict, which the house rule forbids
            // outright. Matches Convoy's playfield.
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Belt-and-braces behind the sheet's material overlay:
                        // a paused game must not be steered.
                        guard !paused else { return }
                        if !focused { focused = true }
                        heldLeft = false
                        heldRight = false
                        truckX = clampX(v.location.x, width: geo.size.width)
                    }
            )
            .onAppear { syncSize(geo.size) }
            .onChange(of: geo.size) { _, new in syncSize(new) }
        }
    }

    private var gameOverPanel: some View {
        VStack(spacing: 10) {
            Text("BED FULL OF JUNK")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Semantics.dangerText)
            Text("\(score) clips offloaded" + (score > bestAtStart ? "  ·  new best" : ""))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Restart") { restart() }
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
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            // Installed only on RunLoop.main; execute in-place so no queued
            // game tick can fire after the sheet's stopTicker/onDisappear.
            MainActor.assumeIsolated {
                let now = Date()
                let dt = min(0.05, now.timeIntervalSince(lastTick ?? now))
                lastTick = now
                step(dt)
            }
        }
        // The Dump Yard's whole point is that it runs WHILE a card hauls, i.e.
        // while the engine is saturating the CPU hashing and copying. Let the
        // run loop coalesce these wakeups; `step` is dt-driven and clamps dt
        // to 0.05, so a coalesced tick changes nothing (Opus games review).
        t.tolerance = 1.0 / 240.0
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    private func step(_ dt: TimeInterval) {
        guard fieldSize.width > 0 else { return }
        if damageFlash > 0 { damageFlash = max(0, damageFlash - dt * 2.5) }
        if bedBounce > 0 { bedBounce = max(0, bedBounce - dt * 6) }
        agePops(dt)
        guard !gameOver else {
            // Nothing left to drive. A game-over panel left open for the rest
            // of a 40-minute offload used to burn 60 wakeups/sec doing
            // nothing. Invalidating from inside the timer's own main-thread
            // fire block is legal — an invalidated timer cannot fire again and
            // execution stays in place, so the comment above still holds.
            if damageFlash == 0, bedBounce == 0, pops.isEmpty { stopTicker() }
            return
        }

        let glide = min(GravelDropTuning.maxTruckSpeed,
                        GravelDropTuning.truckSpeed
                            + CGFloat(max(0, catches - GravelDropTuning.plateauCatches)) * 1.2)
        if drift != 0 {
            truckX = clampX(truckX + drift * glide * CGFloat(dt), width: fieldSize.width)
        }

        spawnClock -= dt
        if spawnClock <= 0 {
            spawn()
            let interval = max(GravelDropTuning.minSpawn,
                               GravelDropTuning.baseSpawn - Double(catches) * 0.012)
            spawnClock = interval * Double.random(in: 0.75...1.25)
        }

        // The catch band is the drawn bed, not the sprite's letterboxed frame:
        // the frame top sits 9.6pt above the roof and the frame bottom 9.7pt
        // below the tyres, so items used to vanish into empty transparency.
        // Band is 20.7pt; worst-case fall per tick is maxSpeed 260 x 1.15
        // jitter x the 0.05 dt cap = 15pt, so nothing can tunnel through.
        let frameTop = fieldSize.height - GravelDropTuning.truckHeight - 6
        let bedTop = frameTop + GravelDropTuning.inkTopInset
        let bedBottom = fieldSize.height - 6 - GravelDropTuning.inkBottomInset
        var caughtGood = 0
        var caughtAt: [CGPoint] = []
        var hit = false
        var missedGood = false

        items = items.compactMap { item in
            var it = item
            it.y += it.speed * CGFloat(dt)
            if it.y >= bedTop, it.y <= bedBottom, intercepts(it) {
                if it.corrupted {
                    hit = true
                } else {
                    caughtGood += 1
                    caughtAt.append(CGPoint(x: it.x, y: it.y))
                }
                return nil
            }
            if it.y > fieldSize.height + GravelDropTuning.itemSize {
                // A corrupt clip falling past is a DODGE, not a miss — it must
                // never break the combo.
                if !it.corrupted { missedGood = true }
                return nil
            }
            return it
        }

        if caughtGood > 0 {
            catches += caughtGood
            combo += caughtGood
            score += caughtGood * multiplier
            // Commit the record on the point, not on death: closing the sheet
            // or quitting mid-run discarded a record run outright, and the
            // Dump Yard's natural end is "the card finished", not "I died"
            // (Opus games review, MAJOR).
            if score > best { best = score }
            for p in caughtAt {
                pops.append(GravelPop(x: p.x, y: p.y, life: 1, points: multiplier))
            }
            ArcadeSounds.catchGood.play()
            if !calmMotion { bedBounce = 1 }
        }
        if missedGood {
            // Only audible once a multiplier was actually lost; a click on
            // every trivial early miss is noise, not feedback. `.flip` rather
            // than `.bad` so the life-loss sound keeps its single meaning.
            if combo >= GravelDropTuning.comboStep { ArcadeSounds.flip.play(volume: 0.18) }
            combo = 0
        }
        if hit {
            damageFlash = 1
            combo = 0
            lives -= 1
            // `.level()` only — "hit a wall". The fun layer must never speak
            // the safety vocabulary, so no verdictFailure() here even at game
            // over: an operator who has learned that triple alert as "a
            // transfer failed" must not get it from a mini game.
            Haptics.level()
            ArcadeSounds.bad.play()
            if lives <= 0 {
                lives = 0
                gameOver = true
                ArcadeSounds.gameOver.play()
                // Announced alongside the cue so the end of a run is not
                // gated on Pref.soundEffects. `bestAtStart` is read, not
                // `best` — the record was already raised on the way here.
                AccessibilityNotification.Announcement(
                    "Game over. \(score) clips offloaded."
                        + (score > bestAtStart ? " New best." : "")
                ).post()
            }
        }
    }

    private func agePops(_ dt: TimeInterval) {
        guard !pops.isEmpty else { return }
        for i in pops.indices {
            // Reduce Motion keeps the "+N" and its fade but drops the drift —
            // a dignified static fallback, not a removed reward. calmMotion,
            // not reduceMotion: this runs inside the Timer closure, where the
            // @Environment read is frozen at ticker creation (Opus final
            // bugcheck — the one straggler after the calmMotion adoption).
            if !calmMotion { pops[i].y -= 26 * CGFloat(dt) }
            pops[i].life -= 1.8 * CGFloat(dt)
        }
        pops.removeAll { $0.life <= 0 }
    }

    private func spawn() {
        let rate = min(GravelDropTuning.maxCorruptRate,
                       GravelDropTuning.corruptRate
                           + Double(max(0, catches - GravelDropTuning.plateauCatches))
                             * GravelDropTuning.corruptRamp)
        let corrupted = Double.random(in: 0...1) < rate
        let margin = GravelDropTuning.itemSize
        let speed = min(GravelDropTuning.maxSpeed,
                        GravelDropTuning.baseSpeed + CGFloat(catches) * GravelDropTuning.speedPerPoint)
        items.append(DropItem(
            x: CGFloat.random(in: margin...(max(margin + 1, fieldSize.width - margin))),
            y: -margin,
            speed: speed * CGFloat.random(in: 0.9...1.15),
            symbol: corrupted ? GravelDropTuning.corruptSymbol
                              : GravelDropTuning.goodSymbols.randomElement() ?? "film",
            corrupted: corrupted
        ))
    }

    // MARK: Helpers

    /// Horizontal window for a clip at `it.x`. Good clips must land in the
    /// BED; corrupt clips only bite well inside the ink, so the catch window
    /// is a strict superset of the damage window at every point.
    private func intercepts(_ it: DropItem) -> Bool {
        if it.corrupted {
            return abs(it.x - truckX) <= GravelDropTuning.hitHalf
        }
        guard TruckSprite.image != nil else {
            return abs(it.x - truckX) <= GravelDropTuning.fallbackCatchHalf
        }
        return it.x >= truckX + GravelDropTuning.bedWindowLo
            && it.x <= truckX + GravelDropTuning.bedWindowHi
    }

    private func clampX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        // Bound the ART, not the empty letterbox: clamping to truckWidth / 2
        // penned the truck 32pt from each wall while spawn() drops clips as
        // close as itemSize (22), and it visibly stopped the drawing 12pt
        // short of each edge.
        let half = GravelDropTuning.inkHalfW
        guard width > half * 2 else { return width / 2 }
        return min(max(x, half), width - half)
    }

    private func syncSize(_ size: CGSize) {
        fieldSize = size
        if truckX == 0 { truckX = size.width / 2 }
        truckX = clampX(truckX, width: size.width)
    }

    private func restart() {
        items.removeAll()
        pops.removeAll()
        score = 0
        catches = 0
        combo = 0
        lives = GravelDropTuning.startingLives
        heldLeft = false
        heldRight = false
        damageFlash = 0
        bedBounce = 0
        spawnClock = 0.4
        gameOver = false
        // A second run in the same session compares against the record the
        // first run may have just set.
        bestAtStart = best
        truckX = fieldSize.width / 2
        // The Restart button's `.defaultAction` shortcut still fires under the
        // sheet's paused overlay, so never start a loop that would then run
        // invisibly — the paused -> live transition starts it instead.
        if !paused { startTicker() }
        // The game-over Restart button held focus until it was torn down.
        focused = true
    }
}
