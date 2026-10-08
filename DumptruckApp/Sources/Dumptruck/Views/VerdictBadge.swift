import SwiftUI

/// ONE verdict, filled where it matters, icon-bearing, non-overlapping copy —
/// rendered in exactly one place per job (the job card header). Rails never
/// carry a verdict word; they may echo Job.verdict as a lowercase pointer.
struct VerdictBadge: View {
    let verdict: Job.Verdict
    let phaseText: String   // running phases show their phase label

    private struct ChipStyle {
        let ink: AnyShapeStyle
        let background: AnyShapeStyle
        let border: AnyShapeStyle
    }

    private var style: ChipStyle {
        switch verdict {
        case .unverified, .failed:
            return ChipStyle(ink: AnyShapeStyle(Semantics.badgeInk),
                             background: AnyShapeStyle(Semantics.dangerText),
                             border: AnyShapeStyle(Color.clear))
        case .safeToWipe:
            return ChipStyle(ink: AnyShapeStyle(Semantics.badgeInk),
                             background: AnyShapeStyle(Semantics.successText),
                             border: AnyShapeStyle(Color.clear))
        case .verifiedKeepCard:
            return ChipStyle(ink: AnyShapeStyle(Semantics.warningText),
                             background: AnyShapeStyle(Semantics.warning.opacity(Semantics.chip)),
                             border: AnyShapeStyle(Semantics.warningText.opacity(0.45)))
        case .running:
            // Neutral on purpose: the running card already carries indigo
            // chrome, and `.secondaryLabelColor` measures 4.05:1 on white
            // (3.90:1 on a card — still below AA, so labelColor stands).
            return ChipStyle(ink: AnyShapeStyle(Color(nsColor: .labelColor)),
                             background: AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)),
                             border: AnyShapeStyle(Color(nsColor: .separatorColor)))
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Latched, not computed from reduceMotion inline: `symbolEffect(value:)`
    /// fires on ANY value change, so `reduceMotion ? false : …` bounced the
    /// badge at the moment the user switched Reduce Motion ON (Opus final
    /// bugcheck). Only a verdict change may move this, and only when motion
    /// is allowed at that moment.
    @State private var bounceTrigger = false

    var body: some View {
        Group {
            switch verdict {
            case .unverified:       chip(verdict.displayLine, "exclamationmark.triangle.fill")
            case .safeToWipe:       chip(verdict.displayLine, "checkmark.seal.fill")
            case .verifiedKeepCard: chip(verdict.displayLine, "externaldrive.badge.exclamationmark")
            case .failed:           chip(verdict.displayLine, "xmark.octagon.fill")
            case .running:          chip(phaseText, "arrow.triangle.2.circlepath")
            }
        }
        // The bounce lives OUTSIDE the switch: each verdict case is its own
        // subtree, and a freshly inserted safe chip would be born with the
        // trigger already true — a modifier inside it never sees the change
        // (codex review). Out here the modifier persists across the swap.
        .symbolEffect(.bounce, options: .nonRepeating, value: bounceTrigger)
        .onChange(of: verdict) { _, new in
            // Set-only, never cleared: assigning `new == .safeToWipe` would
            // fire a bounce on the INCOMING badge if a settled safeToWipe
            // ever changed — unreachable today, but this form needs no such
            // invariant (Opus verification).
            if !reduceMotion, new == .safeToWipe { bounceTrigger = true }
        }
        .animation(settleAnimation, value: verdict)
        // ONE stable accessibility element out here, so a verdict change
        // updates the label VoiceOver is focused on instead of yanking the
        // element out from under the cursor (each switch branch is a
        // distinct subtree — codex review).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verdict == .running ? phaseText : verdict.displayLine)
    }

    /// A short settle only when a verdict is EARNED. Alarms (failed,
    /// unverified) must land with full weight — they snap, never spring.
    private var settleAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch verdict {
        case .safeToWipe, .verifiedKeepCard:
            return .spring(duration: 0.35, bounce: 0.15)
        case .failed, .unverified, .running:
            return nil
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        let s = style
        return Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .imageScale(.small)
            .tracking(0.4)
            .symbolEffect(.pulse, isActive: !reduceMotion && verdict == .running)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(s.ink)
            .background(s.background, in: .capsule)
            .overlay(Capsule().strokeBorder(s.border))
            .transition(reduceMotion ? .opacity
                                     : .scale(scale: 0.92).combined(with: .opacity))
    }
}

extension Job.Verdict {
    /// Lowercase rail-echo pointer — computed from the SAME verdict value the
    /// badge renders, so the two can never drift. Never uppercase, never the
    /// badge vocabulary.
    var railEcho: String? {
        switch self {
        case .safeToWipe: return "verified · this card can be wiped"
        case .verifiedKeepCard: return "verified — keep the card"
        case .unverified, .failed: return "not verified — keep the card"
        case .running: return nil
        }
    }
}
