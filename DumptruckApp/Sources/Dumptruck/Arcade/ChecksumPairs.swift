import SwiftUI
import AppKit

// MARK: - Model

private struct PairCard: Identifiable, Equatable {
    let id: Int
    let kind: Int          // index into ChecksumPairsView.kinds
    let hex: String        // fake short checksum caption
    var faceUp: Bool = false
    var matched: Bool = false
}

/// Horizontal refusal wiggle for a mismatched pair. One unit of
/// animatableData = one full left-right-left sweep ending at rest
/// (sin(3πn) = 0 at every integer). GeometryEffect so the translation
/// interpolates through the curve instead of jumping between states.
private struct CardShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 4 * sin(animatableData * .pi * 3), y: 0))
    }
}

// MARK: - View

struct ChecksumPairsView: View {
    /// Paused, never unmounted. ArcadeSheet keeps the board alive across an
    /// app switch instead of tearing the view down — this game IS the memory
    /// the player has built over 20+ moves, and a rebuild silently discarded
    /// it (Opus games review). Nothing here may resolve, ring or accept input
    /// while the pause overlay covers the yard.
    let paused: Bool

    fileprivate static let kinds: [(symbol: String, label: String)] = [
        ("film", "film"),
        ("waveform", "audio"),
        ("photo", "still"),
        ("doc", "sidecar"),
        ("camera", "cam"),
        ("sdcard", "card"),
        ("externaldrive", "drive"),
        ("lock", "locked")
    ]

    private static let columns = 4
    private static let rows = 4
    /// Pairs are DERIVED from the board, never assumed equal to `kinds.count`:
    /// the two were consistent only by coincidence at 8, so a ninth symbol
    /// would have dealt 18 cards onto a 16-cell grid and made the board
    /// unwinnable with two cards that never render.
    private static let pairCount = min(kinds.count, (rows * columns) / 2)

    @AppStorage("arcade.checksumPairs.best") private var bestMoves: Int = 0

    @State private var cards: [PairCard] = []
    @State private var flipped: [Int] = []
    @State private var moves: Int = 0
    @State private var matchedPairs: Int = 0
    @State private var cursor: Int = 0
    @State private var locked: Bool = false
    @State private var streak: Int = 0
    /// Captured at the moment of decision. Reading the persisted record back
    /// after writing it announced "new best" for a mere tie.
    @State private var isNewBest: Bool = false
    /// Bumped by `deal()` so a RE-deal has something to animate off: the grid
    /// is positional, so a fresh shuffle inserts no views on its own.
    @State private var dealSeed: Int = 0
    @State private var dealtAt = Date()
    /// Solve time accumulated across pauses — a board left covered while a
    /// card hauls must not bill the operator for the wait.
    @State private var bankedTime: TimeInterval = 0
    @State private var solveSeconds: TimeInterval = 0
    @State private var flipBackTask: Task<Void, Never>? = nil
    @State private var glowPair: Set<Int> = []
    @State private var glowTask: Task<Void, Never>? = nil
    @State private var winCueTask: Task<Void, Never>? = nil
    /// Per-card wiggle counter: +1 = one full left-right-left sweep, so the
    /// two halves of a wrong pair visibly refuse before they flip back.
    @State private var cardShakes: [Int: Int] = [:]
    /// The win panel waits for the cascade sweep (below) to finish; under
    /// Reduce Motion it is set synchronously and nothing moves.
    @State private var winShown = false
    @State private var winRevealTask: Task<Void, Never>? = nil

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// No macOS semantic style lands on 20 pt (.title3 is 15, .title2 17), so
    /// this is the one metric that needs scaling by hand; every other size in
    /// the file is a semantic font that follows the operator's Text Size.
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 20

    private var won: Bool { matchedPairs == Self.pairCount }

    var body: some View {
        VStack(spacing: 10) {
            header
            ZStack {
                grid
                    // Dimmed only once the panel arrives, so the win cascade
                    // sweeps a full-brightness board first. Input and the
                    // accessibility tree retire on `won` immediately.
                    .opacity(winShown ? 0.18 : 1)
                    .allowsHitTesting(!won)
                    // .allowsHitTesting does NOT retire a view from the
                    // accessibility tree: without this VoiceOver keeps walking
                    // the finished board instead of the result.
                    .accessibilityHidden(won)
                if winShown {
                    winOverlay
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            footer
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($focused)
        // Arrows repeat while held (matching GravelDrop). Space/return
        // deliberately do NOT: `activate()` re-deals a solved board, so a held
        // space would reshuffle over and over.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                    phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow:  moveCursor(dx: -1, dy: 0)
            case .rightArrow: moveCursor(dx: 1, dy: 0)
            case .upArrow:    moveCursor(dx: 0, dy: -1)
            default:          moveCursor(dx: 0, dy: 1)
            }
            return .handled
        }
        .onKeyPress(.space) { activate(); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onAppear {
            if cards.isEmpty { deal() }
            focused = true
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                // A pending flip-back must not resolve behind the overlay, and
                // a queued win cue must not ring over the safety UI —
                // stopAll() cannot stop a sound that has not started yet.
                flipBackTask?.cancel(); flipBackTask = nil
                winCueTask?.cancel(); winCueTask = nil
                // A cascade interrupted by a pause skips straight to the
                // panel: the overlay must never resume onto a won board with
                // no result showing.
                winRevealTask?.cancel(); winRevealTask = nil
                if won, !winShown { glowPair = []; winShown = true }
                bankedTime += Date().timeIntervalSince(dealtAt)
            } else {
                dealtAt = Date()
                if locked, flipped.count == 2 { scheduleFlipBack() }
            }
        }
        .onDisappear {
            flipBackTask?.cancel(); flipBackTask = nil
            glowTask?.cancel(); glowTask = nil
            winCueTask?.cancel(); winCueTask = nil
            winRevealTask?.cancel(); winRevealTask = nil
            if won, !winShown { glowPair = []; winShown = true }
        }
        .onChange(of: reduceMotion) { _, new in
            // Reduce Motion flipped on mid-cascade: stop the sweep and show
            // the result now — the sweep and its spring are exactly the class
            // of motion the setting suppresses.
            guard new else { return }
            winRevealTask?.cancel(); winRevealTask = nil
            if won, !winShown { glowPair = []; winShown = true }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            if let logo = Self.logoImage {
                Image(nsImage: logo)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .opacity(0.85)
            }
            Text("Checksum Pairs")
                .font(Typo.safety)
            Spacer()
            // Text tokens, not vibrants: the pill's bold digits sat at ~1.7:1
            // on their own wash with Color.green (Opus verification) — same
            // conversion the other two games' HUDs got in the color pass.
            scorePill("moves", "\(moves)", Semantics.runningText)
            scorePill("best", bestMoves > 0 ? "\(bestMoves)" : "—", Semantics.successText)
        }
    }

    private func scorePill(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(Typo.hint.weight(.semibold))
                .foregroundStyle(.secondary)
            // Monospaced so a live counter does not jitter as digits change
            // (same idiom as SettingsView's `.caption.monospaced()`).
            Text(value)
                .font(Typo.evidence.weight(.bold).monospaced())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.10)))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("arrows move · space flips · fewer moves is better")
                .font(Typo.hint)
                .foregroundStyle(.secondary)
            Spacer()
            Button("New deal") { deal() }
                .buttonStyle(HoverHighlightButtonStyle())
                .font(Typo.evidence)
                .foregroundStyle(Semantics.sourceText)
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            let cellW = (geo.size.width - CGFloat(Self.columns - 1) * gap) / CGFloat(Self.columns)
            let cellH = (geo.size.height - CGFloat(Self.rows - 1) * gap) / CGFloat(Self.rows)
            // Grow into the ~44 pt of vertical slack the sheet already hands
            // this panel, never below the old 58, and stay landscape: square
            // cards would shrink ~112 -> ~69 wide and strand the 4x4 block in
            // the middle of a 460+ pt panel.
            let h = max(58, cellH)
            let w = max(24, min(cellW, h * 1.4))   // floor: a negative frame is a crash-adjacent layout
            VStack(spacing: gap) {
                ForEach(0..<Self.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<Self.columns, id: \.self) { col in
                            let index = row * Self.columns + col
                            if index < cards.count {
                                cardView(cards[index], index: index)
                                    .frame(width: w, height: h)
                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                                    .id("\(dealSeed)-\(cards[index].id)")
                                    // Outside the .id on purpose: this modifier
                                    // keeps its own identity across the swap, so
                                    // it still sees dealSeed change and can
                                    // stagger the insertion into a deal gesture.
                                    .animation(reduceMotion ? nil
                                               : Animation.easeOut(duration: 0.22)
                                                   .delay(Double(index) * 0.015),
                                               value: dealSeed)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var winOverlay: some View {
        VStack(spacing: 8) {
            Text("all pairs verified")
                .font(.headline)
                .foregroundStyle(Semantics.successText)
                .accessibilityAddTraits(.isHeader)
            Text("\(moves) moves\(isNewBest ? " · new best" : "")")
                .font(Typo.evidence.monospaced())
                .foregroundStyle(.secondary)
            Text("\(grade) · \(Self.timeText(solveSeconds))")
                .font(Typo.hint)
                .foregroundStyle(.secondary)
            Button("Restart") { deal() }
                .buttonStyle(.borderedProminent)
                .tint(Semantics.destination)
                .controlSize(.small)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Semantics.success.opacity(0.45), lineWidth: 1))
    }

    /// Tiers are set off realistic play, not the theoretical floor: a run that
    /// equals `pairCount` only happens by luck, so advertising it as the target
    /// would set an unreachable bar.
    private var grade: String {
        if moves <= Self.pairCount * 3 / 2 { return "clean verify" }
        if moves <= Self.pairCount * 2 { return "passed" }
        return "re-verify"
    }

    // MARK: Card

    @ViewBuilder
    private func cardView(_ card: PairCard, index: Int) -> some View {
        let showFace = card.faceUp || card.matched
        let kind = Self.kinds[card.kind]
        let isCursor = index == cursor
        let glowing = glowPair.contains(index)
        // SwiftUI layers are double-sided: a container held at 180 degrees
        // draws its content MIRRORED. So the face-down "?" rendered reversed at
        // rest on all 16 cards, and a just-revealed hex read backwards for the
        // whole 180->90 half of the flip. Keep both sides resident, pre-rotate
        // the back (180 + 180 = identity, so it reads forward while face down),
        // and hard-cut the two opacities at the edge-on midpoint where neither
        // side has any rendered width.
        let swapAnim: Animation? = reduceMotion ? nil : Animation.linear(duration: 0.01).delay(0.14)
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(showFace ? Color(nsColor: .controlBackgroundColor) : Semantics.source.opacity(0.16))
            VStack(spacing: 3) {                                  // face
                Image(systemName: kind.symbol)
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(card.matched ? Semantics.success : Semantics.destination)
                Text("xxh64 \(card.hex)")
                    .font(Typo.hint.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
            }
            .opacity(showFace ? 1 : 0)
            .animation(swapAnim, value: showFace)
            Image(systemName: "questionmark")                     // back
                .font(.headline.weight(.bold))
                .foregroundStyle(Semantics.source.opacity(0.55))
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .opacity(showFace ? 0 : 1)
                .animation(swapAnim, value: showFace)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor(card, isCursor: isCursor), lineWidth: isCursor ? 2 : 1)
        )
        .shadow(color: card.matched ? Semantics.success.opacity(glowing ? 0.75 : 0.35) : .clear,
                radius: card.matched ? (glowing ? 10 : 4) : 0)
        .rotation3DEffect(.degrees(reduceMotion || showFace ? 0 : 180), axis: (x: 0, y: 1, z: 0))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: showFace)
        // Keyed on this card's own glow, so a pulse re-animates the two cards
        // it lands on instead of all 16.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: glowing)
        .modifier(CardShake(animatableData: CGFloat(cardShakes[index, default: 0])))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            cursor = index
            focused = true
            reveal(index)
        }
        // `.onTapGesture` is not an accessibility action, so before this a
        // VoiceOver user could read every card and flip none of them. Position
        // is the load-bearing half of the label — the cursor is otherwise only
        // a 2 pt border. `children: .ignore` also keeps the always-resident
        // face from leaking a face-down card's kind and hex.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isCursor ? [.isSelected] : [])
        .accessibilityLabel(
            "row \(index / Self.columns + 1), column \(index % Self.columns + 1)"
            + (showFace ? ", \(kind.label) \(card.hex)" : "")
        )
        .accessibilityValue(card.matched ? "verified" : (card.faceUp ? "face up" : "face down"))
        .accessibilityAction {
            cursor = index
            focused = true
            reveal(index)
        }
    }

    private func borderColor(_ card: PairCard, isCursor: Bool) -> Color {
        if card.matched { return Semantics.success.opacity(0.8) }
        if isCursor { return Semantics.running.opacity(0.9) }
        return Color.primary.opacity(0.10)
    }

    // MARK: Game logic

    private func deal() {
        flipBackTask?.cancel(); flipBackTask = nil
        glowTask?.cancel(); glowTask = nil
        winCueTask?.cancel(); winCueTask = nil
        winRevealTask?.cancel(); winRevealTask = nil
        winShown = false
        cardShakes = [:]
        glowPair = []
        var built: [PairCard] = []
        var id = 0
        // Captions are drawn WITHOUT replacement: two different kinds sharing a
        // checksum is the one thing this app's fiction cannot say, and at four
        // hex digits the collision lands on ~0.04% of deals — always in front
        // of the player who is actually reading the captions.
        var used = Set<String>()
        for kind in 0..<Self.pairCount {
            var hex = Self.randomHex()
            while !used.insert(hex).inserted { hex = Self.randomHex() }
            for _ in 0..<2 {
                built.append(PairCard(id: id, kind: kind, hex: hex))
                id += 1
            }
        }
        built.shuffle()
        cards = built
        dealSeed &+= 1
        flipped = []
        moves = 0
        matchedPairs = 0
        cursor = 0
        locked = false
        streak = 0
        isNewBest = false
        solveSeconds = 0
        bankedTime = 0
        dealtAt = Date()
    }

    /// Row/column aware. The old flat `±1` / `±columns` arithmetic wrapped
    /// Left at column 0 onto the previous row's last card while Up on row 0 did
    /// nothing at all — two different edge behaviours on one grid, neither
    /// announced. The loop is bounded by the axis length so a fully matched row
    /// or column cannot spin forever looking for a live card.
    private func moveCursor(dx: Int, dy: Int) {
        guard !paused, !cards.isEmpty, !won else { return }
        let start = cursor
        var row = cursor / Self.columns
        var col = cursor % Self.columns
        let steps = dx != 0 ? Self.columns : Self.rows
        for _ in 0..<steps {
            col = (col + dx + Self.columns) % Self.columns
            row = (row + dy + Self.rows) % Self.rows
            let candidate = row * Self.columns + col
            guard candidate < cards.count else { continue }
            cursor = candidate
            if !cards[candidate].matched { announceCursor(); return }
        }
        if cursor == start {
            Haptics.level()   // nowhere to go — the app's "refused" pattern
        } else {
            announceCursor()
        }
    }

    private func activate() {
        guard !paused else { return }
        guard !won else { deal(); return }
        reveal(cursor)
    }

    private func reveal(_ index: Int) {
        guard !paused, !won, index >= 0, index < cards.count else { return }
        // An impatient input RESOLVES the pending mismatch instead of being
        // swallowed: the pair snaps face down and this flip lands in the same
        // gesture. ~20 mismatches a solve used to mean ~16 s of silently dead
        // input. Tapping a card that is itself part of the pending pair only
        // clears it, otherwise it would re-flip as card 1 of the next pair.
        if locked {
            let wasPending = flipped.contains(index)
            resolvePending()
            if wasPending { return }
        }
        guard !cards[index].matched, !cards[index].faceUp else {
            // Haptics only, no sound: `.level()` is this app's "refused or hit
            // a wall" pattern (Haptics.swift), and a click on every blocked tap
            // would just be noise under a live VerdictBadge.
            Haptics.level()
            return
        }

        cards[index].faceUp = true
        flipped.append(index)
        // No flip cue on the card that completes a pair — it would double the
        // match sting a frame later.
        if flipped.count == 1 { ArcadeSounds.flip.play(volume: 0.3) }
        guard flipped.count == 2 else { return }

        moves += 1
        let a = flipped[0], b = flipped[1]
        if cards[a].kind == cards[b].kind {
            cards[a].matched = true
            cards[b].matched = true
            flipped.removeAll()
            matchedPairs += 1
            streak += 1
            pulseGlow(a, b)
            ArcadeSounds.match.play(volume: min(0.75, 0.4 + Float(streak) * 0.08))
            // `.alignment` is "the action landed". Deliberately NOT the double
            // `.generic` / triple `.levelChange` patterns — Haptics.swift
            // reserves those for terminal job verdicts, and this sheet renders
            // a live VerdictBadge directly above the board.
            Haptics.alignment()
            // Assistive speech is NOT gated on Pref.soundEffects: that governs
            // ArcadeSounds, and gating VoiceOver on a sound toggle would
            // re-break the thing this fixes. `post()` is inert with no AT running.
            announce("pair verified, \(matchedPairs) of \(Self.pairCount)")
            if matchedPairs == Self.pairCount {
                // Read the record BEFORE writing it: comparing against the
                // already-updated value called a tie a new best.
                isNewBest = bestMoves == 0 || moves < bestMoves
                if isNewBest { bestMoves = moves }
                solveSeconds = bankedTime + Date().timeIntervalSince(dealtAt)
                // Win cascade: a rolling glow WAVE across the pairs in grid
                // order on the still-bright board, THEN the panel springs in.
                // The 70ms step deliberately undercuts the 250ms per-card
                // glow ease, so pulses overlap into one travelling wave
                // rather than eight isolated blinks.
                // The per-match pulseGlow above would clear glowPair mid-
                // sweep, so its task dies first. Reduce Motion: no sweep,
                // panel immediately.
                glowTask?.cancel(); glowTask = nil
                winRevealTask?.cancel()
                if reduceMotion {
                    // pulseGlow above set the final pair glowing and its
                    // clearing task was just cancelled — clear it here or the
                    // pair stays lit under the panel until the next deal.
                    glowPair = []
                    winShown = true
                } else {
                    winRevealTask = Task { @MainActor in
                        var seenKinds = Set<Int>()
                        for idx in cards.indices {
                            let kind = cards[idx].kind
                            guard seenKinds.insert(kind).inserted else { continue }
                            glowPair = Set(cards.indices.filter { cards[$0].kind == kind })
                            try? await Task.sleep(nanoseconds: 70_000_000)
                            if Task.isCancelled { return }
                        }
                        glowPair = []
                        withAnimation(.spring(duration: 0.3)) { winShown = true }
                    }
                }
                // The one game you can WIN must not sign off with the descending
                // cue the other two play on a loss. Offset so it reads as its own
                // beat instead of doubling the match sting; cancelled on pause,
                // re-deal and dismissal, because stopAll() cannot stop a sound
                // that has not started. (A dedicated `arcade_win` asset would be
                // better than the catch ping, but that is an ArcadeSounds change.)
                winCueTask?.cancel()
                // Timed to land WITH the panel: the cascade sweep runs
                // pairCount x 70 ms (~560 ms) before the spring; under Reduce
                // Motion the panel is immediate and the old offset stands.
                let cueDelay: UInt64 = reduceMotion ? 380_000_000 : 620_000_000
                winCueTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: cueDelay)
                    if Task.isCancelled { return }
                    ArcadeSounds.catchGood.play(volume: 0.5)
                }
                announce("all pairs verified in \(moves) moves" + (isNewBest ? ", new best" : ""))
            }
        } else {
            streak = 0
            locked = true
            ArcadeSounds.bad.play(volume: 0.25)
            if !reduceMotion {
                // One sweep per mismatch, per card — the counter only grows,
                // so the GeometryEffect always animates exactly one unit.
                withAnimation(.linear(duration: 0.3)) {
                    cardShakes[a, default: 0] += 1
                    cardShakes[b, default: 0] += 1
                }
            }
            scheduleFlipBack()
        }
    }

    /// Shorter than the old hard 0.8 s, and shorter still under reduce motion
    /// where the flip itself is instant. Since an input during the window now
    /// resolves it early, this is the generous path rather than a lockout.
    private func scheduleFlipBack() {
        flipBackTask?.cancel()
        let delay: UInt64 = reduceMotion ? 350_000_000 : 650_000_000
        flipBackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            resolvePending()
        }
    }

    /// Safe to call from inside `flipBackTask` itself: cancellation is
    /// cooperative and the three statements after it are synchronous.
    private func resolvePending() {
        flipBackTask?.cancel(); flipBackTask = nil
        for i in flipped where i < cards.count { cards[i].faceUp = false }
        flipped.removeAll()
        locked = false
    }

    /// Both halves glow. Pulsing only the second card made the reward read as
    /// if that card did the work, when the first is the one the player
    /// remembered — and it made the pair harder to confirm as a pair.
    private func pulseGlow(_ a: Int, _ b: Int) {
        glowTask?.cancel()
        glowPair = [a, b]
        glowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            if Task.isCancelled { return }
            glowPair = []
        }
    }

    // MARK: Accessibility

    /// The keyboard cursor is expressed only as a border, so arrow keys are
    /// silent to VoiceOver without this.
    private func announceCursor() {
        guard cursor >= 0, cursor < cards.count else { return }
        let card = cards[cursor]
        announce("row \(cursor / Self.columns + 1), column \(cursor % Self.columns + 1), "
                 + (card.matched ? "verified" : (card.faceUp ? "face up" : "face down")))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Helpers

    private static func randomHex() -> String {
        let digits = "0123456789abcdef"
        return String((0..<4).map { _ in digits.randomElement()! })
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
