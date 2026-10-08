import Foundation

enum TerminalJournalCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

    /// Overlapped verify: file B starts copying before file A's file_done.
    /// The displayed total must never fall at that boundary (round 9, F1).
    @MainActor
    static func checkOverlapProgressNeverFalls() {
        let job = Job(label: "OVERLAP", sourcePath: "/tmp/overlap-card",
                      destinations: ["/tmp/overlap-a", "/tmp/overlap-b"])
        var shown: [Int64] = []
        func feed(_ event: [String: Any]) {
            require(AppModel.apply(event: event, to: job), "\(event["event"] ?? "?") was rejected")
            shown.append(job.displayedBytesDone)
        }
        feed(["event": "job_started", "bytes": 300, "files": 2,
              "destinations": ["/tmp/overlap-a", "/tmp/overlap-b"]])
        feed(["event": "file_started", "path": "A.mov"])
        feed(["event": "file_progress", "path": "A.mov", "done": 200])
        feed(["event": "file_started", "path": "B.mov"])
        feed(["event": "file_progress", "path": "B.mov", "done": 10])
        feed(["event": "file_done", "path": "A.mov", "bytes": 200, "outcome": "verified",
              "status": ["/tmp/overlap-a": "verified", "/tmp/overlap-b": "verified"]])
        feed(["event": "file_progress", "path": "B.mov", "done": 100])
        feed(["event": "file_done", "path": "B.mov", "bytes": 100, "outcome": "verified",
              "status": ["/tmp/overlap-a": "verified", "/tmp/overlap-b": "verified"]])
        require(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 },
                "displayed progress fell at a file boundary: \(shown)")
        require(shown[4] == 210, "A's copied bytes must still count while it verifies: \(shown)")
        require(job.displayedBytesDone == 300 && job.fraction == 1.0,
                "finished job must show every byte: \(shown)")
    }

    @MainActor
    static func run() throws {
        checkOverlapProgressNeverFalls()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-terminal-journal-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("CARD").path
        let rawA = root.appendingPathComponent("DEST_A").path
        let rawB = root.appendingPathComponent("DEST_B").path
        let destinationA = rawA + "/SHOW/Raws/DUMPTRUCK_TEST/Raws"
        let destinationB = rawB + "/SHOW/Raws/DUMPTRUCK_TEST/Raws"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rawA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rawB, withIntermediateDirectories: true)
        let engineRoot = root.appendingPathComponent("engine").path
        try FileManager.default.createDirectory(atPath: engineRoot + "/.venv/bin",
                                                 withIntermediateDirectories: true)

        let job = Job(label: "DCIM", sourcePath: source,
                      destinations: [destinationA, destinationB])
        let plan = JournalLaunchPlan(
            src: source,
            rawRoots: [rawA, rawB],
            destinations: [destinationA, destinationB],
            args: ["-m", "dumptruck.cli", "offload", source, destinationA, destinationB,
                   "--label", "DCIM", "--json"],
            enginePython: engineRoot + "/.venv/bin/python",
            engineRoot: engineRoot,
            sourceVolumeUUID: "source-uuid",
            rootVolumeUUIDs: ["a-uuid", "b-uuid"],
            sourceFileID: "1:2",
            rootFileIDs: ["3:4", "5:6"],
            mirroredFolder: "SHOW",
            organizationFolder: "Raws/DUMPTRUCK_TEST/Raws",
            cardLabel: "DCIM")
        job.launchPlanSnapshot = plan

        let laneA = destinationA + "/DCIM"
        let laneB = destinationB + "/DCIM"
        let manifestPaths = [
            laneA + "/ascmhl/0001_DCIM_20260822_032828Z.mhl",
            laneA + "/DCIM_20260822_032828.mhl",
            laneB + "/ascmhl/0001_DCIM_20260822_032828Z.mhl",
            laneB + "/DCIM_20260822_032828.mhl"
        ]
        // Keep this fixture in lockstep with JobEvidenceParser's production
        // default.  A temporary fallback here makes the otherwise-valid
        // engine event look unsafe because the parser deliberately accepts
        // only the real Application Support report root (or DUMPTRUCK_HOME).
        let localReportRoot = ProcessInfo.processInfo.environment["DUMPTRUCK_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Dumptruck").path
        let reportName = "DCIM_offload_20260821_232828_915930_ffee419c"
        let reportPaths = [
            destinationA + "/Reports/DCIM/\(reportName).html",
            destinationB + "/Reports/DCIM/\(reportName).html",
            localReportRoot + "/reports/DCIM/\(reportName).html",
            destinationA + "/Reports/DCIM/\(reportName).pdf"
        ]

        // Apply the same event sequence emitted by the live engine. The
        // terminal event is held pending until the process exit is accepted.
        require(AppModel.apply(event: ["event": "job_started", "bytes": 3,
                                       "files": 1, "destinations": [laneA, laneB]], to: job),
                "job_started was rejected")
        require(AppModel.apply(event: ["event": "file_started", "path": "DCIM/A.mov"], to: job),
                "file_started was rejected")
        require(AppModel.apply(event: ["event": "file_progress", "path": "DCIM/A.mov",
                                       "done": 3], to: job),
                "file_progress was rejected")
        require(AppModel.apply(event: ["event": "file_done", "path": "DCIM/A.mov",
                                       "bytes": 3, "outcome": "verified",
                                       "status": [laneA: "verified", laneB: "verified"]], to: job),
                "file_done was rejected")
        require(AppModel.apply(event: ["event": "finalizing"], to: job),
                "finalizing was rejected")
        require(AppModel.apply(event: ["event": "source_reread_started", "total": 3], to: job),
                "source_reread_started was rejected")
        require(AppModel.apply(event: ["event": "source_reread_progress", "done": 3,
                                       "total": 3], to: job),
                "source_reread_progress was rejected")
        require(AppModel.apply(event: ["event": "job_done", "fully_verified": true,
                                       "errors": [], "warnings": []], to: job),
                "job_done was rejected")
        require(AppModel.apply(event: ["event": "attestation", "safe_to_wipe_source": true,
                                       "safe_to_wipe_blockers": [],
                                       "distinct_physical_devices": 2,
                                       "files_trusted_from_prior_generations": 0], to: job),
                "attestation was rejected")
        require(!job.safeToWipe,
                "mid-run attestation published wipe authority before clean process exit")
        let attestationJournal = JobJournal(
            url: root.appendingPathComponent("attestation-jobs.json"))
        require(attestationJournal.save(
            records: [JobJournalRecord(job: job, plan: plan)]).isSuccess,
            "safe attestation poisoned the still-running journal record")
        require(AppModel.apply(event: ["event": "manifests_written", "paths": manifestPaths], to: job),
                "manifests_written was rejected")
        require(AppModel.apply(event: ["event": "report_written", "paths": reportPaths], to: job),
                "report_written was rejected")
        require(AppModel.apply(event: ["event": "offload_complete", "ok": true,
                                       "protocol": 3, "fully_verified": true,
                                       "safe_to_wipe_source": true], to: job),
                "offload_complete was rejected")

        require(job.pendingTerminalOk && job.pendingFullyVerified == true
                    && job.pendingSafeToWipe == true,
                "terminal result was not held as pending")
        job.fullyVerified = job.pendingFullyVerified ?? false
        job.safeToWipe = job.pendingSafeToWipe ?? false
        job.phase = .done

        let journal = JobJournal(url: root.appendingPathComponent("jobs.json"))
        let record = JobJournalRecord(job: job, plan: plan)
        require(journal.save(records: [record]).isSuccess,
                "terminal event application could not persist its journal record")
        require(job.verdict == .safeToWipe,
                "clean terminal event did not produce SAFE TO WIPE")

        if case .loaded(let document) = journal.load() {
            require(document.records.count == 1, "terminal record did not round-trip")
            require(document.records[0].reportPaths == reportPaths,
                    "terminal report paths were not persisted")
            require(document.records[0].manifestPaths == manifestPaths,
                    "terminal manifest paths were not persisted")
        } else {
            fatalError("terminal record failed to load after persistence")
        }

        print("TerminalJournalCheck: all assertions passed")
    }
}
