import Foundation

/// Sources-rail drop routing (Joshua, 2026-09-14): dropping cards one after
/// another must accumulate, never replace. Pure routing first, then the
/// model round-trip: promote a staged card into a batch, queue it, and the
/// single slot is released to the batch session.
enum SourceDropRoutingCheck {

    @inline(__always)
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func run() throws {
        typealias Route = AppModel.SourceDropRoute

        // 1. Empty rail, one item: the direct path.
        require(AppModel.routeSourceDrop(["/Volumes/A"], staged: nil, pendingBatch: [])
                == .assign("/Volumes/A"), "single drop on empty rail must assign")
        // Ingress standardization survives routing.
        require(AppModel.routeSourceDrop(["/Volumes//A/."], staged: nil, pendingBatch: [])
                == .assign("/Volumes/A"), "assign route must be standardized")

        // 2. Re-dropping the staged card re-mints the same single session.
        require(AppModel.routeSourceDrop(["/Volumes/A"], staged: "/Volumes/A", pendingBatch: [])
                == .assign("/Volumes/A"), "re-drop of the staged card stays single")

        // 3. THE BUG: one item onto an occupied rail joins the staged card,
        //    staged first, instead of replacing it.
        require(AppModel.routeSourceDrop(["/Volumes/B"], staged: "/Volumes/A", pendingBatch: [])
                == .batch(["/Volumes/A", "/Volumes/B"]),
                "second single drop must batch with the staged card, staged first")

        // 4. Several at once onto an empty rail: batch, drop order kept.
        require(AppModel.routeSourceDrop(["/Volumes/C", "/Volumes/B"], staged: nil, pendingBatch: [])
                == .batch(["/Volumes/C", "/Volumes/B"]), "multi-drop keeps drag order")

        // 5. Several at once onto an occupied rail: staged card leads.
        require(AppModel.routeSourceDrop(["/Volumes/B", "/Volumes/C"], staged: "/Volumes/A", pendingBatch: [])
                == .batch(["/Volumes/A", "/Volumes/B", "/Volumes/C"]), "staged card must lead a multi-drop")

        // 6. Pending batch candidates join; duplicates collapse once.
        require(AppModel.routeSourceDrop(["/Volumes/C", "/Volumes/A"], staged: "/Volumes/A",
                                         pendingBatch: ["/Volumes/B"])
                == .batch(["/Volumes/A", "/Volumes/B", "/Volumes/C"]),
                "pending candidates and duplicates must merge in order")
        require(AppModel.routeSourceDrop(["/Volumes/B"], staged: nil, pendingBatch: ["/Volumes/A"])
                == .batch(["/Volumes/A", "/Volumes/B"]),
                "a single drop with a pending batch must join it, not assign")

        // 7. Nothing dropped: no route.
        require(AppModel.routeSourceDrop([], staged: "/Volumes/A", pendingBatch: []) == nil,
                "empty drop routes nowhere")

        // 7b. A staged card that already ran this session stays on the bench
        //     (Joshua, 2026-09-28): pulled into the batch it was refused for
        //     its existing lane folder and its SAFE eject locked. The next
        //     card batches alone, even a single one, and never replaces it.
        require(AppModel.routeSourceDrop(["/Volumes/B"], staged: "/Volumes/A", pendingBatch: [],
                                         stagedAlreadyRan: true)
                == .assign("/Volumes/B"),
                "a single drop next to a finished card is the next card and takes the bench")
        require(AppModel.routeSourceDrop(["/Volumes/B", "/Volumes/C"], staged: "/Volumes/A",
                                         pendingBatch: [], stagedAlreadyRan: true)
                == .batch(["/Volumes/B", "/Volumes/C"]),
                "a multi-drop next to a finished card must leave it out")
        require(AppModel.routeSourceDrop(["/Volumes/C"], staged: "/Volumes/A",
                                         pendingBatch: ["/Volumes/B"], stagedAlreadyRan: true)
                == .batch(["/Volumes/B", "/Volumes/C"]),
                "pending candidates still lead, without the finished card")
        require(AppModel.routeSourceDrop(["/Volumes/A"], staged: "/Volumes/A", pendingBatch: [],
                                         stagedAlreadyRan: true)
                == .assign("/Volumes/A"),
                "re-dropping the finished card itself still re-stages it")

        // 8. Model round-trip on real folders.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-source-drop-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cardA = root.appendingPathComponent("CARD_A").path
        let cardB = root.appendingPathComponent("CARD_B").path
        let cardC = root.appendingPathComponent("CARD_C").path
        // Files are no longer refused (they stage as a loose set, see
        // LooseSourceStagingCheck); a path that does not exist still is.
        let notAFolder = root.appendingPathComponent("never-mounted").path
        try FileManager.default.createDirectory(atPath: cardA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cardB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cardC, withIntermediateDirectories: true)

        let journal = JobJournal(url: root.appendingPathComponent("jobs.json"), historyLimit: 10)
        let model = AppModel(journal: journal)

        require(model.stageDroppedSources([cardA]) == .assign(cardA), "first drop assigns")
        require(model.sourcePath == cardA, "first drop must stage the card")
        require(model.batchStagingShown == false, "first drop must not open the sheet")

        let second = model.stageDroppedSources([cardB])
        require(second == .batch([cardA, cardB]), "second drop must batch both, got \(String(describing: second))")
        require(model.sourcePath == cardA, "staged card must survive promotion until the batch is queued")
        // Rail drops never front the batch window: it took focus from the
        // main window, so the next drag off the Connected shelf only
        // re-activated that window (Joshua, 2026-09-28). The rail lists
        // the pile; the window opens on request.
        require(!model.batchStagingShown, "a rail drop must not open the batch window")
        require(model.batchStagingOpenRequests == 0, "a rail drop must not front the batch window")
        require(model.batchStagingModel.candidates.map(\.path) == [cardA, cardB],
                "batch must list staged card first, then the drop")
        // No destinations yet: every card waits, with no red refusal and no
        // error banner. Nothing is wrong with the cards.
        require(model.batchStagingModel.candidates.allSatisfy { $0.status == .awaitingDestinations },
                "cards dropped before destinations must wait, not be refused")
        require(model.batchStagingModel.generalError == nil,
                "missing destinations must not raise a batch error")
        require(!model.batchStagingModel.canQueueBatch, "waiting cards must not be queueable")

        // Joshua (2026-09-21): the THIRD card, dragged to the rail, must
        // join the list.
        let third = model.stageDroppedSources([cardC])
        require(third == .batch([cardA, cardB, cardC]),
                "third drop must join the pending batch, got \(String(describing: third))")
        require(model.batchStagingModel.candidates.map(\.path) == [cardA, cardB, cardC],
                "list must hold all three in drag order")
        require(model.batchStagingOpenRequests == 0, "the third drop must not front the batch window either")
        model.openBatchWindow()
        require(model.batchStagingShown && model.batchStagingOpenRequests == 1,
                "the rail's Review button opens the batch window")
        require(model.sourcePath == cardA, "staged card still survives until the batch is queued")

        // A missing path can never be a source: the drop is refused whole,
        // the rail and the sheet are untouched, and the reason is visible.
        let refused = model.stageDroppedSources([notAFolder])
        require(refused == nil, "a drop of a missing path must be refused")
        require(model.lastSetupError != nil, "refusal must explain itself")
        require(model.sourcePath == cardA, "refusal must not touch the staged card")
        require(model.batchStagingModel.candidates.count == 3, "refusal must not touch the sheet")
        require(model.batchStagingOpenRequests == 1, "a refused drop must not front the batch window")

        // Cancelling the sheet loses nothing on the rail.
        model.batchStagingModel.cancelStaging()
        model.batchStagingShown = false
        require(model.sourcePath == cardA, "cancelled sheet keeps the staged card")

        // Destinations rail: plain folders (not on a /Volumes drive) dropped
        // together are each their own anchor, and the usual gates still
        // apply (a folder overlapping the staged source is refused whole).
        let destA = root.appendingPathComponent("DEST_A").path
        let destB = root.appendingPathComponent("DEST_B").path
        try FileManager.default.createDirectory(atPath: destA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: destB, withIntermediateDirectories: true)
        require(model.assignDroppedDestinations([destA, destB]), "plain folders must be accepted as destinations: \(model.lastSetupError ?? "")")
        require(model.destinationPaths == [destA, destB], "both folders become anchors in drop order: \(model.destinationPaths)")
        require(model.folderEndpoints.contains(where: { $0.path == destA }), "a plain folder anchor stays available after unassign")
        // A folder INSIDE the staged card overlaps it; the exact staged card
        // is a role move instead (2026-10-05), covered by SetupFlowCheck.
        let insideA = cardA + "/inside"
        try FileManager.default.createDirectory(atPath: insideA, withIntermediateDirectories: true)
        require(!model.assignDroppedDestinations([destA, insideA]), "a folder overlapping the staged source must refuse the whole drop")
        require(model.lastSetupError != nil, "the refusal explains itself")
        require(model.destinationPaths == [destA, destB], "a refused drop changes nothing")
        require(model.sourcePath == cardA, "an overlap refusal leaves the staged card alone")
        try FileManager.default.removeItem(atPath: insideA)
        model.unassignDestination(destA)
        model.unassignDestination(destB)

        // Queueing a batch that contains the staged card releases the single
        // slot: the batch session is now the authority for that path.
        let dest = root.appendingPathComponent("DEST").path
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let engineRoot = root.appendingPathComponent("engine").path
        try FileManager.default.createDirectory(atPath: engineRoot + "/.venv/bin",
                                                withIntermediateDirectories: true)
        let candidate = BatchSourceCandidate(path: cardA, originalPath: cardA)
        candidate.customLabel = "CARD_A"
        let lane = dest + "/SHOW/Raws"
        let plan = AppModel.LaunchPlan(
            src: cardA, rawRoots: [dest], dests: [lane],
            args: ["-m", "dumptruck.cli", "offload", cardA, lane,
                   "--label", "CARD_A", "--json"],
            cardLabel: "CARD_A", mirroredFolder: "SHOW", organizationFolder: "Raws",
            enginePython: engineRoot + "/.venv/bin/python",
            engineRoot: engineRoot,
            srcVolumeUUID: "src-uuid", rootVolumeUUIDs: ["dst-uuid"],
            srcFileID: "1:2", rootFileIDs: ["3:4"])
        let queued = model.queueBatch(plans: [(candidate: candidate, plan: plan)])
        require(queued.isSuccess, "batch queue must succeed: \(queued)")
        require(model.sourcePath == nil, "queued batch containing the staged card must clear the single slot")
        require(model.jobs.contains(where: { $0.sourcePath == cardA }), "batch job must exist for the promoted card")

        // 9. The finished card stays out of the next batch (Joshua,
        //    2026-09-28). Stage B, settle a job for its CURRENT session,
        //    then drop C: C is the next card and takes the bench; B is
        //    never pulled into a batch.
        model.batchStagingModel.cancelStaging()
        require(model.stageDroppedSources([cardB]) == .assign(cardB), "B stages on the empty rail")
        require(!model.stagedSourceAlreadyRan, "a freshly staged card has not run")
        let finished = Job(label: "CARD_B", sourcePath: cardB, destinations: [dest + "/CARD_B"],
                           sourceAssignmentID: model.sourceAssignmentID)
        finished.phase = .done
        model.jobs.insert(finished, at: 0)
        require(model.stagedSourceAlreadyRan, "a settled job for this session means the card ran")
        let next = model.stageDroppedSources([cardC])
        require(next == .assign(cardC),
                "the next card takes the bench, got \(String(describing: next))")
        require(model.sourcePath == cardC, "the next card is staged")
        require(model.batchStagingModel.candidates.isEmpty,
                "the finished card must not be pulled into a batch")
        // An unrun staged card still accumulates: a second drop batches
        // both, staged first, as before.
        require(!model.stagedSourceAlreadyRan, "the new card has not run yet")
        require(model.stageDroppedSources([cardB]) == .batch([cardC, cardB]),
                "an unrun staged card still leads the batch")
        model.batchStagingModel.cancelStaging()
        model.terminateAllEngines()
    }
}
