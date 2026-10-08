import SwiftUI

/// Workbench type tiers. macOS collapses .footnote/.caption/.caption2 to
/// 10 pt (.caption2 is 10 pt Medium), so the only genuine size step below
/// .callout is .subheadline at 11 pt. Never use .system(size:) — fixed
/// sizes ignore the Text Size preference (Pref.textScale).
enum Typo {
    /// 11 pt semibold — verdict-bearing lines the operator acts on.
    static let safety = Font.subheadline.weight(.semibold)
    /// 11 pt regular — safety prose that is read, not scanned.
    static let safetyBody = Font.subheadline
    /// 10 pt medium — supporting evidence: counts, paths, phases.
    static let evidence = Font.footnote.weight(.medium)
    /// 10 pt regular — quiet supporting text.
    static let evidenceQuiet = Font.footnote
    /// 10 pt medium — decorative hints; identical to the old .caption2.
    static let hint = Font.caption2
}

enum TextScale: String, CaseIterable, Identifiable {
    case standard, large, extraLarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard:   return "Default"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard:   return .large      // system default
        case .large:      return .xLarge
        case .extraLarge: return .xxLarge
        }
    }
    static func current(_ raw: String) -> TextScale { TextScale(rawValue: raw) ?? .standard }
}
