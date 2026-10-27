import Foundation

/// Loose files as a source (2026-09-15): staging is a folder of clones on
/// the staging volume, flat, refusing collisions; the model routes a file
/// drop through it, plans it with --loose-files, and retires the set once
/// nothing refers to it.
enum LooseSourceStagingCheck {

    @inline(__always)
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("dumptruck-loose-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let stagingRoot = root.appendingPathComponent("loose-sources", isDirectory: true)
        let savedRoot = LooseSourceStaging.root
        LooseSourceStaging.root = stagingRoot
        defer { LooseSourceStaging.root = savedRoot }

        let downloads = root.appendingPathComponent("Downloads").path
        let elsewhere = root.appendingPathComponent("Elsewhere").path
        try fm.createDirectory(atPath: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        func write(_ path: String, _ bytes: Int) throws {
            let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            try data.write(to: URL(fileURLWithPath: path))
        }
        func listing(_ path: String) -> [String] {
            (try? fm.contentsOfDirectory(atPath: path))?.sorted() ?? ["<unreadable>"]
        }
        let clipA = downloads + "/clip one.mov"
        let clipB = downloads + "/notes.txt"
        try write(clipA, 96 * 1024)
        try write(clipB, 512)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: clipA)

        // 1. Two files stage flat as clones with identical bytes and mtime.
        let set = try LooseSourceStaging.stage(files: [clipA, clipB])
        require(LooseSourceStaging.isStagedSet(set), "staged set must sit directly under the root")
        require(LooseSourceStaging.isLoosePath(set + "/clip one.mov"), "children are loose paths")
        require(!LooseSourceStaging.isLoosePath(downloads), "unrelated folders are not loose")
        require(fm.contentsEqual(atPath: clipA, andPath: set + "/clip one.mov"), "clone bytes must match")
        require(fm.contentsEqual(atPath: clipB, andPath: set + "/notes.txt"), "clone bytes must match")
        let clonedDate = (try? fm.attributesOfItem(atPath: set + "/clip one.mov"))?[.modificationDate] as? Date
        require(clonedDate.map { abs($0.timeIntervalSince(oldDate)) < 1 } == true,
                "clone must keep the original's modification time, got \(String(describing: clonedDate))")
        require(listing(set) == ["clip one.mov", "notes.txt"],
                "set holds exactly the dropped names, flat")
        // Originals untouched.
        require(fm.fileExists(atPath: clipA) && fm.fileExists(atPath: clipB), "originals stay put")

        // 2. Refusals create nothing.
        let before = listing(stagingRoot.path).count
        let clipA2 = elsewhere + "/CLIP ONE.MOV"
        try write(clipA2, 64)
        require((try? LooseSourceStaging.stage(files: [clipA, clipA2])) == nil,
                "a case-only name collision must be refused")
        require((try? LooseSourceStaging.stage(files: [clipA, downloads + "/missing.mov"])) == nil,
                "a missing file must be refused")
        require((try? LooseSourceStaging.stage(files: [clipA, elsewhere])) == nil,
                "a folder must be refused by the file stager")
        let link = elsewhere + "/link.mov"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: clipA)
        require((try? LooseSourceStaging.stage(files: [link])) == nil, "a symlink must be refused")
        require((try? LooseSourceStaging.stage(files: [])) == nil, "an empty drop must be refused")
        require(listing(stagingRoot.path).count == before,
                "refused drops must leave nothing behind")

        // 3. remove() refuses anything that is not a staged set.
        require(!LooseSourceStaging.remove(downloads), "remove must refuse a folder outside the root")
        require(!LooseSourceStaging.remove(set + "/notes.txt"), "remove must refuse a file inside a set")
        require(!LooseSourceStaging.remove(stagingRoot.path), "remove must refuse the root itself")
        require(fm.fileExists(atPath: downloads) && fm.fileExists(atPath: set + "/notes.txt"),
                "refused removals must not delete")
        require(LooseSourceStaging.remove(set), "remove must delete a staged set")
        require(!fm.fileExists(atPath: set), "set is gone after remove")

        // 4. sweep() keeps live sets and young sets, removes stale ones.
        let stale = try LooseSourceStaging.stage(files: [clipB], now: Date(timeIntervalSinceNow: -100))
        let live = try LooseSourceStaging.stage(files: [clipB], now: Date(timeIntervalSinceNow: -200))
        let young = try LooseSourceStaging.stage(files: [clipB], now: Date(timeIntervalSinceNow: -300))
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stale)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: live)
        let removed = LooseSourceStaging.sweep(keeping: [live], olderThan: 86_400)
        require(removed == [stale], "sweep must remove only the stale, unreferenced set: \(removed)")
        require(fm.fileExists(atPath: live) && fm.fileExists(atPath: young), "kept and young sets survive")
        _ = LooseSourceStaging.remove(live)
        _ = LooseSourceStaging.remove(young)

        // 5. Model round trip: a file drop stages a set and assigns it.
        let journal = JobJournal(url: root.appendingPathComponent("jobs.json"), historyLimit: 10)
        let model = AppModel(journal: journal)
        let dropped = model.stageDroppedSources([clipA, clipB])
        guard case .assign(let assigned)? = dropped else {
            fatalError("file drop on an empty rail must assign a staged set, got \(String(describing: dropped))")
        }
        require(LooseSourceStaging.isStagedSet(assigned), "assigned path must be a staged set")
        require(model.sourcePath == assigned, "the set must be the staged source")
        require(model.lastSetupError == nil, "a clean file drop sets no error")

        // 6. Plans for a set carry --loose-files, and the journal accepts them.
        let dest = root.appendingPathComponent("DEST").path
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let engineRoot = root.appendingPathComponent("engine").path
        try fm.createDirectory(atPath: engineRoot + "/.venv/bin", withIntermediateDirectories: true)
        let plan = JournalLaunchPlan(
            src: assigned, rawRoots: [dest], destinations: [dest + "/SHOW/Raws"],
            args: ["-m", "dumptruck.cli", "offload", assigned, dest + "/SHOW/Raws",
                   "--label", "LOOSE", "--json", "--loose-files"],
            enginePython: engineRoot + "/.venv/bin/python", engineRoot: engineRoot,
            sourceVolumeUUID: "src", rootVolumeUUIDs: ["dst"],
            sourceFileID: "1:2", rootFileIDs: ["3:4"],
            mirroredFolder: "SHOW", organizationFolder: "Raws", cardLabel: "LOOSE")
        require(LaunchPlanValidation.isStructurallySafe(plan), "--loose-files must be a canonical flag")
        switch model.buildPlan(src: assigned, rawRoots: [dest], cardLabel: "LOOSE") {
        case .success(let built):
            require(built.args.contains("--loose-files"), "a staged set must plan with --loose-files: \(built.args)")
        case .failure(let err):
            fatalError("buildPlan for a staged set failed: \(err.message)")
        }
        switch model.buildPlan(src: downloads, rawRoots: [dest], cardLabel: "CARD") {
        case .success(let built):
            require(!built.args.contains("--loose-files"), "a folder source must never plan as loose: \(built.args)")
        case .failure(let err):
            fatalError("buildPlan for a folder failed: \(err.message)")
        }

        // 7. Mixed drop: folders pass through, files become one set in the
        //    first file's slot, and the whole thing batches.
        let mixed = model.stageDroppedSources([elsewhere, clipB, clipA])
        guard case .batch(let batched)? = mixed else {
            fatalError("mixed drop must batch, got \(String(describing: mixed))")
        }
        require(batched.count == 3 && batched[0] == assigned && batched[1] == elsewhere
                && LooseSourceStaging.isStagedSet(batched[2]),
                "mixed drop order must be staged card, folder, new set: \(batched)")
        require(listing(batched[2]) == ["clip one.mov", "notes.txt"],
                "the new set holds both files")
        let secondSet = batched[2]
        require(model.sourcePath == assigned, "promotion leaves the rail alone until the batch queues")

        // 8. Cancelling the sheet and clearing the rail retire unused sets;
        //    a set a job refers to stays.
        model.batchStagingModel.cancelStaging()
        model.batchStagingShown = false
        model.releaseLooseSourceIfUnused(secondSet)
        require(!fm.fileExists(atPath: secondSet), "an unreferenced set is removed on release")
        let job = Job(label: "LOOSE", sourcePath: assigned, destinations: [dest + "/SHOW/Raws"])
        job.phase = .failed
        model.jobs = [job]
        model.clearSource()
        require(model.sourcePath == nil, "rail cleared")
        require(fm.fileExists(atPath: assigned), "a set a job still refers to must survive clearSource")
        model.jobs = []
        model.releaseLooseSourceIfUnused(assigned)
        require(!fm.fileExists(atPath: assigned), "with no job left the set is removed")

        // 9. Files on another drive (a disk image here) stage as a selection
        //    set: a list, no clones, folders kept below the shared one.
        let drive = try mountScratchVolume(at: root.appendingPathComponent("Drive").path,
                                           image: root.appendingPathComponent("drive.dmg").path)
        defer { detachScratchVolume(drive) }
        try fm.createDirectory(atPath: drive + "/DCIM/A001", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: drive + "/DCIM/B001", withIntermediateDirectories: true)
        let pickA = drive + "/DCIM/A001/clip.braw"
        let pickB = drive + "/DCIM/B001/clip.braw"
        try write(pickA, 4096)
        try write(pickB, 2048)
        try write(drive + "/DCIM/A001/unpicked.braw", 1024)
        let picked = try LooseSourceStaging.stage(files: [pickB, pickA])
        require(LooseSourceStaging.isSelectionSet(picked), "drive files must stage as a selection set")
        require(LooseSourceStaging.engineFlags(for: picked) == ["--selection"],
                "a selection set adds --selection")
        require(listing(picked) == [LooseSourceStaging.selectionFolder],
                "a selection set holds the list only, no clones: \(listing(picked))")
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: picked + "/"
            + LooseSourceStaging.selectionFolder + "/" + LooseSourceStaging.selectionManifest))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        require(manifest?["version"] as? Int == 1
                && manifest?["root"] as? String == drive + "/DCIM"
                && manifest?["files"] as? [String] == ["B001/clip.braw", "A001/clip.braw"],
                "manifest lists the picked files under their shared folder: \(String(describing: manifest))")
        require(fm.contentsEqual(atPath: pickA, andPath: pickA) && fm.fileExists(atPath: pickB),
                "originals stay put")
        // The set's own creation reaches FSEvents after a watcher arms; the
        // staged-source watcher must not call that a card change.
        final class Fired: @unchecked Sendable { var value = false }
        let fired = Fired()
        let fresh = try LooseSourceStaging.stage(files: [pickA, pickB])
        let watcher = SourceMutationMonitor(path: fresh, filter: .sourceJunk(root: fresh)) {
            fired.value = true
        }
        require(watcher != nil, "a selection set can be watched")
        Thread.sleep(forTimeInterval: 1.5)
        _ = watcher?.stop()
        require(!fired.value, "staging a selection set must not read as a card change")
        _ = LooseSourceStaging.remove(fresh)
        let single = try LooseSourceStaging.stage(files: [pickA])
        require((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: single
            + "/.selection/manifest.json")))) .flatMap { $0 as? [String: Any] }?["root"] as? String
                == drive + "/DCIM/A001", "one picked file is listed under its own folder")
        _ = LooseSourceStaging.remove(single)
        let beforeMixed = listing(stagingRoot.path).count
        do {
            _ = try LooseSourceStaging.stage(files: [pickA, clipA])
            fatalError("files on two volumes must be refused")
        } catch let refusal as LooseSourceStaging.Refusal {
            require(refusal.message.contains("more than one drive"), "mixed-drive refusal says why: \(refusal.message)")
        }
        require(listing(stagingRoot.path).count == beforeMixed, "a mixed-drive refusal leaves nothing behind")
        switch model.buildPlan(src: picked, rawRoots: [dest], cardLabel: "PICKED") {
        case .success(let built):
            require(built.args.contains("--loose-files") && built.args.contains("--selection"),
                    "a selection set plans with --loose-files --selection: \(built.args)")
            require(built.args[3] == picked, "the set stays the planned source: \(built.args)")
        case .failure(let err):
            fatalError("buildPlan for a selection set failed: \(err.message)")
        }
        let pickedPlan = JournalLaunchPlan(
            src: picked, rawRoots: [dest], destinations: [dest + "/SHOW/Raws"],
            args: ["-m", "dumptruck.cli", "offload", picked, dest + "/SHOW/Raws",
                   "--label", "PICKED", "--json", "--loose-files", "--selection"],
            enginePython: engineRoot + "/.venv/bin/python", engineRoot: engineRoot,
            sourceVolumeUUID: "src", rootVolumeUUIDs: ["dst"],
            sourceFileID: "1:2", rootFileIDs: ["3:4"],
            mirroredFolder: "SHOW", organizationFolder: "Raws", cardLabel: "PICKED")
        require(LaunchPlanValidation.isStructurallySafe(pickedPlan), "--selection must be a canonical flag")
        // A selection copying from the drive keeps the drive from a one-click
        // eject, though its path is the staging folder (Sol review S1).
        let driveVolume = Volume(path: drive, name: "DTPICK", isEjectable: true,
                                 totalBytes: nil, freeBytes: nil)
        let copying = Job(label: "PICKED", sourcePath: picked, destinations: [dest + "/SHOW/Raws"])
        copying.phase = .copying
        model.jobs = [copying]
        require(!model.canEject(driveVolume), "the drive a selection is copying from must not one-click eject")
        if case .transferRunning(_, let asSource)? = model.ejectHold(driveVolume) {
            require(asSource, "the hold names the drive as the source")
        } else {
            fatalError("the hold must say a transfer is running")
        }
        model.jobs = []
        require(LooseSourceStaging.remove(picked), "a selection set removes like any set")
        require(fm.fileExists(atPath: pickA) && fm.fileExists(atPath: pickB),
                "removing a selection set never touches the drive")
        model.terminateAllEngines()
    }

    /// A small APFS disk image mounted at `mountPoint`, standing in for a
    /// camera drive: a second volume the staging root cannot clone from.
    private static func mountScratchVolume(at mountPoint: String, image: String) throws -> String {
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try hdiutil(["create", "-quiet", "-size", "8m", "-fs", "APFS", "-volname", "DTPICK", image])
        try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint, image])
        return URL(fileURLWithPath: mountPoint).standardizedFileURL.path
    }

    private static func detachScratchVolume(_ mountPoint: String) {
        try? hdiutil(["detach", "-quiet", "-force", mountPoint])
    }

    private static func hdiutil(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        require(process.terminationStatus == 0, "hdiutil \(args.first ?? "") failed")
    }
}
