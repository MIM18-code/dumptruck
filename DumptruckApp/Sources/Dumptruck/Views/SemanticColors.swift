import AppKit
import SwiftUI

private func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
}

/// Pinned, appearance-resolved, never the system accent. Resolved at draw
/// time, so one token is correct in both modes and inside shape styles.
private func pinned(_ name: String, light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

/// TEXT variants of the pinned palette. Same hue family as the vibrant fill
/// tokens, darkened in light mode to clear WCAG AA (>=4.5:1) for small text,
/// and left vibrant (or lifted) in dark mode so nothing regresses there.
/// Rule of use (revised 2026-08-28 audit): TEXT, small safety glyphs, AND
/// decorative role glyphs take these — at this app's 10-11pt sizes an SF
/// Symbol carries the same visual weight as the text beside it, and the
/// vibrant tokens measured 2.0-3.5:1 as glyphs on cards. Shape fills, bars,
/// tracks, tints on progress views, drop-target strokes, and game ART (the
/// arcade's sprites and hazards) keep the vibrant `Semantics.*` tokens.
extension Semantics {
    // Dark values re-derived 2026-08-28 (color audit): warning/danger/source
    // were lifted so text clears AA on its own tinted washes (the KEEP CARD
    // chip measured 3.81:1 before), and success got its own value instead of
    // aliasing the vibrant fill. The lifts also tighten the dark family's
    // OKLCH lightness spread to match the light family's.
    static let successText     = pinned("dt.successText",     light: srgb( 14, 122,  52), dark: srgb( 76, 216, 107))
    static let warningText     = pinned("dt.warningText",     light: srgb(154,  74,   0), dark: srgb(247, 162,  74))
    static let dangerText      = pinned("dt.dangerText",      light: srgb(193,  37,  27), dark: srgb(255, 140, 130))
    static let runningText     = pinned("dt.runningText",     light: srgb( 88,  86, 214), dark: srgb(167, 163, 255))
    static let sourceText      = pinned("dt.sourceText",      light: srgb( 10,  95, 203), dark: srgb(124, 182, 255))
    static let destinationText = pinned("dt.destinationText", light: srgb( 14, 116, 144), dark: srgb( 64, 200, 224))

    /// The wash scale (2026-08-28 color audit): fifteen ad-hoc alphas were
    /// doing five jobs, and identical error strips disagreed about their own
    /// ground. Two stops, non-text fills only — text always takes a `*Text`
    /// token ON one of these. (A third "emphasis" stop was cut the same day:
    /// its one candidate call site was a chip, and a two-stop scale that is
    /// fully used beats a three-stop scale with a dead stop.)
    static let wash: Double = 0.10          // strips, panels, quiet grounds
    static let chip: Double = 0.14          // capsules, chips, badges

    /// Ink for a FILLED verdict badge. Inverted on purpose: light-mode badges
    /// are dark fills carrying white text, dark-mode badges are vibrant fills
    /// carrying near-black text. Never `.primary`.
    static let badgeInk = pinned("dt.badgeInk", light: .white, dark: srgb(13, 13, 15))

    /// Fill for `.borderedProminent` buttons that must carry a WHITE system
    /// label in BOTH modes (Force Eject). Fixed, not mode-flipping.
    static let dangerProminent = pinned("dt.dangerProminent", light: srgb(193, 37, 27), dark: srgb(193, 37, 27))
}

/// Brand chrome — the hand-inked logo's amber, pinned in both modes. Amber is
/// the app's voice, not a safety word: it may tint primary actions and the
/// COPYING phase, and must never appear in verdict vocabulary (warning stays
/// the redder `Semantics.warning` precisely so brand amber can't be misread
/// as a caution). Introduced in the 2026-08-26 facelift (Victor's "ugly and
/// busy" + Kimi K3 design review): the chrome carries the identity, the
/// pinned semantic palette keeps carrying safety.
enum Brand {
    /// Logo amber (#F2B03B), identical in both modes — it always carries the
    /// near-black ink label below, so it needs no appearance flip.
    static let amber = pinned("dt.brandAmber", light: srgb(242, 176, 59), dark: srgb(242, 176, 59))
    /// The logo's ink — label color ON amber fills (8.31:1 on #F2B03B,
    /// measured 2026-08-28; an earlier comment understated it as 7.9).
    static let ink = pinned("dt.brandInk", light: srgb(42, 33, 24), dark: srgb(42, 33, 24))
}

/// Hover backdrop for borderless/plain controls in the BODY of the app.
/// macOS hands toolbar items a translucent rounded hover highlight for free;
/// body controls styled .plain/.borderless got nothing, so the chrome felt
/// alive while the content felt dead (Joshua, 2026-08-28). One style, every
/// bare clickable icon, text button, and row. Press responds with light,
/// not motion, matching BrandProminentButtonStyle.
struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hoverHighlight()
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

/// The same backdrop for clickables that are NOT plain Buttons — borderless
/// Menus, and .link buttons that keep their link styling. Hover parity is a
/// property of "clickable", not of Button.
struct HoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(hovering && isEnabled
                        ? AnyShapeStyle(.quaternary)
                        : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlightModifier()) }
}

/// Primary-action style: amber fill, ink label. Brightness on press — never
/// motion (hover-lift is a web-ism; Mac buttons respond with light).
struct BrandProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Brand.amber, in: .rect(cornerRadius: 8))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
