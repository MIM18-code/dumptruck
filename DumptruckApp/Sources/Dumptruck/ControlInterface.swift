import Foundation

/// The agent's way into the running app. Every command calls the same
/// AppModel method a button calls, so it passes the same gates, and a
/// refusal comes back as the reason the window would show next to that
/// button. Nothing here starts, stops or ejects by any other route.
///
/// Requests and replies are one JSON object each. The socket server
/// (ControlSocketServer.swift) carries them; `dumptruck/ctl.py` is the CLI.
/// Reply shape: `{"ok": true, "message": …}` or `{"ok": false, "error": …}`,
/// plus whatever the command reports (`state`, `bench`, `job`, `jobs`,
/// `eject`).
@MainActor
final class AppControl {
    /// Bumped when a reply field changes meaning. The CLI prints it in
    /// `status` so an agent can tell which app it is talking to.
    nonisolated static let protocolVersion = 2

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// The socket entry point: bytes in, bytes out.
    func handle(_ data: Data) async -> Data {
        let reply: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data),
           let request = object as? [String: Any] {
            reply = await perform(request)
        } else {
            reply = ["ok": false, "error": "The request was not a JSON object."]
        }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: reply, options: options))
            ?? Data(#"{"ok":false,"error":"The reply could not be encoded."}"#.utf8)
    }

    func perform(_ request: [String: Any]) async -> [String: Any] {
        guard let model else { return ["ok": false, "error": "Dumptruck is shutting down."] }
        guard let command = request["command"] as? String else {
            return refused("The request has no command.")
        }
        switch command {
        case "status":
            // The model's own mount notifications and 30-second timer keep
            // the volume list current; a status poll only reads it.
            return ["ok": true, "state": state(model, landing: true)]
        case "stage-source": return stageSource(model, request)
        case "set-label": return setLabel(model, request)
        case "reread-source": return rereadSource(model)
        case "clear-source": return clearSource(model)
        case "stage-destination": return stageDestination(model, request)
        case "remove-destination": return removeDestination(model, request)
        case "clear-destinations": return clearDestinations(model)
        case "set-mirror-folder": return setMirrorFolder(model, request)
        case "clear-mirror-folder":
            model.clearMirroredDestinationFolder()
            return ok("The mirrored folder is cleared.", ["bench": bench(model)])
        case "job":
            // Reading a job is harmless, so a label shared by a retry and the
            // run it replaced reads the newest. Actions still refuse.
            switch resolveJob(model, request, newestOnTie: true) {
            case .failure(let refusal): return refused(refusal.reason)
            case .success(let found): return ["ok": true, "job": job(model, found)]
            }
        case "start": return start(model, request)
        case "pause": return pause(model, request)
        case "resume": return resume(model, request)
        case "stop": return stop(model, request)
        case "stage-retry": return stageRetry(model, request)
        case "eject-check": return ejectCheck(model, request)
        case "eject": return await eject(model, request)
        default:
            return refused("Unknown command \"\(command)\". Commands: status, stage-source, "
                + "set-label, reread-source, clear-source, stage-destination, remove-destination, "
                + "clear-destinations, set-mirror-folder, clear-mirror-folder, job, start, "
                + "pause, resume, stop, stage-retry, eject-check, eject.")
        }
    }

    // MARK: - Replies

    private func ok(_ message: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var reply = extra
        reply["ok"] = true
        reply["message"] = message
        return reply
    }

    private func refused(_ reason: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var reply = extra
        reply["ok"] = false
        reply["error"] = reason
        return reply
    }

    private func string(_ request: [String: Any], _ key: String) -> String? {
        guard let value = request[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func flag(_ request: [String: Any], _ key: String) -> Bool {
        request[key] as? Bool ?? false
    }

    // MARK: - Paths and names

    struct Refusal: Error { let reason: String }

    /// An absolute path, or the name of a mounted volume ("B001" for
    /// /Volumes/B001). Names are what an operator says out loud.
    private func resolvePath(_ model: AppModel, _ raw: String) -> Result<String, Refusal> {
        if let ambiguous = ambiguousName(model, raw) { return .failure(ambiguous) }
        if raw.hasPrefix("/") {
            return .success(URL(fileURLWithPath: raw).standardizedFileURL.path)
        }
        if raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            return .success(URL(fileURLWithPath: expanded).standardizedFileURL.path)
        }
        if let volume = resolveVolume(model, raw) { return .success(volume.path) }
        return .failure(Refusal(reason: "No mounted volume is named \"\(raw)\". Give an absolute path or a "
            + "volume name from `status`."))
    }

    private func resolveVolume(_ model: AppModel, _ raw: String) -> Volume? {
        let standardized = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw).standardizedFileURL.path : nil
        if let standardized, let hit = model.volumes.first(where: { $0.path == standardized }) {
            return hit
        }
        // Two cards can share a name ("A001" at /Volumes/A001 and
        // /Volumes/A001 1). A name only counts when exactly one mount has it.
        let exact = model.volumes.filter { $0.name == raw }
        if exact.count == 1 { return exact[0] }
        guard exact.isEmpty else { return nil }
        let folded = model.volumes.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
        return folded.count == 1 ? folded[0] : nil
    }

    private func ambiguousName(_ model: AppModel, _ raw: String) -> Refusal? {
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        let exact = model.volumes.filter { $0.name == raw }
        let matches = exact.isEmpty
            ? model.volumes.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame } : exact
        guard matches.count > 1 else { return nil }
        return Refusal(reason: "\(matches.count) mounted volumes are named \"\(raw)\": "
            + matches.map(\.path).joined(separator: ", ") + ". Give the path.")
    }

    private func volumeOrRefusal(_ model: AppModel, _ raw: String) -> Result<Volume, Refusal> {
        if let ambiguous = ambiguousName(model, raw) { return .failure(ambiguous) }
        guard let volume = resolveVolume(model, raw) else {
            return .failure(Refusal(reason: "No mounted volume matches \"\(raw)\"."))
        }
        return .success(volume)
    }

    /// A job by id, id prefix (8+ characters), or card label. A label that
    /// names several runs is refused with their ids rather than guessed,
    /// unless the caller only reads (`newestOnTie`).
    private func resolveJob(_ model: AppModel, _ request: [String: Any],
                            newestOnTie: Bool = false) -> Result<Job, Refusal> {
        guard let key = string(request, "job") else {
            return .failure(Refusal(reason: "Name the job: its id from `status`, or its card label."))
        }
        if let id = UUID(uuidString: key), let job = model.jobs.first(where: { $0.id == id }) {
            return .success(job)
        }
        let lower = key.lowercased()
        if lower.count >= 8 {
            let prefixed = model.jobs.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            if prefixed.count == 1 { return .success(prefixed[0]) }
        }
        let named = model.runsNewestFirst { $0.label == key }
        if named.count == 1 || (newestOnTie && !named.isEmpty) { return .success(named[0]) }
        if named.isEmpty {
            return .failure(Refusal(reason: "No job has the id or card label \"\(key)\"."))
        }
        let ids = named.prefix(6).map {
            "\($0.id.uuidString) (\($0.isRunning ? $0.activityText : Self.badgeLine($0)))"
        }
        return .failure(Refusal(reason: "\(named.count) jobs are labeled \"\(key)\". Name one by id, newest "
            + "first: " + ids.joined(separator: "; ")))
    }

    // MARK: - Bench

    private func stageSource(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard let raw = string(request, "path") else {
            return refused("stage-source needs a path or volume name.")
        }
        let path: String
        switch resolvePath(model, raw) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let resolved): path = resolved
        }
        guard model.assign(path, as: .source) else {
            return refused(model.lastSetupError ?? "Dumptruck did not stage \(raw) as the source.",
                           ["bench": bench(model)])
        }
        var message = "Staged \(model.endpointDisplayName(path)) as the source."
        if let label = request["label"] as? String {
            model.operatorEditedLabel(label)
            message += " Card name: \(model.label)."
        }
        return ok(message, ["bench": bench(model, landing: true)])
    }

    private func setLabel(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard model.sourcePath != nil else {
            return refused("No card is staged. Stage a source first; the card name belongs to it.")
        }
        guard let label = request["label"] as? String else {
            return refused("set-label needs a label.")
        }
        model.operatorEditedLabel(label)
        let message = model.label.isEmpty
            ? "The card name is empty; Start will ask for one."
            : "Card name: \(model.label)."
        return ok(message, ["bench": bench(model, landing: true)])
    }

    private func rereadSource(_ model: AppModel) -> [String: Any] {
        guard model.sourcePath != nil else { return refused("No card is staged to re-read.") }
        model.rereadStagedSource()
        if let reason = model.lastSetupError { return refused(reason, ["bench": bench(model)]) }
        return ok("Re-reading the staged card.", ["bench": bench(model)])
    }

    private func clearSource(_ model: AppModel) -> [String: Any] {
        guard let path = model.sourcePath else {
            return ok("No source was staged.", ["bench": bench(model)])
        }
        model.clearSource()
        return ok("Removed \(model.endpointDisplayName(path)) from the job.", ["bench": bench(model)])
    }

    private func stageDestination(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard let raw = string(request, "path") else {
            return refused("stage-destination needs a path or volume name.")
        }
        let path: String
        switch resolvePath(model, raw) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let resolved): path = resolved
        }
        guard model.assign(path, as: .destination) else {
            return refused(model.lastSetupError ?? "Dumptruck did not add \(raw) as a destination.",
                           ["bench": bench(model)])
        }
        // A folder that overlaps a destination already staged leaves the
        // list as it was without a word in the window. Say so here.
        let landed = model.destinationPaths.contains(path)
            || model.destinationPaths.contains { anchor in
                let relative = DestinationFolderProjection.relativePath(selected: path, under: anchor)
                return relative != nil && relative == model.destinationFolderRelativePath
            }
        guard landed else {
            return refused("\(model.endpointDisplayName(path)) overlaps a destination already "
                + "staged, so the destinations did not change.", ["bench": bench(model)])
        }
        return ok("Added \(model.endpointDisplayName(path)) as a destination.",
                  ["bench": bench(model, landing: true)])
    }

    private func removeDestination(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard let raw = string(request, "path") else {
            return refused("remove-destination needs a path or volume name.")
        }
        let path: String
        switch resolvePath(model, raw) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let resolved): path = resolved
        }
        guard model.destinationPaths.contains(path) else {
            let staged = model.destinationPaths.isEmpty
                ? "none" : model.destinationPaths.joined(separator: ", ")
            return refused("\(path) is not a destination of this job. Staged: \(staged).")
        }
        model.unassignDestination(path)
        return ok("Removed \(model.endpointDisplayName(path)) from the destinations.",
                  ["bench": bench(model)])
    }

    private func clearDestinations(_ model: AppModel) -> [String: Any] {
        let anchors = model.destinationAnchorsWithoutExtraFolders
        for anchor in anchors { model.unassignDestination(anchor) }
        // Extra folders whose drive was not itself an anchor.
        for leftover in model.destinationPaths { model.unassignDestination(leftover) }
        return ok(anchors.isEmpty ? "No destinations were staged." : "Cleared the destinations.",
                  ["bench": bench(model)])
    }

    private func setMirrorFolder(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard let raw = string(request, "path") else {
            return refused("set-mirror-folder needs the folder's full path on a destination drive.")
        }
        let path: String
        switch resolveMirrorPath(model, raw) {
        case .failure(let refusal): return refused(refusal.reason, ["bench": bench(model)])
        case .success(let resolved): path = resolved
        }
        // The drive row's folder button when the folder is on a staged
        // drive; otherwise ⇧⌘O, which is held inside the only staged drive.
        let stagedDrive = model.volumes.first { volume in
            model.destinationPaths.contains(volume.path)
                && DestinationFolderProjection.relativePath(selected: path, under: volume.path) != nil
        }
        let boundary = model.destinationFolderBoundary(on: stagedDrive?.path)
        guard model.useChosenFolder(path, inside: boundary, as: .destination) else {
            return refused(model.lastSetupError ?? "Dumptruck did not use \(raw) as the mirrored folder.",
                           ["bench": bench(model)])
        }
        let relative = model.destinationFolderRelativePath
        let benchNow = bench(model, landing: true)
        var message = relative.isEmpty ? "Copies go to the top of each destination."
            : "Mirrored folder: \(relative), on every destination."
        if let folders = benchNow["cardFolders"] as? [String], !folders.isEmpty {
            let resolved = benchNow["cardFoldersResolved"] as? Bool == true
            message += (resolved ? " Cards land in " : " Preview: cards would land in ")
                + folders.joined(separator: ", ") + "."
        }
        var extra: [String: Any] = ["bench": benchNow]
        if let note = benchNow["cardFoldersNote"] as? String { extra["note"] = note }
        return ok(message, extra)
    }

    /// The mirrored folder as typed: a full path, `~/…`, a path that starts
    /// with a mounted drive's name ("X9/Raws/11232026"), or a path inside the
    /// one staged destination drive ("Raws/11232026"). The CLI sends anything
    /// that is not absolute as typed, so a drive-relative path reaches here
    /// instead of being joined to the shell's directory.
    private func resolveMirrorPath(_ model: AppModel, _ raw: String) -> Result<String, Refusal> {
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return resolvePath(model, raw) }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let fm = FileManager.default
        func isFolder(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func standardized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
        // A drive's name, then the folder on it.
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        if let first = parts.first {
            if let ambiguous = ambiguousName(model, first) { return .failure(ambiguous) }
            if let volume = resolveVolume(model, first) {
                let rest = parts.count > 1 ? parts[1] : ""
                return .success(standardized(rest.isEmpty ? volume.path
                    : (volume.path as NSString).appendingPathComponent(rest)))
            }
        }
        // Inside the one staged destination drive, when that folder exists.
        if let drive = model.destinationFolderBoundary() {
            let candidate = standardized((drive as NSString).appendingPathComponent(trimmed))
            if isFolder(candidate),
               DestinationFolderProjection.relativePath(selected: candidate, under: drive) != nil {
                return .success(candidate)
            }
        }
        let stagedHint = model.destinationFolderBoundary().map {
            " or a folder that exists inside \($0)" } ?? ""
        return .failure(Refusal(reason: "\"\(raw)\" is not a full path. Give the folder as "
            + "/Volumes/<drive>/…, as <drive name>/…\(stagedHint)."))
    }

    // MARK: - Jobs

    private func start(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        // `start --wait` presses again while the card is read; if someone
        // staged another card meanwhile, that press is not for this one.
        // The session id, not the path: a different card mounted at the same
        // path is a new session.
        if let expected = request["expectSession"] as? String,
           model.sourceAssignmentID?.uuidString != expected {
            return refused("The staged card changed since Start was first pressed.",
                           ["bench": bench(model)])
        }
        // `start --verify fast|full`: this press only. The saved Verification
        // setting is not touched.
        let verify = string(request, "verify")
        guard verify == nil || verify == "fast" || verify == "full" else {
            return refused("verify is \"fast\" or \"full\", not \"\(verify ?? "")\".")
        }
        if verify != nil, model.stagedRetryLabel != nil, !model.retryUsesCurrentSettings {
            return refused("The staged retry runs with its saved settings, which fix its verification. "
                + "Stage it with current settings (dumptruck-ctl retry … --settings current) to choose.",
                ["bench": bench(model)])
        }
        let before = Set(model.jobs.map(\.id))
        model.startOrExplain(verifyMode: verify)
        let started = model.jobs.filter { !before.contains($0.id) }
        guard !started.isEmpty else {
            let reason = model.lastSetupError ?? model.toolbarStartBlockedReason
                ?? "Start did not begin a transfer."
            // A card read settles by itself in a few seconds; the CLI's
            // --wait retries on this flag and on nothing else.
            return refused(reason, ["retryable": reason == AppModel.readingCardReason,
                                    "bench": bench(model)])
        }
        var reply: [String: Any] = ["jobs": started.map { job(model, $0) }]
        if let note = model.lastSetupError { reply["note"] = note }
        let names = started.map(\.label).joined(separator: ", ")
        return ok("Started \(names).", reply)
    }

    private func pause(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        let job: Job
        switch resolveJob(model, request) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): job = found
        }
        guard model.canPause(job) else {
            let reason: String
            if job.isPaused { reason = "\(job.label) is already paused." }
            else if !job.isRunning { reason = "\(job.label) is not running; it ended \(Self.badgeLine(job))." }
            else if job.stopRequested { reason = "\(job.label) is stopping." }
            else if job.phase != .copying && job.phase != .sourceVerify {
                reason = "\(job.label) is at \"\(job.activityText)\". Pause is offered only while "
                    + "bytes are moving (copying, or the second read of the card)."
            } else { reason = "\(job.label) has no running engine to pause." }
            return refused(reason, ["job": self.job(model, job)])
        }
        model.pause(job: job)
        guard job.isPaused else {
            return refused(model.lastSetupError ?? "\(job.label) did not pause.",
                           ["job": self.job(model, job)])
        }
        return ok("Paused \(job.label). Keep the card and drives connected.",
                  ["job": self.job(model, job)])
    }

    private func resume(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        let job: Job
        switch resolveJob(model, request) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): job = found
        }
        guard job.isPaused else {
            return refused("\(job.label) is not paused.", ["job": self.job(model, job)])
        }
        model.resume(job: job)
        return ok("Resumed \(job.label).", ["job": self.job(model, job)])
    }

    private func stop(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        let job: Job
        switch resolveJob(model, request) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): job = found
        }
        guard job.isRunning else {
            return refused("\(job.label) is not running; it ended \(Self.badgeLine(job)).",
                           ["job": self.job(model, job)])
        }
        if job.stopRequested {
            return ok("\(job.label) is already stopping.", ["job": self.job(model, job)])
        }
        // The window asks "Stop copying …?" first. This is that question.
        guard flag(request, "confirm") else {
            let consequence = job.phase == .queued
                ? "It has not started; stopping takes it off the queue."
                : "It ends \(VerdictBadge.stoppedLine). Everything already verified stays on "
                    + "the drives; the rest of the card needs another run."
            return refused("Stop copying \(job.label)? \(consequence) Pass confirm "
                + "(dumptruck-ctl stop … --confirm) to stop it.",
                ["needs": "confirm", "job": self.job(model, job)])
        }
        model.stop(job: job)
        return ok("Stopping \(job.label).", ["job": self.job(model, job)])
    }

    private func stageRetry(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        let job: Job
        switch resolveJob(model, request) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): job = found
        }
        // The bench's "Use current verification and report settings"
        // toggle. Staging resets it to current, so it is set afterwards.
        let settings = string(request, "settings")
        guard settings == nil || settings == "current" || settings == "saved" else {
            return refused("settings is \"current\" or \"saved\", not \"\(settings ?? "")\".")
        }
        // Stage Retry is offered only on a finished card with a saved plan.
        // Asking the model anyway would disarm a retry already staged.
        if job.isRunning {
            return refused("\(job.label) is still running; Stage Retry is offered once it ends.",
                           ["job": self.job(model, job)])
        }
        if job.launchPlanSnapshot == nil {
            return refused("This older job has no frozen plan to retry safely",
                           ["job": self.job(model, job)])
        }
        guard model.stageRetry(job) else {
            return refused(model.retryRefusals[job.id] ?? "This retry could not be staged.",
                           ["job": self.job(model, job), "bench": bench(model)])
        }
        if settings == "saved" { model.retryUsesCurrentSettings = false }
        return ok("Staged a retry of \(job.label). Start runs it. \(model.retrySettingsSummary)",
                  ["bench": bench(model)])
    }

    // MARK: - Eject

    private func ejectCheck(_ model: AppModel, _ request: [String: Any]) -> [String: Any] {
        guard let raw = string(request, "volume") else { return refused("Name the volume.") }
        let volume: Volume
        switch volumeOrRefusal(model, raw) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): volume = found
        }
        return ok(ejectSummary(model, volume), ["eject": ejectDetails(model, volume)])
    }

    private func eject(_ model: AppModel, _ request: [String: Any]) async -> [String: Any] {
        guard let raw = string(request, "volume") else { return refused("Name the volume.") }
        let volume: Volume
        switch volumeOrRefusal(model, raw) {
        case .failure(let refusal): return refused(refusal.reason)
        case .success(let found): volume = found
        }
        if let refusal = ejectRefusal(model, volume, request) { return refusal }
        model.eject(volume)
        // diskutil runs in the background; report what it did.
        let deadline = Date().addingTimeInterval(60)
        while model.ejectingVolumePaths.contains(volume.path), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if model.ejectingVolumePaths.contains(volume.path) {
            return ok("Eject of \(volume.name) is still running after 60 seconds.")
        }
        // lastEjectError is shared by every eject; the mount list, which
        // the eject's own completion refreshed, is the answer.
        if model.volumes.contains(where: { $0.path == volume.path }) {
            let error = model.lastEjectError.flatMap {
                $0.hasPrefix("Eject failed for \(volume.name):") ? $0 : nil }
            return refused(error ?? "\(volume.name) is still mounted; the eject did not finish.")
        }
        return ok("Ejected \(volume.name).")
    }

    /// The eject control's gate, applied to a request: nil when the eject
    /// may go ahead, else the refusal. EjectControl ejects on one click when
    /// canEject or harmless and otherwise opens the warning sheet, whose
    /// Force Eject (risky) and Eject (not risky) are `force` and `confirm`.
    func ejectRefusal(_ model: AppModel, _ volume: Volume,
                      _ request: [String: Any]) -> [String: Any]? {
        let details = ejectDetails(model, volume)
        guard model.offersEject(volume) else {
            return refused(Self.notOfferedReason(volume), ["eject": details])
        }
        guard !model.ejectingVolumePaths.contains(volume.path) else {
            return refused("\(volume.name) is already ejecting.", ["eject": details])
        }
        if model.canEject(volume) || model.ejectIsHarmless(volume) { return nil }
        let hold = model.ejectHold(volume)
        let needs = Self.ejectNeeds(hold)
        let allowed = needs == "force" ? flag(request, "force")
                                       : (flag(request, "confirm") || flag(request, "force"))
        if allowed { return nil }
        return refused(Self.sheetWords(hold, volume: volume)
                       + " Pass \(needs) (dumptruck-ctl eject … --\(needs)) to eject anyway.",
                       ["needs": needs, "eject": details])
    }

    /// `force` only while a transfer is reading or writing this volume,
    /// where ejecting can damage a copy in progress. Any other warning
    /// (a finished Fast-mode or failed run, a verdict that is not SAFE, a
    /// card never offloaded) is a question, answered with `confirm`. The
    /// window's sheet labels some of those Force Eject; the socket goes by
    /// whether a copy is in progress, as the README says.
    nonisolated static func ejectNeeds(_ hold: AppModel.EjectHold?) -> String {
        if case .transferRunning = hold { return "force" }
        return "confirm"
    }

    nonisolated static func notOfferedReason(_ volume: Volume) -> String {
        volume.isLocal
            ? "Dumptruck offers no eject for \(volume.name): it is an internal disk that is not ejectable."
            : "Dumptruck offers no eject for \(volume.name): it is a network volume."
    }

    /// The sheet's title, message and (for "verified, not safe") every
    /// blocker, as one paragraph.
    private static func sheetWords(_ hold: AppModel.EjectHold?, volume: Volume) -> String {
        let title = EjectSheetText.title(hold, volumeName: volume.name)
        var words = title + (title.hasSuffix("?") ? " " : ". ")
            + EjectSheetText.plain(hold, volumeName: volume.name)
        if case .verifiedNotSafe(let job, false) = hold, !job.wipeBlockers.isEmpty {
            words += " Reasons: " + job.wipeBlockers.joined(separator: "; ") + "."
        }
        return words
    }

    private func ejectSummary(_ model: AppModel, _ volume: Volume) -> String {
        guard model.offersEject(volume) else { return Self.notOfferedReason(volume) }
        if model.canEject(volume) || model.ejectIsHarmless(volume) {
            return "\(volume.name) ejects on one click."
        }
        return Self.sheetWords(model.ejectHold(volume), volume: volume)
    }

    func ejectDetails(_ model: AppModel, _ volume: Volume) -> [String: Any] {
        guard model.offersEject(volume) else {
            return ["offered": false, "reason": Self.notOfferedReason(volume)]
        }
        var out: [String: Any] = [
            "offered": true,
            "oneClick": model.canEject(volume) || model.ejectIsHarmless(volume),
            "ejecting": model.ejectingVolumePaths.contains(volume.path),
        ]
        let watches = model.safeWatchesEndedByEjecting(volume)
        if !watches.isEmpty { out["endsSafeWatchOn"] = watches }
        if let hold = model.ejectHold(volume) {
            var h: [String: Any] = [
                "kind": Self.holdKind(hold),
                "summary": hold.summary,
                "title": EjectSheetText.title(hold, volumeName: volume.name),
                "message": EjectSheetText.plain(hold, volumeName: volume.name),
                "risky": EjectSheetText.isRisky(hold),
                "needs": Self.ejectNeeds(hold),
            ]
            if let job = hold.job {
                h["job"] = job.id.uuidString
                h["info"] = EjectSheetText.infoLine(hold, job: job)
                if case .verifiedNotSafe(_, false) = hold { h["blockers"] = job.wipeBlockers }
            }
            out["hold"] = h
        }
        return out
    }

    private static func holdKind(_ hold: AppModel.EjectHold) -> String {
        switch hold {
        case .transferRunning: return "transfer_running"
        case .copiesUnverified: return "copies_unverified"
        case .custodyDamaged: return "custody_damaged"
        case .verifiedNotSafe: return "verified_not_safe"
        case .verdictNotCurrent: return "verdict_not_current"
        case .destinationCheckPending: return "destination_check_pending"
        case .notOffloaded: return "not_offloaded"
        case .journalUnavailable: return "journal_unavailable"
        }
    }

    // MARK: - State

    func state(_ model: AppModel, landing: Bool = false) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var app: [String: Any] = [
            "protocol": Self.protocolVersion,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "version": info?["CFBundleShortVersionString"] as? String ?? "",
            "engineRoot": model.engineRoot,
            "dispatchPaused": model.isDispatchPaused,
        ]
        if let error = model.journalError { app["journalError"] = error }
        if let error = model.lastSetupError { app["lastSetupError"] = error }
        if let error = model.lastEjectError { app["lastEjectError"] = error }
        if let error = model.engineConfigurationError { app["engineError"] = error }
        return [
            "app": app,
            "volumes": model.volumes.map { volume(model, $0) },
            "bench": bench(model, landing: landing),
            "jobs": model.jobs.map { job(model, $0) },
        ]
    }

    private func volume(_ model: AppModel, _ volume: Volume) -> [String: Any] {
        var out: [String: Any] = [
            "path": volume.path,
            "name": volume.name,
            "ejectable": volume.isEjectable,
            "external": volume.isExternal,
            "local": volume.isLocal,
            "eject": ejectDetails(model, volume),
        ]
        if let total = volume.totalBytes { out["totalBytes"] = total }
        if let free = volume.freeBytes { out["freeBytes"] = free }
        if model.sourcePath == volume.path { out["role"] = "source" }
        else if model.destinationPaths.contains(volume.path) { out["role"] = "destination" }
        return out
    }

    func bench(_ model: AppModel, landing: Bool = false) -> [String: Any] {
        var out: [String: Any] = [
            "destinations": model.destinationPaths,
            "mirrorFolder": model.destinationFolderRelativePath,
            "label": model.label,
            "inspecting": model.inspecting,
            "canStart": model.toolbarStartBlockedReason == nil,
        ]
        if let source = model.sourcePath { out["source"] = source }
        if let session = model.sourceAssignmentID { out["session"] = session.uuidString }
        if !model.exactDestinationRoots.isEmpty { out["extraFolders"] = model.exactDestinationRoots }
        // The toolbar's Start, which is what `start` presses.
        if let reason = model.toolbarStartBlockedReason { out["startBlockedReason"] = reason }
        if let error = model.inspectionError { out["inspectionError"] = error }
        if let retry = model.stagedRetryLabel {
            out["stagedRetry"] = retry
            out["retrySettings"] = model.retryUsesCurrentSettings ? "current" : "saved"
        }
        if landing { out.merge(cardFolders(model)) { _, new in new } }
        if let i = model.inspection {
            out["inspection"] = [
                "format": i.format, "formatName": i.formatName, "reelName": i.reelName,
                "suggestedLabel": i.suggestedLabel, "known": i.known,
                "files": i.files, "bytes": i.bytes,
            ] as [String: Any]
        }
        return out
    }

    func job(_ model: AppModel, _ job: Job) -> [String: Any] {
        let lanes = job.laneRoots.isEmpty ? job.destinations : job.laneRoots
        var out: [String: Any] = [
            "id": job.id.uuidString,
            "label": job.label,
            "source": job.sourcePath,
            "destinations": job.destinations,
            "phase": Self.phaseKey(job.phase),
            "activity": job.activityText,
            "running": job.isRunning,
            "paused": job.isPaused,
            "stopRequested": job.stopRequested,
            "progress": job.fraction,
            "bytesTotal": job.bytesTotal,
            "bytesDone": job.displayedBytesDone,
            "filesTotal": job.filesTotal,
            "filesCopied": job.filesCopied,
            "filesSkipped": job.filesSkipped,
            "filesFailed": job.filesFailed,
            "verdict": Self.verdictKey(job),
            "needsAttention": job.verifiedNeedsAttention,
            "verdictLine": Self.badgeLine(job),
            "stopped": job.stoppedByOperator,
            "fullyVerified": job.fullyVerified,
            // SAFE TO CLEAR only while the verdict still covers the mounted
            // card; `verdict` keeps what the run itself proved.
            "safeToClear": job.safeToWipe && !job.isRunning && model.isCurrentSourceVerdict(job),
            "canPause": model.canPause(job),
            "canRetry": job.launchPlanSnapshot != nil,
            "restored": job.restoredFromJournal,
            "createdAt": Self.iso(job.createdDate),
            "perDestination": lanes.map { root -> [String: Any] in
                let p = job.destProgress[root] ?? DestProgress()
                return ["root": root, "filesVerified": p.filesVerified,
                        "filesTrusted": p.filesTrusted, "filesFailed": p.filesFailed,
                        "bytesVerified": p.bytesVerified, "sizeOnly": p.sizeOnly]
            },
        ]
        if job.isRunning { out["bytesPerSecond"] = job.currentSpeed }
        if let args = job.launchPlanSnapshot?.args {
            out["verifyMode"] = args.contains("--fast") ? "fast" : "full"
        }
        out["copiedClean"] = Self.copiedClean(job)
        if !job.isRunning, job.verdict == .safeToWipe {
            out["verdictCurrent"] = model.isCurrentSourceVerdict(job)
        }
        if !job.wipeBlockers.isEmpty { out["wipeBlockers"] = job.wipeBlockers }
        if let started = job.startedDate { out["startedAt"] = Self.iso(started) }
        if let finished = job.finishedDate { out["finishedAt"] = Self.iso(finished) }
        if let report = job.reportPath { out["reportPath"] = report }
        if let refusal = model.retryRefusals[job.id] { out["retryRefusal"] = refusal }
        if let withdrawn = job.destinationAuthorityWithdrawn { out["verdictWithdrawn"] = withdrawn }
        let messages = job.messages.suffix(20).map {
            ["severity": $0.severity == .error ? "error" : "warning", "text": $0.text]
        }
        if !messages.isEmpty { out["messages"] = messages }
        return out
    }

    /// Where the staged card would land if Start were pressed now: the card
    /// folder on each destination, from the same plan builder Start uses
    /// (Organize template, mirrored folder, a free "_2" name). Read only:
    /// nothing is created. `cardFoldersNote` names a folder that repeats
    /// ("…/Raws/Raws/MixPre"), which a mirrored folder that already ends
    /// in the template's folder produces.
    func cardFolders(_ model: AppModel) -> [String: Any] {
        guard let src = model.sourcePath, !model.destinationPaths.isEmpty else { return [:] }
        let label = model.label.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String: Any] = [:]
        var notes: [String] = []
        var folders: [String]
        // Resolved only when Start's own plan builds; until then (card still
        // being read, no name, or a refusal) it is the template's preview,
        // and says so: the read can change the camera folders and the name.
        var resolved = false
        if !label.isEmpty, !model.inspecting {
            switch model.planUnderFreeName(src: src, rawRoots: model.destinationPaths, base: label) {
            case .success(let named):
                resolved = true
                folders = named.plan.dests.map { ($0 as NSString).appendingPathComponent(named.label) }
                if named.label != label {
                    notes.append("\(label) is taken on a destination, so the card copies as \(named.label).")
                }
            case .failure(let error):
                folders = []
                notes.append("Start would refuse: \(error.message)")
            }
        } else {
            folders = []
        }
        if !resolved {
            let shown = label.isEmpty ? "<card name>" : label
            folders = model.effectiveDestinations(model.destinationPaths, forSource: src)
                .map { ($0 as NSString).appendingPathComponent(shown) }
            if model.inspecting { notes.append("Preview while the card is read; Start may name it differently.") }
        }
        out["cardFolders"] = folders
        out["cardFoldersResolved"] = resolved
        if let hit = folders.lazy.compactMap({ path in Self.repeatedFolder(path).map { ($0, path) } }).first {
            notes.append("The path repeats \"\(hit.0)\" (\(hit.1)). If the mirrored folder already "
                + "ends in the Organize template's folder, mirror its parent instead.")
        }
        if !notes.isEmpty { out["cardFoldersNote"] = notes.joined(separator: " ") }
        return out
    }

    /// The first folder name that appears twice in a row in `path`.
    nonisolated static func repeatedFolder(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        for (a, b) in zip(parts, parts.dropFirst())
        where a.caseInsensitiveCompare(b) == .orderedSame { return a }
        return nil
    }

    /// A run that ended with every file copied and none failed, but without
    /// a full read-back: Fast mode's COPIED · NOT VERIFIED. `wait` treats
    /// it as its own outcome so a script can wait on Fast jobs.
    static func copiedClean(_ job: Job) -> Bool {
        !job.isRunning && job.phase == .done && job.verdict == .unverified
            && job.filesFailed == 0 && !job.stoppedByOperator
            && !job.messages.contains { $0.severity == .error }
            // Fast mode's own blocker is expected. Anything else the app
            // would show amber is not a clean copy: objects the engine
            // skipped, files that appeared after its scan, a failed flush,
            // camera history that was not preserved, or later damage.
            && !job.hasCustodyFailure
            && job.attentionBlockers.allSatisfy { $0 == Self.fastModeBlocker }
    }

    nonisolated static let fastModeBlocker = "copy is not fully verified"


    /// The words on the job's verdict badge, STOPPED included.
    static func badgeLine(_ job: Job) -> String {
        job.stoppedByOperator ? VerdictBadge.stoppedLine : job.verdictLine
    }

    nonisolated static func phaseKey(_ phase: JobPhase) -> String {
        switch phase {
        case .queued: return "queued"
        case .starting: return "starting"
        case .copying: return "copying"
        case .sourceVerify: return "source_verify"
        case .reports: return "reports"
        case .done: return "done"
        case .failed: return "failed"
        case .refused: return "refused"
        }
    }

    /// A verified run the app shows amber (a file left behind, the card
    /// changed mid-copy, a failed flush, damage found later) is not plain
    /// "verified": `wait` must not report it as done.
    static func verdictKey(_ job: Job) -> String {
        if job.verifiedNeedsAttention { return "verified_attention" }
        if job.destinationAuthorityWithdrawn != nil, job.verdict == .safeToWipe {
            return "verified_attention"
        }
        return verdictKey(job.verdict)
    }

    nonisolated static func verdictKey(_ verdict: Job.Verdict) -> String {
        switch verdict {
        case .running: return "running"
        case .safeToWipe: return "safe_to_clear"
        case .verifiedKeepCard: return "verified"
        case .unverified: return "unverified"
        case .failed: return "failed"
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
