import AppKit

/// Tiny arcade sound kit for the Dump Yard games. Entirely opt-in twice
/// over: the games only exist behind the toolbar button, and the master
/// sound toggle (Settings > Cards > Truck sound effects) silences these too.
/// NSSound instances are held until they finish so playback never cuts off.
enum ArcadeSounds {
    case catchGood, bad, jump, flip, match, gameOver

    private var file: String {
        switch self {
        case .catchGood: return "arcade_catch"
        case .bad: return "arcade_bad"
        case .jump: return "arcade_jump"
        case .flip: return "arcade_flip"
        case .match: return "arcade_match"
        case .gameOver: return "arcade_gameover"
        }
    }

    @MainActor private static var live: [NSSound] = []

    @MainActor
    func play(volume: Float = 0.4) {
        guard UserDefaults.standard.bool(forKey: Pref.soundEffects),
              let url = Bundle.main.url(forResource: file, withExtension: "mp3",
                                        subdirectory: "sfx/arcade"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = volume
        Self.live.removeAll { !$0.isPlaying }
        Self.live.append(sound)
        sound.play()
    }

    /// Closing/hiding the Dump Yard is a hard lifetime boundary: no arcade
    /// sound may continue over the safety UI, and completed NSSound objects
    /// should not remain retained until some future game action cleans them.
    @MainActor
    static func stopAll() {
        for sound in live { sound.stop() }
        live.removeAll()
    }
}
