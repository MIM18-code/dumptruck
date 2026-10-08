import AppKit

/// Trackpad haptics for the workbench. Every call is gated on
/// `Pref.haptics` — one master toggle, the same contract the sound effects
/// keep, so an operator who wants a silent, still trackpad gets one.
///
/// The patterns are a vocabulary, not decoration:
///   `.alignment`  — the action landed (valid drop, assignment, Start)
///   `.levelChange` — the action was refused or hit a wall (blocked drop,
///                    divider clamp, mistyped force-eject name)
///   `.generic`     — a milestone passed
///
/// Nothing here reports safety state on its own; terminal-verdict patterns are
/// fired by whoever already read `Job.verdict`, never recomputed here.
enum Haptics {
    /// AppModel registers the other Pref defaults at launch; this key is
    /// registered here so haptics default to ON even if nothing else has read
    /// the preference yet.
    private static let registerDefaults: Void = {
        UserDefaults.standard.register(defaults: [Pref.haptics: true])
    }()

    private static var enabled: Bool {
        _ = registerDefaults
        return UserDefaults.standard.bool(forKey: Pref.haptics)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    /// A thing snapped into place.
    static func alignment() { perform(.alignment) }

    /// A thing was refused, blocked, or hit a clamp bound.
    static func level() { perform(.levelChange) }

    /// A milestone passed.
    static func generic() { perform(.generic) }

    /// Double tap — a settled job that came out clean.
    static func verdictSuccess() {
        guard enabled else { return }
        perform(.generic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { perform(.generic) }
    }

    /// Triple alert — a settled job that did not.
    static func verdictFailure() {
        guard enabled else { return }
        perform(.levelChange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { perform(.levelChange) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { perform(.levelChange) }
    }
}
