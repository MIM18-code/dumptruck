import Foundation

/// Pure validation for the frozen, persisted engine invocation. Keeping the
/// parser here lets journal loading and a staged retry's final Start gate use
/// exactly the same safety vocabulary without consulting live UI settings.
enum LaunchPlanValidation {
    static func isStructurallySafe(_ plan: JournalLaunchPlan) -> Bool {
        guard isSafeAbsolutePath(plan.src),
              !plan.rawRoots.isEmpty,
              plan.rawRoots.allSatisfy(isSafeAbsolutePath),
              plan.destinations.count == plan.rawRoots.count,
              plan.destinations.allSatisfy(isSafeAbsolutePath),
              Set(plan.rawRoots).count == plan.rawRoots.count,
              Set(plan.destinations).count == plan.destinations.count,
              plan.rawRoots.count == plan.rootFileIDs.count,
              plan.rawRoots.count == plan.rootVolumeUUIDs.count,
              plan.sourceFileID != nil,
              plan.rootFileIDs.allSatisfy({ $0 != nil }),
              !plan.cardLabel.isEmpty,
              !containsControl(plan.cardLabel),
              !plan.cardLabel.contains("/"),
              !plan.cardLabel.contains("\\"),
              plan.cardLabel.count <= 512,
              !containsControl(plan.mirroredFolder),
              !containsControl(plan.organizationFolder),
              plan.mirroredFolder.count <= 8_192,
              plan.organizationFolder.count <= 8_192,
              isSafeRelativePath(plan.mirroredFolder),
              isSafeRelativePath(plan.organizationFolder),
              isSafeAbsolutePath(plan.engineRoot),
              isSafeAbsolutePath(plan.enginePython),
              plan.enginePython == (plan.engineRoot as NSString)
                .appendingPathComponent(".venv/bin/python"),
              argumentsAreCanonical(plan) else { return false }

        // Static string containment catches malformed persisted plans before
        // any live filesystem check. Symlink resolution and identity pins are
        // deliberately rechecked by AppModel immediately before Start.
        if let exact = plan.exactRoots {
            guard Set(exact).count == exact.count,
                  exact.allSatisfy({ plan.rawRoots.contains($0) }),
                  exact.count < plan.rawRoots.count else { return false }
        }
        guard !cardFoldersOverlap(plan.destinations, cardLabel: plan.cardLabel,
                                  caseSensitive: plan.destinations.map { _ in true }) else {
            return false
        }
        for (root, destination) in zip(plan.rawRoots, plan.destinations) {
            // The GUI passes the organization base; the engine appends the
            // card-label continuation folder exactly once. Accepting an
            // already-expanded path would append the label again on retry.
            guard projectedDestinations(plan, root: root).contains(destination),
                  destination == root || destination.hasPrefix(root + "/") else {
                return false
            }
            guard !pathOverlaps(plan.src, root) else { return false }
        }
        return true
    }

    static func argumentsAreCanonical(_ plan: JournalLaunchPlan) -> Bool {
        guard plan.args.count <= 128 else { return false }
        var cursor = 0
        func consume(_ expected: String) -> Bool {
            guard plan.args.indices.contains(cursor), plan.args[cursor] == expected else {
                return false
            }
            cursor += 1
            return true
        }
        guard consume("-m"), consume("dumptruck.cli"), consume("offload"),
              consume(plan.src) else { return false }
        for destination in plan.destinations where !consume(destination) { return false }
        guard consume("--label"), consume(plan.cardLabel), consume("--json") else {
            return false
        }
        var seen = Set<String>()
        let flagOptions = Set(["--fast", "--no-source-verify", "--reverify-existing",
                               "--no-report", "--no-thumbs", "--slate-first",
                               "--loose-files"])
        while cursor < plan.args.count {
            let option = plan.args[cursor]
            cursor += 1
            guard !seen.contains(option), !containsControl(option), option.count <= 256 else {
                return false
            }
            seen.insert(option)
            if flagOptions.contains(option) { continue }
            if option == "--hash" {
                guard plan.args.indices.contains(cursor) else { return false }
                let raw = plan.args[cursor]
                cursor += 1
                guard raw.count <= 64, !containsControl(raw) else { return false }
                let hashes = raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                let allowed = Set(["md5", "sha1", "sha256", "c4"])
                guard !hashes.isEmpty, hashes.count <= allowed.count,
                      Set(hashes).count == hashes.count,
                      Set(hashes).isSubset(of: allowed) else { return false }
                continue
            }
            return false
        }
        return true
    }

    static func isSafeAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !containsControl(value), value.count <= 8_192 else {
            return false
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    /// The destinations a saved plan may carry for `root`. An extra folder
    /// takes neither the mirrored folder nor the Organize template; a 0.5.9
    /// record applied the template below it, and stays valid so an old
    /// journal entry never invalidates the journal or its retry.
    static func projectedDestinations(_ plan: JournalLaunchPlan, root: String) -> [String] {
        func standardized(_ organization: String) -> String {
            URL(fileURLWithPath: DestinationFolderProjection.project(
                root: root,
                mirroredFolder: DestinationFolderProjection.mirroredFolder(
                    plan.mirroredFolder, for: root, exactRoots: plan.exactRoots),
                organizationFolder: organization)).standardizedFileURL.path
        }
        let current = standardized(DestinationFolderProjection.organizationFolder(
            plan.organizationFolder, for: root, exactRoots: plan.exactRoots))
        guard (plan.exactRoots ?? []).contains(root) else { return [current] }
        return [current, standardized(plan.organizationFolder)]
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        // Empty is the normal "no mirrored subfolder" setting. Swift's
        // split(..., omittingEmptySubsequences: false) represents it as one
        // empty component, so handle the valid sentinel before component
        // validation instead of rejecting every default workbench launch.
        if value.isEmpty { return true }
        guard !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.contains("\\") else { return false }
        for component in value.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != "..",
                  !containsControl(String(component)) else { return false }
        }
        return true
    }

    /// Two destinations on one drive must never put one card folder inside
    /// the other: the outer copy would absorb the inner one's files.
    /// Unicode spellings always compare as one name (APFS and HFS+ are
    /// normalization-insensitive). Case spellings compare as one name unless
    /// both folders of a pair are case-sensitive: `caseSensitive[i]` says
    /// whether destination i's volume reports case-sensitive names, so
    /// `Shoot` and `shoot` stay distinct on a case-sensitive volume, as on
    /// main, whatever the other destinations are. Persisted-plan validation
    /// passes all true, so an old journal record is never invalidated by a
    /// case rule it predates; the engine re-checks the real filesystem.
    static func cardFoldersOverlap(_ destinations: [String], cardLabel: String,
                                   caseSensitive: [Bool]) -> Bool {
        let nfc = destinations.map {
            ($0 as NSString).appendingPathComponent(cardLabel)
                .precomposedStringWithCanonicalMapping
        }
        let folded = nfc.map { $0.folding(options: .caseInsensitive, locale: nil) }
        for i in nfc.indices {
            for j in nfc.indices where j > i {
                let both = i < caseSensitive.count && j < caseSensitive.count
                    && caseSensitive[i] && caseSensitive[j]
                let keys = both ? nfc : folded
                if pathOverlaps(keys[i], keys[j]) { return true }
            }
        }
        return false
    }

    /// True only when `path` sits on a volume that reports case-sensitive
    /// names. Unknown or unreadable volumes count as case-insensitive
    /// (fail closed), matching the engine's probe.
    static func isCaseSensitive(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == true
    }

    private static func pathOverlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
