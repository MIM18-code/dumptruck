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

    @MainActor
    static func run() async throws {
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
        for good in ["CARD_A", "A001", "Tom Davis Shows B", "Loose 2026-09-15 14.02.31", "reel-01.v2"] {
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
        // The existing-lane refusal looks at the same rendered path. The
        // label was typed, so it is refused (with the fix), never renamed.
        try fm.createDirectory(atPath: batchDest + "/QA_PROJECT/Raws/R2_BATCH_ONE", withIntermediateDirectories: true)
        staging.revalidateAll(appModel: model)
        require(candidate.status == .refused(BatchLabelAllocator.existingFolderRefusal(
                    label: "R2_BATCH_ONE", lanePath: batchDest + "/QA_PROJECT/Raws/R2_BATCH_ONE")),
                "an existing rendered lane is refused: \(candidate.status)")
        require(candidate.inspection != nil, "a refused card keeps its inspection")
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
        // refused; a typed duplicate refuses only the cards involved and
        // clears on the next edit; a folder from a different card is
        // stepped around; a known card still continues into its own folder.
        let nameDest = root.appendingPathComponent("NAME_DEST").path
        try fm.createDirectory(atPath: nameDest, withIntermediateDirectories: true)
        require(model.assignDroppedDestinations([nameDest]), "stage the naming destination")
        let namingTemplate = defaults.object(forKey: Pref.folderTemplate)
        defaults.set("", forKey: Pref.folderTemplate)   // lanes are <root>/<label>
        func sameNameCard(_ dir: String, known: Bool = false,
                          previous: [String] = []) throws -> BatchSourceCandidate {
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
                                             mounts: known ? 1 : 0, files: 1, bytes: 1,
                                             previousDestinations: previous)
            card.seedAutomaticLabel("NO NAME")   // what the preflight writes
            return card
        }
        let sameNames = BatchSourceStagingModel()
        let a7s = try (1...3).map { try sameNameCard("A7S_\($0)") }
        sameNames.candidates = a7s
        sameNames.revalidateAll(appModel: model)
        require(a7s.allSatisfy { $0.status == .ready }, "same-name cards are all Ready: \(a7s.map(\.status))")
        require(a7s.map(\.effectiveLabel) == ["NO NAME", "NO NAME_2", "NO NAME_3"],
                "same-name cards are numbered in drag order: \(a7s.map(\.effectiveLabel))")
        require(a7s[0].renameNote == nil && a7s[1].renameNote != nil && a7s[2].renameNote != nil,
                "only the renamed cards carry a note")
        require(sameNames.generalError == nil && sameNames.canQueueBatch, "nothing blocks the batch")

        // The operator types one name on two cards: those two are refused,
        // inspections kept; the third is untouched.
        sameNames.updateLabel(id: a7s[1].id, newLabel: "CAM_B", appModel: model)
        sameNames.updateLabel(id: a7s[2].id, newLabel: "CAM_B", appModel: model)
        require(a7s[1].status == .refused(BatchLabelAllocator.sameNameRefusal(label: "CAM_B", other: "A7S_3"))
                    && a7s[2].status == .refused(BatchLabelAllocator.sameNameRefusal(label: "CAM_B", other: "A7S_2")),
                "a typed duplicate refuses both cards that carry it: \(a7s.map(\.status))")
        require(a7s[0].status == .ready, "the other card stays Ready")
        require(a7s[1].inspection != nil && a7s[2].inspection != nil, "refused cards keep their inspection")
        sameNames.updateLabel(id: a7s[2].id, newLabel: "CAM_C", appModel: model)
        require(a7s.allSatisfy { $0.status == .ready }, "one edit clears the duplicate: \(a7s.map(\.status))")
        require(a7s[0].effectiveLabel == "NO NAME", "the untouched card keeps its name")

        // Yesterday's "NO NAME" folder, from a different card: the new
        // card is numbered around it, never written into it.
        try fm.createDirectory(atPath: nameDest + "/NO NAME", withIntermediateDirectories: true)
        let fresh = try sameNameCard("A7S_4")
        let taken = BatchSourceStagingModel()
        taken.candidates = [fresh]
        taken.revalidateAll(appModel: model)
        require(fresh.status == .ready && fresh.effectiveLabel == "NO NAME_2",
                "a different card steps around an existing folder: \(fresh.status) \(fresh.effectiveLabel)")
        require(fresh.projectedLanes == [nameDest + "/NO NAME_2"], "its lane is the numbered one")
        require(fresh.renameNote == BatchLabelAllocator.renameNote(
                    from: "NO NAME", reason: .folderTaken(lanePath: nameDest + "/NO NAME")),
                "the note says a different card owns the folder")

        // The card that wrote that folder comes back: it continues into it,
        // and the new card with the same default name is numbered instead.
        let returning = try sameNameCard("A7S_1_AGAIN", known: true, previous: [nameDest + "/NO NAME"])
        let continuing = BatchSourceStagingModel()
        let newcomer = try sameNameCard("A7S_5")
        continuing.candidates = [newcomer, returning]
        continuing.revalidateAll(appModel: model)
        require(returning.status == .ready && returning.effectiveLabel == "NO NAME",
                "a known card continues into its own folder: \(returning.status)")
        require(returning.projectedLanes == [nameDest + "/NO NAME"], "continuation writes its own lane")
        require(newcomer.status == .ready && newcomer.effectiveLabel == "NO NAME_2",
                "the newcomer is numbered even though it was dragged first")

        // A known card whose folder here belongs to someone else is not
        // renamed behind the operator's back; only it is refused.
        let stranger = try sameNameCard("A7S_6", known: true, previous: ["/Volumes/ELSEWHERE/NO NAME"])
        let blocked = BatchSourceStagingModel()
        blocked.candidates = [stranger]
        blocked.revalidateAll(appModel: model)
        require(stranger.status == .refused(BatchLabelAllocator.existingFolderRefusal(
                    label: "NO NAME", lanePath: nameDest + "/NO NAME")),
                "a known card blocked by another card's folder is refused alone: \(stranger.status)")
        defaults.set(namingTemplate, forKey: Pref.folderTemplate)
        model.unassignDestination(nameDest)

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
        } else {
            require(false, "a destination receiving a job was not named as mid-transfer")
        }
        let oneDrive = Job(label: "ONE_DRIVE", sourcePath: shelfSource, destinations: [dest])
        oneDrive.phase = .done
        oneDrive.fullyVerified = true
        oneDrive.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
        shelfModel.jobs = [oneDrive]
        require(oneDrive.verdict == .verifiedKeepCard, "one-drive fixture is VERIFIED · KEEP CARD")
        require(!shelfModel.canEject(shelfVolume),
                "a keep-card verdict still withholds one-click source eject")
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
        oneDrive.fullyVerified = true
        oneDrive.safeToWipe = true
        oneDrive.wipeBlockers = []
        require(oneDrive.verdict == .safeToWipe, "stale-SAFE fixture is SAFE TO WIPE")
        if case .verdictNotCurrent = shelfModel.ejectHold(shelfVolume) {} else {
            require(false, "a SAFE verdict without live proof was not named as no longer current")
        }
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
