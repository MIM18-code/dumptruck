import Foundation

/// The agent control interface: every command reaches the AppModel method a
/// button calls, refusals come back as text, destructive commands need their
/// flag, and the socket plus `dumptruck/ctl.py` carry it end to end.
enum ControlInterfaceCheck {

    @inline(__always)
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("ControlInterfaceCheck: " + message) }
    }

    @MainActor
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dumptruck-control-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let card = root.appendingPathComponent("CARD").path
        let dest = root.appendingPathComponent("DEST").path
        let destInner = dest + "/inner"
        try fm.createDirectory(atPath: card + "/DCIM", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: destInner, withIntermediateDirectories: true)
        let cardStd = URL(fileURLWithPath: card).standardizedFileURL.path
        let destStd = URL(fileURLWithPath: dest).standardizedFileURL.path

        let journal = JobJournal(url: root.appendingPathComponent("jobs.json"), historyLimit: 20)
        let model = AppModel(journal: journal)
        let control = AppControl(model: model)
        func send(_ request: [String: Any]) async -> [String: Any] { await control.perform(request) }

        // Unknown and malformed requests are refused in words.
        var reply = await send(["command": "explode"])
        require(reply["ok"] as? Bool == false, "unknown command was accepted")
        require((reply["error"] as? String)?.contains("Unknown command") == true, "unknown command had no reason")
        let garbage = await control.handle(Data("not json".utf8))
        require(String(decoding: garbage, as: UTF8.self).contains("not a JSON object"),
                "a non-JSON request was not refused in words")

        // Start with nothing staged: the window's own reason, not retryable.
        reply = await send(["command": "start"])
        require(reply["ok"] as? Bool == false, "start with an empty bench was accepted")
        require(reply["error"] as? String == model.startBlockedReason,
                "start refusal was not the bench reason: \(reply)")
        require(reply["retryable"] as? Bool == false, "an empty bench was marked retryable")
        require(model.jobs.isEmpty, "a refused start made a job")

        // Staging goes through assign(_:as:) and its gates.
        reply = await send(["command": "stage-source", "path": root.appendingPathComponent("NOPE").path])
        require(reply["ok"] as? Bool == false, "a missing source was staged")
        require(reply["error"] as? String == "Only an existing folder or mounted volume can be assigned",
                "missing source refusal was not assignmentBlockedReason: \(reply)")
        reply = await send(["command": "stage-source", "path": "NoSuchVolumeName"])
        require((reply["error"] as? String)?.contains("No mounted volume is named") == true,
                "an unknown volume name was not refused by name")
        reply = await send(["command": "set-label", "label": "A001"])
        require(reply["ok"] as? Bool == false, "set-label with no card staged was accepted")

        reply = await send(["command": "stage-source", "path": card, "label": "A001"])
        require(reply["ok"] as? Bool == true, "stage-source failed: \(reply)")
        require(model.sourcePath == cardStd, "stage-source did not set the staged source")
        require(model.label == "A001" && model.labelEditedByUser,
                "the card name did not go through operatorEditedLabel")
        reply = await send(["command": "start", "expectSession": UUID().uuidString])
        require((reply["error"] as? String)?.contains("staged card changed") == true && model.jobs.isEmpty,
                "a start for another staged card was not refused: \(reply)")
        reply = await send(["command": "set-label", "label": "A 002"])
        require(model.label == CardLabelRules.cleaned("A 002"), "set-label did not clean like the field")

        // Destinations: the source-overlap gate, a silent overlap made loud.
        reply = await send(["command": "stage-destination", "path": card + "/DCIM"])
        require(reply["ok"] as? Bool == false, "a destination inside the source was accepted")
        require(reply["error"] as? String == AppModel.sourceOverlapReason, "overlap refusal changed: \(reply)")
        reply = await send(["command": "stage-destination", "path": dest])
        require(reply["ok"] as? Bool == true, "stage-destination failed: \(reply)")
        require(model.destinationPaths == [destStd], "destination did not land")
        reply = await send(["command": "stage-destination", "path": destInner])
        require(reply["ok"] as? Bool == false, "an overlapping destination reported success")
        require((reply["error"] as? String)?.contains("overlaps a destination") == true,
                "overlapping destination had no reason: \(reply)")
        require(model.destinationPaths == [destStd], "an overlapping destination changed the list")
        reply = await send(["command": "remove-destination", "path": destInner])
        require(reply["ok"] as? Bool == false, "removing a destination that is not staged succeeded")
        reply = await send(["command": "status"])
        let bench = (reply["state"] as? [String: Any])?["bench"] as? [String: Any]
        require(bench?["source"] as? String == cardStd, "status bench lost the source")
        require(bench?["destinations"] as? [String] == [destStd], "status bench lost the destination")
        // Where the card lands: the plan Start would build, card folder last.
        let folders = bench?["cardFolders"] as? [String]
        // Resolved only once the card read settles; a preview says so.
        require(bench?["cardFoldersResolved"] as? Bool == !(bench?["inspecting"] as? Bool ?? true)
                    && (bench?["inspecting"] as? Bool != true
                        || (bench?["cardFoldersNote"] as? String)?.contains("Preview") == true),
                "the landing path did not say whether it is resolved: \(String(describing: bench))")
        require(folders?.count == 1 && folders?[0].hasPrefix(destStd + "/") == true
                    && folders?[0].hasSuffix("/" + model.label) == true,
                "status did not show where the card lands: \(String(describing: bench))")
        require(AppControl.repeatedFolder("/Volumes/X9/Raws/11232026/Raws/Raws/MixPre") == "Raws"
                    && AppControl.repeatedFolder("/Volumes/X9/Raws/11232026/Raws/MixPre") == nil,
                "a doubled folder was not found, or a single one was")

        // `start --verify` reaches the plan for that press only.
        let savedVerify = UserDefaults.standard.string(forKey: Pref.verifyMode)
        UserDefaults.standard.set("fast", forKey: Pref.verifyMode)
        func planArgs() -> [String] {
            guard case .success(let plan) = model.buildPlan(
                src: cardStd, rawRoots: model.destinationPaths, cardLabel: model.label) else { return [] }
            return plan.args
        }
        let fullArgs = model.withVerifyOverride("full", planArgs)
        require(fullArgs.contains("--json") && !fullArgs.contains("--fast"),
                "a full override still planned a size-only copy")
        UserDefaults.standard.set("full", forKey: Pref.verifyMode)
        require(model.withVerifyOverride("fast", planArgs).contains("--fast"),
                "a fast override did not plan a size-only copy")
        require(!planArgs().contains("--fast") && model.startVerifyOverride == nil,
                "the override outlived its press")
        require(UserDefaults.standard.string(forKey: Pref.verifyMode) == "full",
                "the override changed the saved Verification setting")
        if let savedVerify { UserDefaults.standard.set(savedVerify, forKey: Pref.verifyMode) }
        else { UserDefaults.standard.removeObject(forKey: Pref.verifyMode) }
        reply = await send(["command": "start", "verify": "quick"])
        require((reply["error"] as? String)?.contains("\"fast\" or \"full\"") == true && model.jobs.isEmpty,
                "an unknown verify mode was not refused: \(reply)")

        // A mirrored folder typed relative to a drive: by the drive's name,
        // or inside the one staged drive. The shell's directory plays no part.
        let savedVolumes = model.volumes
        model.volumes = savedVolumes + [Volume(path: destStd, name: "DESTDRIVE", isEjectable: true,
                                               isExternal: true, isLocal: true,
                                               totalBytes: nil, freeBytes: nil)]
        reply = await send(["command": "set-mirror-folder", "path": "DESTDRIVE/inner"])
        require(reply["ok"] as? Bool == true && model.destinationFolderRelativePath == "inner",
                "a drive-name mirror path failed: \(reply)")
        require((reply["message"] as? String)?.contains("land in \(destStd)/inner/") == true
                    && ((reply["message"] as? String)?.contains("Preview") == true)
                        == ((reply["bench"] as? [String: Any])?["cardFoldersResolved"] as? Bool != true),
                "the mirror reply did not say where cards land: \(reply)")
        model.clearMirroredDestinationFolder()
        reply = await send(["command": "set-mirror-folder", "path": "inner"])
        require(reply["ok"] as? Bool == true && model.destinationFolderRelativePath == "inner",
                "a mirror path inside the staged drive failed: \(reply)")
        model.clearMirroredDestinationFolder()
        reply = await send(["command": "set-mirror-folder", "path": "NoSuchDrive/Raws"])
        require((reply["error"] as? String)?.contains("is not a full path") == true,
                "an unresolvable relative mirror path was not explained: \(reply)")
        model.volumes = savedVolumes

        reply = await send(["command": "remove-destination", "path": dest])
        require(reply["ok"] as? Bool == true && model.destinationPaths.isEmpty, "remove-destination failed")
        reply = await send(["command": "clear-source"])
        require(reply["ok"] as? Bool == true && model.sourcePath == nil, "clear-source failed")

        // Two mounts with one name: refuse and list both, never pick one.
        let saved = model.volumes
        model.volumes = [
            Volume(path: card, name: "DUP", isEjectable: true, isExternal: true, isLocal: true,
                   totalBytes: nil, freeBytes: nil),
            Volume(path: dest, name: "DUP", isEjectable: true, isExternal: true, isLocal: true,
                   totalBytes: nil, freeBytes: nil),
        ]
        reply = await send(["command": "stage-source", "path": "DUP"])
        require((reply["error"] as? String)?.contains("2 mounted volumes are named") == true
                && model.sourcePath == nil, "a shared volume name was not refused: \(reply)")
        reply = await send(["command": "eject", "volume": "DUP", "force": true])
        require((reply["error"] as? String)?.contains("2 mounted volumes are named") == true,
                "eject by a shared volume name was not refused: \(reply)")
        model.volumes = saved

        // Jobs: stop needs confirm, pause explains, labels never guess.
        func makeJob(_ label: String, _ phase: JobPhase) -> Job {
            let job = Job(label: label, sourcePath: card, destinations: [dest + "/\(label)"])
            job.phase = phase
            return job
        }
        let queued = makeJob("B001", .queued)
        let twinA = makeJob("TWIN", .done)
        let twinB = makeJob("TWIN", .failed)
        model.jobs = [queued, twinA, twinB]

        reply = await send(["command": "stop", "job": "B001"])
        require(reply["ok"] as? Bool == false && reply["needs"] as? String == "confirm",
                "stop without confirm was not refused: \(reply)")
        require(queued.isRunning, "an unconfirmed stop stopped the job")
        reply = await send(["command": "pause", "job": queued.id.uuidString])
        require((reply["error"] as? String)?.contains("only while bytes are moving") == true,
                "pausing a queued job did not say why: \(reply)")
        reply = await send(["command": "resume", "job": "B001"])
        require(reply["error"] as? String == "B001 is not paused.", "resume of an unpaused job: \(reply)")
        reply = await send(["command": "stage-retry", "job": "TWIN"])
        require((reply["error"] as? String)?.contains("2 jobs are labeled") == true,
                "an ambiguous label was not refused: \(reply)")
        reply = await send(["command": "job", "job": "TWIN"])
        require((reply["job"] as? [String: Any])?["id"] as? String
                    == model.runsNewestFirst({ $0.label == "TWIN" }).first?.id.uuidString,
                "reading an ambiguous label did not return the newest run: \(reply)")
        reply = await send(["command": "job", "job": String(twinB.id.uuidString.prefix(8))])
        require((reply["job"] as? [String: Any])?["id"] as? String == twinB.id.uuidString,
                "an id prefix did not find its job")
        reply = await send(["command": "stop", "job": "B001", "confirm": true])
        require(reply["ok"] as? Bool == true && queued.phase == .failed, "confirmed stop failed: \(reply)")
        let stopped = reply["job"] as? [String: Any]
        require(stopped?["verdictLine"] as? String == VerdictBadge.stoppedLine && stopped?["stopped"] as? Bool == true,
                "a stopped job did not read as its badge: \(String(describing: stopped))")
        reply = await send(["command": "stop", "job": "B001", "confirm": true])
        require((reply["error"] as? String)?.contains("is not running") == true,
                "stopping a stopped job did not say so: \(reply)")
        // A SAFE result no live session vouches for is history, not leave
        // to clear the card.
        twinA.fullyVerified = true
        twinA.safeToWipe = true
        let historical = control.job(model, twinA)
        require(historical["verdict"] as? String == "safe_to_clear" && historical["safeToClear"] as? Bool == false,
                "a SAFE verdict without a current session read as safe to clear: \(historical)")
        reply = await send(["command": "stage-retry", "job": twinB.id.uuidString])
        require(reply["ok"] as? Bool == false, "retry of a job with no plan was staged")
        require((reply["error"] as? String)?.contains("no frozen plan") == true,
                "retry of a job with no plan did not say why: \(reply)")
        require(model.retryRefusals[twinB.id] == nil, "an unoffered retry still reached the model")

        // Eject: the control's gate, the sheet's words, the sheet's buttons.
        let network = Volume(path: card, name: "SHARE", isEjectable: false, isExternal: false,
                             isLocal: false, totalBytes: nil, freeBytes: nil)
        let refusal = control.ejectRefusal(model, network, ["force": true])
        require((refusal?["error"] as? String)?.contains("network volume") == true,
                "a network volume eject was not refused: \(String(describing: refusal))")

        let cardVolume = Volume(path: card, name: "CARD", isEjectable: true, isExternal: true,
                                isLocal: true, totalBytes: nil, freeBytes: nil)
        let copying = makeJob("C001", .copying)
        model.jobs = [copying]
        let running = control.ejectRefusal(model, cardVolume, ["confirm": true])
        require(running?["needs"] as? String == "force", "a mid-copy eject did not need force")
        require((running?["error"] as? String)?.hasPrefix("Eject a card mid-transfer?") == true,
                "the mid-copy refusal was not the sheet's title: \(String(describing: running))")
        require(control.ejectRefusal(model, cardVolume, ["force": true]) == nil,
                "force did not clear the mid-copy gate")
        let details = control.ejectDetails(model, cardVolume)
        let hold = details["hold"] as? [String: Any]
        require(hold?["kind"] as? String == "transfer_running" && hold?["risky"] as? Bool == true,
                "eject details did not carry the hold: \(details)")

        let kept = makeJob("D001", .done)
        kept.fullyVerified = true
        kept.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
        model.jobs = [kept]
        let oneDrive = control.ejectRefusal(model, cardVolume, [:])
        require(oneDrive?["needs"] as? String == "confirm", "a one-drive eject did not ask for confirm")
        require((oneDrive?["error"] as? String)?.contains("keep this card and don't format it") == true,
                "the one-drive refusal lost the sheet's words: \(String(describing: oneDrive))")
        require(control.ejectRefusal(model, cardVolume, ["confirm": true]) == nil,
                "confirm did not clear a warning that cannot damage a copy")

        // A finished Fast-mode run: COPIED · NOT VERIFIED, nothing failed.
        // No copy is in progress, so confirm is enough, as the README says.
        let fast = makeJob("E001", .done)
        model.jobs = [fast]
        require(control.job(model, fast)["copiedClean"] as? Bool == true,
                "a clean Fast-mode run did not read as copied")
        let unverified = control.ejectRefusal(model, cardVolume, [:])
        require(unverified?["needs"] as? String == "confirm",
                "a finished unverified run's card needed more than confirm: \(String(describing: unverified))")
        require(control.ejectRefusal(model, cardVolume, ["confirm": true]) == nil,
                "confirm did not clear a finished unverified run")
        fast.filesFailed = 1
        require(control.job(model, fast)["copiedClean"] as? Bool == false,
                "a run with a failed file read as a clean copy")
        fast.filesFailed = 0
        for blocker in ["2 source object(s) were not copied", "source tree changed after the initial scan"] {
            fast.wipeBlockers = ["copy is not fully verified", blocker]
            require(control.job(model, fast)["copiedClean"] as? Bool == false,
                    "a run the engine called incomplete read as a clean copy: \(blocker)")
        }
        for blocker in ["full flush-to-media failed on at least one destination file",
                        "camera-written MHL custody was not preserved consistently"] {
            fast.wipeBlockers = ["copy is not fully verified", blocker]
            require(control.job(model, fast)["copiedClean"] as? Bool == false,
                    "a Fast run the window shows amber read as a clean copy: \(blocker)")
        }
        fast.wipeBlockers = ["copy is not fully verified"]
        require(control.job(model, fast)["copiedClean"] as? Bool == true,
                "Fast mode's own blocker stopped a clean copy reading as copied")

        // A verified run the window shows amber is not plain "verified".
        let amber = makeJob("F001", .done)
        amber.fullyVerified = true
        amber.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
        require(control.job(model, amber)["verdict"] as? String == "verified",
                "a routine one-drive verified run lost its verdict")
        amber.wipeBlockers.append("source tree changed after the initial scan")
        require(control.job(model, amber)["verdict"] as? String == "verified_attention"
                    && control.job(model, amber)["needsAttention"] as? Bool == true,
                "an amber verified run read as plain verified")

        // Eject unmounts only this volume when a sibling shares its disk.
        require(AppModel.wholeDisk(of: "disk7s2") == "disk7" && AppModel.wholeDisk(of: "disk12") == "disk12"
                    && AppModel.wholeDisk(of: "/dev/disk3s1s1") == "disk3",
                "whole-disk names were not derived from partition names")
        require(AppModel.physicalDisks(fromDiskutilInfo: [
                    "ParentWholeDisk": "disk12",
                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk7s2"],
                                           ["APFSPhysicalStore": "disk8s2"]]]) == ["disk7", "disk8"],
                "an APFS volume did not resolve to all its physical stores' disks")
        require(AppModel.physicalDisks(fromDiskutilInfo: ["ParentWholeDisk": "disk5"]) == ["disk5"],
                "an HFS or exFAT partition did not resolve to its parent disk")
        let diskInfo: [String: [String: Any]] = [
            "/Volumes/A": ["ParentWholeDisk": "disk13"],
            "/Volumes/B": ["ParentWholeDisk": "disk13"],
            "/Volumes/APFS": ["ParentWholeDisk": "disk20",
                              "APFSPhysicalStores": [["APFSPhysicalStore": "disk9s2"],
                                                     ["APFSPhysicalStore": "disk13s3"]]],
            "/Volumes/OTHER": ["ParentWholeDisk": "disk14"]]
        let lookup: (String) -> [String: Any]? = { diskInfo[$0] ?? ($0 == "/" ? ["ParentWholeDisk": "disk3",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]] : nil) }
        require(AppModel.ejectVerb(for: "/Volumes/A", otherMountedPaths: ["/Volumes/B", "/Volumes/OTHER"],
                                   info: lookup) == "unmount",
                "a partition with a mounted sibling was ejected whole")
        require(AppModel.ejectVerb(for: "/Volumes/A", otherMountedPaths: ["/Volumes/APFS"],
                                   info: lookup) == "unmount",
                "a sibling on a later APFS physical store was missed")
        require(AppModel.ejectVerb(for: "/Volumes/A", otherMountedPaths: ["/Volumes/OTHER"],
                                   info: lookup) == "eject",
                "the last volume on its disk did not eject the disk")
        require(AppModel.ejectVerb(for: "/Volumes/GONE", otherMountedPaths: ["/Volumes/B"],
                                   info: lookup) == "eject",
                "an unidentified volume did not fall back to a normal eject")
        let bootedExternally: (String) -> [String: Any]? = { path in
            path == "/" || path == "/Volumes/MEDIA" ? ["ParentWholeDisk": "disk5"] : nil }
        require(AppModel.ejectVerb(for: "/Volumes/MEDIA", otherMountedPaths: [],
                                   info: bootedExternally) == "unmount",
                "a volume on the startup disk's device was ejected disk-wide")
        require(!AppModel.diskMounts(excluding: "/nonexistent").contains { $0.on == "/" },
                "the startup disk was offered as an eject sibling")
        // A queued eject rechecks the mount and any new transfer first.
        var queuedCard = Volume(path: card, name: "CARD", isEjectable: true, isExternal: true,
                                isLocal: true, totalBytes: nil, freeBytes: nil)
        queuedCard.appearedAt = Date(timeIntervalSince1970: 1_000)
        let queuedSavedVolumes = model.volumes
        let queuedSavedJobs = model.jobs
        model.volumes = [queuedCard]
        model.jobs = []
        let identity = AppModel.mountIdentity(queuedCard)
        require(model.queuedEjectRefusal(queuedCard, identity: identity, approvedTransfer: nil) == nil,
                "an unchanged idle card was refused at queued eject")
        var swapped = queuedCard
        swapped.appearedAt = Date(timeIntervalSince1970: 2_000)
        model.volumes = [swapped]
        require(model.queuedEjectRefusal(queuedCard, identity: identity, approvedTransfer: nil) != nil,
                "a card replaced while the eject waited was ejected")
        model.volumes = [queuedCard]
        require(model.queuedEjectRefusal(queuedCard, identity: identity + "-other", approvedTransfer: nil) != nil,
                "a different mount at the same path and time was ejected")
        let started = makeJob("Q001", .copying)
        model.jobs = [started]
        require(model.queuedEjectRefusal(queuedCard, identity: identity, approvedTransfer: nil) != nil,
                "a transfer that started while the eject waited was ejected without force")
        require(model.queuedEjectRefusal(queuedCard, identity: identity, approvedTransfer: started.id) == nil,
                "a forced eject of the transfer it was approved for was refused")
        require(model.queuedEjectRefusal(queuedCard, identity: identity, approvedTransfer: UUID()) != nil,
                "force approved for one transfer covered a different one")
        // A refused eject leaves its reason for that volume's eject control,
        // only while that mount is still there.
        var ghost = Volume(path: card + "/GHOST", name: "GHOST", isEjectable: true, isExternal: true,
                           isLocal: true, totalBytes: nil, freeBytes: nil)
        ghost.appearedAt = Date(timeIntervalSince1970: 5_000)
        var replaced = ghost
        replaced.appearedAt = Date(timeIntervalSince1970: 6_000)
        func ejectAndWait(_ volume: Volume, from control: UUID? = nil,
                          thenStart job: Job? = nil) async throws {
            model.eject(volume, from: control)
            // A transfer that starts after the request, before it runs.
            if let job { model.jobs = [job] }
            let deadline = Date().addingTimeInterval(15)
            while model.ejectingVolumePaths.contains(volume.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        model.jobs = []
        model.volumes = [ghost]
        try await ejectAndWait(replaced)   // the request names a mount that is not this one
        require(model.ejectRefusal(for: replaced) == nil && model.ejectRefusal(for: ghost) == nil,
                "a refusal was stored for a mount that is not there")
        require(model.lastEjectError?.contains("changed before it could be ejected") == true,
                "the banner lost the refusal for a missing mount")
        model.volumes = [ghost]
        model.jobs = []
        let railControl = UUID(), shelfControl = UUID()
        try await ejectAndWait(ghost, from: shelfControl, thenStart: makeJob("Q002", .copying))
        require(model.ejectRefusal(for: ghost)?.contains("transfer started") == true,
                "a refused eject left no reason for its control: \(model.ejectRefusals)")
        require(model.ejectRefusal(for: replaced) == nil,
                "another mount at the same path inherited the eject reason")
        // Only the control that asked shows the reason.
        require(model.showsEjectRefusal(ghost, control: shelfControl)
                    && !model.showsEjectRefusal(ghost, control: railControl),
                "the reason showed on a control that did not ask for the eject")
        // A cancelled force sheet hands nothing to a later eject.
        model.armForceEject(ghost, control: railControl)
        require(model.takeForceEjectInitiator(ghost) == railControl,
                "the force sheet lost the control that opened it")
        require(model.takeForceEjectInitiator(ghost) == nil,
                "a force-sheet initiator was handed out twice")
        // An eject with no button (the CLI) shows the reason on none.
        model.jobs = []
        try await ejectAndWait(ghost, thenStart: makeJob("Q003", .copying))
        require(model.ejectRefusal(for: ghost) != nil
                    && !model.showsEjectRefusal(ghost, control: shelfControl)
                    && !model.showsEjectRefusal(ghost, control: railControl),
                "a CLI eject's reason showed on a button")
        model.dismissEjectRefusal(ghost)
        require(model.ejectRefusal(for: ghost) == nil, "dismissing the eject reason did not clear it")
        model.volumes = queuedSavedVolumes
        model.jobs = queuedSavedJobs

        // A job whose crashed engine could not be ruled out may still write.
        let orphan = makeJob("G001", .failed)
        require(!AppModel.mayStillBeWriting(orphan), "a finished job read as writing")
        orphan.unresolvedRecoveryPhase = "copying"
        require(AppModel.mayStillBeWriting(orphan),
                "an unresolved crash recovery did not hold eject")
        // Even when the card was plugged in again after the job began.
        var replugged = Volume(path: card, name: "CARD", isEjectable: true, isExternal: true,
                               isLocal: true, totalBytes: nil, freeBytes: nil)
        replugged.appearedAt = Date().addingTimeInterval(3_600)
        model.jobs = [orphan]
        let orphanEject = control.ejectRefusal(model, replugged, ["confirm": true])
        require(orphanEject?["needs"] as? String == "force",
                "an unresolved crash recovery's card ejected without force: \(String(describing: orphanEject))")
        model.jobs = [fast]

        try await socketRoundTrip(control: control, model: model, root: root)
        model.jobs = []
    }

    /// The socket and the CLI, end to end, on a scratch socket.
    @MainActor
    private static func socketRoundTrip(control: AppControl, model: AppModel, root: URL) async throws {
        let fm = FileManager.default
        let socketPath = "/tmp/dtctl-check-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }
        let server = ControlSocketServer(path: socketPath) { data in await control.handle(data) }
        try server.start()
        var info = stat()
        require(lstat(socketPath, &info) == 0 && (info.st_mode & 0o777) == 0o600,
                "the socket file is not mode 0600")
        do {
            let rival = ControlSocketServer(path: socketPath) { _ in Data() }
            try rival.start()
            rival.stop()
            require(false, "a second server took a live socket")
        } catch ControlSocketServer.StartError.inUse {}

        let engineRoot = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent().path
        require(fm.fileExists(atPath: engineRoot + "/dumptruck/ctl.py"),
                "dumptruck/ctl.py not found beside DumptruckApp (run from DumptruckApp/)")
        func ctl(_ args: [String]) async -> (status: Int32, out: String, err: String) {
            await runProcess("/usr/bin/env", ["python3", "-m", "dumptruck.ctl", "--socket", socketPath] + args,
                             cwd: engineRoot)
        }
        var result = await ctl(["--json", "status"])
        require(result.status == 0, "ctl status exited \(result.status): \(result.err)")
        let parsed = try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any]
        let app = (parsed?["state"] as? [String: Any])?["app"] as? [String: Any]
        require(app?["protocol"] as? Int == AppControl.protocolVersion, "ctl status lost the protocol")
        result = await ctl(["stage", root.appendingPathComponent("NOPE").path])
        require(result.status == 1, "a refused ctl command exited \(result.status)")
        require(result.err.contains("refused: Only an existing folder"), "ctl did not print the reason: \(result.err)")
        result = await ctl(["stop", "nobody"])
        require(result.status == 1 && result.err.contains("No job has the id"), "ctl stop of nobody: \(result.err)")
        // wait on a clean Fast-mode run: its own exit code, or 0 when asked.
        require(model.jobs.first?.label == "E001", "the Fast-mode job is not staged for wait")
        result = await ctl(["wait", "E001"])
        require(result.status == 5 && result.out.contains("COPIED · NOT VERIFIED"),
                "wait on a clean Fast-mode run exited \(result.status): \(result.out) \(result.err)")
        result = await ctl(["wait", "E001", "--accept-copied"])
        require(result.status == 0, "wait --accept-copied exited \(result.status): \(result.err)")
        model.jobs.first?.filesFailed = 2
        result = await ctl(["wait", "E001", "--accept-copied"])
        require(result.status == 1, "wait --accept-copied passed a run with failed files")
        model.jobs.first?.filesFailed = 0

        server.stop()
        require(lstat(socketPath, &info) != 0, "stop left the socket file")
        result = await ctl(["status"])
        require(result.status == 3 && result.err.contains("not answering"),
                "ctl against no app exited \(result.status): \(result.err)")

        // A crashed run's socket is replaced; a plain file is never removed.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        let again = ControlSocketServer(path: socketPath) { data in await control.handle(data) }
        try again.start()
        again.stop()
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: socketPath))
        do {
            let rival = ControlSocketServer(path: socketPath) { _ in Data() }
            try rival.start()
            rival.stop()
            require(false, "a server replaced a plain file")
        } catch ControlSocketServer.StartError.notASocket {}
        require(fm.contents(atPath: socketPath) == Data("keep me".utf8), "a plain file was touched")
    }

    /// Runs a process without blocking the main actor, which the socket's
    /// handler needs while the CLI waits for its reply.
    private static func runProcess(_ executable: String, _ arguments: [String],
                                   cwd: String) async -> (status: Int32, out: String, err: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (proc.terminationStatus, o, e))
            }
            do {
                try process.run()
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
            } catch {
                continuation.resume(returning: (-1, "", "\(error)"))
            }
        }
    }
}
