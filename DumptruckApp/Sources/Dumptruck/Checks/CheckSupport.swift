import Foundation

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// A throwaway UserDefaults suite for a check. Named suites land in
/// ~/Library/Preferences, and cfprefsd writes the plist a moment after
/// removePersistentDomain, so every run stranded a file there (138 had piled
/// up by 2026-10-08). An absolute-path suite keeps the plist in the temp
/// folder instead.
func scratchDefaults(_ prefix: String) -> (defaults: UserDefaults, suite: String) {
    let suite = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    return (UserDefaults(suiteName: suite)!, suite)
}

func discardScratchDefaults(_ defaults: UserDefaults, suite: String) {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: "\(suite).plist")
}
