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
        for (root, destination) in zip(plan.rawRoots, plan.destinations) {
            let projected = DestinationFolderProjection.project(
                root: root, mirroredFolder: plan.mirroredFolder,
                organizationFolder: plan.organizationFolder)
            // The GUI passes the organization base; the engine appends the
            // card-label continuation folder exactly once. Accepting an
            // already-expanded path would append the label again on retry.
            guard destination == URL(fileURLWithPath: projected)
                    .standardizedFileURL.path,
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

    private static func pathOverlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
