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
        model.terminateAllEngines()
    }
}
