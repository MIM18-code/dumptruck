import Foundation

/// Regression checks for the Codex desktop QA of 2026-09-15.
/// DT-QA-01: the model republishes only on a real preference change.
/// DT-QA-02: a bad card name is refused at the field and can never poison
///           the journal; correcting it recovers without a relaunch.
/// DT-QA-04: a later verification is attached to the job it checked,
///           revokes SAFE TO WIPE on damage, persists, and restores.
/// Round 3 (2026-09-15 evening):
/// R3-01: current wipe authority is withdrawn when a destination the SAFE
///        verdict rests on unmounts or a copied file under it changes.
/// R3-05: external drives offer an eject control even when Cocoa does not
///        call them "ejectable".
enum DesktopQACheck {

    @inline(__always)
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    struct Timeout: Error {}

    final class CallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// A settled card, failed included, can be dismissed; a running one
    /// cannot; a later alarm brings a dismissed card back (beta tester,
    /// 2026-11-03: a stopped transfer had no way off the screen).
    @MainActor
    static func dismissalRule() {
        let failed = Job(label: "STOPPED", sourcePath: "/Volumes/CARD", destinations: ["/Volumes/D/X"])
        failed.phase = .failed
        failed.stopRequested = true
        let key = JobDismissal.alarmKey(failed)
        require(JobDismissal.isHidden(failed, dismissedAs: key), "a dismissed failed card hides")
        require(!JobDismissal.isHidden(failed, dismissedAs: nil), "an undismissed card shows")
        // As recordLaterVerification files damage: on the job and by lane.
        let later = LaterVerification(
            date: Date(), folder: "/Volumes/D/X", passed: 0, failed: 1, missing: 0,
            new: 0, unverifiable: 0, chainProblems: 0)
        failed.laterVerification = later
        failed.custodyFailures["/Volumes/D/X"] = later
        require(!JobDismissal.isHidden(failed, dismissedAs: key),
                "a damage finding after the dismissal brings the card back")
        // A stop the operator chose reads as a stop, and Clear Finished may
        // take it; a stop on top of a damaged file stays a failure.
        let stopped = Job(label: "STOP2", sourcePath: "/Volumes/CARD", destinations: ["/Volumes/D/X"])
        stopped.phase = .failed
        stopped.stopRequested = true
        require(stopped.verdict == .failed, "a stop is still FAILED for every safety decision")
        require(stopped.stoppedByOperator, "a plain stop reads as stopped")
        require(stopped.currentCustodyEcho == "stopped · keep the card", "the rail says stopped")
        require(LiveJobClearing.isClearable(stopped), "Clear Finished takes a stopped card")
        let crashed = Job(label: "FAIL", sourcePath: "/Volumes/CARD", destinations: ["/Volumes/D/X"])
        crashed.phase = .failed
        require(!crashed.stoppedByOperator && !LiveJobClearing.isClearable(crashed),
                "a real failure is not a stop and stays on screen")
        let fast = Job(label: "FAST", sourcePath: "/Volumes/CARD", destinations: ["/Volumes/D/X"])
        fast.phase = .done
        require(fast.verdict == .unverified && LiveJobClearing.isClearable(fast),
                "a clean Fast-mode copy clears with the rest")
        require(fileCount(1) == "1 file" && fileCount(3) == "3 files", "file counts read right at one")
        // Damage on a second destination after the dismissal is a new alarm.
        let damaged = Job(label: "DMG", sourcePath: "/Volumes/CARD",
                          destinations: ["/Volumes/A/X", "/Volumes/B/X"])
        damaged.phase = .failed
        func finding(_ folder: String, _ t: Double) -> LaterVerification {
            LaterVerification(date: Date(timeIntervalSince1970: t), folder: folder, passed: 0,
                              failed: 1, missing: 0, new: 0, unverifiable: 0, chainProblems: 0)
        }
        damaged.custodyFailures["/Volumes/A/X"] = finding("/Volumes/A/X", 1)
        let damagedKey = JobDismissal.alarmKey(damaged)
        require(JobDismissal.isHidden(damaged, dismissedAs: damagedKey), "dismissed with A damaged")
        damaged.custodyFailures["/Volumes/B/X"] = finding("/Volumes/B/X", 2)
        require(!JobDismissal.isHidden(damaged, dismissedAs: damagedKey),
                "damage on B after the dismissal brings the card back")
        let running = Job(label: "RUN", sourcePath: "/Volumes/CARD", destinations: ["/Volumes/D/X"])
        running.phase = .copying
        require(!JobDismissal.isHidden(running, dismissedAs: JobDismissal.alarmKey(running)),
                "a running card never hides")
    }

    @MainActor
    static func run() async throws {
        dismissalRule()
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("dumptruck-desktop-qa-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Make the source before the other checks. These fixtures are not a
        // transfer; their creation must settle before minting its SAFE session.
        let r3Root = (root.path as NSString).resolvingSymlinksInPath  // FSEvents wants real paths
        let r3Source = r3Root + "/R3_CARD"
        let r3DestA = r3Root + "/R3_DEST_A"
        let r3DestB = r3Root + "/R3_DEST_B"
        for p in [r3Source, r3DestA + "/R3_SAFE", r3DestB + "/R3_SAFE"] {
            try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        }
        try Data("clip".utf8).write(to: URL(fileURLWithPath: r3Source + "/clip.mov"))
        for d in [r3DestA, r3DestB] {
            try Data("clip".utf8).write(to: URL(fileURLWithPath: d + "/R3_SAFE/clip.mov"))
        }

        // Engine xxHash64 vectors, including every tail boundary and multiple reads.
        let vectors: [(Int, UInt64)] = [
            (0, 0xef46db3751d8e999),
            (1, 0xe934a84adb052768),
            (4, 0xffced8604453cc1e),
            (7, 0x14cc643f630c72d2),
            (8, 0x884a173614b81b8d),
            (15, 0xa948f5f0f6abac2d),
            (16, 0x44b6ef2fb84169f7),
            (31, 0xc346d2b59b4d8ee1),
            (32, 0xcbf59c5116ff32b4),
            (33, 0x0c535d1acafb8ead),
            (63, 0xe26aa9e2a95f8e4f),
            (64, 0xf7c67301db6713f0),
            (65, 0xc31eb63b2ae4465b),
            (4097, 0xba236f554636de5b),
            (1048613, 0x4ceb0aec2321345e)
        ]
        for (length, expected) in vectors {
            let bytes = (0..<length).map { UInt8($0 % 251) }
            for chunkSize in [1, 7, 32, 1024 * 1024] {
                var hash = DestinationXXH64()
                for start in stride(from: 0, to: length, by: chunkSize) {
                    hash.update(bytes[start..<min(start + chunkSize, length)])
                }
                require(hash.value == expected, "xxHash64 disagrees with engine at length \(length), chunk \(chunkSize)")
            }
        }
        let directJudge = DestinationChangeJudge(root: r3DestA + "/R3_SAFE",
            expectedHashes: ["clip.mov": vectors.first(where: { $0.0 == 4 })!.1])
        directJudge.capture()
        require(!directJudge.isReady, "a baseline with the wrong engine checksum must fail closed")
        // A file saved beside an older one of the same name is watched where
        // it was saved. Checked at its card path, the watch compared the new
        // hash with the older file and withdrew a good SAFE verdict (Codex
        // review of PR 18).
        let besideRoot = r3Root + "/BESIDE/CARD"
        try FileManager.default.createDirectory(atPath: besideRoot, withIntermediateDirectories: true)
        let olderBytes = (0..<4097).map { UInt8($0 % 251) }
        let newerBytes = (0..<1048613).map { UInt8($0 % 251) }
        try Data(olderBytes).write(to: URL(fileURLWithPath: besideRoot + "/clip.mov"))
        try Data(newerBytes).write(to: URL(fileURLWithPath: besideRoot + "/clip_2.mov"))
        let besideJob = Job(label: "CARD", sourcePath: r3Root + "/BESIDE/SRC", destinations: [r3Root + "/BESIDE"])
        require(AppModel.apply(event: [
            "event": "file_done", "path": "clip.mov", "bytes": 1048613, "outcome": "verified",
            "xxh64": "4ceb0aec2321345e", "status": [besideRoot: "verified"],
            "saved_as": [besideRoot: "clip_2.mov"],
        ], to: besideJob), "a file_done with saved_as is a valid event")
        require(besideJob.expectedHashes(forRoot: besideRoot) == ["clip_2.mov": 0x4ceb0aec2321345e],
                "the hash is expected at the saved-as name: \(besideJob.expectedHashes(forRoot: besideRoot))")
        require(besideJob.expectedHashes(forRoot: r3Root + "/OTHER") == ["clip.mov": 0x4ceb0aec2321345e],
                "a destination that holds the file at its card path keeps that path")
        let besideJudge = DestinationChangeJudge(
            root: besideRoot, expectedHashes: besideJob.expectedHashes(forRoot: besideRoot))
        besideJudge.capture()
        require(besideJudge.isReady, "the baseline holds with the older file still at the card path")
        let cardPathJudge = DestinationChangeJudge(root: besideRoot, expectedHashes: besideJob.verifiedFileHashes)
        cardPathJudge.capture()
        require(!cardPathJudge.isReady, "checked at the card path the same folder fails, which was the bug")
        let missingJudge = DestinationChangeJudge(root: r3Root + "/missing", expectedHashes: ["x": 1])
        missingJudge.capture()
        require(!missingJudge.isReady && missingJudge.provesChange(r3Root + "/missing"),
                "a missing baseline must fail closed")
        let sourceCallbacks = CallbackCounter()
        let sourceBox = SourceMutationCallbackBox(filter: nil, judge: nil,
            settled: {}, handler: { sourceCallbacks.increment() })
        sourceBox.receiveEvent(paths: ["/fixture/clip"], forced: false)
        sourceBox.receiveEvent(paths: ["/fixture/clip"], forced: false)
        require(sourceCallbacks.value == 2, "source monitors must keep reporting after a new verification")
        // Browsing a card in Finder is not a change to the card (Joshua,
        // 2026-09-28): the source filter drops exactly the engine's junk
        // and metadata-only events, and nothing else.
        let cardRoot = "/Volumes/NO NAME"
        let sourceJunkFilter = MutationEventFilter.sourceJunk(root: cardRoot)
        let browseCallbacks = CallbackCounter()
        let browseBox = SourceMutationCallbackBox(filter: sourceJunkFilter, judge: nil,
            settled: {}, handler: { browseCallbacks.increment() })
        browseBox.receiveEvent(paths: [cardRoot + "/.DS_Store",
                                       cardRoot + "/PRIVATE/M4ROOT/CLIP/._C0001.MP4",
                                       cardRoot + "/.Spotlight-V100/Store-V2/x",
                                       cardRoot + "/.fseventsd/0001"],
                               forced: false, eventMetadataOnly: [false, false, false, false])
        require(browseCallbacks.value == 0, "Finder litter on a card is not a change")
        browseBox.receiveEvent(paths: [cardRoot + "/.DS_Store", cardRoot + "/PRIVATE/M4ROOT/CLIP/C0001.MP4"],
                               forced: false, eventMetadataOnly: [false, true])
        require(browseCallbacks.value == 0, "a last-opened tag on a clip is not a change")
        browseBox.receiveEvent(paths: [cardRoot + "/.DS_Store", cardRoot + "/PRIVATE/M4ROOT/CLIP/C0001.MP4"],
                               forced: false, eventMetadataOnly: [false, false])
        require(browseCallbacks.value == 1, "a content event on a clip still fires, even beside litter")
        browseBox.receiveEvent(paths: [cardRoot + "/DCIM/NEW.MP4"], forced: false,
                               eventMetadataOnly: [false])
        require(browseCallbacks.value == 2, "a new file on the card still fires")
        browseBox.receiveEvent(paths: [cardRoot + "/.DS_Store"], forced: true,
                               eventMetadataOnly: [false])
        require(browseCallbacks.value == 3, "an unknown change set bypasses the source filter")
        browseBox.receiveEvent(paths: ["/Volumes/OTHER/.DS_Store"], forced: false,
                               eventMetadataOnly: [false])
        require(browseCallbacks.value == 4, "a path the filter cannot place under the card fails closed")
        browseBox.receiveEvent(paths: [cardRoot + "/PRIVATE/M4ROOT/CLIP/C0001.MP4"], forced: false)
        require(browseCallbacks.value == 5, "without per-event flags nothing is assumed metadata-only")
        require(!sourceJunkFilter.isIgnorable(cardRoot + "/DS_Store_notes.txt")
                && !sourceJunkFilter.isIgnorable(cardRoot + "/CLIP/.hidden_but_real.MP4"),
                "only the engine's junk names are ignorable")
        let forcedBox = SourceMutationCallbackBox(filter: .destinationJunk, judge: nil,
                                                  settled: {}, handler: {})
        forcedBox.receiveEvent(paths: [r3DestA + "/R3_SAFE/.DS_Store"], forced: true)
        require(forcedBox.hasSeenMutation, "unknown change sets bypass the junk filter")
        let hiddenParent = root.appendingPathComponent(".TemporaryItems/selected-lane")
        try fm.createDirectory(at: hiddenParent, withIntermediateDirectories: true)
        let hiddenClip = hiddenParent.appendingPathComponent("clip.mov")
        try Data("clip".utf8).write(to: hiddenClip)
        let hiddenJudge = DestinationChangeJudge(root: hiddenParent.path,
            expectedHashes: ["clip.mov": 401716075516235880])
        hiddenJudge.capture()
        require(hiddenJudge.isReady, "fixture under a junk-named ancestor is checked")
        let hiddenBox = SourceMutationCallbackBox(filter: .destinationJunk, judge: hiddenJudge,
                                                  settled: {}, handler: {})
        try Data("damage".utf8).write(to: hiddenClip)
        hiddenBox.receiveEvent(paths: [hiddenClip.path], forced: false)
        require(hiddenBox.hasSeenMutation, "a junk-named ancestor cannot hide changes inside the selected lane")
        let journalURL = root.appendingPathComponent("jobs.json")
        let model = AppModel(journal: JobJournal(url: journalURL, historyLimit: 10))

        // ---- DT-QA-01: equal-value writes do not republish; real changes do.
        let defaults = UserDefaults.standard
        let savedTemplate = defaults.object(forKey: Pref.folderTemplate)
        let savedHUD = defaults.object(forKey: Pref.menuBarHUD)
        defer {
            defaults.set(savedTemplate, forKey: Pref.folderTemplate)
            defaults.set(savedHUD, forKey: Pref.menuBarHUD)
        }
        _ = model.preferencesDidChange()   // absorb whatever init left behind
        let hud = defaults.bool(forKey: Pref.menuBarHUD)
        defaults.set(hud, forKey: Pref.menuBarHUD)   // what MenuBarExtra does every scene update
        require(!model.preferencesDidChange(), "an equal-value write must not republish")
        defaults.set("railWidth-\(UUID().uuidString)", forKey: "railWidth.sources.qa")
        require(!model.preferencesDidChange(), "a key the model never reads must not republish")
        defaults.set("{Project}/QA-\(UUID().uuidString)", forKey: Pref.folderTemplate)
        require(model.preferencesDidChange(), "a real preference change must republish")
        require(!model.preferencesDidChange(), "and only once per change")
        let fp1 = AppModel.preferenceFingerprint()
        require(fp1 == AppModel.preferenceFingerprint(), "the fingerprint is stable between writes")

        // ---- DT-QA-02: the card-name rules, at the gate and in the journal.
        for bad in ["../escape", "a/b", "a\\b", "a:b", ".", "..", "", "  ", "ASCMHL", "x\u{07}y"] {
            require(CardLabelRules.validate(bad) != nil, "label \(bad.debugDescription) must be refused")
        }
        for good in ["CARD_A", "A001", "Stage Shows B", "Loose 2026-09-15 14.02.31", "reel-01.v2"] {
            require(CardLabelRules.validate(good) == nil, "label \(good.debugDescription) must be accepted")
        }
        let source = root.appendingPathComponent("CARD").path
        let dest = root.appendingPathComponent("DEST").path
        try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: source + "/clip.mov"))
        require(model.assign(source, as: .source), "stage the source")
        model.inspectionError = nil
        // Start now waits out the card read ("Reading card…", 2026-09-28);
        // this block checks the label gate, which sits after it.
        model.inspecting = false
        require(model.assignDroppedDestinations([dest]), "stage the destination")
        model.label = "../escape"
        let reason = model.startBlockedReason
        require(reason?.contains("illegal path character") == true,
                "the Start gate must name the bad label, got \(String(describing: reason))")
        require(!model.canStart, "Start must be disabled")
        model.start()
        require(model.jobs.isEmpty, "a refused label must not create a job")
        require(model.journalError == nil, "a refused label must not touch the journal")
        // Even if the field gate were bypassed, the record itself is refused
        // before insertion (the shape rule the journal enforces).
        let escaped = Job(label: "../escape", sourcePath: source, destinations: [dest + "/x"])
        require(!JobJournal.recordShapeIsValid(JobJournalRecord(job: escaped, plan: nil)),
                "a path-escaping label is not a valid record")
        model.label = "card_alpha"
        let after = model.startBlockedReason
        require(after.map { !$0.contains("Card label") && !$0.contains("journal") } ?? true,
                "correcting the name must clear the label and journal reasons, got \(String(describing: after))")
        require(model.journalError == nil, "journal still healthy after correction")
        model.clearSource()

        let savedReverify = defaults.object(forKey: Pref.reverifyExisting)
        defer { defaults.set(savedReverify, forKey: Pref.reverifyExisting) }
        defaults.set(false, forKey: Pref.reverifyExisting)
        guard case .success(let retryPlan) = model.buildPlan(src: source, rawRoots: [dest], cardLabel: "RETRY") else {
            fatalError("retry fixture plan failed")
        }
        for path in retryPlan.dests { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let retryJob = Job(label: "RETRY", sourcePath: source, destinations: retryPlan.dests)
        retryJob.phase = .done
        retryJob.launchPlanSnapshot = model.journalPlan(retryPlan)
        defaults.set(true, forKey: Pref.reverifyExisting)
        require(model.stageRetry(retryJob), "retry fixture must stage")
        require(model.retryUsesCurrentSettings, "retry should default to visible current settings")
        let currentRetry = model.currentEnginePlanForRetry(retryPlan)
        require(currentRetry?.args.contains("--reverify-existing") == true,
                "enabled reread must survive Stage Retry")
        require(currentRetry?.dests == retryPlan.dests, "retry settings must not retarget the folders")
        require(currentRetry?.rootFileIDs == retryPlan.rootFileIDs
            && currentRetry?.srcFileID == retryPlan.srcFileID, "retry settings must preserve identity pins")
        require(model.retrySettingsSummary.contains("existing copies re-read"), "retry must describe its effective settings")
        model.retryUsesCurrentSettings = false
        require(model.currentEnginePlanForRetry(retryPlan)?.args.contains("--reverify-existing") == false,
                "explicit saved-settings choice must preserve original flags")
        require(model.retrySettingsSummary.contains("existing copies trusted"), "saved trust must be disclosed")
        model.clearSource()

        // ---- DT-QA-04: a later verification lands on the job and the ledger.
        let lane = dest + "/SHOW/Raws/CARD_B"
        let good = Job(label: "CARD_B", sourcePath: source, destinations: [dest + "/SHOW/Raws", dest + "/SECOND"])
        good.phase = .done
        good.fullyVerified = true
        good.safeToWipe = true
        good.physicalDevices = 2
        good.laneRoots = [lane, dest + "/SECOND/CARD_B"]
        let other = Job(label: "CARD_C", sourcePath: source, destinations: [dest + "/SHOW/Raws"])
        other.phase = .done
        other.fullyVerified = true
        other.safeToWipe = true
        other.physicalDevices = 2
        other.laneRoots = [dest + "/SHOW/Raws/CARD_C"]
        model.jobs = [good, other]
        func summary(failed: [String], missing: [String], new: [String]) -> ExistingVerificationSummary {
            ExistingVerificationSummary(
                passed: 64, failed: failed, missing: missing, new: new,
                unverifiable: [], chainProblems: [], seconds: 1, protocolVersion: 3,
                fNocache: true, reportPaths: [], custodyPaths: [])
        }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        model.recordLaterVerification(folder: lane + "/", summary: summary(failed: ["hello.txt"], missing: ["tiny_000.txt"], new: ["extra.bin", "extra2.bin"]), date: when)
        require(good.laterVerification?.failed == 1 && good.laterVerification?.missing == 1
                && good.laterVerification?.new == 2, "the damaged summary lands on the job that wrote the lane")
        require(!good.safeToWipe, "damage revokes SAFE TO WIPE")
        require(good.verdict == .verifiedKeepCard, "the offload verdict itself stays what the offload proved")
        require(good.wipeBlockers.contains(where: { $0.hasPrefix("a later verification found damage") }),
                "the blocker names the later check: \(good.wipeBlockers)")
        require(good.laterVerification?.line.contains("1 failed, 1 missing, 2 new") == true,
                "the line reads the counts: \(good.laterVerification?.line ?? "")")
        require(other.laterVerification == nil && other.safeToWipe, "an unrelated job is untouched")
        model.recordLaterVerification(folder: other.laneRoots[0], summary: summary(failed: [], missing: [], new: []), date: when)
        require(other.laterVerification?.isClean == true && other.safeToWipe, "a clean later check keeps the verdict")
        // Persisted: the ledger on disk carries both results (a second
        // AppModel cannot take the instance lock in-process, so read the
        // document the way a relaunch would decode it).
        require(model.journalError == nil, "recording a later verification must persist cleanly")
        guard case .loaded(let document) = JobJournal(url: journalURL, historyLimit: 10).load() else {
            fatalError("the journal must load after a later verification was recorded")
        }
        let restored = document.records.first(where: { $0.label == "CARD_B" })
        require(restored?.laterVerification?.failed == 1 && restored?.safeToWipe == false,
                "the later verification and the revoked wipe are in the ledger")
        require(document.records.first(where: { $0.label == "CARD_C" })?.laterVerification?.isClean == true,
                "the clean later check is in the ledger too")
        require(good.currentCustodyEcho == "custody check failed, keep the card",
                "current rail must not call damaged custody verified")
        require(restored?.custodyFailures?[lane]?.failed == 1, "damage map must persist")
        let secondLane = dest + "/SECOND/CARD_B"
        model.recordLaterVerification(folder: secondLane, summary: summary(failed: ["x"], missing: [], new: []))
        require(good.custodyFailures.count == 2, "a second damaged lane must not erase the first")
        model.recordLaterVerification(folder: secondLane, summary: summary(failed: [], missing: [], new: []))
        require(good.custodyFailures.count == 1 && good.custodyFailure(for: lane) != nil,
                "a clean unrelated lane must not clear known damage")
        model.recordLaterVerification(folder: lane, summary: summary(failed: [], missing: [], new: []))
        require(!good.hasCustodyFailure, "a successful custody reread may retire the damage warning")
        require(!good.wipeBlockers.contains { $0.hasPrefix("a later verification found damage") },
                "a clean custody reread must remove the obsolete damage warning")
        require(!good.safeToWipe, "clearing damage must not revive old wipe authority")

        // ---- R2-01: the real inspector settles every time, cancelled or not.
        //      Twelve back-to-back runs against the checkout's engine, every
        //      other one cancelled mid-flight, each bounded by a timeout. The
        //      old reader-thread waitUntilExit() parked forever with no child.
        let engineRoot = EngineRootResolver.resolve()
        let enginePython = engineRoot + "/.venv/bin/python"
        if fm.isExecutableFile(atPath: enginePython) {
            let card = root.appendingPathComponent("INSPECT_CARD").path
            try fm.createDirectory(atPath: card, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: card + "/A001.mov"))
            let inspector = StandardBatchSourceInspector(enginePython: enginePython, engineRoot: engineRoot)
            let pin = FileIdentityPin(deviceId: 1, fileId: 1, volumeUUID: nil)
            for round in 0..<12 {
                let task = Task { try await inspector.inspect(sourcePath: card, pin: pin) }
                if round % 2 == 1 {
                    try await Task.sleep(nanoseconds: UInt64(20_000_000 * (round % 3 + 1)))
                    task.cancel()
                }
                do {
                    let result = try await withTimeout(30) { try await task.value }
                    require(result.metadata.fileCount == 1, "inspection reads the one file (round \(round))")
                } catch is Timeout {
                    fatalError("inspector never settled in round \(round) (cancelled: \(round % 2 == 1))")
                } catch let error as BatchSourceStagingError {
                    require(round % 2 == 1 && error == .cancelled,
                            "an uncancelled inspection must succeed, got \(error) in round \(round)")
                }
            }
        } else {
            print("DesktopQACheck: no engine python at \(enginePython); R2-01 live-inspector loop skipped")
        }

        // ---- R2-02 + R2-03: batch labels and lane previews.
        let staging = BatchSourceStagingModel()
        let batchCard = root.appendingPathComponent("BATCH_CARD").path
        try fm.createDirectory(atPath: batchCard, withIntermediateDirectories: true)
        let attrs = try fm.attributesOfItem(atPath: batchCard)
        let candidate = BatchSourceCandidate(path: batchCard)
        candidate.identityPin = FileIdentityPin(
            deviceId: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            fileId: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            volumeUUID: (try? URL(fileURLWithPath: batchCard)
                .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString)
        candidate.inspection = CardInspection(format: "generic", formatName: "Generic data", reelName: "",
                                              suggestedLabel: "BATCH_CARD", known: false, mounts: 0,
                                              files: 1, bytes: 1, previousDestinations: [])
        // Before preflight seeds the field, the suggestion stands in.
        require(candidate.effectiveLabel == "", "an un-seeded field with an inspection is empty, not the suggestion")
        candidate.customLabel = "R2_BATCH_ONE"
        staging.candidates = [candidate]
        let batchDest = root.appendingPathComponent("BATCH_DEST").path
        try fm.createDirectory(atPath: batchDest, withIntermediateDirectories: true)
        model.unassignDestination(dest)   // only the batch destination from here on
        require(model.assignDroppedDestinations([batchDest]), "stage the batch destination")
        let savedProject = defaults.object(forKey: Pref.projectName)
        defaults.set("{Project}/Raws", forKey: Pref.folderTemplate)
        defaults.set("QA_PROJECT", forKey: Pref.projectName)
        defer { defaults.set(savedProject, forKey: Pref.projectName) }
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready, "a good label and a free lane are ready: \(candidate.status)")
        require(candidate.projectedLanes == [batchDest + "/QA_PROJECT/Raws/R2_BATCH_ONE"],
                "the preview must be the lane the launch writes, template included: \(candidate.projectedLanes)")
        require(BatchSourceStagingModel.laneBase(
                    root: batchDest, label: "X", volumeName: "V", cameraFormat: "?", reel: "",
                    mirroredFolder: "", template: "", project: "") == batchDest,
                "no template means root/label, as before")
        // The taken-folder check looks at the same rendered path. It used to
        // refuse a typed label whose folder existed at all; owner's rule,
        // 2026-11-09: an empty folder is free, and a folder holding another
        // card's footage numbers the typed name instead of refusing it.
        let renderedLane = batchDest + "/QA_PROJECT/Raws/R2_BATCH_ONE"
        try fm.createDirectory(atPath: renderedLane, withIntermediateDirectories: true)
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready && candidate.effectiveLabel == "R2_BATCH_ONE"
                    && candidate.projectedLanes == [renderedLane] && candidate.renameNote == nil,
                "an empty existing rendered lane keeps the name: \(candidate.status) \(candidate.effectiveLabel)")
        try Data([1]).write(to: URL(fileURLWithPath: renderedLane + "/C0001.MP4"))
        staging.cardRegistry = { [CardFolderClaims.Record(
            id: "someone-else", label: "OTHER", destinations: [renderedLane])] }
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready && candidate.effectiveLabel == "R2_BATCH_ONE_2",
                "a typed name whose rendered lane holds another card's footage is numbered: "
                    + "\(candidate.status) \(candidate.effectiveLabel)")
        require(candidate.customLabel == "R2_BATCH_ONE", "the field keeps what was typed")
        require(candidate.projectedLanes == [batchDest + "/QA_PROJECT/Raws/R2_BATCH_ONE_2"],
                "the numbered lane is the rendered one: \(candidate.projectedLanes)")
        require(candidate.renameNote == BatchLabelAllocator.renameNote(
                    from: "R2_BATCH_ONE", to: "R2_BATCH_ONE_2",
                    reason: .folderTaken(lanePath: renderedLane)),
                "the note says where the card is going: \(candidate.renameNote ?? "nil")")
        staging.cardRegistry = { [] }
        try fm.removeItem(atPath: batchDest + "/QA_PROJECT")
        // A cleared label is an error, not a silent fallback to the suggestion.
        for cleared in ["", "   "] {
            candidate.customLabel = cleared
            staging.revalidateAll(appModel: model)
            require(candidate.status == .refused("Card label cannot be empty."),
                    "a cleared batch label is refused: \(candidate.status)")
            require(candidate.projectedLanes.isEmpty, "no lane is previewed for an empty label")
        }
        candidate.customLabel = "R2_BATCH_ONE"
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready, "restoring the label recovers")

        // Batch and single-card Start agree on the folder template: with
        // {Project} in the template and no project name, both leave the
        // project segment out and the card lands in <root>/Raws. The
        // 2026-09-28 rule made both refuse so they could not drift; the
        // 2026-10-05 rule keeps them together without the gate (Joshua: a
        // project name must not be required to dump cards).
        defaults.set("", forKey: Pref.projectName)
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready,
                "a batch card is ready without a project name: \(candidate.status)")
        require(candidate.projectedLanes == [batchDest + "/Raws/R2_BATCH_ONE"],
                "the lane leaves the project segment out, as single Start does: \(candidate.projectedLanes)")
        require(staging.cardsReadyToQueue, "an unset project name keeps Start enabled")
        require(BatchSourceStagingModel.templateRefusal(
                    template: "{Project}/Raws", project: "", volumeName: "V", label: "A001",
                    cameraFormat: "?", reel: "") == nil,
                "a template with {Project} needs no project name")
        require(BatchSourceStagingModel.templateRefusal(
                    template: "Raws/{CardLabel}", project: "", volumeName: "V", label: "A001",
                    cameraFormat: "?", reel: "") == nil,
                "a template without {Project} needs no project name")

        // A stale banner from an earlier failed queue must not disable Start
        // once the cards are Ready again, and clicking Start re-derives the
        // current reason instead of repeating the stale one.
        defaults.set("QA_PROJECT", forKey: Pref.projectName)
        staging.revalidateAll(appModel: model)
        require(candidate.status == .ready, "setting the project name keeps the card ready")
        staging.generalError = "stale failure from an earlier Start"
        require(staging.cardsReadyToQueue && !staging.canQueueBatch,
                "Ready cards enable Start even with a stale banner")
        // The live refusal is a broken template now that a blank project
        // name no longer refuses anything.
        let badTemplateReason = "Folder template has an unknown token {Bogus} — fix it in Settings > Organize"
        defaults.set("{Bogus}/Raws", forKey: Pref.folderTemplate)
        if case .failure(let error) = staging.queueBatch(appModel: model) {
            require(error == .preflightFailed(badTemplateReason),
                    "Start re-checks and reports the live reason, not the stale one: \(error)")
        } else {
            require(false, "a batch whose template refuses must not queue")
        }
        require(staging.generalError == badTemplateReason, "the banner shows the live reason")
        defaults.set("{Project}/Raws", forKey: Pref.folderTemplate)
        staging.revalidateAll(appModel: model)
        require(staging.generalError == nil && staging.canQueueBatch, "fixing the cause clears the banner")
        model.unassignDestination(batchDest)

        // ---- Same-name cards (Joshua, 2026-09-28): a stack of one camera
        // model mounts with one default name. They are numbered, not
        // refused; a typed duplicate is numbered too (2026-11-09); a folder
        // holding a different card's footage is stepped around; a known card
        // still continues into its own folder.
        let nameDest = root.appendingPathComponent("NAME_DEST").path
        try fm.createDirectory(atPath: nameDest, withIntermediateDirectories: true)
        require(model.assignDroppedDestinations([nameDest]), "stage the naming destination")
        let namingTemplate = defaults.object(forKey: Pref.folderTemplate)
        defaults.set("", forKey: Pref.folderTemplate)   // lanes are <root>/<label>
        func sameNameCard(_ dir: String, known: Bool = false,
                          previous: [String] = [], id: String? = nil) throws -> BatchSourceCandidate {
            let path = root.appendingPathComponent(dir).path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            let a = try fm.attributesOfItem(atPath: path)
            let card = BatchSourceCandidate(path: path)
            card.identityPin = FileIdentityPin(
                deviceId: (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                fileId: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                volumeUUID: (try? URL(fileURLWithPath: path)
                    .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString)
            card.inspection = CardInspection(format: "sony_xavc_s", formatName: "Sony XAVC S",
                                             reelName: "", suggestedLabel: "NO NAME", known: known,
                                             datasetID: id,
                                             mounts: known ? 1 : 0, files: 1, bytes: 1,
                                             previousDestinations: previous)
            card.seedAutomaticLabel("NO NAME")   // what the preflight writes
            return card
        }
        // The card record these checks see: one earlier card wrote
        // <dest>/NO NAME. Never the operator's real record.
        let noNameLane = nameDest + "/NO NAME"
        let namingRecord: () -> [CardFolderClaims.Record] = {
            [CardFolderClaims.Record(id: "a7s-1", label: "NO NAME", destinations: [noNameLane])]
        }
        let sameNames = BatchSourceStagingModel()
        sameNames.cardRegistry = namingRecord
        let a7s = try (1...3).map { try sameNameCard("A7S_\($0)") }
        sameNames.candidates = a7s
        sameNames.revalidateAll(appModel: model)
        require(a7s.allSatisfy { $0.status == .ready }, "same-name cards are all Ready: \(a7s.map(\.status))")
        require(a7s.map(\.effectiveLabel) == ["NO NAME", "NO NAME_2", "NO NAME_3"],
                "same-name cards are numbered in drag order: \(a7s.map(\.effectiveLabel))")
        require(a7s[0].renameNote == nil && a7s[1].renameNote != nil && a7s[2].renameNote != nil,
                "only the renamed cards carry a note")
        require(sameNames.generalError == nil && sameNames.canQueueBatch, "nothing blocks the batch")

        // A job already writing <dest>/NO NAME holds that folder: the batch
        // numbers past it instead of sending a second writer the engine
        // would refuse (Sol review, 2026-11-10).
        let writing = Job(label: "NO NAME", sourcePath: root.appendingPathComponent("BENCH").path,
                          destinations: [nameDest], sourceAssignmentID: UUID())
        writing.phase = .queued
        model.jobs.insert(writing, at: 0)
        sameNames.revalidateAll(appModel: model)
        require(a7s.map(\.effectiveLabel) == ["NO NAME_2", "NO NAME_3", "NO NAME_4"],
                "a folder an active job writes is taken: \(a7s.map(\.effectiveLabel))")
        model.jobs.removeAll { $0.id == writing.id }
        sameNames.revalidateAll(appModel: model)
        require(a7s.map(\.effectiveLabel) == ["NO NAME", "NO NAME_2", "NO NAME_3"],
                "the names come back when the job is gone: \(a7s.map(\.effectiveLabel))")

        // The operator types one name on two cards. Both used to be
        // refused; owner's rule, 2026-11-09: the earlier in drag order keeps
        // it, the later copies as "CAM_B_2" with a note, and the field keeps
        // "CAM_B" as its base, so later passes never make "CAM_B_2_2".
        sameNames.updateLabel(id: a7s[1].id, newLabel: "CAM_B", appModel: model)
        sameNames.updateLabel(id: a7s[2].id, newLabel: "CAM_B", appModel: model)
        for pass in 1...2 {
            if pass == 2 { sameNames.revalidateAll(appModel: model) }
            require(a7s.allSatisfy { $0.status == .ready },
                    "typed duplicates are Ready (pass \(pass)): \(a7s.map(\.status))")
            require(a7s.map(\.effectiveLabel) == ["NO NAME", "CAM_B", "CAM_B_2"],
                    "the later typed duplicate is numbered (pass \(pass)): \(a7s.map(\.effectiveLabel))")
            require(a7s[1].customLabel == "CAM_B" && a7s[2].customLabel == "CAM_B",
                    "both fields keep the typed text (pass \(pass)): \(a7s.map(\.customLabel))")
            require(a7s[2].projectedLanes == [nameDest + "/CAM_B_2"],
                    "the numbered card's lane is the numbered one (pass \(pass))")
            require(a7s[1].renameNote == nil && a7s[2].renameNote == BatchLabelAllocator.renameNote(
                        from: "CAM_B", to: "CAM_B_2", reason: .sameNameInBatch),
                    "only the numbered card carries a note (pass \(pass)): \(a7s[2].renameNote ?? "nil")")
        }
        require(sameNames.canQueueBatch, "typed duplicates do not block the batch")
        sameNames.updateLabel(id: a7s[2].id, newLabel: "CAM_C", appModel: model)
        require(a7s.allSatisfy { $0.status == .ready }, "one edit clears the duplicate: \(a7s.map(\.status))")
        require(a7s[2].effectiveLabel == "CAM_C" && a7s[2].renameNote == nil,
                "a distinct typed name copies as typed, with no note")
        require(a7s[0].effectiveLabel == "NO NAME", "the untouched card keeps its name")

        // Yesterday's "NO NAME" folder. The engine's rule (owner's rule,
        // 2026-11-09, same as single-card Start): an empty folder is free,
        // and so is a folder of files no card on record claims (a stopped
        // first copy resumes into it). Only footage a different card on
        // record wrote makes the new card step around it. This used to
        // number the card as soon as the folder existed.
        try fm.createDirectory(atPath: noNameLane, withIntermediateDirectories: true)
        let fresh = try sameNameCard("A7S_4")
        let taken = BatchSourceStagingModel()
        taken.cardRegistry = namingRecord
        taken.candidates = [fresh]
        taken.revalidateAll(appModel: model)
        require(fresh.status == .ready && fresh.effectiveLabel == "NO NAME" && fresh.renameNote == nil,
                "an empty existing folder keeps the name: \(fresh.status) \(fresh.effectiveLabel)")
        try Data([1]).write(to: URL(fileURLWithPath: noNameLane + "/C0001.MP4"))
        taken.cardRegistry = { [] }
        taken.revalidateAll(appModel: model)
        require(fresh.status == .ready && fresh.effectiveLabel == "NO NAME" && fresh.renameNote == nil,
                "a folder of files no card on record claims keeps the name: \(fresh.effectiveLabel)")
        taken.cardRegistry = namingRecord
        taken.revalidateAll(appModel: model)
        require(fresh.status == .ready && fresh.effectiveLabel == "NO NAME_2",
                "a different card steps around another card's footage: \(fresh.status) \(fresh.effectiveLabel)")
        require(fresh.projectedLanes == [nameDest + "/NO NAME_2"], "its lane is the numbered one")
        require(fresh.renameNote == BatchLabelAllocator.renameNote(
                    from: "NO NAME", to: "NO NAME_2", reason: .folderTaken(lanePath: noNameLane)),
                "the note says another card's footage is there: \(fresh.renameNote ?? "nil")")

        // A typed name whose folder holds another card's footage is
        // numbered too, and keeps its typed text as the base.
        let camDLane = nameDest + "/CAM_D"
        try fm.createDirectory(atPath: camDLane, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: camDLane + "/C0001.MP4"))
        let typedIntoTaken = try sameNameCard("A7S_4B")
        let typedTaken = BatchSourceStagingModel()
        typedTaken.cardRegistry = { [CardFolderClaims.Record(
            id: "cam-d", label: "CAM_D", destinations: [camDLane])] }
        typedTaken.candidates = [typedIntoTaken]
        typedTaken.updateLabel(id: typedIntoTaken.id, newLabel: "CAM_D", appModel: model)
        require(!typedIntoTaken.labelIsAutomatic, "the name counts as typed")
        for pass in 1...2 {
            if pass == 2 { typedTaken.revalidateAll(appModel: model) }
            require(typedIntoTaken.status == .ready && typedIntoTaken.effectiveLabel == "CAM_D_2"
                        && typedIntoTaken.customLabel == "CAM_D",
                    "a typed name on another card's footage is numbered (pass \(pass)): "
                        + "\(typedIntoTaken.status) \(typedIntoTaken.effectiveLabel) field \(typedIntoTaken.customLabel)")
            require(typedIntoTaken.projectedLanes == [nameDest + "/CAM_D_2"], "its lane is the numbered one")
            require(typedIntoTaken.renameNote == BatchLabelAllocator.renameNote(
                        from: "CAM_D", to: "CAM_D_2", reason: .folderTaken(lanePath: camDLane)),
                    "the typed card carries the note too")
        }

        // The card that wrote that folder comes back: it continues into it,
        // and the new card with the same default name is numbered instead.
        let returning = try sameNameCard("A7S_1_AGAIN", known: true, previous: [noNameLane], id: "a7s-1")
        let continuing = BatchSourceStagingModel()
        continuing.cardRegistry = namingRecord
        let newcomer = try sameNameCard("A7S_5")
        continuing.candidates = [newcomer, returning]
        continuing.revalidateAll(appModel: model)
        require(returning.status == .ready && returning.effectiveLabel == "NO NAME",
                "a known card continues into its own folder: \(returning.status)")
        require(returning.projectedLanes == [nameDest + "/NO NAME"], "continuation writes its own lane")
        require(newcomer.status == .ready && newcomer.effectiveLabel == "NO NAME_2",
                "the newcomer is numbered even though it was dragged first")

        // A known card whose folder here holds another card's footage used
        // to be refused to keep its continuation key. Owner's rule,
        // 2026-11-09: it copies under the next free name, with a note.
        let stranger = try sameNameCard("A7S_6", known: true, previous: ["/Volumes/ELSEWHERE/NO NAME"],
                                        id: "a7s-6")
        let blocked = BatchSourceStagingModel()
        blocked.cardRegistry = namingRecord
        blocked.candidates = [stranger]
        blocked.revalidateAll(appModel: model)
        require(stranger.status == .ready && stranger.effectiveLabel == "NO NAME_2",
                "a known card blocked by another card's folder is numbered: \(stranger.status) \(stranger.effectiveLabel)")
        require(stranger.projectedLanes == [nameDest + "/NO NAME_2"], "it never writes into the other card's folder")
        require(stranger.renameNote == BatchLabelAllocator.renameNote(
                    from: "NO NAME", to: "NO NAME_2", reason: .folderTaken(lanePath: noNameLane)),
                "the known card says why it moved")

        // ---- Issue #25 (2026-11-11): one refused card does not hold back
        // the Ready ones. Start copies every Ready card and the refused one
        // stays staged with its reason.
        model.pauseDispatch()   // queued jobs stay queued: no engine runs here
        let savedBatchModel = model.batchStagingModel
        let partial = BatchSourceStagingModel()
        partial.cardRegistry = { [] }
        model.batchStagingModel = partial
        let partialCards = try ["PARTIAL_A", "PARTIAL_B", "PARTIAL_PULLED"].map { try sameNameCard($0) }
        for card in partialCards { card.seedAutomaticLabel((card.path as NSString).lastPathComponent) }
        partialCards[0].customLabel = "CAM_A"
        partialCards[1].customLabel = "CAM_B"
        partial.candidates = partialCards
        partial.revalidateAll(appModel: model)
        require(partialCards.allSatisfy { $0.status == .ready }, "three cards start Ready: \(partialCards.map(\.status))")
        // The third card is pulled after it was read.
        try fm.removeItem(atPath: partialCards[2].path)
        partial.revalidateAll(appModel: model)
        require(partialCards[2].status == .refused("source was removed, replaced, or became a symlink"),
                "the pulled card is refused: \(partialCards[2].status)")
        require(partial.canStartReadyCards && !partial.cardsReadyToQueue,
                "two Ready cards can start beside a refused one")
        if model.engineConfigurationError == nil {
            require(model.batchStartBlockedReason == nil,
                    "Start Offload is not blocked by the refused card: \(model.batchStartBlockedReason ?? "nil")")
        }
        switch partial.queueBatch(appModel: model) {
        case .success(let started):
            require(started.map(\.label) == ["CAM_A", "CAM_B"],
                    "the Ready cards are queued under their names: \(started.map(\.label))")
            require(started.allSatisfy { $0.phase == .queued }, "they wait in the queue while dispatch is paused")
        case .failure(let error):
            require(false, "a batch with Ready cards must start: \(error)")
        }
        require(partial.candidates.map(\.path) == [partialCards[2].path],
                "only the refused card stays staged: \(partial.candidates.map(\.displayName))")
        require(partial.refusedCards.count == 1 && partial.generalError != nil,
                "the card left behind keeps its reason: \(partial.generalError ?? "nil")")
        require(partial.heldBackLine == "PARTIAL_PULLED stayed in the batch: "
                    + "source was removed, replaced, or became a symlink",
                "one line says which card stayed and why: \(partial.heldBackLine ?? "nil")")
        // With nothing Ready, Start says so and queues nothing more.
        let queuedSoFar = model.jobs.count
        if model.engineConfigurationError == nil {
            require(model.batchStartBlockedReason == "The card in the batch can't start — Review Batch shows why",
                    "a batch of one refused card explains itself: \(model.batchStartBlockedReason ?? "nil")")
        }
        if case .success = partial.queueBatch(appModel: model) {
            require(false, "a batch with no Ready card must not report a start")
        }
        require(model.jobs.count == queuedSoFar, "nothing was queued for the refused card")
        partial.cancelStaging()

        // A card Ready only since the edge re-check was never shown Ready,
        // so it waits for the next Start; the cards shown Ready still go.
        let lateCards = try ["LATE_A", "LATE_B"].map { try sameNameCard($0) }
        lateCards[0].customLabel = "LATE_A"
        lateCards[1].customLabel = "   "
        partial.candidates = lateCards
        partial.revalidateAll(appModel: model)
        require(lateCards[0].status == .ready && lateCards[1].status == .refused("Card label cannot be empty."),
                "one Ready, one with an empty name: \(lateCards.map(\.status))")
        lateCards[1].customLabel = "LATE_B"   // typed, not yet re-checked
        if case .success(let started) = partial.queueBatch(appModel: model) {
            require(started.map(\.label) == ["LATE_A"], "only the card shown Ready starts: \(started.map(\.label))")
        } else {
            require(false, "the Ready card must start")
        }
        require(partial.candidates.map(\.path) == [lateCards[1].path] && lateCards[1].status == .ready,
                "the renamed card stays, now Ready, for the next Start: \(lateCards[1].status)")
        partial.cancelStaging()

        // A pulled card can free the plain name a numbered card was stepping
        // around. The renumbered card waits for the next Start, since its
        // new name was never shown, and the card whose name held still goes
        // (Sol review, 2026-11-11: one renumbered card used to stop them all).
        let renumber = try ["RENUMBER_A", "RENUMBER_B", "RENUMBER_C"].map { try sameNameCard($0) }
        renumber[2].customLabel = "CAM_C"
        partial.candidates = renumber
        partial.revalidateAll(appModel: model)
        require(renumber.map(\.effectiveLabel) == ["NO NAME", "NO NAME_2", "CAM_C"],
                "two same-name cards and a typed one: \(renumber.map(\.effectiveLabel))")
        try fm.removeItem(atPath: renumber[0].path)   // pulled; nothing re-checked yet
        if case .success(let started) = partial.queueBatch(appModel: model) {
            require(started.map(\.label) == ["CAM_C"],
                    "the card whose name held starts: \(started.map(\.label))")
        } else {
            require(false, "a renumbered card must not stop the others: \(partial.generalError ?? "nil")")
        }
        require(partial.candidates.map(\.path) == [renumber[0].path, renumber[1].path],
                "the pulled card and the renumbered card stay staged")
        require(renumber[1].status == .ready && renumber[1].effectiveLabel == "NO NAME",
                "the renumbered card shows its new name: \(renumber[1].status) \(renumber[1].effectiveLabel)")
        require(partial.heldBackLine == "1 card got a new name at the last check and stayed in the batch. "
                    + "Check the names and press Start again."
                    && partial.generalError == partial.heldBackLine,
                "the operator is told why it stayed: \(partial.heldBackLine ?? "nil")")
        if case .success(let started) = partial.queueBatch(appModel: model) {
            require(started.map(\.label) == ["NO NAME"], "the next Start sends it under the name shown: \(started.map(\.label))")
        } else {
            require(false, "the renumbered card starts on the next press")
        }
        partial.cancelStaging()

        // ---- Issue #24 (2026-11-11): the preflight holds out the one card
        // it refuses over and checks the others again without it.
        let overlapCard = "/Volumes/A001/DCIM"
        let cleanCards = ["/Volumes/B002", "/Volumes/C003"]
        var stagedSets: [[String]] = []
        let heldOne = await BatchSourceStagingModel.preflightHoldingOutRefusedCards(
            paths: [cleanCards[0], overlapCard, cleanCards[1]]) { remaining in
            stagedSets.append(remaining)
            if remaining.contains(overlapCard) {
                throw BatchSourceStagingError.activeSourceOverlap(source: overlapCard, activeSource: "/Volumes/A001")
            }
            return []
        }
        if case let .checked(_, heldOut) = heldOne {
            require(heldOut == [overlapCard: "overlaps A001, which is staged or copying"],
                    "only the overlapping card is held out, with its reason: \(heldOut)")
        } else {
            require(false, "a refusal about one card must not fail the batch")
        }
        require(stagedSets == [[cleanCards[0], overlapCard, cleanCards[1]], cleanCards],
                "the other cards are checked again without it: \(stagedSets)")
        let wholeBatch = await BatchSourceStagingModel.preflightHoldingOutRefusedCards(paths: cleanCards) { _ in
            throw BatchSourceStagingError.timeout(seconds: 5)
        }
        if case .failed(let message) = wholeBatch {
            require(message == BatchSourceStagingError.timeout(seconds: 5).description,
                    "a refusal about the whole batch still fails it")
        } else {
            require(false, "a timeout is not one card's fault")
        }
        let everyCard = await BatchSourceStagingModel.preflightHoldingOutRefusedCards(paths: cleanCards) { remaining in
            throw BatchSourceStagingError.sourceNotFound(path: remaining[0])
        }
        if case let .checked(staged, heldOut) = everyCard {
            require(staged.isEmpty && Set(heldOut.keys) == Set(cleanCards), "every card can be held out; the loop ends")
        } else {
            require(false, "held-out cards are not a batch failure")
        }
        require(BatchSourceStagingModel.cardRefusal(for: .protocolMismatch(expected: 3, actual: 2, path: "/x")) == nil,
                "an engine mismatch is not one card's fault")

        // A held-out card keeps its refusal through label edits; the cards
        // that passed are Ready beside it.
        let heldCards = try ["HELD_GOOD", "HELD_OUT"].map { try sameNameCard($0) }
        partial.candidates = heldCards
        partial.applyPreflight(
            [BatchStagedSourceItem(
                originalPath: heldCards[0].path, normalizedSourcePath: heldCards[0].path,
                label: "HELD_GOOD", identityPin: heldCards[0].identityPin!,
                metadata: CardInspectionMetadata(label: "HELD_GOOD", totalBytes: 1, fileCount: 1,
                                                 customProperties: [:], previousDestinations: [],
                                                 datasetID: nil),
                destinationLanes: [])],
            heldOut: [heldCards[1].path: "overlaps A001, which is staged or copying"],
            appModel: model)
        require(heldCards[0].status == .ready && heldCards[0].effectiveLabel == "HELD_GOOD",
                "the card that passed is Ready: \(heldCards[0].status)")
        require(heldCards[1].status == .refused("overlaps A001, which is staged or copying"),
                "the held-out card says why: \(heldCards[1].status)")
        partial.updateLabel(id: heldCards[1].id, newLabel: "RENAMED", appModel: model)
        require(heldCards[1].status == .refused("overlaps A001, which is staged or copying"),
                "a label edit does not make a held-out card Ready: \(heldCards[1].status)")
        require(partial.canStartReadyCards, "the batch can start without the held-out card")
        partial.cancelStaging()
        model.jobs = []
        model.resumeDispatch()
        model.batchStagingModel = savedBatchModel
        defaults.set(namingTemplate, forKey: Pref.folderTemplate)
        model.unassignDestination(nameDest)

        // ---- Issue #24: a card that is already copying cannot be added
        // through the folder pickers. No destination is staged here, so the
        // added card waits and no engine read starts.
        let pickerCopying = root.appendingPathComponent("PICKER_COPYING").path
        let pickerFresh = root.appendingPathComponent("PICKER_FRESH").path
        try fm.createDirectory(atPath: pickerCopying, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: pickerFresh, withIntermediateDirectories: true)
        let pickerJob = Job(label: "PICKER_COPYING", sourcePath: pickerCopying, destinations: ["/dest"])
        pickerJob.phase = .queued
        model.jobs = [pickerJob]
        let picker = BatchSourceStagingModel()
        picker.addCandidates(paths: [pickerCopying, pickerFresh], appModel: model)
        require(picker.candidates.map(\.path) == [pickerFresh],
                "the copying card is left out of the batch: \(picker.candidates.map(\.path))")
        require(picker.notice == "PICKER_COPYING is already copying, so it was not added.",
                "the window says which card was left out: \(picker.notice ?? "nil")")
        require(picker.candidates[0].status == .awaitingDestinations && picker.generalError == nil,
                "the other card waits for destinations, not refused: \(picker.candidates[0].status)")
        require(BatchSourceStagingModel.alreadyCopyingNotice(["A001", "B002", "C003"])
                    == "A001, B002 and C003 are already copying, so they were not added.",
                "several left-out cards read as one sentence")
        picker.cancelStaging()
        model.jobs = []

        // ---- R3-05: the eject control's visibility predicate.
        let usbFixed = Volume(path: "/Volumes/QA_USB", name: "QA_USB", isEjectable: false,
                              isExternal: true, totalBytes: nil, freeBytes: nil)
        let internalPartition = Volume(path: "/Volumes/QA_INT", name: "QA_INT", isEjectable: false,
                                       isExternal: false, totalBytes: nil, freeBytes: nil)
        let imageVolume = Volume(path: "/test-image", name: "Image", isEjectable: true,
                                 isExternal: false, totalBytes: nil, freeBytes: nil)
        let networkVolume = Volume(path: "/test-network", name: "Network", isEjectable: true,
                                   isExternal: true, isLocal: false, totalBytes: nil, freeBytes: nil)
        require(model.offersEject(imageVolume), "local disk images retain eject")
        require(!model.offersEject(networkVolume), "network mounts do not offer an unsupported diskutil action")
        require(model.offersEject(usbFixed), "a USB hard drive offers eject without Cocoa's ejectable flag")
        require(!model.offersEject(internalPartition), "an internal partition with no jobs offers no eject")
        let internalSourceJob = Job(label: "INT", sourcePath: "/Volumes/QA_INT", destinations: ["/dest"])
        model.jobs = [internalSourceJob]
        require(model.offersEject(internalPartition), "a whole-volume source stays ejectable whatever the flags say")
        model.jobs = []

        // The Connected shelf can still show a whole volume when its source
        // is a folder inside it. Its EjectControl must use the volume-wide
        // interlock, including older destination jobs and batch candidates.
        let shelfRoot = root.appendingPathComponent("SHELF_DRIVE").path
        let shelfSource = shelfRoot + "/SourceFolder"
        try fm.createDirectory(atPath: shelfSource, withIntermediateDirectories: true)
        let shelfVolume = Volume(path: shelfRoot, name: "Shelf drive", isEjectable: false,
                                 isExternal: true, totalBytes: nil, freeBytes: nil)
        let shelfModel = AppModel(journal: JobJournal(
            url: root.appendingPathComponent("shelf-eject-journal.json"), historyLimit: 10))
        shelfModel.volumes = [shelfVolume]
        shelfModel.sourcePath = shelfSource
        require(shelfEjectVolume(for: Endpoint(path: shelfRoot, kind: .volume),
                                 in: shelfModel.volumes) == shelfVolume,
                "whole-volume shelf tile finds its ejectable volume")
        require(shelfEjectVolume(for: Endpoint(path: shelfSource, kind: .folder),
                                 in: shelfModel.volumes) == nil,
                "folder shelf tile offers no containing-volume eject control")
        require(shelfModel.sourceCandidatesSnapshot.contains { $0.path == shelfRoot && $0.kind == .volume },
                "whole volume with a staged folder source remains on the Connected shelf")
        let oldDestinationJob = Job(label: "OLD", sourcePath: source,
                                    destinations: [shelfRoot + "/OlderCopy"])
        oldDestinationJob.phase = .done
        shelfModel.jobs = [oldDestinationJob]
        require(!shelfModel.canEject(shelfVolume),
                "a staged folder source stays force-eject-only despite destination history")
        shelfModel.sourcePath = nil
        shelfModel.jobs = []
        shelfModel.batchStagingModel.candidates = [BatchSourceCandidate(path: shelfSource)]
        require(!shelfModel.canEject(shelfVolume),
                "a staged batch source stays force-eject-only on the Connected shelf")
        shelfModel.batchStagingModel.candidates = []
        require(shelfModel.offersEject(shelfVolume) && shelfModel.canEject(shelfVolume),
                "an unassigned external shelf drive keeps one-click eject")
        // Eject-all only takes cards a settled job READ; a drive that merely
        // allows eject, or only received copies, is not "dumped".
        require(shelfModel.dumpedCardVolumes.isEmpty,
                "a drive with no settled source job is not a dumped card")
        shelfModel.jobs = [oldDestinationJob]
        require(shelfModel.dumpedCardVolumes.isEmpty,
                "destination-only history does not make a drive a dumped card")
        shelfModel.jobs = []
        let runningSource = Job(label: "RUN_SOURCE", sourcePath: shelfSource,
                                destinations: [dest])
        runningSource.phase = .copying
        shelfModel.jobs = [runningSource]
        require(!shelfModel.canEject(shelfVolume), "running nested source blocks shelf one-click eject")
        let runningDestination = Job(label: "RUN_DEST", sourcePath: source,
                                     destinations: [shelfRoot + "/ActiveCopy"])
        runningDestination.phase = .copying
        let unrelatedJob = Job(label: "OTHER", sourcePath: source, destinations: [dest])
        unrelatedJob.phase = .copying
        shelfModel.jobs = [unrelatedJob, runningDestination]
        require(!shelfModel.canEject(shelfVolume),
                "a later batch job using the drive blocks shelf one-click eject")

        // The warning sheet names WHY one-click eject was withheld. A card
        // verified to ONE drive fell through to "Eject an UNVERIFIED card?"
        // with Force Eject as the only way out (Joshua, 2026-09-28).
        if case .transferRunning(let job, false) = shelfModel.ejectHold(shelfVolume) {
            require(job === runningDestination, "the mid-job hold names the running destination job")
            require(!shelfModel.ejectIsHarmless(shelfVolume),
                    "ejecting a drive mid-job must still ask first")
        } else {
            require(false, "a destination receiving a job was not named as mid-transfer")
        }
        let oneDrive = Job(label: "ONE_DRIVE", sourcePath: shelfSource, destinations: [dest])
        oneDrive.phase = .done
        oneDrive.fullyVerified = true
        oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
        shelfModel.jobs = [oneDrive]
        require(oneDrive.verdict == .verifiedKeepCard, "one-drive fixture is VERIFIED (keep card)")
        require(!shelfModel.canEject(shelfVolume),
                "a keep-card verdict still withholds one-click source eject")
        // A routine reason stays plain good news; anything else, including
        // a reason this build has never heard of, keeps KEEP CARD in amber.
        // Custody damage demotes SAFE to this same verdict, so this is what
        // stands between a damaged copy and a green badge.
        require(!oneDrive.verifiedNeedsAttention && oneDrive.verdictLine == "VERIFIED",
                "one drive is a clean VERIFIED")
        for routine in ["picked files: this run copied chosen files, not a whole card",
                        "no consistent second source read this run",
                        "3 file(s) accepted on prior-generation trust on at least one destination without re-verification this run (--reverify-existing re-reads them)",
                        "SAFE TO WIPE needs verified copies on 2 separate drives; this run has 1. NAS doesn't count"] {
            oneDrive.wipeBlockers = [routine]
            require(!oneDrive.verifiedNeedsAttention, "routine reason read as a problem: \(routine)")
        }
        for serious in ["a later verification found damage in CARD: 1 failed",
                        "a previous custody check found damage; run Verify Existing Custody before wiping",
                        "source tree changed after the initial scan",
                        "2 source object(s) were not copied",
                        "full flush-to-media failed on at least one destination file",
                        "cache bypass failed on at least one destination write",
                        "no destination copy was fully read this run",
                        "a reason added by some later version"] {
            oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required", serious]
            require(oneDrive.verifiedNeedsAttention && oneDrive.verdictLine == "VERIFIED · KEEP CARD",
                    "a serious reason read as a clean VERIFIED: \(serious)")
            require(oneDrive.attentionBlockers == [serious], "the amber card must name \(serious)")
        }
        oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
        require(Job.plainWipeBlocker(oneDrive.wipeBlockers[0]).hasPrefix("Only one separate drive"),
                "the one-drive reason reads in plain words")
        require(Job.plainWipeBlocker("2 source object(s) were not copied").hasPrefix("2 items"),
                "a count survives into the plain wording")
        require(Job.plainWipeBlocker("1 source object(s) were not copied").hasPrefix("1 item on"),
                "one item reads as one item")
        require(Job.plainWipeBlocker("a reason added by some later version") == "a reason added by some later version",
                "an unknown reason shows as written, never swallowed")
        require(oneDrive.spokenResult == "ONE_DRIVE: verified",
                "VoiceOver reads the result in words, got \(oneDrive.spokenResult)")
        // The batch summary: one line once nothing is left running, and it
        // never reads as all-clear when a card didn't make it.
        func settled(_ label: String, verified: Bool, phase: JobPhase = .done,
                     blockers: [String] = []) -> Job {
            let job = Job(label: label, sourcePath: "/tmp/\(label)", destinations: [dest])
            job.phase = phase
            job.fullyVerified = verified
            job.wipeBlockers = blockers
            return job
        }
        let doneA = settled("DONE_A", verified: true)
        let doneB = settled("DONE_B", verified: true)
        doneB.phase = .copying
        shelfModel.jobs = [doneA, doneB]
        shelfModel.noteFinishedForAllDone(doneA)
        require(shelfModel.allDoneSummary == nil, "no summary while a card is still running")
        doneB.phase = .done
        shelfModel.noteFinishedForAllDone(doneB)
        require(shelfModel.allDoneSummary == AllDoneSummary(line: "All 2 cards verified.", tone: .good),
                "two clean cards summarize as verified, got \(String(describing: shelfModel.allDoneSummary))")
        // Damage found later turns the same strip amber instead of leaving
        // an all-clear standing.
        doneA.custodyFailures["/Volumes/DEST"] = LaterVerification(
            date: Date(), folder: "/Volumes/DEST", passed: 0, failed: 1, missing: 0,
            new: 0, unverifiable: 0, chainProblems: 0)
        require(shelfModel.allDoneSummary?.tone == .attention,
                "later damage must change the batch line, got \(String(describing: shelfModel.allDoneSummary))")
        // One at a time: a queued card keeps the batch open, so the last
        // card's finish still reports the whole run.
        let serialA = settled("SERIAL_A", verified: true)
        let serialB = settled("SERIAL_B", verified: true, phase: .queued)
        shelfModel.jobs = [serialA, serialB]
        shelfModel.noteFinishedForAllDone(serialA)
        require(shelfModel.allDoneSummary == nil, "a queued card keeps the batch open")
        serialB.phase = .done
        shelfModel.noteFinishedForAllDone(serialB)
        require(shelfModel.allDoneSummary == AllDoneSummary(line: "All 2 cards verified.", tone: .good),
                "a one-at-a-time batch still gets its summary")
        // Amber results reach the Dock and menu bar, and a clean retry of
        // the same card clears them.
        let amberRun = settled("AMBER_RUN", verified: true, blockers: ["source tree changed after the initial scan"])
        shelfModel.jobs = [amberRun]
        require(shelfModel.dockBadge(activeJobCount: 0) == "!"
                    && shelfModel.hudPresenceLine == "VERIFIED · KEEP CARD · AMBER_RUN",
                "an amber result must warn on the Dock and menu bar, got \(String(describing: shelfModel.hudPresenceLine))")
        let lone = settled("LONE", verified: true)
        shelfModel.jobs = [lone]
        shelfModel.noteFinishedForAllDone(lone)
        require(shelfModel.allDoneSummary == nil, "a single job gets no batch summary")
        let mixed = [settled("OK", verified: true),
                     settled("AMBER", verified: true, blockers: ["source tree changed after the initial scan"]),
                     settled("FAST", verified: false),
                     settled("BAD", verified: false, phase: .failed)]
        require(AllDoneSummary.from(mixed)
                    == AllDoneSummary(line: "All 4 cards done: 1 verified, 2 need a look, 1 failed.", tone: .failed),
                "got \(String(describing: AllDoneSummary.from(mixed)))")
        require(AllDoneSummary.from(Array(mixed.prefix(2)))?.tone == .attention,
                "an amber card keeps the summary amber")
        require(AppModel.showsNotificationsOffHint(off: true, notifyOnCompletion: true,
                                                   dismissed: false, hasLiveJobs: true),
                "denied notifications get the hint")
        for (on, dismissed, live) in [(false, false, true), (true, true, true), (true, false, false)] {
            require(!AppModel.showsNotificationsOffHint(off: true, notifyOnCompletion: on,
                                                        dismissed: dismissed, hasLiveJobs: live),
                    "the hint must stay quiet: \(on) \(dismissed) \(live)")
        }
        require(!AppModel.showsNotificationsOffHint(off: false, notifyOnCompletion: true,
                                                    dismissed: false, hasLiveJobs: true),
                "allowed notifications get no hint")
        shelfModel.jobs = [oneDrive]
        // Ejecting after a verified copy only ends a read: one click, no
        // sheet (tester feedback, 2026-11-03).
        // This fixture has no live source session, so its verdict is stale:
        // the "keep the card" sheet stays. The current-verdict case is the
        // live one-click path.
        require(!shelfModel.isCurrentSourceVerdict(oneDrive)
                    && !shelfModel.ejectIsHarmless(shelfVolume),
                "a verified verdict that no longer covers the card keeps its eject sheet")
        if case .verifiedNotSafe(let job, true) = shelfModel.ejectHold(shelfVolume) {
            require(job === oneDrive, "the single-drive hold names the verified job")
        } else {
            require(false, "a card verified to one drive was not named as a single-drive hold")
        }
        oneDrive.wipeBlockers = ["no consistent second source read this run"]
        if case .verifiedNotSafe(_, false) = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "a verified card held for another blocker was not named as verified")
        }
        // Unknown topology ("span only 0") and a device count beside another
        // blocker are not "backed up to one drive".
        oneDrive.wipeBlockers = ["copies span only 0 known physical device(s); 2+ required"]
        if case .verifiedNotSafe(_, false) = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "unknown device topology was named a one-drive backup")
        }
        oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required",
                                 "full flush-to-media failed on at least one destination file"]
        if case .verifiedNotSafe(_, false) = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "a one-drive card with another blocker hid that blocker")
        }
        // Custody damage revokes SAFE but leaves fullyVerified standing; it
        // must never read as a proven copy with Eject on Return.
        oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required",
                                 "a later verification found damage in CARD: 1 failed"]
        if case .custodyDamaged(let job) = shelfModel.ejectHold(shelfVolume) {
            require(job === oneDrive, "the custody hold names the damaged job")
        } else {
            require(false, "a copy found damaged later was named as verified")
        }
        oneDrive.fullyVerified = false
        if case .copiesUnverified(_, true) = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "an UNVERIFIED source run lost its unverified warning")
        }
        require(!shelfModel.ejectIsHarmless(shelfVolume),
                "an unverified card must still ask before ejecting")
        oneDrive.fullyVerified = true
        oneDrive.safeToWipe = true
        oneDrive.wipeBlockers = []
        require(oneDrive.verdict == .safeToWipe, "stale-SAFE fixture is SAFE TO WIPE")
        if case .verdictNotCurrent = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "a SAFE verdict without live proof was not named as no longer current")
        }
        require(!shelfModel.ejectIsHarmless(shelfVolume),
                "a stale SAFE verdict keeps its eject warning")
        // A SAFE whose post-verdict re-check of the copies is still running
        // is not "no longer covers this card" (Joshua, 2026-09-28).
        oneDrive.destinationCheckPending = true
        if case .destinationCheckPending(let job) = shelfModel.ejectHold(shelfVolume) {
            require(job === oneDrive, "the re-check hold names the SAFE job")
        } else {
            require(false, "a SAFE card still being re-checked was not named as pending")
        }
        require(!shelfModel.canEject(shelfVolume),
                "a pending re-check still withholds one-click source eject")
        oneDrive.destinationCheckPending = false
        shelfModel.jobs = []
        shelfModel.sourcePath = shelfSource
        if case .notOffloaded = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "a staged card that never ran was not named as not offloaded")
        }
        shelfModel.sourcePath = nil
        require(shelfModel.ejectHold(shelfVolume) == nil, "an ejectable drive carries no hold")

        // A retry queued behind waiting cards is inserted BELOW its own
        // older failure in display order. "Newest run" is creation order,
        // or the retry's SAFE could never become current (Joshua,
        // 2026-09-28).
        let olderFailure = Job(label: "ORDER", sourcePath: shelfSource, destinations: [dest])
        olderFailure.phase = .failed
        usleep(2_000)
        let newerRetry = Job(label: "ORDER", sourcePath: shelfSource, destinations: [dest])
        newerRetry.phase = .done
        shelfModel.jobs = [olderFailure, newerRetry]
        require(shelfModel.runsNewestFirst({ $0.sourcePath == shelfSource }).first === newerRetry,
                "a retry listed below its older failure must still count as the newest run")
        shelfModel.jobs = []

        // ---- R6-01: a receipt is discoverable with reports off (no HTML).
        let r6Dest = root.appendingPathComponent("R6_DEST").path
        let r6ReportDir = r6Dest + "/Reports/R6_NO_REPORT"
        try fm.createDirectory(atPath: r6ReportDir, withIntermediateDirectories: true)
        let r6Receipt = r6ReportDir + "/R6_NO_REPORT_offload_20260916_000000_000000_abcd1234.receipt.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: r6Receipt))
        let r6Job = Job(label: "R6_NO_REPORT", sourcePath: source, destinations: [r6Dest])
        r6Job.laneRoots = [r6Dest + "/R6_NO_REPORT"]
        require(JobEvidenceParser.findReceiptURL(for: r6Job) == nil, "no pointer, no receipt")
        r6Job.receiptPath = r6Receipt
        require(JobEvidenceParser.findReceiptURL(for: r6Job)?.path == r6Receipt,
                "an engine-emitted receipt path is found without an HTML sibling")
        r6Job.receiptPath = root.appendingPathComponent("elsewhere.receipt.json").path
        require(JobEvidenceParser.findReceiptURL(for: r6Job) == nil,
                "a receipt pointer outside the job's report directories is refused")
        require(JobEvidenceParser.validatedReceiptPaths([r6Receipt], label: "R6_NO_REPORT",
                                                        destinations: [r6Dest], laneRoots: r6Job.laneRoots) == [r6Receipt],
                "receipt_paths from report_written validate")
        require(JobEvidenceParser.validatedReceiptPaths([r6ReportDir + "/x.html"], label: "R6_NO_REPORT",
                                                        destinations: [r6Dest], laneRoots: r6Job.laneRoots) == nil,
                "a non-receipt path is refused as a receipt")
        // ---- R7-01: a reports-off record survives the journal round trip.
        r6Job.receiptPath = r6Receipt
        r6Job.phase = .done
        r6Job.fullyVerified = true
        require(JobEvidenceParser.persistedArtifactPathsAreValid(
                    label: "R6_NO_REPORT", destinations: [r6Dest], laneRoots: r6Job.laneRoots,
                    reportPath: nil, reportPaths: [], manifestPaths: [], receiptPath: r6Receipt),
                "a standalone receipt inside the job's report directory is a valid persisted artifact")
        require(!JobEvidenceParser.persistedArtifactPathsAreValid(
                    label: "R6_NO_REPORT", destinations: [r6Dest], laneRoots: r6Job.laneRoots,
                    reportPath: nil, reportPaths: [], manifestPaths: [],
                    receiptPath: root.appendingPathComponent("elsewhere.receipt.json").path),
                "a receipt outside the report directories is still refused")
        let r7JournalURL = root.appendingPathComponent("r7-jobs.json")
        let r7Journal = JobJournal(url: r7JournalURL, historyLimit: 10)
        let r7Record = JobJournalRecord(job: r6Job, plan: nil)
        switch r7Journal.save(records: [r7Record]) {
        case .success: break
        case .failure(let error): fatalError("saving a reports-off record must succeed: \(error)")
        }
        guard case .loaded(let r7Doc) = JobJournal(url: r7JournalURL, historyLimit: 10).load() else {
            fatalError("a journal holding a reports-off record must load")
        }
        require(r7Doc.records.first?.receiptPath == r6Receipt && r7Doc.records.first?.reportPaths == nil,
                "the reloaded record keeps its receipt pointer and no report paths")
        let r7Restored = Job(label: "R6_NO_REPORT", sourcePath: source, destinations: [r6Dest])
        r7Restored.laneRoots = r6Job.laneRoots
        r7Restored.receiptPath = r7Doc.records.first?.receiptPath
        require(JobEvidenceParser.findReceiptURL(for: r7Restored)?.path == r6Receipt,
                "evidence is found again after the round trip")
        // ---- R7-02: a blocked recovery keeps the live phase in the journal.
        let r7Live = Job(label: "R7_LIVE", sourcePath: source, destinations: [r6Dest])
        r7Live.phase = .failed
        r7Live.markRestoredInterrupted()
        r7Live.unresolvedRecoveryPhase = JobPhase.reports.rawValue
        let r7LiveRecord = JobJournalRecord(job: r7Live, plan: nil)
        require(r7LiveRecord.phase == JobPhase.reports.rawValue && r7LiveRecord.interrupted == nil,
                "an unresolved recovery persists its live phase, not a terminal failure")
        r7Live.unresolvedRecoveryPhase = nil
        let r7SettledRecord = JobJournalRecord(job: r7Live, plan: nil)
        require(r7SettledRecord.phase == JobPhase.failed.rawValue && r7SettledRecord.interrupted == true,
                "a resolved interrupted record persists as failed")

        // ---- R3-01: current wipe authority dies with its destinations.
        //      The job card keeps its SAFE receipt; the rail echo, one-click
        //      eject, Dock checkmark and notification action all read
        //      isCurrentSourceVerdict, which must fail closed once a lane
        //      unmounts (removed here) or a copied file under it changes.
        require(model.assign(r3Source, as: .source), "stage the round-3 source")
        model.inspectionError = nil
        func safeJob() -> Job {
            let job = Job(label: "R3_SAFE", sourcePath: r3Source, destinations: [r3DestA, r3DestB],
                          sourceAssignmentID: model.sourceAssignmentID)
            job.phase = .done
            job.fullyVerified = true
            job.safeToWipe = true
            job.physicalDevices = 2
            job.filesTotal = 1
            job.verifiedFileHashes = ["clip.mov": 0x05932ea46db59068]
            job.laneRoots = [r3DestA + "/R3_SAFE", r3DestB + "/R3_SAFE"]
            return job
        }
        let swappedCase = safeJob()
        swappedCase.launchPlanSnapshot = JournalLaunchPlan(
            src: r3Source, rawRoots: [r3DestA, r3DestB], destinations: [r3DestA, r3DestB],
            args: ["-m", "dumptruck.cli", "offload", r3Source, r3DestA, r3DestB, "--label", "R3_SAFE", "--json"],
            enginePython: "/fixture/.venv/bin/python", engineRoot: "/fixture", sourceVolumeUUID: nil,
            rootVolumeUUIDs: [nil, nil], sourceFileID: "1:2",
            rootFileIDs: ["3:4", "5:6"],
            mirroredFolder: "", organizationFolder: "", cardLabel: "R3_SAFE")
        model.jobs = [swappedCase]
        require(!model.armDestinationAuthority(for: swappedCase)
                && swappedCase.destinationAuthorityWithdrawn?.contains("changed identity") == true,
                "a replaced destination must not become current even if its files match")
        let unmountCase = safeJob()
        model.jobs = [unmountCase]
        require(!model.isCurrentSourceVerdict(unmountCase), "a SAFE receipt alone grants no live destination authority")
        require(model.armDestinationAuthority(for: unmountCase), "destination watchers arm on both lanes")
        for _ in 0..<100 where !model.destinationWatchersReady(for: unmountCase) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        require(model.isCurrentSourceVerdict(unmountCase), "checked destinations make the verdict current, ready=\(model.destinationWatchersReady(for: unmountCase)), withdrawn=\(unmountCase.destinationAuthorityWithdrawn ?? "nil"), assignment=\(String(describing: unmountCase.sourceAssignmentID))/\(String(describing: model.sourceAssignmentID)), journal=\(model.journalError ?? "nil")")
        require(model.latestCurrentSafeVerdict == .safeToWipe, "the Dock checkmark source sees the current SAFE verdict")
        try fm.removeItem(atPath: r3DestB)   // the cable-pull stand-in
        model.refreshVolumes()
        require(!model.isCurrentSourceVerdict(unmountCase),
                "a destination that is gone withdraws current wipe authority")
        // The fixture deletes a folder on the boot disk: nothing was
        // ejected, so it is the red "missing" case, not the amber one.
        require(unmountCase.destinationAuthorityWithdrawn?.contains("missing after verification") == true,
                "the withdrawal names the missing destination: \(unmountCase.destinationAuthorityWithdrawn ?? "nil")")
        require(!unmountCase.destinationAuthorityWithdrawnByEjection
                    && unmountCase.ejectedDestinationName == nil,
                "a deleted lane folder is a change, not an ejected drive")
        require(unmountCase.verdict == .safeToWipe, "the historical verdict stays what the run proved")
        require(model.latestCurrentSafeVerdict == nil, "the Dock checkmark source reads no current SAFE verdict")
        require(unmountCase.messages.contains { $0.text.contains("current wipe authority withdrawn") },
                "the job records why authority went")
        try fm.createDirectory(atPath: r3DestB + "/R3_SAFE", withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: URL(fileURLWithPath: r3DestB + "/R3_SAFE/clip.mov"))
        model.refreshVolumes()
        require(!model.isCurrentSourceVerdict(unmountCase), "a remount does not restore withdrawn authority")
        require(!model.armDestinationAuthority(for: unmountCase), "a withdrawn job cannot be re-armed")

        func armAndWait(_ job: Job, _ what: String) async throws {
            model.jobs = [job]
            require(model.armDestinationAuthority(for: job), "destination watchers arm for \(what)")
            for _ in 0..<50 where !model.destinationWatchersReady(for: job) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            require(model.destinationWatchersReady(for: job),
                    "watchers take their baseline for \(what), withdrawn=\(job.destinationAuthorityWithdrawn ?? "nil"), sourceChanged=\(model.sourceChangedSinceVerification)")
            require(model.isCurrentSourceVerdict(job), "\(what) starts current")
        }
        func waitForWithdrawal(_ job: Job) async throws -> Bool {
            for _ in 0..<50 {   // FSEvents latency is 0.2 s; allow 10 s
                try await Task.sleep(nanoseconds: 200_000_000)
                if job.destinationAuthorityWithdrawn != nil { return true }
            }
            return false
        }
        let mutationCase = safeJob()
        try await armAndWait(mutationCase, "the mutation case")
        // Finder litter under a lane is not damage.
        try Data("finder".utf8).write(to: URL(fileURLWithPath: r3DestA + "/R3_SAFE/.DS_Store"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        require(model.isCurrentSourceVerdict(mutationCase),
                "a .DS_Store written into a lane does not withdraw authority")
        // Opening a clip stamps a last-used xattr (ctime moves, bytes do not).
        let clipA = r3DestA + "/R3_SAFE/clip.mov"
        let stamp = Data("2026".utf8)
        let xattrResult = stamp.withUnsafeBytes { raw in
            setxattr(clipA, "com.apple.lastuseddate#PS", raw.baseAddress, raw.count, 0, 0)
        }
        require(xattrResult == 0, "fixture: xattr written")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        require(model.isCurrentSourceVerdict(mutationCase),
                "a metadata-only xattr on a copied clip does not withdraw authority")
        // A copied file rewritten in place does.
        var oldStat = stat()
        require(lstat(clipA, &oldStat) == 0, "fixture stat")
        try Data("clop".utf8).write(to: URL(fileURLWithPath: clipA))
        var oldTimes = [oldStat.st_atimespec, oldStat.st_mtimespec]
        require(utimensat(AT_FDCWD, clipA, &oldTimes, 0) == 0, "fixture restores exact mtime")
        let rewriteWithdrawn = try await waitForWithdrawal(mutationCase)
        require(rewriteWithdrawn, "a rewritten copied file withdraws current wipe authority")
        require(mutationCase.destinationAuthorityWithdrawn?.contains("changed after verification") == true,
                "the withdrawal names the change: \(mutationCase.destinationAuthorityWithdrawn ?? "nil")")
        require(mutationCase.verdict == .safeToWipe, "the receipt is history, not permission")
        // A change between the verdict and baseline cannot become the new truth.
        let preBaselineCase = safeJob()
        model.jobs = [preBaselineCase]
        require(model.armDestinationAuthority(for: preBaselineCase), "arm over the corrupt copied file")
        let baselineWithdrawn = try await waitForWithdrawal(preBaselineCase)
        require(baselineWithdrawn, "the baseline must reject bytes that differ from engine evidence")
        try Data("clip".utf8).write(to: URL(fileURLWithPath: clipA))
        // A file that appears inside a lane is a change too.
        let additionCase = safeJob()
        try await armAndWait(additionCase, "the addition case")
        try Data("extra".utf8).write(to: URL(fileURLWithPath: r3DestB + "/R3_SAFE/extra.mov"))
        let additionWithdrawn = try await waitForWithdrawal(additionCase)
        require(additionWithdrawn, "a file appearing inside a lane withdraws current wipe authority")
        // A superseding run for the same card releases the older watchers.
        try fm.removeItem(atPath: r3DestB + "/R3_SAFE/extra.mov")
        let supersededCase = safeJob()
        try await armAndWait(supersededCase, "the superseded case")
        // Moving on from a finished SAFE card keeps its verdict: the watch
        // moves to a post-terminal session instead of being dropped, so an
        // untouched card never reads "verify again" (Joshua, 2026-09-28).
        model.clearSource()
        require(model.sourcePath == nil, "the rail is clear")
        require(model.destinationWatchersReady(for: supersededCase),
                "a handed-off SAFE card keeps its destination watchers")
        require(model.isCurrentSourceVerdict(supersededCase),
                "a SAFE card the operator moved on from stays current")
        require(model.ejectHold(Volume(path: r3Source, name: "R3", isEjectable: true,
                                       isExternal: true, totalBytes: nil, freeBytes: nil)) == nil,
                "and keeps its one-click eject")
        // The handed-off watch is still a watch: a write to the card ends it.
        let touched = r3Source + "/handoff-touch.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: touched))
        var handoffRetired = false
        for _ in 0..<50 {   // FSEvents latency is 0.2 s; allow 10 s
            try await Task.sleep(nanoseconds: 200_000_000)
            if !model.isCurrentSourceVerdict(supersededCase) { handoffRetired = true; break }
        }
        require(handoffRetired, "a write to a handed-off card retires its verdict")
        require(!model.destinationWatchersReady(for: supersededCase),
                "retiring the handed-off verdict releases its destination watchers")
        try fm.removeItem(atPath: touched)
        // Let the cleanup event settle before staging this fixture again.
        // Otherwise its delayed delivery invalidates the next assignment.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Ejected vs changed decides wording only. A lane under /Volumes whose
        // drive is no longer mounted was ejected; a lane folder missing from a
        // drive that is still mounted, or anywhere off /Volumes, changed.
        require(AppModel.destinationDriveIsGone("/Volumes/BACKUP_B/A001",
                                                mountedVolumePaths: ["/", "/Volumes/CARD"]),
                "a lane on an unmounted drive reads as ejected")
        require(!AppModel.destinationDriveIsGone("/Volumes/BACKUP_B/A001",
                                                 mountedVolumePaths: ["/", "/Volumes/BACKUP_B"]),
                "a lane missing from a mounted drive is not an ejection")
        require(AppModel.destinationDriveIsGone("/Volumes/BACKUP_B_2/A001",
                                                mountedVolumePaths: ["/Volumes/BACKUP_B"]),
                "a mounted drive whose name only shares a prefix does not count")
        require(!AppModel.destinationDriveIsGone(r3DestA + "/R3_SAFE", mountedVolumePaths: []),
                "a folder off /Volumes is never an ejected drive")
        let ejectedJob = safeJob()
        ejectedJob.withdrawDestinationAuthority("destination BACKUP_B/R3_SAFE is no longer mounted",
                                                root: "/Volumes/BACKUP_B/R3_SAFE", ejected: true)
        require(ejectedJob.ejectedDestinationName == "BACKUP_B",
                "the ejected-drive wording names the drive")
        require(ejectedJob.verdict == .safeToWipe && ejectedJob.destinationAuthorityWithdrawn != nil,
                "an ejection withdraws authority exactly like a change")

        // A staged card that unmounts takes its destination watchers with
        // it. A leftover watcher withdrew authority later, when the backup
        // drives were ejected at wrap, and painted the earlier SAFE card red
        // (Joshua, 2026-09-28).
        require(model.assign(r3Source, as: .source), "re-stage the round-3 source")
        model.inspectionError = nil
        let unmountedCardCase = safeJob()
        try await armAndWait(unmountedCardCase, "the unmounted-card case")
        let r3SourceAside = r3Root + "/R3_CARD_ASIDE"
        try fm.moveItem(atPath: r3Source, toPath: r3SourceAside)   // the card unmounts
        model.refreshVolumes()
        require(model.sourcePath == nil, "an unmounted card leaves the source rail")
        require(!model.destinationWatchersReady(for: unmountedCardCase),
                "an unmounted card releases its destination watchers")
        let r3DestAAside = r3Root + "/R3_DEST_A_ASIDE"
        try fm.moveItem(atPath: r3DestA, toPath: r3DestAAside)     // then a backup drive goes
        model.refreshVolumes()
        try await Task.sleep(nanoseconds: 1_000_000_000)          // any late FSEvents callback
        require(unmountedCardCase.destinationAuthorityWithdrawn == nil,
                "a released watcher cannot withdraw a gone card's verdict: \(unmountedCardCase.destinationAuthorityWithdrawn ?? "nil")")
        try fm.moveItem(atPath: r3DestAAside, toPath: r3DestA)
        try fm.moveItem(atPath: r3SourceAside, toPath: r3Source)
        model.terminateAllEngines()
    }
}
