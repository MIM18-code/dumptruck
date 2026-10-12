import Foundation

/// An extra folder on a drive that is already a destination (the drive
/// row's "Also Copy to Another Folder on This Drive…" item, 2026-09-24).
enum ExtraDestinationFolderCheck {

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

static func plan(rawRoots: [String], destinations: [String],
                 exactRoots: [String]?) -> JournalLaunchPlan {
    JournalLaunchPlan(
        src: "/Volumes/CARD", rawRoots: rawRoots, destinations: destinations,
        args: ["-m", "dumptruck.cli", "offload", "/Volumes/CARD"] + destinations
            + ["--label", "B001", "--json"],
        enginePython: "/tmp/engine/.venv/bin/python", engineRoot: "/tmp/engine",
        sourceVolumeUUID: nil, rootVolumeUUIDs: rawRoots.map { _ in nil },
        sourceFileID: "1:2", rootFileIDs: rawRoots.map { _ in "3:4" },
        mirroredFolder: "Shoot", organizationFolder: "",
        cardLabel: "B001", exactRoots: exactRoots)
}

@MainActor
static func run() throws {
    // Saved plans: an exact root skips the mirrored folder; anything else
    // must still project through it; card folders never nest.
    let drive = "/Volumes/X9"
    let extra = drive + "/Second"
    let ok = plan(rawRoots: [drive, extra], destinations: [drive + "/Shoot", extra],
                  exactRoots: [extra])
    require(LaunchPlanValidation.isStructurallySafe(ok),
            "a plan with an extra folder on the same drive is structurally safe")
    require(!LaunchPlanValidation.isStructurallySafe(
        plan(rawRoots: [drive, extra], destinations: [drive + "/Shoot", extra], exactRoots: nil)),
            "without the exact-root marker the extra folder must project the mirrored folder")
    require(!LaunchPlanValidation.isStructurallySafe(
        plan(rawRoots: [drive, extra], destinations: [drive + "/Shoot", extra],
             exactRoots: [extra, "/Volumes/Elsewhere"])),
            "an exact root that is not a raw root is refused")
    let nested = drive + "/Shoot/B001"
    require(!LaunchPlanValidation.isStructurallySafe(
        plan(rawRoots: [drive, nested], destinations: [drive + "/Shoot", nested],
             exactRoots: [nested])),
            "a destination inside another destination's card folder is refused")

    // On a case-insensitive volume, case and Unicode spellings of one
    // folder count as the same folder.
    require(LaunchPlanValidation.cardFoldersOverlap([drive + "/Shoot", drive + "/shoot"],
                                                    cardLabel: "B001", caseSensitive: [false, false]),
            "two spellings of one folder are the same card folder")
    require(LaunchPlanValidation.cardFoldersOverlap([drive + "/outer", drive + "/outer/card"],
                                                    cardLabel: "CARD", caseSensitive: [false, false]),
            "a case alias of the card folder nests")
    require(LaunchPlanValidation.cardFoldersOverlap(
        [drive + "/outer", drive + "/outer/CAFE\u{0301}92"], cardLabel: "CAF\u{00C9}92",
        caseSensitive: [false, false]),
            "a Unicode alias of the card folder nests")
    require(!LaunchPlanValidation.cardFoldersOverlap([drive + "/one", drive + "/two"],
                                                     cardLabel: "B001", caseSensitive: [false, false]),
            "side-by-side folders do not overlap")
    // On a case-sensitive volume Shoot and shoot are two folders, as on main
    // (Sol regression review, 2026-10-12); Unicode aliases still nest.
    require(!LaunchPlanValidation.cardFoldersOverlap([drive + "/Shoot", drive + "/shoot"],
                                                     cardLabel: "B001", caseSensitive: [true, true]),
            "case-distinct folders on a case-sensitive volume are distinct")
    require(LaunchPlanValidation.cardFoldersOverlap(
        [drive + "/outer", drive + "/outer/CAFE\u{0301}92"], cardLabel: "CAF\u{00C9}92",
        caseSensitive: [true, true]),
            "a Unicode alias nests even on a case-sensitive volume")
    // Per pair: an unrelated case-insensitive destination must not fold the
    // names on a case-sensitive volume (Sol re-check, 2026-10-12).
    require(!LaunchPlanValidation.cardFoldersOverlap(
        ["/Volumes/CS/Backups/Shoot", "/Volumes/CS/Backups/shoot", "/Volumes/CI/Backup"],
        cardLabel: "B001", caseSensitive: [true, true, false]),
            "a case-insensitive third drive leaves case-sensitive folders distinct")
    require(LaunchPlanValidation.cardFoldersOverlap(
        ["/Volumes/CS/Backups/Shoot", "/Volumes/CS/Backups/shoot"],
        cardLabel: "B001", caseSensitive: [true, false]),
            "a pair folds when either side is not known case-sensitive")
    // A saved plan from main with case-distinct destinations stays valid: an
    // old journal record must never be invalidated by the new case rule.
    let upper = "/Volumes/CS/Backups/Shoot", lower = "/Volumes/CS/Backups/shoot"
    require(LaunchPlanValidation.isStructurallySafe(
        plan(rawRoots: [upper, lower], destinations: [upper + "/Shoot", lower + "/Shoot"],
             exactRoots: nil)),
            "a legacy plan with case-distinct roots still validates")
    require(!LaunchPlanValidation.isCaseSensitive("/Volumes/no-such-volume-\(UUID().uuidString)"),
            "an unreadable volume counts as case-insensitive (fail closed)")

    // Records written before extra folders existed still decode, as nil.
    let old = try JSONEncoder().encode(plan(rawRoots: [drive], destinations: [drive + "/Shoot"],
                                            exactRoots: nil))
    var object = try JSONSerialization.jsonObject(with: old) as! [String: Any]
    object.removeValue(forKey: "exactRoots")
    let decoded = try JSONDecoder().decode(
        JournalLaunchPlan.self, from: JSONSerialization.data(withJSONObject: object))
    require(decoded.exactRoots == nil, "an older record decodes with no extra folders")

    // Staging on a real folder tree.
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("dumptruck-extra-folder-check-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let anchor = root.appendingPathComponent("X9").path
    let second = anchor + "/Second"
    let mirrored = anchor + "/Shoot"
    try fm.createDirectory(atPath: second, withIntermediateDirectories: true)
    let model = AppModel(journal: JobJournal(
        url: root.appendingPathComponent("journal.json"), historyLimit: 10))
    model.label = "B001"
    require(!model.addExtraDestinationFolder(second, onDrive: anchor),
            "an extra folder needs its drive staged as a destination first")
    model.destinationPaths = [anchor]
    model.destinationFolderRelativePath = "Shoot"
    // The drive's card folder under whatever Organize template is set; a
    // folder picked inside it would nest the two cards.
    let driveCardFolder = model.effectiveDestinations([anchor], forSource: nil)[0] + "/B001"
    try fm.createDirectory(atPath: driveCardFolder, withIntermediateDirectories: true)
    require(!model.addExtraDestinationFolder(driveCardFolder, onDrive: anchor),
            "an extra folder inside the drive's card folder is refused")
    require(model.addExtraDestinationFolder(second, onDrive: anchor),
            "a side-by-side folder on the same drive is accepted: \(model.lastSetupError ?? "")")
    require(model.destinationPaths == [anchor, second] && model.isExtraDestinationFolder(second),
            "the extra folder is staged and marked")
    let rendered = model.effectiveDestinations(model.destinationPaths, forSource: nil)
    require(rendered[0].hasPrefix(mirrored) && rendered[1].hasPrefix(second)
                && !rendered[1].contains("/Shoot"),
            "the drive gets the mirrored folder, the extra folder is used as picked: \(rendered)")
    require(!model.addExtraDestinationFolder(second, onDrive: anchor),
            "the same extra folder cannot be added twice")
    model.unassignDestination(anchor)
    require(model.destinationPaths.isEmpty && !model.isExtraDestinationFolder(second),
            "removing the drive removes its extra folders")

    // Whatever drops the drive drops its extra folders: setting a folder on
    // the drive as the source removes the drive as a destination.
    let sourceOnDrive = anchor + "/Source"
    try fm.createDirectory(atPath: sourceOnDrive, withIntermediateDirectories: true)
    model.destinationPaths = [anchor]
    require(model.addExtraDestinationFolder(second, onDrive: anchor), "extra re-added")
    model.setSource(sourceOnDrive)
    require(!model.destinationPaths.contains(second) && !model.isExtraDestinationFolder(second),
            "an extra folder does not outlive its drive: \(model.destinationPaths)")

    // A preset installs plain anchors: a stale marker must not attach to one.
    model.setSource(root.appendingPathComponent("elsewhere").path)
    model.destinationPaths = [anchor]
    require(model.addExtraDestinationFolder(second, onDrive: anchor), "extra re-added for preset")
    model.installPresetDestinationSelection(anchors: [second], mirroredFolder: "Shoot")
    require(model.destinationPaths == [second] && !model.isExtraDestinationFolder(second),
            "a preset anchor never inherits an extra-folder marker")
    require(model.destinationAnchorsWithoutExtraFolders == [second],
            "the preset anchor counts as an anchor")

    // Batch staging previews and collision-checks the lane launch writes:
    // an extra folder takes no mirrored folder there either (Astra review,
    // 2026-10-12: batch inspected Second/Shoot/B001 while launch wrote
    // Second/B001, so an occupied lane was missed).
    require(BatchSourceStagingModel.laneBase(
                root: drive, label: "B001", volumeName: "B001", cameraFormat: "?", reel: "",
                mirroredFolder: "Shoot", exactRoots: [extra], template: "", project: "")
                == drive + "/Shoot",
            "a drive anchor keeps the mirrored folder in batch lanes")
    require(BatchSourceStagingModel.laneBase(
                root: extra, label: "B001", volumeName: "B001", cameraFormat: "?", reel: "",
                mirroredFolder: "Shoot", exactRoots: [extra], template: "", project: "")
                == extra,
            "an extra folder takes no mirrored folder in batch lanes, as in buildPlan")
    require(BatchSourceStagingModel.laneBase(
                root: extra, label: "B001", volumeName: "B001", cameraFormat: "?", reel: "",
                mirroredFolder: "Shoot", exactRoots: [extra], template: "{Project}", project: "P")
                == extra + "/P",
            "the organization template still applies below an extra folder")
}
}
