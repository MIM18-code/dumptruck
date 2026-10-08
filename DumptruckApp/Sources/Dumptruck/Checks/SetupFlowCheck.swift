import Foundation

/// Setup-flow annoyances (Joshua, 2026-09-28):
/// - a typed card name survives the card read landing and a Re-read Card,
///   and only the name field's own write path marks it as typed;
/// - a newly staged card opens the bench;
/// - setup refusals clear when their cause is fixed;
/// - ordinary next steps are told apart from real problems, and Start
///   waits out the card read instead of asking for a name;
/// - two cards that both mount as "NO NAME" read apart;
/// - the overlap refusal describes both directions.
enum SetupFlowCheck {

    @inline(__always)
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func run() async throws {
        // 1. Which name wins when an inspection lands. Pure.
        require(AppModel.labelAfterInspection(current: "MINE", editedByUser: true,
                                              retryLabel: nil, suggested: "A001") == "MINE",
                "a typed name must survive the card read")
        require(AppModel.labelAfterInspection(current: "", editedByUser: true,
                                              retryLabel: nil, suggested: "A001") == "A001",
                "an emptied field takes the suggestion")
        require(AppModel.labelAfterInspection(current: "OLD", editedByUser: false,
                                              retryLabel: nil, suggested: "A001") == "A001",
                "an untyped field takes the suggestion")
        require(AppModel.labelAfterInspection(current: "MINE", editedByUser: true,
                                              retryLabel: "RETRY", suggested: "A001") == "MINE",
                "a name typed after a retry was staged wins")
        require(AppModel.labelAfterInspection(current: "RETRY", editedByUser: false,
                                              retryLabel: "RETRY", suggested: "A001") == "RETRY",
                "a staged retry keeps its frozen key")

        // 5. Next steps are quiet; problems keep the warning color. Pure.
        for step in [AppModel.pickSourceReason, AppModel.noDestinationReason,
                     AppModel.readingCardReason, AppModel.nameCardReason] {
            require(AppModel.isNextStepReason(step), "\(step) is a next step")
        }
        for problem in [AppModel.sourceChangedReason, AppModel.runningTransferReason,
                        AppModel.sourceOverlapReason,
                        "Job journal unavailable — resolve it before starting a transfer"] {
            require(!AppModel.isNextStepReason(problem), "\(problem) is a problem")
        }

        // 8. The overlap refusal covers a destination that CONTAINS the source.
        require(AppModel.sourceOverlapReason.contains("one is inside the other"),
                "overlap wording must cover both directions")
        require(!AppModel.sourceOverlapReason.contains("destination inside the source"),
                "the one-directional wording is gone")

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("dumptruck-setup-flow-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let card = root.appendingPathComponent("CARD_ONE").path
        let card2 = root.appendingPathComponent("CARD_TWO").path
        let dest = root.appendingPathComponent("DEST").path
        for path in [card, card2, dest] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try Data("clip".utf8).write(to: URL(fileURLWithPath: card + "/clip.mov"))
        try Data("clip".utf8).write(to: URL(fileURLWithPath: card2 + "/clip.mov"))

        let journal = JobJournal(url: root.appendingPathComponent("jobs.json"), historyLimit: 10)
        let model = AppModel(journal: journal)
        defer { model.terminateAllEngines() }

        // The engine may be real (a quick inspect of a tiny folder) or absent
        // (an immediate failure); either way the read settles.
        func settle(_ what: String) async throws {
            for _ in 0..<300 where model.inspecting {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            require(!model.inspecting, "the card read must settle (\(what))")
        }

        // 3. A newly staged card opens the bench, whatever state it was in.
        model.benchCollapsed = true
        require(model.assign(card, as: .source), "stage the card")
        require(!model.benchCollapsed, "staging a card must open the bench")

        // 5. While the card is read, Start says so rather than "Name the card".
        //    No await since staging, so the read cannot have landed yet.
        require(model.inspecting, "staging starts the card read")
        require(model.assignDroppedDestinations([dest]), "stage a destination")
        let reading = model.startBlockedReason
        require(reading != nil, "Start must be blocked while the card is read")
        if model.engineConfigurationError == nil {
            require(reading == AppModel.readingCardReason,
                    "the gate must say the card is being read, got \(String(describing: reading))")
        }

        // 4. The explanation reaches the strip; typing the name clears it.
        model.startOrExplain()
        require(model.lastSetupError == reading, "a blocked Start explains itself")
        require(model.jobs.isEmpty, "a blocked Start creates no job")
        model.operatorEditedLabel("MY_CARD")
        require(model.labelEditedByUser && model.label == "MY_CARD", "the field write marks the name as typed")
        require(model.lastSetupError == nil, "editing the name clears the stale explanation")

        // 1. The typed name survives the read landing.
        try await settle("first read")
        require(model.label == "MY_CARD", "the card read must not replace a typed name, got \(model.label)")

        // 6. Re-read Card: same card, new session and read, name kept.
        let session = model.sourceAssignmentID
        model.rereadStagedSource()
        require(model.sourcePath == card, "Re-read keeps the same card staged")
        require(model.sourceAssignmentID != session, "Re-read mints a new session")
        require(model.label == "MY_CARD" && model.labelEditedByUser, "Re-read keeps the typed name")
        try await settle("re-read")
        require(model.label == "MY_CARD", "the re-read must not replace a typed name, got \(model.label)")

        // 4. Removing a destination clears a refusal it caused.
        model.lastSetupError = "stale refusal"
        model.unassignDestination(dest)
        require(model.lastSetupError == nil, "unassigning a destination clears the stale refusal")

        // 1. A different card starts fresh, and a programmatic write (preset,
        //    retry) is not an operator edit, so the read may replace it.
        require(model.assign(card2, as: .source), "stage a different card")
        require(!model.labelEditedByUser, "a different card must not inherit the typed flag")
        require(model.label.isEmpty, "a different card must not inherit the typed name, got \(model.label)")
        model.label = "PRESET_NAME"
        require(!model.labelEditedByUser, "a programmatic label write is not an operator edit")
        try await settle("second card")
        require(model.label != "PRESET_NAME", "an untyped name follows the card read")

        // 4. Clearing the bench clears its refusals and the typed flag.
        model.operatorEditedLabel("TYPED")
        model.lastSetupError = "stale refusal"
        model.clearSource()
        require(model.lastSetupError == nil, "clearing the bench clears the stale refusal")
        require(!model.labelEditedByUser && model.label.isEmpty, "clearing the bench forgets the typed name")

        // A second source drop promotes both cards into a pending batch.
        // Every card must leave the shelf, even though only one is focused.
        require(model.sourceCandidatesSnapshot.contains { $0.path == card2 },
                "an unassigned card is available on the shelf")
        require(model.stageDroppedSources([card, card2]) == .batch([card, card2]),
                "a group source drop stages both cards as a batch")
        for path in [card, card2] {
            require(!model.sourceCandidatesSnapshot.contains { $0.path == path },
                    "a pending batch card must leave source candidates")
            require(!model.destinationCandidatesSnapshot.contains { $0.path == path },
                    "a pending batch card must leave destination candidates")
            require(model.assignmentBlockedReason(path, as: .destination) == AppModel.sourceOverlapReason,
                    "a pending batch source cannot also become a destination")
        }
        let removed = model.batchStagingModel.candidates.first { $0.path == card2 }!
        model.batchStagingModel.removeCandidate(id: removed.id, appModel: model)
        require(model.sourceCandidatesSnapshot.contains { $0.path == card2 },
                "removing a batch card restores it to the shelf")
        require(!model.sourceCandidatesSnapshot.contains { $0.path == card },
                "removing one batch card keeps the other staged")
        model.batchStagingModel.cancelStaging()
        require(model.sourceCandidatesSnapshot.contains { $0.path == card },
                "canceling the batch restores its remaining card")

        let previousBatch = model.batchStagingModel
        model.batchStagingModel = BatchSourceStagingModel()
        model.batchStagingModel.candidates = [BatchSourceCandidate(path: card2)]
        previousBatch.candidates = [BatchSourceCandidate(path: card)]
        require(model.sourceCandidatesSnapshot.contains { $0.path == card },
                "an old batch model cannot change the shelf")
        require(!model.sourceCandidatesSnapshot.contains { $0.path == card2 },
                "a replacement batch model updates the shelf")
        model.batchStagingModel.cancelStaging()

        // 8. A drag between rails changes the card's role; a drag back to
        //    the shelf unstages it (Joshua, 2026-10-05).
        for staged in model.destinationPaths { model.unassignDestination(staged) }
        require(model.assign(card, as: .source), "stage the card for the role move")
        try await settle("role move")
        require(model.assignDroppedDestinations([card]),
                "the staged source dropped on the destinations rail moves there: \(String(describing: model.lastSetupError))")
        require(model.sourcePath == nil && model.destinationPaths == [card],
                "the card left the source slot and is the destination")
        require(model.stageDroppedSources([card]) == .assign(card),
                "the staged destination dropped on the sources rail moves back")
        require(model.sourcePath == card && model.destinationPaths.isEmpty,
                "the card left the destinations and is the source")
        try await settle("role move back")
        require(model.assignDroppedDestinations([dest]), "a real destination still stages")
        require(model.assignmentBlockedReason(card + "/clip.mov", as: .destination) != nil
                    && model.sourcePath == card,
                "only the exact staged path moves; a path inside it is still gated and releases nothing")
        require(model.releaseStaged([card, dest]), "a drop on the shelf unstages both rails")
        require(model.sourcePath == nil && model.destinationPaths.isEmpty,
                "the shelf drop cleared the source and the destination")
        require(model.sourceCandidatesSnapshot.contains { $0.path == card }
                    && model.destinationCandidatesSnapshot.contains { $0.path == dest },
                "both cards are back on the shelf")
        require(!model.releaseStaged([card]), "releasing an unstaged card changes nothing")
        require(model.stageDroppedSources([card, card2]) == .batch([card, card2]),
                "stage a batch for the role move")
        require(model.assignDroppedDestinations([card2]),
                "a pending batch card dropped on the destinations rail moves there")
        require(model.destinationPaths == [card2]
                    && !model.batchStagingModel.candidates.contains { $0.path == card2 }
                    && model.batchStagingModel.candidates.contains { $0.path == card },
                "the moved card left the batch and the other card stayed")
        model.unassignDestination(card2)
        model.batchStagingModel.cancelStaging()

        // 7. Two cards from one camera both mount as "NO NAME".
        let savedVolumes = model.volumes
        model.volumes = [
            Volume(path: "/Volumes/NO NAME", name: "NO NAME", isEjectable: true,
                   totalBytes: nil, freeBytes: nil),
            Volume(path: "/Volumes/NO NAME 1", name: "NO NAME", isEjectable: true,
                   totalBytes: nil, freeBytes: nil),
            Volume(path: "/Volumes/SHUTTLE", name: "SHUTTLE", isEjectable: true,
                   totalBytes: nil, freeBytes: nil),
        ]
        let first = model.endpointDisplayName("/Volumes/NO NAME")
        let second = model.endpointDisplayName("/Volumes/NO NAME 1")
        require(first != second, "same-named cards must read apart, got \(first) / \(second)")
        require(second == "NO NAME (NO NAME 1)", "the twin names its mount folder, got \(second)")
        require(model.endpointDisplayName("/Volumes/SHUTTLE") == "SHUTTLE",
                "a unique name stays plain")
        model.volumes = savedVolumes
    }
}
