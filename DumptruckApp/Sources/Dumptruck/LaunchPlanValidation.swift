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
                               "--loose-files", "--selection"])
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
    /// Case sensitivity of the volume holding `path`, read from the nearest
    /// folder that exists (a card lane may not be created yet); nil when no
    /// folder on the way can be read.
    static func caseSensitivityOfNearestFolder(_ path: String) -> Bool? {
        var current = path
        while true {
            if let values = try? URL(fileURLWithPath: current)
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = values.volumeSupportsCaseSensitiveNames {
                return sensitive
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

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

/// The app spells paths the way Foundation does, and Foundation drops a
/// leading /private from /private/tmp, /private/var and /private/etc. The
/// engine reports os.path.realpath() spellings, which keep it. A job whose
/// destination was under /tmp or /var therefore got engine roots that did
/// not match its own destinations; the journal refused the record, the job
/// showed FAILED and every later Start was blocked until relaunch.
/// Engine events are respelled once, where they are decoded.
enum EnginePathSpelling {
    private static let privatePrefixes = ["/private/tmp", "/private/var", "/private/etc"]

    /// The inverse: the real path behind the system's /tmp, /var and /etc.
    static func privateSpelling(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    static func appSpelling(_ path: String) -> String {
        for prefix in privatePrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Respell every string value and dictionary key in a decoded event.
    /// Only absolute paths start with one of the prefixes, so relative file
    /// paths, hashes and free text pass through unchanged.
    static func respell(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return appSpelling(text)
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in dictionary { out[appSpelling(key)] = respell(item) }
            return out
        case let array as [Any]:
            return array.map(respell)
        default:
            return value
        }
    }

    static func respell(event: [String: Any]) -> [String: Any] {
        respell(event) as? [String: Any] ?? event
    }
}

/// Symlink checks by lstat, one existing folder at a time. Comparing a path
/// with Foundation's resolvingSymlinksInPath went wrong two ways: it leaves
/// a path unchanged when its last folder does not exist yet, so a symlinked
/// parent slipped through, and on case-insensitive volumes it rewrites an
/// existing folder to its on-disk capitals, so `show` read as a symlink to
/// `Show`.
enum DestinationPathCheck {
    /// True when no existing folder or file along an absolute path is a
    /// symlink, reading /tmp, /var and /etc through /private. Unlike
    /// comparing with resolvingSymlinksInPath, a folder spelled in other
    /// capitals than the disk's still passes.
    static func hasNoSymlink(_ path: String) -> Bool {
        firstUnsafeComponent(path) == nil
    }

    /// The first symlink (or unreadable folder) anywhere along an absolute
    /// path, the destination root included, in the app's spelling; nil when
    /// there is none. The engine follows a symlinked root to its target.
    static func firstUnsafeComponent(_ path: String) -> String? {
        unsafeComponent(from: "/", to: EnginePathSpelling.privateSpelling(path))
            .map(EnginePathSpelling.appSpelling)
    }

    static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The first folder below `root` on the way to `path` that is a symlink
    /// or cannot be examined, or nil when every existing folder is a real
    /// directory. Folders that do not exist yet end the walk: nothing below
    /// them exists either. `root` itself is not examined.
    static func unsafeComponent(from root: String, to path: String) -> String? {
        guard isContained(path, in: root) else { return path }
        guard path != root else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        var current = base
        for component in path.dropFirst(base.count + 1).split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) != 0 {
                return errno == ENOENT ? nil : current
            }
            if (info.st_mode & S_IFMT) == S_IFLNK { return current }
        }
        return nil
    }
}
