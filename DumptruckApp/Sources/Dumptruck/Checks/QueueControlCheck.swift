import Foundation

enum QueueControlCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

    @MainActor
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-queue-control-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("CARD").path
        let dest = root.appendingPathComponent("DEST").path
        let engineRoot = root.appendingPathComponent("engine").path
        let enginePython = engineRoot + "/.venv/bin/python"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: engineRoot + "/.venv/bin", withIntermediateDirectories: true)

        let journalURL = root.appendingPathComponent("jobs.json")
        let journal = JobJournal(url: journalURL, historyLimit: 10)
        let model = AppModel(journal: journal)

        // Sections 1-6 describe the one-at-a-time queue (a resume with a
        // running job must launch nothing). Section 7 flips the preference
        // itself. The runner's defaults domain is put back afterwards.
        let defaults = UserDefaults.standard
        let priorQueueMode = defaults.string(forKey: Pref.queueMode)
        defer {
            if let priorQueueMode { defaults.set(priorQueueMode, forKey: Pref.queueMode) }
            else { defaults.removeObject(forKey: Pref.queueMode) }
        }
        defaults.set("single", forKey: Pref.queueMode)

        func makePlan(label: String) -> JournalLaunchPlan {
            JournalLaunchPlan(
                src: source,
                rawRoots: [dest],
                destinations: [dest + "/SHOW/Raws"],
                args: ["-m", "dumptruck.cli", "offload", source, dest + "/SHOW/Raws",
                       "--label", label, "--json"],
                enginePython: enginePython,
                engineRoot: engineRoot,
                sourceVolumeUUID: "src-uuid",
                rootVolumeUUIDs: ["dst-uuid"],
                sourceFileID: "1:2",
                rootFileIDs: ["3:4"],
                mirroredFolder: "SHOW",
                organizationFolder: "Raws",
                cardLabel: label
            )
        }

        func makeJob(label: String, phase: JobPhase = .queued) -> Job {
            let plan = makePlan(label: label)
            let job = Job(label: label, sourcePath: source, destinations: plan.destinations)
            job.phase = phase
            job.launchPlanSnapshot = plan
            return job
        }

        // -------------------------------------------------------------
        // 1. Initial Queue Ordering and Position Inspection
        // -------------------------------------------------------------
        let q1 = makeJob(label: "CARD_1")
        let q2 = makeJob(label: "CARD_2")
        let q3 = makeJob(label: "CARD_3")
        let runningJob = makeJob(label: "CARD_RUNNING", phase: .copying)
        let doneJob = makeJob(label: "CARD_DONE", phase: .done)
        doneJob.fullyVerified = true
        doneJob.safeToWipe = true
        doneJob.physicalDevices = 2
        doneJob.wipeBlockers = []

        model.jobs = [q1, q2, q3, runningJob, doneJob]
        require(journal.save(records: model.jobs.map { JobJournalRecord(job: $0, plan: $0.launchPlanSnapshot) }).isSuccess,
                "initial journal save failed")

        require(model.queuedJobs.count == 3, "queuedJobs did not filter exactly queued jobs")
        require(model.queuePosition(of: q1) == 1, "q1 position was not 1")
        require(model.queuePosition(of: q2) == 2, "q2 position was not 2")
        require(model.queuePosition(of: q3) == 3, "q3 position was not 3")
        require(model.queuePosition(of: runningJob) == nil, "non-queued job reported a queue position")

        require(!model.canMoveQueuedEarlier(job: q1), "first queued job allowed moving earlier")
        require(model.canMoveQueuedLater(job: q1), "first queued job disallowed moving later")
        require(model.canMoveQueuedEarlier(job: q2), "middle queued job disallowed moving earlier")
        require(model.canMoveQueuedLater(job: q2), "middle queued job disallowed moving later")
        require(model.canMoveQueuedEarlier(job: q3), "last queued job disallowed moving earlier")
        require(!model.canMoveQueuedLater(job: q3), "last queued job allowed moving later")

        // -------------------------------------------------------------
        // 2. Deterministic Move Earlier / Later
        // -------------------------------------------------------------
        // Move q2 earlier -> order should become [q2, q1, q3, running, done]
        require(model.moveQueuedEarlier(job: q2), "moveQueuedEarlier(q2) failed")
        require(model.jobs.map(\.label) == ["CARD_2", "CARD_1", "CARD_3", "CARD_RUNNING", "CARD_DONE"],
                "reordered jobs did not swap correctly on move earlier")
        require(model.queuePosition(of: q2) == 1, "q2 did not become position 1")
        require(model.queuePosition(of: q1) == 2, "q1 did not become position 2")

        // Move q3 earlier twice -> order becomes [q3, q2, q1, running, done]
        require(model.moveQueuedEarlier(job: q3), "first moveQueuedEarlier(q3) failed")
        require(model.jobs.map(\.label) == ["CARD_2", "CARD_3", "CARD_1", "CARD_RUNNING", "CARD_DONE"],
                "q3 did not move past q1")
        require(model.moveQueuedEarlier(job: q3), "second moveQueuedEarlier(q3) failed")
        require(model.jobs.map(\.label) == ["CARD_3", "CARD_2", "CARD_1", "CARD_RUNNING", "CARD_DONE"],
                "q3 did not move to front")
        require(!model.moveQueuedEarlier(job: q3), "moving front job earlier succeeded unexpectedly")

        // Move q3 later once -> order becomes [q2, q3, q1, running, done]
        require(model.moveQueuedLater(job: q3), "moveQueuedLater(q3) failed")
        require(model.jobs.map(\.label) == ["CARD_2", "CARD_3", "CARD_1", "CARD_RUNNING", "CARD_DONE"],
                "q3 did not move later")

        // Interspersed non-queued jobs: move q1 earlier past runningJob ->
        // only queued jobs swap with each other; non-queued jobs stay in place.
        let mixedQ1 = makeJob(label: "MIX_Q1")
        let mixedRun = makeJob(label: "MIX_RUN", phase: .copying)
        let mixedQ2 = makeJob(label: "MIX_Q2")
        model.jobs = [mixedQ1, mixedRun, mixedQ2]
        require(model.moveQueuedEarlier(job: mixedQ2), "mixed moveQueuedEarlier failed")
        require(model.jobs.map(\.label) == ["MIX_Q2", "MIX_RUN", "MIX_Q1"],
                "interspersed queued jobs did not swap cleanly across non-queued items")

        // -------------------------------------------------------------
        // 3. Journal Persistence of Custom Queue Order
        // -------------------------------------------------------------
        model.jobs = [q3, q2, q1, runningJob, doneJob]
        _ = model.moveQueuedEarlier(job: q1) // [q3, q1, q2, running, done]
        switch journal.load() {
        case .loaded(let document):
            let loadedLabels = document.records.map(\.label)
            require(loadedLabels == ["CARD_3", "CARD_1", "CARD_2", "CARD_RUNNING", "CARD_DONE"],
                    "journal did not persist the exact reordered sequence: \(loadedLabels)")
        default:
            fatalError("reordered journal failed to load")
        }

        // Bounded journal preserves live queued jobs even if history limit is small
        let tightJournalURL = root.appendingPathComponent("tight-jobs.json")
        let tightJournal = JobJournal(url: tightJournalURL, historyLimit: 3)
        let oldTerminal = makeJob(label: "OLD_DONE", phase: .done)
        oldTerminal.finishedDate = Date(timeIntervalSince1970: 10)
        let newTerminal = makeJob(label: "NEW_DONE", phase: .done)
        newTerminal.finishedDate = Date(timeIntervalSince1970: 500)
        let tightRecords = [
            JobJournalRecord(job: q3, plan: q3.launchPlanSnapshot),
            JobJournalRecord(job: q1, plan: q1.launchPlanSnapshot),
            JobJournalRecord(job: oldTerminal, plan: nil),
            JobJournalRecord(job: newTerminal, plan: nil)
        ]
        require(tightJournal.save(records: tightRecords).isSuccess, "tight journal save failed")
        if case .loaded(let tightDoc) = tightJournal.load() {
            let labels = tightDoc.records.map(\.label)
            require(labels.contains("CARD_3") && labels.contains("CARD_1"),
                    "history cap dropped live queued records")
            require(labels.contains("NEW_DONE"), "history cap dropped newest terminal record")
            require(!labels.contains("OLD_DONE"), "history cap retained oldest terminal record")
        } else {
            fatalError("tight journal failed to load")
        }

        // -------------------------------------------------------------
        // 4. Global Pause / Resume Dispatch
        // -------------------------------------------------------------
        require(!model.isDispatchPaused, "isDispatchPaused did not default to false")
        model.pauseDispatch()
        require(model.isDispatchPaused, "pauseDispatch did not set isDispatchPaused")
        model.pauseDispatch() // idempotent
        require(model.isDispatchPaused, "second pauseDispatch corrupted state")

        model.toggleDispatchPause()
        require(!model.isDispatchPaused, "toggleDispatchPause did not resume dispatch")
        model.toggleDispatchPause()
        require(model.isDispatchPaused, "toggleDispatchPause did not pause dispatch")
        model.resumeDispatch()
        require(!model.isDispatchPaused, "resumeDispatch did not resume dispatch")

        // -------------------------------------------------------------
        // 5. Remove Queued Job vs Stop Queued Job (Fail-Closed)
        // -------------------------------------------------------------
        // When dispatch is paused, removeQueued updates queue positions without auto-dispatching
        model.pauseDispatch()
        model.jobs = [q3, q1, q2]
        model.removeQueued(job: q1)
        require(model.jobs.map(\.label) == ["CARD_3", "CARD_2"],
                "removeQueued did not remove the specified job")
        require(model.queuePosition(of: q3) == 1, "q3 position was not updated to 1")
        require(model.queuePosition(of: q2) == 2, "q2 position was not updated to 2")

        // Stop a queued job: must fail closed immediately and stay in history as failed
        let stopTarget = makeJob(label: "STOP_ME")
        model.jobs = [stopTarget, q2]
        model.stop(job: stopTarget)
        require(stopTarget.phase == .failed, "stopped queued job was not marked .failed")
        require(stopTarget.verdict == .failed, "stopped queued job verdict was not .failed")
        require(!stopTarget.fullyVerified && !stopTarget.safeToWipe,
                "stopped queued job retained verify/safe booleans")
        require(stopTarget.messages.contains(where: { $0.text.contains("operator stopped this queued transfer") }),
                "stopped queued job did not record operator stop message")
        require(!model.queuedJobs.contains(where: { $0.id == stopTarget.id }),
                "stopped queued job remained in active queuedJobs")
        // Recorded as an operator Stop, which keeps the ending quiet (no
        // failure beeper or alert) without softening the FAILED record.
        require(stopTarget.stopRequested, "a queued Stop was not recorded as an operator stop")

        // -------------------------------------------------------------
        // 6. Crash / Relaunch Recovery Fail-Closed Semantics
        // -------------------------------------------------------------
        let crashJournalURL = root.appendingPathComponent("crash-jobs.json")
        let crashJournal = JobJournal(url: crashJournalURL)
        let crashedQueued = makeJob(label: "CRASHED_QUEUED")
        let crashedPlan = makePlan(label: "CRASHED_QUEUED")
        crashedQueued.launchPlanSnapshot = crashedPlan
        _ = crashJournal.save(records: [JobJournalRecord(job: crashedQueued, plan: crashedPlan)])

        let crashModel = AppModel(journal: crashJournal)
        let restoredCrashed = crashModel.jobs.first(where: { $0.label == "CRASHED_QUEUED" })
        require(restoredCrashed != nil, "crashed job was not restored")
        require(restoredCrashed?.phase == .failed,
                "crashed queued job was not restored as failed")
        require(restoredCrashed?.verdict == .failed,
                "crashed queued job verdict was not .failed")
        require(restoredCrashed?.wipeBlockers.contains("transfer interrupted before terminal verification") == true,
                "crashed queued job did not retain an explicit wipe blocker")
        require((restoredCrashed?.safeToWipe ?? true)
                    == (restoredCrashed?.wipeBlockers.isEmpty ?? false),
                "crashed queued job violated safe iff wipe blockers are empty")
        // Still "queued" in the journal means it never launched: the message
        // says so instead of implying a copy died mid-way (Joshua, 2026-09-28).
        require(restoredCrashed?.messages.contains(where: { $0.text.contains("Never started: Dumptruck quit while this card was queued") }) == true,
                "crashed queued job lacked its never-started message")
        require(restoredCrashed?.messages.contains(where: { $0.text.contains("relaunched before this transfer settled") }) == false,
                "a never-started queued job was described as an interrupted transfer")
        require(restoredCrashed?.launchPlanSnapshot != nil,
                "crashed job lost its launchPlanSnapshot needed for manual stageRetry")
        require(crashModel.queuedJobs.isEmpty,
                "relaunched model treated crashed jobs as automatically resuming queue")

        // Records written by older builds could contain a settled unsafe job
        // with no blocker. Loading them must migrate the safety evidence so
        // `safeToWipe` remains equivalent to an empty blocker list.
        let legacyJournalURL = root.appendingPathComponent("legacy-unsafe-jobs.json")
        let legacyJournal = JobJournal(url: legacyJournalURL)
        let legacyFailed = makeJob(label: "LEGACY_FAILED")
        legacyFailed.phase = .failed
        legacyFailed.safeToWipe = false
        legacyFailed.wipeBlockers = []
        _ = legacyJournal.save(records: [JobJournalRecord(job: legacyFailed, plan: nil)])
        let legacyModel = AppModel(journal: legacyJournal)
        let restoredLegacy = legacyModel.jobs.first
        require(restoredLegacy?.wipeBlockers
                    .contains("terminal verification did not authorize wiping") == true,
                "settled legacy unsafe job was restored without a wipe blocker")
        require((restoredLegacy?.safeToWipe ?? true)
                    == (restoredLegacy?.wipeBlockers.isEmpty ?? false),
                "settled legacy unsafe job violated safe iff wipe blockers are empty")

        // -------------------------------------------------------------
        // 7. Drain honors the Queueing preference (Joshua, 2026-09-21: a
        //    batch ran its cards one after another even with Queueing
        //    "Off", and nothing offered to run them together).
        // -------------------------------------------------------------
        // /private/var, not /var: a queued launch refuses a destination
        // whose path resolves through a symlink.
        let drainRoot = (root.path as NSString).resolvingSymlinksInPath
        let drainSrc = drainRoot + "/DRAIN_SRC"
        let drainDest = drainRoot + "/DRAIN_DEST"
        try FileManager.default.createDirectory(atPath: drainSrc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: drainDest, withIntermediateDirectories: true)
        // A shell script stands in for the engine's python. It never speaks
        // the protocol, so the job sits in .starting until terminated. The
        // plan itself is canonical: a queued launch now commits the journal
        // before the engine runs, and the journal refuses a non-canonical
        // plan (Joshua, 2026-09-28).
        let drainEngineRoot = drainRoot + "/drain-engine"
        let drainPython = drainEngineRoot + "/.venv/bin/python"
        try FileManager.default.createDirectory(atPath: drainEngineRoot + "/.venv/bin",
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: URL(fileURLWithPath: drainPython))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drainPython)
        func sleeper(_ label: String) -> Job {
            let plan = JournalLaunchPlan(
                src: drainSrc, rawRoots: [drainDest], destinations: [drainDest],
                args: ["-m", "dumptruck.cli", "offload", drainSrc, drainDest,
                       "--label", label, "--json"],
                enginePython: drainPython, engineRoot: drainEngineRoot,
                sourceVolumeUUID: nil, rootVolumeUUIDs: [nil],
                sourceFileID: AppModel.fileID(drainSrc), rootFileIDs: [AppModel.fileID(drainDest)],
                mirroredFolder: "", organizationFolder: "", cardLabel: label)
            let job = Job(label: label, sourcePath: drainSrc, destinations: [drainDest])
            job.phase = .queued
            job.launchPlanSnapshot = plan
            return job
        }
        let drainJournal = JobJournal(url: root.appendingPathComponent("drain-jobs.json"), historyLimit: 10)
        let drainModel = AppModel(journal: drainJournal)

        defaults.set("single", forKey: Pref.queueMode)
        drainModel.pauseDispatch()
        drainModel.jobs = [sleeper("SERIAL_1"), sleeper("SERIAL_2")]
        drainModel.resumeDispatch()
        require(drainModel.jobs.map(\.phase) == [.starting, .queued],
                "one at a time must launch only the first queued job: \(drainModel.jobs.map(\.phase))")
        drainModel.terminateAllEngines()

        defaults.set("off", forKey: Pref.queueMode)
        drainModel.pauseDispatch()
        drainModel.jobs = [sleeper("PAR_1"), sleeper("PAR_2"), sleeper("PAR_3")]
        drainModel.resumeDispatch()
        require(drainModel.jobs.map(\.phase) == [.starting, .starting, .starting],
                "all at once must launch every queued job: \(drainModel.jobs.map(\.phase))")
        drainModel.terminateAllEngines()

        print("QueueControlCheck: all assertions passed")
    }
}
