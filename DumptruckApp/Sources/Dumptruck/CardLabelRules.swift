import Foundation

/// The one set of card-name rules, shared by the single-source Start gate,
/// the batch sheet, and (via the journal's record shape) persistence. The
/// engine enforces the same set (`_valid_label` in cli.py); the point of
/// checking here is that a bad name is refused next to the field, before
/// any job exists (Codex desktop QA 2026-09-15, DT-QA-02).
enum CardLabelRules {
    /// The engine's own folders inside a lane; a card may not be named after them.
    static let reserved: Set<String> = ["reports", "ascmhl", "ascmhl_camera"]

    /// Nil when the label is usable, otherwise the sentence to show.
    static func validate(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Card label cannot be empty." }
        guard trimmed.utf8.count <= 255 else { return "Card label is too long." }
        guard trimmed != ".", trimmed != ".." else { return "Card label cannot be '.' or '..'." }
        guard !trimmed.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\0" }) else {
            return "Card label contains an illegal path character."
        }
        guard trimmed.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else { return "Card label contains a control character." }
        guard !reserved.contains(trimmed.lowercased()) else {
            return "Card label \"\(trimmed)\" is reserved for the engine's own folders."
        }
        return nil
    }
}
