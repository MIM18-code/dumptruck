import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications

enum EngineRootResolver {
    static let fallbackRoot =
        "\(NSHomeDirectory())/Documents/Claude Video Studio/offloader"

    /// A Finder-launched app has no visible stderr, so a rejected embedded
    /// engine root would otherwise fall through to another (valid-looking)
    /// engine silently — the packaged app running the dev checkout forever
    /// (round-24 finding). The UI renders this notice whenever it is set.
    private static let noticeLock = NSLock()
    nonisolated(unsafe) private static var _embeddedRejectionNotice: String?
    static var embeddedRejectionNotice: String? {
        noticeLock.lock(); defer { noticeLock.unlock() }
        return _embeddedRejectionNotice
    }
    private static func setEmbeddedRejectionNotice(_ value: String?) {
        noticeLock.lock(); defer { noticeLock.unlock() }
        _embeddedRejectionNotice = value
    }

    static func resolve(bundleURL: URL = Bundle.main.bundleURL,
                        defaults: UserDefaults = .standard,
                        fileManager: FileManager = .default) -> String {
        // An explicit operator override (Settings › Engine, or defaults
        // write) always outranks auto-detection. Still inspect a packaged
        // pointer below: a stale formula breadcrumb is actionable packaging
        // state even when this machine currently has a development override.
        let override = defaults.string(forKey: "engineRoot")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitOverride = (override?.isEmpty == false) ? override : nil
        let embeddedFile = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("engine_root.txt", isDirectory: false)
        var validEmbeddedRoot: String?
        if fileManager.fileExists(atPath: embeddedFile.path) {
            do {
                let contents = try String(contentsOf: embeddedFile, encoding: .utf8)
                let root = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !root.isEmpty,
                      root.hasPrefix("/"),
                      root.rangeOfCharacter(from: .newlines) == nil else {
                    reject("the packaged engine pointer at \(embeddedFile.path) "
                           + "is malformed", explicitOverride: explicitOverride)
                    return explicitOverride
                        ?? resolveByBundleWalk(bundleURL: bundleURL, fileManager: fileManager)
                }

                let normalized = URL(fileURLWithPath: root)
                    .standardizedFileURL.resolvingSymlinksInPath()
                let cli = normalized
                    .appendingPathComponent("dumptruck", isDirectory: true)
                    .appendingPathComponent("cli.py", isDirectory: false)
                var rootIsDirectory: ObjCBool = false
                var cliIsDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: normalized.path,
                                          isDirectory: &rootIsDirectory),
                   rootIsDirectory.boolValue,
                   fileManager.fileExists(atPath: cli.path,
                                          isDirectory: &cliIsDirectory),
                   !cliIsDirectory.boolValue {
                    setEmbeddedRejectionNotice(nil)
                    validEmbeddedRoot = normalized.path
                } else {
                    reject("the packaged engine at \(normalized.path) is missing "
                           + "(dumptruck/cli.py not found) — was it uninstalled or "
                           + "upgraded?", explicitOverride: explicitOverride)
                }
            } catch {
                reject("the packaged engine pointer at \(embeddedFile.path) "
                       + "is unreadable: \(error.localizedDescription)",
                       explicitOverride: explicitOverride)
            }
        } else {
            setEmbeddedRejectionNotice(nil)
        }
        if let explicitOverride { return explicitOverride }
        if let validEmbeddedRoot { return validEmbeddedRoot }
        // A self-contained (DMG) build carries the whole engine inside the
        // bundle at Contents/Resources/engine, laid out with the same
        // contract as a brew libexec (dumptruck/cli.py + .venv/bin/python).
        // A relative location cannot use the pointer file above, which
        // requires an absolute path — the app may sit anywhere.
        let internalEngine = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("engine", isDirectory: true)
        let internalCLI = internalEngine
            .appendingPathComponent("dumptruck", isDirectory: true)
            .appendingPathComponent("cli.py", isDirectory: false)
        var internalCLIIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: internalCLI.path,
                                  isDirectory: &internalCLIIsDirectory),
           !internalCLIIsDirectory.boolValue {
            return internalEngine.standardizedFileURL.path
        }
        return resolveByBundleWalk(bundleURL: bundleURL, fileManager: fileManager)
    }

    /// A rejected embedded root is BOTH logged and remembered for the UI —
    /// stderr alone is invisible from Finder.
    private static func reject(_ message: String, explicitOverride: String?) {
        log("ignoring embedded engine root: \(message)")
        let sentence = message.last.map { ".?!".contains($0) } == true
            ? message : message + "."
        if let explicitOverride {
            setEmbeddedRejectionNotice(
                "Packaged engine not used: \(sentence) Running the operator-selected "
                + "engine at \(explicitOverride) instead — verify Settings › Engine.")
        } else {
            setEmbeddedRejectionNotice(
                "Packaged engine not used: \(sentence) Running the engine found "
                + "at the fallback location instead — verify Settings › Engine.")
        }
    }

    private static func resolveByBundleWalk(bundleURL: URL,
                                            fileManager: FileManager) -> String {
        var candidate = bundleURL.standardizedFileURL
        while true {
            let cli = candidate
                .appendingPathComponent("dumptruck", isDirectory: true)
                .appendingPathComponent("cli.py", isDirectory: false)
            if fileManager.fileExists(atPath: cli.path) { return candidate.path }
            if candidate.path == "/" { break }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return fallbackRoot
    }

    private static func log(_ message: String) {
        let line = "EngineRootResolver: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Finder-launched apps do not inherit Homebrew's shell PATH. The formula
    /// places ffmpeg and ffprobe beside the engine Python, so every engine
    /// process must search that directory first.
    ///
    /// The bundled camera helpers stay off until the operator agrees to
    /// their terms (CameraComponentTerms).
    static func processEnvironment(root: String,
                                   base: [String: String] = ProcessInfo.processInfo.environment,
                                   cameraHelpersAllowed: Bool? = nil)
        -> [String: String] {
        var environment = base
        let engineBin = URL(fileURLWithPath: root)
            .appendingPathComponent(".venv/bin", isDirectory: true).path
        let oldPath = environment["PATH"] ?? ""
        environment["PATH"] = oldPath.isEmpty ? engineBin : "\(engineBin):\(oldPath)"
        let allowed = cameraHelpersAllowed
            ?? CameraComponentTerms.helpersAllowed(CameraComponentTerms.status(engineRoot: root))
        if !allowed { environment["DUMPTRUCK_CAMERA_HELPERS"] = "0" }
        return environment
    }

    /// Validate the exact operator-selected checkout before any child process
    /// is launched.  This powers an ambient main-window error as well as the
    /// Start gate, so a stale defaults override cannot look like an idle app.
    static func configurationError(root: String,
                                   fileManager: FileManager = .default) -> String? {
        let normalized = URL(fileURLWithPath: root).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Engine folder not found at \(normalized). Open Settings > Engine, "
                + "choose the Dumptruck repository, then click Test Engine."
        }
        let cli = URL(fileURLWithPath: normalized)
            .appendingPathComponent("dumptruck/cli.py").path
        guard fileManager.fileExists(atPath: cli, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return "Engine folder \(normalized) does not contain dumptruck/cli.py. "
                + "Open Settings > Engine and choose the repository root."
        }
        let python = URL(fileURLWithPath: normalized)
            .appendingPathComponent(".venv/bin/python").path
        guard fileManager.fileExists(atPath: python, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: python) else {
            return "Engine Python is missing or not executable at \(python). "
                + "Repair the repository environment, then use Settings > Engine > Test Engine."
        }
        return nil
    }
}

enum CompletionNotification {
    static let openReportAction = "OPEN_REPORT"
    static let ejectCardAction = "EJECT_CARD"
    static let reportCategory = "COMPLETION_REPORT"
    static let noReportCategory = "COMPLETION_NO_REPORT"
    static let safeCategory = "COMPLETION_SAFE"
    static let safeNoReportCategory = "COMPLETION_SAFE_NO_REPORT"
    static let jobIDKey = "jobID"
    static let reportPathKey = "reportPath"
}

/// The dock tile keeps the normal app icon and adds only engine-backed
/// progress. A moving segment represents phases whose progress is unknown.
private final class DockProgressView: NSView {
    var progress: Double?
    private var pulse = 0.0

    func advance(progress: Double?) {
        self.progress = progress
        pulse = (pulse + 0.14).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp?.applicationIconImage?.draw(in: bounds)

        let track = NSRect(x: 9, y: 8, width: max(0, bounds.width - 18), height: 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        let inset = track.insetBy(dx: 2, dy: 2)
        let fill: NSRect
        if let progress {
            fill = NSRect(x: inset.minX, y: inset.minY,
                          width: inset.width * min(1, max(0, progress)),
                          height: inset.height)
        } else {
            let width = inset.width * 0.28
            fill = NSRect(x: inset.minX + (inset.width - width) * pulse,
                          y: inset.minY, width: width, height: inset.height)
        }
        // Pinned running color — the user's accent may be GREEN, and green
        // in this app is reserved for verified safety (agy audit, MEDIUM 5).
        NSColor.systemIndigo.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

/// Mutable pipe/parser state is owned exclusively by `queue`. The unchecked
/// Sendable conformance documents that synchronization boundary and avoids
/// pretending several captured local vars are independently thread-safe.
private final class EnginePipeState: @unchecked Sendable {
    let queue: DispatchQueue
    var buffer = Data()
    var stderrText = ""
    var streamFailed = false
    var eventTail: Task<Void, Never>?

    init(jobID: UUID) {
        queue = DispatchQueue(label: "dumptruck.pipe.\(jobID)")
    }
}

/// Pipe reads must return on the first protocol bytes, not wait for a large
/// requested buffer to fill. Kept as a seam so ChecksRunner can protect the
/// exact streaming primitive used by launch().
enum EnginePipeReader {
    static func nextChunk(from handle: FileHandle) -> Data {
        handle.availableData
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var volumes: [Volume] = [] { didSet { refreshCandidateSnapshots() } }
    @Published var sourcePath: String? { didSet { refreshCandidateSnapshots() } }
    @Published private(set) var sourceAssignmentID: UUID?
    @Published private(set) var sourceChangedSinceVerification = false
    @Published private(set) var sourceMutationMonitoringActive = false
    @Published var destinationPaths: [String] = [] {
        didSet {
            refreshCandidateSnapshots()
            // Cards waiting in the batch were held for "no destinations";
            // re-inspect them here, not in the batch window, because that
            // window is no longer forced open by rail drops. Only on a real
            // change: the volume refresh rewrites this array every pass.
            if destinationPaths != oldValue, !batchStagingModel.candidates.isEmpty {
                batchStagingModel.startSerialInspection(appModel: self)
            }
        }
    }
    /// A single relative folder projected below every selected destination
    /// anchor. Choosing it on one drive mirrors the same structure on all the
    /// others; launch(), not staging, creates missing peers.
    @Published var destinationFolderRelativePath = "" {
        didSet {
            // A mirrored-folder change alone never touched destinationPaths,
            // so it slipped past every other freeze invalidation and could
            // arm a stale render for a new layout (codex verify F3). The
            // buildPlan field-match is the backstop; this is the front door.
            if destinationFolderRelativePath != oldValue { continuationFreeze = nil }
        }
    }
    @Published var label = "" {
        didSet {
            // A frozen continuation render was matched for the OLD label —
            // any label edit invalidates it (codex v0.4.x review, F1).
            if label != oldValue { continuationFreeze = nil }
        }
    }
    /// True once the operator typed in the card-name field for the card now
    /// staged. The label is the continuation key and the destination folder
    /// name, so an inspection that lands later (a slow card read, or the
    /// re-read after a write to the card) must not replace what the operator
    /// typed (Joshua, 2026-09-28). Set ONLY by `operatorEditedLabel`: presets,
    /// retries and inspections write `label` without claiming authorship.
    /// Reset when a different card is staged or the bench is cleared.
    private(set) var labelEditedByUser = false
    /// Root device:inode of the staged card, taken at staging. A card pulled
    /// and another mounted at the same "/Volumes/NO NAME" is a different
    /// card, so the path string alone cannot carry a typed name across.
    private var stagedSourceFileID: String?
    /// The last reason `startOrExplain` copied into `lastSetupError`, so a
    /// finished card read can retire that explanation without wiping an
    /// unrelated refusal that arrived meanwhile.
    private var startGateExplanation: String?
    @Published var inspection: CardInspection?
    @Published var inspecting = false
    @Published var inspectionError: String?
    @Published var jobs: [Job] = []
    /// A corrupt/future journal is safety state, not a recoverable preference:
    /// show it and block new runs rather than replacing the evidence.
    @Published private(set) var journalError: String?
    /// Set only after the operator explicitly quarantines an invalid journal.
    /// The old evidence path remains visible after the fresh empty ledger is
    /// created so the operator knows historical records were retained.
    @Published private(set) var journalQuarantineNotice: String?
    /// Recovery must prove that every interrupted engine is gone before a
    /// fresh transfer or queued drain may touch any media. A process that
    /// cannot be matched/terminated remains visible and blocks Start.
    @Published private(set) var orphanRecoveryError: String?
    @Published private(set) var stagedRetryLabel: String?
    @Published var lastEjectError: String?
    /// Volume roots remain here only while diskutil owns an eject attempt.
    /// Rows use the set as a cosmetic hook; failure removes the path so the
    /// existing error strip and restored row tell the whole story.
    @Published private(set) var ejectingVolumePaths: Set<String> = []
    @Published var lastSetupError: String?
    // Two-sided workbench: chosen folders get real rail rows and survive
    // being unassigned (they used to vanish after the open panel closed).
    @Published var folderEndpoints: [Endpoint] = [] { didSet { refreshCandidateSnapshots() } }
    // The bench collapses to a strip once its job starts — the lanes need
    // the vertical space more than the staging controls do.
    @Published var benchCollapsed = false
    // The Dump Yard (optional mini games) — openable from the toolbar and
    // from the hint on a running job card.
    @Published var arcadeShown = false
    // Persistent job history and CSV export sheet
    @Published var historyShown = false
    @Published var cameraTermsShown = false
    // Batch source staging
    @Published var batchStagingShown = false
    /// Bumped by every drop or pick that lands in the batch list. The main
    /// window opens (or fronts) the batch window on each bump, so a card
    /// dropped on the rail while the list is already up is seen arriving.
    @Published var batchStagingOpenRequests = 0
    @Published var batchStagingModel = BatchSourceStagingModel() {
        didSet { observeBatchCandidates() }
    }
    private var batchCandidatesSubscription: AnyCancellable?
    private var sleepAssertion: NSObjectProtocol?
    private var inspectionProcess: Process?
    private var volumeRefreshTimer: Timer?
    private var throughputTimer: Timer?
    private let dockProgressView = DockProgressView()
    private var sourceMutationMonitor: SourceMutationMonitor?
    private var sourceMutationRefreshTask: Task<Void, Never>?
    private var sourceMonitorSession = SourceMonitorSession()
    private struct JobSourceMonitorRecord {
        let monitorID: UUID
        let monitor: SourceMutationMonitor
    }
    private var jobSourceMonitors: [UUID: JobSourceMonitorRecord] = [:]
    /// Live batch-source sessions, path → the assignment UUID minted when the
    /// candidate was queued. Written by queueBatch, and by
    /// handOffStagedVerdict when the operator moves on from a finished SAFE
    /// card (same session, same watcher contract); retired by mutation,
    /// unmount, or the path being re-staged in the source rail. This is what
    /// lets a batch job's verdict prove currency the way a staged card's
    /// verdict proves it against `sourceAssignmentID` (round-24 finding: batch
    /// SAFE verdicts could never become current on any surface).
    private var batchSourceSessions: [String: UUID] = [:]
    /// Post-terminal mutation watchers for batch sources whose SAFE verdict is
    /// still current. Without one of these, a settled batch card would keep
    /// eject authority while unmonitored — so currency REQUIRES the watcher.
    private var batchAuthorityMonitors: [String: SourceMutationMonitor] = [:]
    private let journal: JobJournal
    /// Non-nil only after an operator explicitly stages a historical retry.
    /// It keeps the original rendered organization path independent of current
    /// Settings and is consumed once the operator presses Start.
    private var stagedRetryPlan: LaunchPlan?
    @Published var retryUsesCurrentSettings = true
    private var stagedRetryJobID: UUID?

    // Engine location, strongest claim first: the operator's defaults
    // override, the packaged app's embedded engine_root.txt, the checkout
    // surrounding the app bundle, then the legacy development path:
    //   defaults write tv.mindinmotion.dumptruck engineRoot /path/to/offloader
    var engineRoot: String {
        EngineRootResolver.resolve()
    }
    var enginePython: String { "\(engineRoot)/.venv/bin/python" }
    var engineConfigurationError: String? {
        EngineRootResolver.configurationError(root: engineRoot)
    }
    /// Non-nil when a packaged engine pointer was rejected and resolution
    /// fell through to another engine — silent divergence otherwise.
    var engineResolutionNotice: String? {
        _ = engineRoot  // refresh the resolver's verdict before reading it
        return EngineRootResolver.embeddedRejectionNotice
    }

    init(journal: JobJournal = JobJournal()) {
        self.journal = journal
        // Launch-time notification actions arrive before any view appears —
        // the delegate must know this model from birth (agy audit, HIGH 4).
        AppDelegate.model = self
        // The Settings UI's @AppStorage defaults are an ILLUSION until the
        // user opens Settings — register the same defaults here so a
        // first-run launch() reads the values the Settings window displays
        // (smoke-test finding: the {Project}/Raws template silently didn't
        // apply because AppModel read nil).
        UserDefaults.standard.register(defaults: [
            Pref.verifyMode: "full",
            Pref.queueMode: "off",
            Pref.sourceReread: true,
            Pref.reverifyExisting: false,
            Pref.makeReports: true,
            Pref.thumbnails: true,
            Pref.slateFirst: false,
            Pref.openReportWhenDone: false,
            Pref.autoSourceOnMount: false,
            Pref.autoEjectWhenSafe: false,
            Pref.notifyOnCompletion: true,
            Pref.webhookEnabled: false,
            Pref.webhookURL: "",
            Pref.soundEffects: true,
            Pref.haptics: true,
            Pref.menuBarHUD: true,
            Pref.folderTemplate: "{Project}/Raws",
            Pref.projectName: "",
        ])
        loadJournalAndRecover()
        // Staged loose sets no journal record refers to are scratch from a
        // past session (a cancelled drop, a crash before queueing). Any
        // recorded job keeps its set, so a failed run can still retry. A
        // session without an authoritative journal (lock lost, ledger
        // invalid) has no idea what is referenced and sweeps nothing
        // (Opus review 2026-09-15, finding 6).
        if journalError == nil {
            LooseSourceStaging.sweep(keeping: Set(jobs.map(\.sourcePath)),
                                     olderThan: 24 * 3600)
        }
        observeBatchCandidates()
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            // Notification is not Sendable. Extract the immutable value before
            // crossing into the main actor rather than capturing the object.
            let mountedPath = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            Task { @MainActor in
                guard let self else { return }
                self.refreshVolumes()
                if UserDefaults.standard.bool(forKey: Pref.autoSourceOnMount),
                   self.sourcePath == nil,
                   let mountedPath,
                   mountedPath.hasPrefix("/Volumes/") {
                    self.setSource(mountedPath)
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVolumes() }
        }
        // Settings edits land in UserDefaults, which nothing here publishes —
        // without this, the main window's Start gate and blocked-reason text
        // keep enforcing the OLD settings until some other state mutates.
        // Republish only on a real value change: UserDefaults posts this
        // notification on EVERY write, equal value or not, and SwiftUI's
        // MenuBarExtra writes its isInserted binding back on every scene
        // update. An unconditional republish re-rendered the window, which
        // updated the scenes, which wrote the binding again: a 35 Hz loop
        // that pinned a core at idle and starved input (Codex desktop QA
        // 2026-09-15, DT-QA-01).
        preferenceFingerprint = Self.preferenceFingerprint()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.preferencesDidChange() }
        }
        // Free-space gauges must track reality, not mount-time state: bytes
        // written by anything (including our own running jobs) show within
        // 30s. statfs per volume is microseconds — polling is cheap.
        volumeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshVolumes() }
        }
        // Throughput must advance on wall-clock time, not only when progress
        // events happen. This tick turns a stalled transfer into 0 B/s instead
        // of leaving the last healthy speed and ETA frozen indefinitely.
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.jobs.filter { $0.isRunning }.forEach { $0.sampleThroughput() }
                self.updateDockTile()
            }
        }
    }

    /// Verify Existing Custody finished over `folder`. Attach the result to
    /// every job that wrote that lane, so the workbench and the journal both
    /// carry the newest fact about the copy, and revoke SAFE TO WIPE when the
    /// check found damage (Codex desktop QA 2026-09-15, DT-QA-04).
    func recordLaterVerification(folder: String, summary: ExistingVerificationSummary,
                                 date: Date = Date()) {
        let target = URL(fileURLWithPath: folder).standardizedFileURL.path
        let result = LaterVerification(
            date: date, folder: target, passed: summary.passed,
            failed: summary.failed.count, missing: summary.missing.count,
            new: summary.new.count, unverifiable: summary.unverifiable.count,
            chainProblems: summary.chainProblems.count)
        var touched = false
        for job in jobs where !job.isRunning {
            let lanes = (job.laneRoots + job.destinations)
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            guard lanes.contains(target) else { continue }
            job.laterVerification = result
            if result.isClean {
                job.custodyFailures.removeValue(forKey: target)
                if !job.hasCustodyFailure {
                    job.wipeBlockers.removeAll { $0.hasPrefix("a later verification found damage")
                        || $0.hasPrefix("a previous custody check found damage") }
                }
            } else {
                job.custodyFailures[target] = result
                stopJobDestinationMonitoring(job.id)
                job.safeToWipe = false
                let blocker = "a later verification found damage in "
                    + "\((target as NSString).lastPathComponent): \(result.line)"
                if !job.wipeBlockers.contains(blocker) { job.wipeBlockers.append(blocker) }
                retireSafeNotifications(for: job.sourcePath)
            }
            touched = true
        }
        guard touched else { return }
        _ = persistJournal()
        objectWillChange.send()
        updateDockTile()
    }

    private var preferenceFingerprint = ""

    /// One string per preference the model reads, so an equal-value write
    /// (or a write to a key the model never reads) is invisible here.
    static func preferenceFingerprint(_ defaults: UserDefaults = .standard) -> String {
        Pref.all.map { key in
            "\(key)=\(defaults.object(forKey: key).map { String(describing: $0) } ?? "nil")"
        }.joined(separator: "\u{1F}")
    }

    /// Called on every UserDefaults notification; publishes once per real
    /// change. Returns whether it published, for the check suite.
    @discardableResult
    func preferencesDidChange() -> Bool {
        let current = Self.preferenceFingerprint()
        guard current != preferenceFingerprint else { return false }
        preferenceFingerprint = current
        objectWillChange.send()
        return true
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { return nil }  // never offer the boot disk
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let cap = Volume.capacity(ofPath: path)
            return Volume(path: path,
                          name: vals?.volumeName ?? url.lastPathComponent,
                          isEjectable: vals?.volumeIsEjectable ?? false,
                          isExternal: vals?.volumeIsInternal == false,
                          isLocal: vals?.volumeIsLocal == true,
                          totalBytes: cap?.total,
                          freeBytes: cap?.free)
        }.sorted { $0.name < $1.name }
        // A card that is gone cannot hold a current verdict (see
        // isCurrentSourceVerdict), so its destination watchers go with it,
        // exactly as clearSource and setSource release them. Left running,
        // they later withdrew authority when the DIT ejected the backup
        // drives at wrap and painted those earlier SAFE cards red. This runs
        // BEFORE the missing-destination sweep so a card and a backup drive
        // leaving in the same refresh do the same (Joshua, 2026-09-28).
        let fm = FileManager.default
        if let s = sourcePath, !fm.fileExists(atPath: s) {
            stopDestinationMonitoring(forSource: s)
        }
        for path in batchSourceSessions.keys where !fm.fileExists(atPath: path) {
            stopDestinationMonitoring(forSource: path)
        }
        // A SAFE verdict whose destination went away is history, not
        // permission: the required second copy is no longer where the
        // verdict put it (desktop QA round 3, R3-01).
        retireVerdictsWithMissingDestinations()
        if let s = sourcePath, !FileManager.default.fileExists(atPath: s) {
            inspectionProcess?.terminate()
            inspectionProcess = nil
            stopMonitoringSource()
            sourcePath = nil
            sourceAssignmentID = nil
            sourceChangedSinceVerification = false
            inspection = nil
            inspectionError = nil
        }
        destinationPaths.removeAll { !FileManager.default.fileExists(atPath: $0) }
        if destinationPaths.isEmpty { destinationFolderRelativePath = "" }
        folderEndpoints.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        // An unmounted batch card ends its session; a later remount at the
        // same path is a different card until a new batch queues it.
        for path in batchSourceSessions.keys
        where !FileManager.default.fileExists(atPath: path) {
            batchSourceSessions.removeValue(forKey: path)
            batchAuthorityMonitors.removeValue(forKey: path)?.stop()
        }
    }

    // MARK: source / destinations

    /// Moving on from a finished SAFE card used to cost its verdict: only
    /// the staged card was watched, so staging the next card (or clearing
    /// the rail) dropped the watch and the untouched card read "verify
    /// again before wiping" (Joshua, 2026-09-28: "why would it need to
    /// recheck a card that hasn't changed?"). A still-current SAFE verdict
    /// now moves to a post-terminal session, exactly the one batch cards
    /// get: same assignment UUID, its own mutation watcher (started BEFORE
    /// the staged watcher stops, so there is no unwatched gap), and its
    /// destination watchers kept. Any write, unmount, or re-stage retires
    /// it the same way it retires a batch card's verdict.
    private func handOffStagedVerdict(from path: String) -> Bool {
        guard let job = runsNewestFirst({ $0.sourcePath == path }).first,
              !job.isRunning,
              job.verdict == .safeToWipe,
              isCurrentSourceVerdict(job),
              let session = job.sourceAssignmentID,
              batchAuthorityMonitors[path] == nil,
              let monitor = SourceMutationMonitor(
                  path: path, filter: .sourceJunk(root: path), handler: { [weak self] in
                  Task { @MainActor [weak self] in
                      self?.retireBatchSourceAuthority(for: path)
                  }
              }) else { return false }
        batchSourceSessions[path] = session
        batchAuthorityMonitors[path] = monitor
        return true
    }

    func setSource(_ path: String) {
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        // Before the staged watcher stops: a finished SAFE card keeps its
        // verdict under its own watcher instead of losing it.
        let handedOff = sourcePath.map { $0 != path && handOffStagedVerdict(from: $0) } ?? false
        stopMonitoringSource()
        retireSafeNotifications(for: path)
        // Staging a path the batch flow was watching hands authority to the
        // staged session; the batch verdicts for it go stale, never dual.
        retireBatchSourceAuthority(for: path)
        let previous = sourcePath
        sourcePath = path
        if let previous, !handedOff { stopDestinationMonitoring(forSource: previous) }
        if previous != path { releaseLooseSourceIfUnused(previous) }
        // Always mint a new session, even when the path string is identical.
        // A remounted continuation card commonly returns at the same path but
        // may now contain footage the previous verdict never attested.
        sourceAssignmentID = UUID()
        sourceChangedSinceVerification = false
        // A typed card name survives only a re-stage of the SAME card (Re-read
        // Card, the staged card dropped again): same path, same root identity.
        // Anything else is a new card and gets its own suggested name.
        let fileID = Self.fileID(path)
        if previous != path || fileID == nil || fileID != stagedSourceFileID {
            labelEditedByUser = false
        }
        stagedSourceFileID = fileID
        // A newly staged card is not running yet; its bench must be readable.
        // Only launch() collapses it, and only for this card's own job.
        benchCollapsed = false
        destinationPaths.removeAll { pathsOverlap($0, path) }
        if destinationPaths.isEmpty { destinationFolderRelativePath = "" }
        rememberCurrentIngestDestinations()
        startMonitoringSource(path)
        inspect(path)
    }

    /// The card-name field's write path. Only this marks the name as the
    /// operator's; `label` stays a plain property so presets, retries and
    /// inspections can set it without claiming authorship.
    func operatorEditedLabel(_ newValue: String) {
        guard newValue != label else { return }
        label = newValue
        labelEditedByUser = true
        // Whatever Start said about the old name no longer applies, and the
        // bench footer re-derives the live reason (Joshua, 2026-09-28).
        lastSetupError = nil
    }

    /// The bench's Re-read Card button. Any write to a staged card retires its
    /// session (deliberately unfiltered), and before this the only way back
    /// was removing and re-adding the card, which lost its typed name. Runs
    /// the ordinary source assignment, so every gate still applies and a new
    /// session and inspection are minted (Joshua, 2026-09-28).
    func rereadStagedSource() {
        guard let src = sourcePath else { return }
        assign(src, as: .source)
    }

    /// Clear the staged source (Kimi K3 review F4 — deselection did not
    /// exist). Kills any in-flight inspection so its late result can't
    /// resurrect the cleared bench.
    func clearSource() {
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        inspectionProcess?.terminate()
        inspectionProcess = nil
        inspectionToken += 1
        let handedOff = sourcePath.map { handOffStagedVerdict(from: $0) } ?? false
        stopMonitoringSource()
        let previous = sourcePath
        if let previous, !handedOff { stopDestinationMonitoring(forSource: previous) }
        sourcePath = nil
        sourceAssignmentID = nil
        sourceChangedSinceVerification = false
        inspection = nil
        inspecting = false
        inspectionError = nil
        label = ""
        labelEditedByUser = false
        stagedSourceFileID = nil
        benchCollapsed = false
        // Whatever the old bench was refused for went with it.
        lastSetupError = nil
        releaseLooseSourceIfUnused(previous)
    }

    /// A filesystem event retires the current staging session immediately.
    /// The historical job card remains truthful about what it verified, but
    /// its rail echo, one-click eject, Dock-safe authority, and notification
    /// eject action can no longer speak for the now-changed source tree.
    private func startMonitoringSource(_ path: String) {
        let monitorID = sourceMonitorSession.begin()
        sourceMutationMonitor = SourceMutationMonitor(
            path: path, filter: .sourceJunk(root: path)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.sourceDidMutate(monitoredPath: path, monitorID: monitorID)
            }
        }
        if sourceMutationMonitor == nil { sourceMonitorSession.end() }
        sourceMutationMonitoringActive = sourceMutationMonitor != nil
        updateDockTile()
    }

    private func stopMonitoringSource() {
        // Reject already-queued callbacks before the C stream is torn down.
        // This matters when the replacement source mounts at the same path.
        sourceMonitorSession.end()
        sourceMutationRefreshTask?.cancel()
        sourceMutationRefreshTask = nil
        sourceMutationMonitor?.stop()
        sourceMutationMonitor = nil
        sourceMutationMonitoringActive = false
        updateDockTile()
    }

    private func sourceDidMutate(monitoredPath path: String, monitorID: UUID) {
        guard sourceMonitorSession.accepts(monitorID),
              sourcePath == path else { return }
        retireCurrentSourceAuthority(for: path)

        // The engine owns the active run and performs its own terminal source
        // stability scan. Avoid racing it with another inspect; the new UUID
        // still prevents that run from granting current-source eject authority.
        guard !jobs.contains(where: { $0.isRunning && $0.sourcePath == path }) else { return }

        // A camera or Finder operation commonly emits an event burst. Refresh
        // card metadata once the burst settles instead of spawning one engine
        // inspect per file.
        sourceMutationRefreshTask?.cancel()
        sourceMutationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.sourcePath == path,
                  !self.jobs.contains(where: { $0.isRunning && $0.sourcePath == path }) else { return }
            self.inspect(path)
        }
    }

    /// Idempotent within one dirty period: a burst may reach both the staged
    /// watcher and the running-job watcher, but authority needs retiring once.
    private func retireCurrentSourceAuthority(for path: String) {
        guard sourcePath == path else { return }
        stopDestinationMonitoring(forSource: path)
        if !sourceChangedSinceVerification {
            // Mint before any asynchronous work so every gate fails closed in
            // the same main-actor turn as the filesystem event.
            sourceAssignmentID = UUID()
            sourceChangedSinceVerification = true
        }
        retireSafeNotifications(for: path)
        objectWillChange.send()
        updateDockTile()
    }

    /// Staging can move to another card while this job is queued/running, so
    /// every job keeps its own recursive source watcher until terminal state.
    private func startJobSourceMonitoring(_ job: Job) -> Bool {
        let monitorID = UUID()
        let jobID = job.id
        let sourcePath = job.sourcePath
        guard let monitor = SourceMutationMonitor(
            path: job.sourcePath, filter: .sourceJunk(root: job.sourcePath),
            handler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.jobSourceDidMutate(jobID: jobID,
                                         sourcePath: sourcePath,
                                         monitorID: monitorID)
            }
        }) else { return false }
        jobSourceMonitors[jobID] = JobSourceMonitorRecord(
            monitorID: monitorID, monitor: monitor)
        return true
    }

    private func jobSourceDidMutate(jobID: UUID, sourcePath: String, monitorID: UUID) {
        guard let record = jobSourceMonitors[jobID],
              record.monitorID == monitorID,
              let job = jobs.first(where: { $0.id == jobID }),
              !job.sourceMutatedAfterStart else { return }

        job.noteSourceMutation()
        retireCurrentSourceAuthority(for: sourcePath)
        retireBatchSourceAuthority(for: sourcePath)
        objectWillChange.send()
        _ = persistJournal()

        if job.phase == .queued {
            queuedParams.removeValue(forKey: job.id)
            job.enforceSourceMutationFailure()
            finalizeTerminal(job)
        } else if let process = runningProcesses[job.id], process.isRunning {
            process.terminate()
        }
    }

    /// Returns true when the stream observed a mutation even if its UI callback
    /// was still queued. Remove the record first so late callbacks are ignored.
    private func stopJobSourceMonitoring(_ jobID: UUID) -> Bool {
        guard let record = jobSourceMonitors.removeValue(forKey: jobID) else { return false }
        return record.monitor.stop()
    }

    // MARK: destination currency (desktop QA round 3, R3-01)

    /// Post-terminal watchers on the card roots a SAFE verdict rests on. A
    /// verdict is current only while every one of its copies is still
    /// mounted and unchanged since the verdict settled; the watchers and
    /// `refreshVolumes` retire it otherwise. Keyed by job; they are dropped
    /// whenever the job can no longer be current (a later run, re-staging or
    /// clearing its card, a batch session ending, quit).
    private var jobDestinationMonitors: [UUID: [SourceMutationMonitor]] = [:]
    private var pendingDestinationNotifications: Set<UUID> = []

    private func destinationMonitoringSettled(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              jobDestinationMonitors[jobID] != nil else { return }
        let pending = !destinationWatchersReady(for: job) && job.destinationAuthorityWithdrawn == nil
        if job.destinationCheckPending != pending { job.destinationCheckPending = pending }
        objectWillChange.send()
        updateDockTile()
        if destinationWatchersReady(for: job), isCurrentSourceVerdict(job),
           pendingDestinationNotifications.remove(jobID) != nil {
            notify(job: job)
        }
    }

    /// True once every lane watcher for the job holds its baseline. The
    /// check suite waits on this before mutating a lane.
    func destinationWatchersReady(for job: Job) -> Bool {
        guard let monitors = jobDestinationMonitors[job.id] else { return false }
        return !monitors.isEmpty && monitors.allSatisfy { $0.isReady }
    }

    private func stopDestinationMonitoring(forSource path: String, except keep: UUID? = nil) {
        for job in jobs where job.sourcePath == path && job.id != keep {
            stopJobDestinationMonitoring(job.id)
        }
    }

    private func stopAllDestinationMonitoring() {
        for id in Array(jobDestinationMonitors.keys) { stopJobDestinationMonitoring(id) }
    }

    /// The card roots a verdict rests on: the engine's lane roots when the
    /// stream carried them, else the frozen plan's destinations plus label.
    func verdictLaneRoots(_ job: Job) -> [String] {
        if !job.laneRoots.isEmpty { return job.laneRoots }
        return job.destinations.map { ($0 as NSString).appendingPathComponent(job.label) }
    }

    /// Arm destination currency for a job that just settled SAFE. Package
    /// visibility so the check suite can drive the exact code path
    /// `finalizeTerminal` uses. Fails closed: a lane that cannot be watched
    /// withdraws authority rather than leaving an unwatched green verdict.
    @discardableResult
    func armDestinationAuthority(for job: Job) -> Bool {
        guard job.verdict == .safeToWipe,
              job.destinationAuthorityWithdrawn == nil,
              jobDestinationMonitors[job.id] == nil else { return false }
        let jobID = job.id
        job.destinationCheckPending = true
        guard job.filesTotal > 0, job.verifiedFileHashes.count == job.filesTotal,
              !verdictLaneRoots(job).isEmpty else {
            withdrawDestinationAuthority(job, reason: "verified file checksums are unavailable for destination monitoring")
            return false
        }
        if let plan = job.launchPlanSnapshot {
            let pinsHold = plan.rawRoots.count == plan.rootFileIDs.count
                && plan.rawRoots.count == plan.rootVolumeUUIDs.count
                && plan.rawRoots.enumerated().allSatisfy { i, path in
                    guard let pin = plan.rootFileIDs[i], Self.fileID(path) == pin else { return false }
                    return plan.rootVolumeUUIDs[i].map { Self.volumeUUID(path) == $0 } ?? true
                }
            guard pinsHold else {
                withdrawDestinationAuthority(job, reason: "a destination changed identity before its currency check")
                return false
            }
        }
        var monitors: [SourceMutationMonitor] = []
        for root in verdictLaneRoots(job) {
            guard FileManager.default.fileExists(atPath: root) else {
                for m in monitors { m.stop() }
                withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                             + "is not present after the verdict", root: root)
                return false
            }
            guard let monitor = SourceMutationMonitor(
                path: root, filter: .destinationJunk,
                judge: DestinationChangeJudge(root: root, expectedHashes: job.verifiedFileHashes),
                settled: { [weak self] in
                    Task { @MainActor [weak self] in self?.destinationMonitoringSettled(jobID: jobID) }
                },
                handler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.destinationDidChange(jobID: jobID, root: root)
                    }
                }) else {
                for m in monitors { m.stop() }
                withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                             + "could not be watched for changes", root: root)
                return false
            }
            monitors.append(monitor)
        }
        jobDestinationMonitors[jobID] = monitors
        return true
    }

    private func stopJobDestinationMonitoring(_ jobID: UUID) {
        pendingDestinationNotifications.remove(jobID)
        jobs.first(where: { $0.id == jobID })?.destinationCheckPending = false
        guard let monitors = jobDestinationMonitors.removeValue(forKey: jobID) else { return }
        for m in monitors { m.stop() }
    }

    private func destinationDidChange(jobID: UUID, root: String) {
        // Only a job still under watch may be retired by its watcher; a
        // stopped stream's late callback must not touch a superseded job.
        guard jobDestinationMonitors[jobID] != nil,
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        // An unmount usually reaches us here first, as a root-changed event.
        // Same withdrawal either way; only the wording differs.
        if Self.destinationDriveIsGone(root, mountedVolumePaths: Self.mountedVolumePaths()) {
            withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                         + "is no longer mounted", root: root, ejected: true)
            return
        }
        withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                     + "changed after verification or could no longer be checked", root: root)
    }

    /// Whether the drive holding `root` is gone (ejected or unplugged), as
    /// opposed to the lane folder vanishing or changing on a drive that is
    /// still mounted. Only a drive under /Volumes can be ejected; a missing
    /// folder anywhere else was deleted, which is a change. Decides wording
    /// only, never whether authority is withdrawn (Joshua, 2026-09-28).
    nonisolated static func destinationDriveIsGone(_ root: String,
                                                   mountedVolumePaths: [String]) -> Bool {
        let prefix = "/Volumes/"
        guard root.hasPrefix(prefix),
              let name = root.dropFirst(prefix.count).split(separator: "/").first
        else { return false }
        return !mountedVolumePaths.contains(prefix + name)
    }

    private static func mountedVolumePaths() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                               options: []) ?? []).map(\.path)
    }

    private func withdrawDestinationAuthority(_ job: Job, reason: String, root: String? = nil,
                                              ejected: Bool = false) {
        stopJobDestinationMonitoring(job.id)
        guard job.withdrawDestinationAuthority(reason, root: root, ejected: ejected) else { return }
        retireSafeNotifications(for: job.sourcePath)
        _ = persistJournal()   // the warning line travels with the record
        objectWillChange.send()
        updateDockTile()
    }

    /// Called from every volume refresh: an unmounted destination is the
    /// cable-pull case. The FSEvents root-changed event usually lands first;
    /// this is the second line for the notification path.
    private func retireVerdictsWithMissingDestinations() {
        let mounted = Self.mountedVolumePaths()
        for job in jobs where jobDestinationMonitors[job.id] != nil {
            for root in verdictLaneRoots(job)
            where !FileManager.default.fileExists(atPath: root) {
                if Self.destinationDriveIsGone(root, mountedVolumePaths: mounted) {
                    withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                                 + "is no longer mounted", root: root, ejected: true)
                } else {
                    // The drive is still here but the lane folder is not:
                    // deleted or moved, which is a change, not an ejection.
                    withdrawDestinationAuthority(job, reason: "destination \(volumeRelativePath(root)) "
                                                 + "is missing after verification", root: root)
                }
                break
            }
        }
    }

    // MARK: two-sided assignment

    /// Published SNAPSHOTS of the candidate lists, recomputed only when
    /// volumes or staging actually change (property observers on volumes /
    /// sourcePath / destinationPaths / folderEndpoints). Views read THESE:
    /// the computed lists below call `pathsOverlap`, which resolves symlinks
    /// on disk, and a candidate list computed from a view body put that I/O
    /// on the main render loop with a wedged-mount hazard (codex v0.4.x
    /// review F5 — the same class as Ox F3's statfs-in-body).
    @Published private(set) var sourceCandidatesSnapshot: [Endpoint] = []
    @Published private(set) var destinationCandidatesSnapshot: [Endpoint] = []

    private func observeBatchCandidates() {
        batchCandidatesSubscription = batchStagingModel.$candidates.sink { [weak self] candidates in
            // Published sends before assignment. Use the incoming list so a
            // staged card disappears immediately and removal restores it.
            self?.refreshCandidateSnapshots(batchPaths: candidates.map(\.path))
        }
    }

    private var stagedSourcePaths: [String] {
        (sourcePath.map { [$0] } ?? []) + batchStagingModel.candidates.map(\.path)
    }

    private func candidateEndpoints(batchPaths: [String], role: EndpointRole) -> [Endpoint] {
        let sources = (sourcePath.map { [$0] } ?? []) + batchPaths
        return allEndpoints.filter { endpoint in
            !sources.contains { role == .source ? endpoint.path == $0 : pathsOverlap(endpoint.path, $0) }
                && !destinationPaths.contains { pathsOverlap(endpoint.path, $0) }
        }
    }

    private func refreshCandidateSnapshots(batchPaths: [String]? = nil) {
        let paths = batchPaths ?? batchStagingModel.candidates.map(\.path)
        sourceCandidatesSnapshot = candidateEndpoints(batchPaths: paths, role: .source)
        destinationCandidatesSnapshot = candidateEndpoints(batchPaths: paths, role: .destination)
    }

    /// Everything eligible to be offered as a source. Off the render path —
    /// views take `sourceCandidatesSnapshot`.
    var sourceCandidates: [Endpoint] {
        candidateEndpoints(batchPaths: batchStagingModel.candidates.map(\.path), role: .source)
    }

    /// Everything eligible to be offered as a destination. Off the render
    /// path — views take `destinationCandidatesSnapshot`.
    var destinationCandidates: [Endpoint] {
        candidateEndpoints(batchPaths: batchStagingModel.candidates.map(\.path), role: .destination)
    }

    private var allEndpoints: [Endpoint] {
        volumes.map { Endpoint(path: $0.path, kind: .volume) }
            + folderEndpoints.filter { fe in !volumes.contains { $0.path == fe.path } }
    }

    func endpointDisplayName(_ path: String) -> String {
        if let exact = volumes.first(where: { $0.path == path }) {
            // Two cards from one camera both mount as "NO NAME"; macOS tells
            // them apart only by the mount folder ("/Volumes/NO NAME 1"), so
            // the rows must too (Joshua, 2026-09-28). In-memory list, no I/O.
            let folder = (path as NSString).lastPathComponent
            if folder != exact.name,
               volumes.contains(where: { $0.path != path && $0.name == exact.name }) {
                return "\(exact.name) (\(folder))"
            }
            return exact.name
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: continuation proposal (2026-08-26 facelift)

    /// The one-click continuation offer for a KNOWN card, shown by the bench
    /// in place of manual staging. Everything here is derived from engine
    /// facts, never inferred: the card registry's recorded card-root folders
    /// (`inspection.previousDestinations`, engine `identity.record_offload`),
    /// intersected with the 30s `volumes` snapshot. Pure string work over
    /// published state — NSString path ops, never `URL(fileURLWithPath:)`,
    /// which stats the filesystem; no statfs, no FileManager, no symlink
    /// resolution in a computed var a body reads (Ox review F3). The full
    /// assignment and start gates still run on click; this only PROPOSES.
    struct ContinuationProposal {
        /// What Continue stages: anchor roots, or mirror folders ABOVE the
        /// rendered Organize path — NEVER the recorded card-root parent
        /// itself, because that parent already embeds the rendered folder
        /// template and buildPlan renders the template again at Start
        /// (facelift review, CRITICAL 1: staging the parent double-nested
        /// the tree — /Raws/Raws/CARD_A — and silently re-copied the card).
        let stagingTargets: [String]
        /// Containing volume root per staging target, same order.
        let anchors: [String]
        /// The one mirrored suffix under every anchor ("" = volume root).
        let relativePath: String
        /// Previously used card roots that are NOT part of this proposal
        /// (unmounted, or off-volume) — stated on the banner, never
        /// silently dropped.
        let unreachablePriors: Int
        /// The Organize render the tail match succeeded against. Continue
        /// FREEZES this into the launch (`continuationFreeze`)
        /// so Start cannot re-render it differently — a {JobID} token draws
        /// a fresh ID and a {Date} template can roll past midnight between
        /// the match and the click, and either would write a folder that is
        /// not the one the banner promised (codex v0.4.x review, F1).
        let organizationRender: String
    }

    /// Everything the Continue click promised, frozen together. A bare
    /// render string leaked: a mirrored-folder edit after a blocked Continue
    /// left the old render armed for a DIFFERENT layout (codex verify F3),
    /// so buildPlan consumes the render only when EVERY frozen field still
    /// matches the plan it is building.
    struct ContinuationFreeze {
        let sourcePath: String
        let anchors: [String]
        let relativePath: String
        let label: String
        let organizationRender: String
    }

    /// One-shot: set by continueKnownCard, consumed by the next matching
    /// buildPlan, invalidated by any staging or label change (every
    /// stagedRetryPlan-invalidation site, the label observer, and the
    /// mirrored-folder observer). Never survives into an unrelated start.
    private(set) var continuationFreeze: ContinuationFreeze?

    /// The Organize-template render the plan builder will produce at Start,
    /// computed with the same context (jobID stays "PREVIEW", exactly like
    /// the destination card's preflight — a {JobID} template therefore never
    /// matches a recorded path and the proposal correctly refuses).
    private var proposalOrganizationRender: String {
        let d = UserDefaults.standard
        let context = TemplateContext(
            project: d.string(forKey: Pref.projectName) ?? "",
            volumeName: (sourcePath as NSString?)?.lastPathComponent ?? "",
            cardLabel: label,
            date: Date(),
            cameraFormat: (inspection?.formatName == "?" ? "" : (inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: inspection?.reelName ?? "",
            jobID: "PREVIEW"
        )
        return TemplateRenderer.render(
            d.string(forKey: Pref.folderTemplate) ?? "", context: context)
    }

    /// nil unless: the card is known, nothing is staged as a destination yet,
    /// at least one previously used card root (whose folder name matches the
    /// CURRent continuation key) sits on a mounted volume, every reachable
    /// prior agrees on one mirrored suffix, and today's Organize render
    /// reproduces each recorded path's tail exactly. Any reachable prior the
    /// template cannot reproduce (template changed since the recorded run, a
    /// {JobID} token, a {Date} token on a different day) fails the WHOLE
    /// proposal — the bench falls back to manual staging rather than ever
    /// proposing a folder that is not literally the card's existing one.
    var continuationProposal: ContinuationProposal? {
        guard let ins = inspection, ins.known,
              destinationPaths.isEmpty,
              !label.isEmpty,
              !ins.previousDestinations.isEmpty else { return nil }
        // Only roots that are literally this card's current folder name —
        // a stale root from an earlier label must not resurrect that label.
        let matching = ins.previousDestinations.filter {
            ($0 as NSString).lastPathComponent == label
        }
        guard !matching.isEmpty else { return nil }
        let orgRender = proposalOrganizationRender
        var stagingTargets: [String] = []
        var anchors: [String] = []
        var rels = Set<String>()
        var unreachable = 0
        for root in matching {
            guard let vol = volumes.first(where: {
                root == $0.path || root.hasPrefix($0.path + "/")
            }) else { unreachable += 1; continue }
            let parent = (root as NSString).deletingLastPathComponent
            guard parent == vol.path || parent.hasPrefix(vol.path + "/") else {
                unreachable += 1; continue
            }
            // Strip the rendered Organize tail: buildPlan will re-create it
            // at Start, so staging must stop ABOVE it. The stripped target
            // must still sit at-or-inside its anchor — a render that eats
            // into the anchor path itself is a mismatch, not a target.
            let target: String
            if orgRender.isEmpty {
                target = parent
            } else if parent.hasSuffix("/" + orgRender) {
                target = String(parent.dropLast(orgRender.count + 1))
            } else {
                return nil   // template cannot reproduce this recorded path
            }
            guard target == vol.path || target.hasPrefix(vol.path + "/") else {
                return nil
            }
            let rel = target == vol.path
                ? "" : String(target.dropFirst(vol.path.count + 1))
            // EVERY reachable prior votes on the mirrored suffix (facelift
            // review: inserting after the dedupe let same-drive conflicts
            // slip past the one-suffix guard by registry order)…
            rels.insert(rel)
            // …then one target per physical anchor: a card that historically
            // used two folders on one drive is one copy, not two — and its
            // conflicting suffixes now refuse the proposal above.
            guard !anchors.contains(vol.path) else { continue }
            stagingTargets.append(target)
            anchors.append(vol.path)
        }
        guard !stagingTargets.isEmpty, rels.count == 1 else { return nil }
        return ContinuationProposal(stagingTargets: stagingTargets,
                                    anchors: anchors,
                                    relativePath: rels.first ?? "",
                                    unreachablePriors: unreachable,
                                    organizationRender: orgRender)
    }

    /// The banner's Continue button: stage the proposal, then start. Every
    /// path runs the ordinary assignment gate and `startOrExplain` — a block
    /// explains itself exactly like a manual click (never a silently dead
    /// control), and nothing weaker than the normal start can launch here.
    func continueKnownCard() {
        guard let proposal = continuationProposal else { return }
        for target in proposal.stagingTargets {
            guard assign(target, as: .destination) else { return }
        }
        // AFTER the assigns (which clear it, like every staging mutation):
        // freeze the WHOLE promise — source, anchors, mirrored suffix,
        // label, render — so Start writes the folder the banner named and
        // nothing else can inherit the render (codex F1 + verify F3).
        guard let src = sourcePath else { return }
        continuationFreeze = ContinuationFreeze(
            sourcePath: src,
            anchors: proposal.anchors,
            relativePath: proposal.relativePath,
            label: label,
            organizationRender: proposal.organizationRender)
        startOrExplain()
        // The freeze must not outlive this click: a successful start consumed
        // it synchronously above, and on ANY blocked or failed outcome it is
        // disarmed here — so no later manual Start can consume a render the
        // rail preview never showed (codex verify round 3, NEW 2).
        continuationFreeze = nil
    }

    /// Overlap runs both ways: a drive dropped as a destination may CONTAIN
    /// the source, not only sit inside it, and the old wording ("a destination
    /// inside the source") described the wrong case (Joshua, 2026-09-28).
    static let sourceOverlapReason = "That folder overlaps the source (one is inside "
        + "the other) — the copy would end up copying itself."

    /// nil when the assignment is legal; otherwise the reason it is not —
    /// the startOrExplain doctrine extended to assignment: never a silently
    /// dead control (Opus workbench spec §2.5).
    func assignmentBlockedReason(_ path: String, as role: EndpointRole) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            return "Only an existing folder or mounted volume can be assigned"
        }
        if jobs.contains(where: { $0.isRunning &&
            ([$0.sourcePath] + $0.destinations).contains(where: { pathsOverlap($0, path) }) }) {
            return "\(endpointDisplayName(path)) is being written by a running transfer — "
                 + "wait for it to finish before changing its role"
        }
        if role == .destination, stagedSourcePaths.contains(where: { pathsOverlap(path, $0) }) {
            return Self.sourceOverlapReason
        }
        if role == .source, destinationPaths.contains(where: { pathsOverlap($0, path) }) {
            return "\(endpointDisplayName(path)) is already a destination for this card"
        }
        return nil
    }

    @discardableResult
    func assign(_ rawPath: String, as role: EndpointRole) -> Bool {
        // Standardize at INGRESS (click-time; I/O is fine here): a dropped
        // URL's `.path` can carry repeated slashes or "." segments, which
        // the lexical containment helpers would miscompare and journal
        // validation would refuse — disabling journal writes for the whole
        // process (codex verify round 3, NEW 3).
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if let reason = assignmentBlockedReason(path, as: role) {
            lastSetupError = reason
            return false
        }
        lastSetupError = nil
        // Finder drops and Open-panel picks share this path. Any chosen
        // subfolder (including one under /Volumes) must remain in AVAILABLE
        // after it is unassigned; only exact mounted-volume roots are already
        // represented by `volumes`.
        if !volumes.contains(where: { $0.path == path }),
           !folderEndpoints.contains(where: { $0.path == path }) {
            folderEndpoints.append(Endpoint(path: path, kind: .folder))
        }
        switch role {
        case .source: setSource(path)
        case .destination:
            if let volume = containingVolume(for: path), path != volume.path {
                return setMirroredDestinationFolder(path, anchor: volume.path)
            }
            if !destinationPaths.contains(path) { toggleDestination(path) }
        }
        return true
    }

    /// A multi-item DROP on the destinations rail, committed all-or-nothing.
    /// One-at-a-time assigns were wrong twice over (codex v0.4.x review,
    /// F3): each nested folder REPLACES the one shared mirrored suffix, so
    /// dropping /A/Foo + /B/Bar silently retargeted both anchors at Bar; and
    /// a later success cleared the earlier item's refusal from
    /// lastSetupError. Validate every item first — including the symlink
    /// gates setMirroredDestinationFolder would apply — refuse the whole
    /// drop with the first reason if anything fails, and commit only a
    /// selection the shared-suffix model can actually represent.
    /// Ingress standardization for DROPPED paths, shared by every drop entry
    /// point: one canonical spelling per item, order-preserving dedupe — a
    /// noncanonical spelling of a volume root must never survive to endpoint
    /// identity (codex verify round 4: `/Volumes//BACKUP/.` entered
    /// folderEndpoints as a second logical endpoint for a mounted volume).
    static func standardizedDropPaths(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in raw {
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(std).inserted { out.append(std) }
        }
        return out
    }

    /// A card dragged from one rail to the other, or back onto the shelf, is
    /// changing role, not colliding with itself. Before a drop is gated, the
    /// exact staged paths in the drop (never a folder inside one) leave the
    /// roles they hold: `except` names the role the drop is moving INTO, so
    /// a drop on the destinations rail releases source and batch roles, a
    /// drop on the sources rail releases destination roles, and nil (the
    /// shelf) releases everything. A path a running transfer is using keeps
    /// its role; the gate after this refuses it with the running reason.
    /// Joshua, 2026-10-05: dragging the staged card to the other rail was
    /// refused as "overlaps the source", and nothing took a drag back.
    @discardableResult
    func releaseStaged(_ rawPaths: [String], except keep: EndpointRole? = nil) -> Bool {
        let paths = Self.standardizedDropPaths(rawPaths)
        var released = false
        for path in paths {
            let busy = jobs.contains { $0.isRunning &&
                ([$0.sourcePath] + $0.destinations).contains(where: { pathsOverlap($0, path) }) }
            if busy { continue }
            if keep != .source {
                if sourcePath == path {
                    clearSource()
                    released = true
                }
                if let candidate = batchStagingModel.candidates.first(where: { $0.path == path }) {
                    batchStagingModel.removeCandidate(id: candidate.id, appModel: self)
                    releaseLooseSourceIfUnused(path)
                    released = true
                }
            }
            if keep != .destination, destinationPaths.contains(path) {
                unassignDestination(path)
                released = true
            }
        }
        return released
    }

    @discardableResult
    func assignDroppedDestinations(_ rawPaths: [String]) -> Bool {
        let paths = Self.standardizedDropPaths(rawPaths)
        guard !paths.isEmpty else { return false }
        releaseStaged(paths, except: .destination)
        var nestedRels = Set<String>()
        var nestedPaths: [String] = []
        var plainFolders: [String] = []
        var anchors: [String] = []
        for path in paths {
            if let reason = assignmentBlockedReason(path, as: .destination) {
                lastSetupError = reason
                return false
            }
            guard let vol = containingVolume(for: path) else {
                // A folder that is not on a /Volumes drive (the boot disk, a
                // network share) is its own anchor, exactly as the Choose
                // Folder path and single-item assign() already treat it.
                // Only the drop path refused these (Joshua, 2026-09-15).
                plainFolders.append(path)
                if !anchors.contains(path) { anchors.append(path) }
                continue
            }
            if path != vol.path {
                // The mirrored-folder symlink gates, run during VALIDATION —
                // the commit below calls nothing fallible.
                let standard = URL(fileURLWithPath: path).standardizedFileURL.path
                let resolved = (path as NSString).resolvingSymlinksInPath
                let anchorResolved = (vol.path as NSString).resolvingSymlinksInPath
                guard resolved == standard,
                      resolved == anchorResolved || resolved.hasPrefix(anchorResolved + "/"),
                      let rel = DestinationFolderProjection.relativePath(
                          selected: path, under: vol.path) else {
                    lastSetupError = "That folder uses a symlink — choose the real folder so the same path can be mirrored on every drive"
                    return false
                }
                nestedRels.insert(rel)
                nestedPaths.append(path)
            }
            if !anchors.contains(vol.path) { anchors.append(vol.path) }
        }
        guard nestedRels.count <= 1 else {
            lastSetupError = "Dropped folders sit at different paths on their drives — "
                + "destinations share ONE mirrored folder. Drop drive roots, or "
                + "folders with the same path on each drive."
            return false
        }
        // Publish ONCE from the validated values (codex verify F4): the old
        // commit re-ran per-item assign(), whose gates could fail on a
        // filesystem change between validation and commit and leave a
        // partial selection behind a success return. Nothing below can fail.
        stagedRetryPlan = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        continuationFreeze = nil
        for folder in nestedPaths + plainFolders
        where !folderEndpoints.contains(where: { $0.path == folder }) {
            folderEndpoints.append(Endpoint(path: folder, kind: .folder))
        }
        var roots = destinationPaths
        for anchor in anchors where !roots.contains(anchor) {
            // One anchor per physical tree, same as the single-item path.
            roots.removeAll {
                pathIsAtOrInsideLexically($0, root: anchor)
                    || pathIsAtOrInsideLexically(anchor, root: $0)
            }
            roots.append(anchor)
        }
        destinationPaths = roots
        if let rel = nestedRels.first { destinationFolderRelativePath = rel }
        rememberCurrentIngestDestinations()
        lastSetupError = nil
        return true
    }

    func unassignDestination(_ path: String) {
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        destinationPaths.removeAll { $0 == path }
        if destinationPaths.isEmpty { destinationFolderRelativePath = "" }
        rememberCurrentIngestDestinations()
        // Removing a destination is the usual fix for the refusal on screen
        // (an overlap, a full drive); a stale one reads as a live problem.
        lastSetupError = nil
    }

    func toggleDestination(_ path: String) {
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        if destinationPaths.contains(path) {
            destinationPaths.removeAll { $0 == path }
            if destinationPaths.isEmpty { destinationFolderRelativePath = "" }
            rememberCurrentIngestDestinations()
            lastSetupError = nil
        } else if let src = sourcePath, pathsOverlap(path, src) {
            lastSetupError = Self.sourceOverlapReason
        } else if !destinationPaths.contains(where: { pathsOverlap($0, path) }) {
            destinationPaths.append(path)
            rememberCurrentIngestDestinations()
        }
    }

    /// True when one path contains the other (or they are the same).
    /// Symlinks are resolved: an interlock that compares unresolved text can
    /// clear a volume a job is actually writing through a link.
    private func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let ra = (URL(fileURLWithPath: a).standardizedFileURL.path as NSString).resolvingSymlinksInPath
        let rb = (URL(fileURLWithPath: b).standardizedFileURL.path as NSString).resolvingSymlinksInPath
        return ra == rb || ra.hasPrefix(rb + "/") || rb.hasPrefix(ra + "/")
    }

    func chooseFolder(as role: String) {
        chooseFolder(inside: nil, as: role == "source" ? .source : .destination)
    }

    /// ⇧⌘O and the destination card's folder button: pick the mirrored
    /// folder inside a staged destination drive. It used to live only in the
    /// card's right-click menu, so a drive dragged onto the destination rail
    /// had no visible way to choose a folder on it (Joshua, 2026-09-28).
    /// With one staged drive the picker opens inside it; with several it is
    /// unbounded, and the chosen folder's own drive anchors the mirror.
    func chooseDestinationFolder(on drive: String? = nil) {
        var anchor = drive
        if anchor == nil {
            var drives: [String] = []
            for path in destinationPaths {
                if let volume = containingVolume(for: path), !drives.contains(volume.path) {
                    drives.append(volume.path)
                }
            }
            if drives.count == 1 { anchor = drives[0] }
        }
        chooseFolder(inside: anchor, as: .destination)
    }

    /// First-class nested-folder picker for both rails. When opened from a
    /// drive row, the result must remain inside that drive. A destination
    /// choice becomes the shared mirrored folder; a source choice is the
    /// exact subtree the engine will inspect and offload.
    func chooseFolder(inside boundary: String?, as role: EndpointRole) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = role == .destination
        panel.directoryURL = boundary.map { URL(fileURLWithPath: $0) }
        panel.prompt = role == .source ? "Use as Source" : "Mirror to Destinations"
        if panel.runModal() == .OK, let path = panel.url?.path {
            if let boundary,
               DestinationFolderProjection.relativePath(selected: path, under: boundary) == nil {
                lastSetupError = "Choose a folder inside \(endpointDisplayName(boundary))"
                return
            }
            if role == .destination,
               let anchor = boundary ?? containingVolume(for: path)?.path {
                _ = setMirroredDestinationFolder(path, anchor: anchor)
            } else {
                _ = assign(path, as: role)
            }
        }
    }

    /// Set/replace the shared destination folder from a real folder on one
    /// drive. Only the chosen folder must already exist. Peer folders on all
    /// other destinations are planned now and created atomically at launch.
    @discardableResult
    private func setMirroredDestinationFolder(_ selected: String, anchor: String) -> Bool {
        guard let relative = DestinationFolderProjection.relativePath(
            selected: selected, under: anchor) else {
            lastSetupError = "Choose a folder inside \(endpointDisplayName(anchor))"
            return false
        }
        // Refuse symlink redirection at selection time, before the displayed
        // relative path can claim one drive while resolving onto another.
        let selectedStandard = URL(fileURLWithPath: selected).standardizedFileURL.path
        let selectedResolved = (selected as NSString).resolvingSymlinksInPath
        let anchorResolved = (anchor as NSString).resolvingSymlinksInPath
        guard selectedResolved == selectedStandard else {
            lastSetupError = "That folder uses a symlink — choose the real folder so the same path can be mirrored on every drive"
            return false
        }
        guard selectedResolved == anchorResolved
                || selectedResolved.hasPrefix(anchorResolved + "/") else {
            lastSetupError = "That folder leaves its drive — choose a real folder on the destination drive"
            return false
        }
        if let reason = assignmentBlockedReason(selected, as: .destination) {
            lastSetupError = reason
            return false
        }
        if !volumes.contains(where: { $0.path == selected }),
           !folderEndpoints.contains(where: { $0.path == selected }) {
            folderEndpoints.append(Endpoint(path: selected, kind: .folder))
        }
        if !destinationPaths.contains(anchor) {
            // One anchor per physical tree: replacing a nested folder on an
            // already-selected drive changes the shared suffix, not the copy
            // count or safety badge.
            destinationPaths.removeAll { pathsOverlap($0, anchor) }
            destinationPaths.append(anchor)
        }
        destinationFolderRelativePath = relative
        lastSetupError = nil
        rememberCurrentIngestDestinations()
        return true
    }

    func clearMirroredDestinationFolder() {
        destinationFolderRelativePath = ""
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
        rememberCurrentIngestDestinations()
        lastSetupError = nil
    }

    /// Preset application has already passed the live endpoint and relative
    /// path validators. Keep the private setter protected for ordinary UI
    /// callers while exposing this narrow staging-only handoff to the preset
    /// extension; it never creates folders or starts a job.
    func installPresetDestinationSelection(anchors: [String],
                                           mirroredFolder: String) {
        continuationFreeze = nil
        destinationPaths = anchors
        destinationFolderRelativePath = mirroredFolder
        rememberCurrentIngestDestinations()
    }

    /// Stage (never launch) a fresh attempt from a historical job. The saved
    /// raw roots and identity pins are checked now, and again at Start; a
    /// missing/replaced card or destination cannot be converted into a retry
    /// that looks like the original proof.
    @discardableResult
    func stageRetry(_ historical: Job) -> Bool {
        // Never leave an older retry armed when a new staging request is
        // refused; otherwise a later Start could launch the wrong card.
        clearStagedRetry()
        guard !historical.isRunning else {
            lastSetupError = "Stop the running transfer before staging a retry"
            return false
        }
        guard let saved = historical.launchPlanSnapshot else {
            lastSetupError = "This older job has no frozen plan to retry safely"
            return false
        }
        let plan = launchPlan(saved)
        guard LaunchPlanValidation.isStructurallySafe(saved),
              validateRetryPlan(plan) else {
            if lastSetupError == nil {
                lastSetupError = "The saved retry flags or invocation are unsafe — retry refused"
            }
            return false
        }
        if jobs.contains(where: { other in
            other.isRunning && (
                pathsOverlap(other.sourcePath, plan.src)
                || other.destinations.contains { destination in
                    pathsOverlap(destination, plan.src)
                        || plan.rawRoots.contains { root in pathsOverlap(root, destination) }
                }
            )
        }) {
            lastSetupError = "A transfer is using this source or destination — wait for it to finish"
            return false
        }
        // setSource deliberately mints a new assignment and starts a fresh
        // inspect. The retry context is installed afterward so its label and
        // rendered organization folder win when that inspect returns.
        setSource(plan.src)
        destinationPaths = plan.rawRoots
        destinationFolderRelativePath = plan.mirroredFolder
        rememberCurrentIngestDestinations()
        label = plan.cardLabel
        // The retry's frozen key is the name now, not an earlier typed one.
        labelEditedByUser = false
        stagedRetryPlan = plan
        retryUsesCurrentSettings = true
        stagedRetryJobID = historical.id
        stagedRetryLabel = plan.cardLabel
        benchCollapsed = false
        lastSetupError = nil
        objectWillChange.send()
        return true
    }

    private func validateRetryPlan(_ plan: LaunchPlan) -> Bool {
        let fm = FileManager.default
        var sourceDirectory: ObjCBool = false
        guard fm.fileExists(atPath: plan.src, isDirectory: &sourceDirectory),
              sourceDirectory.boolValue else {
            lastSetupError = "The original source is not mounted — retry was not staged"
            return false
        }
        guard plan.rawRoots.count == plan.rootFileIDs.count,
              plan.rawRoots.count == plan.rootVolumeUUIDs.count else {
            lastSetupError = "The saved destination identity record is incomplete — retry refused"
            return false
        }
        func identityHolds(_ path: String, uuid: String?, fid: String?) -> Bool {
            guard fm.fileExists(atPath: path) else { return false }
            if let uuid, Self.volumeUUID(path) != uuid { return false }
            guard let fid else { return false }
            return Self.fileID(path) == fid
        }
        guard identityHolds(plan.src, uuid: plan.srcVolumeUUID, fid: plan.srcFileID) else {
            lastSetupError = "The original source was replaced or remounted — retry refused"
            return false
        }
        for (index, root) in plan.rawRoots.enumerated() {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  identityHolds(root, uuid: plan.rootVolumeUUIDs[index],
                                fid: plan.rootFileIDs[index]) else {
                lastSetupError = "A saved destination was replaced, removed, or remounted — retry refused"
                return false
            }
        }
        for (index, root) in plan.rawRoots.enumerated() {
            let resolvedRoot = (root as NSString).resolvingSymlinksInPath
            guard !pathsOverlap(plan.src, root) else {
                lastSetupError = "The saved source and destination overlap — retry refused"
                return false
            }
            let dest = plan.dests.indices.contains(index) ? plan.dests[index] : ""
            guard !dest.isEmpty else {
                lastSetupError = "The saved rendered destination is incomplete — retry refused"
                return false
            }
            if fm.fileExists(atPath: dest) {
                let resolved = (dest as NSString).resolvingSymlinksInPath
                guard resolved == dest,
                      resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
                    lastSetupError = "The saved destination leaves its drive or uses a symlink — retry refused"
                    return false
                }
            } else {
                // The rendered peer folder may legitimately be absent. Its
                // parent/root identity is what is pinned and it is created
                // only after the operator presses Start.
                let projected = DestinationFolderProjection.project(
                    root: root, mirroredFolder: plan.mirroredFolder,
                    organizationFolder: plan.organizationFolder)
                guard projected == dest,
                      projected == root || projected.hasPrefix(root + "/") else {
                    lastSetupError = "The saved rendered destination escapes its drive — retry refused"
                    return false
                }
            }
        }
        return true
    }

    private func clearStagedRetry() {
        stagedRetryPlan = nil
        continuationFreeze = nil
        stagedRetryJobID = nil
        stagedRetryLabel = nil
    }

    var retrySettingsSummary: String {
        guard let plan = stagedRetryPlan else { return "" }
        let d = UserDefaults.standard
        let fast = retryUsesCurrentSettings ? d.string(forKey: Pref.verifyMode) == "fast" : plan.args.contains("--fast")
        let reread = retryUsesCurrentSettings ? d.object(forKey: Pref.sourceReread) == nil || d.bool(forKey: Pref.sourceReread) : !plan.args.contains("--no-source-verify")
        let existing = retryUsesCurrentSettings ? d.bool(forKey: Pref.reverifyExisting) : plan.args.contains("--reverify-existing")
        return "\(fast ? "Size check only" : "Full verification") · source reread \(reread ? "on" : "off") · existing copies \(existing ? "re-read" : "trusted")"
    }

    /// Validate the saved invocation before applying the visible settings
    /// choice. Destination identity is checked again at Start.
    func currentEnginePlanForRetry(_ frozen: LaunchPlan) -> LaunchPlan? {
        guard LaunchPlanValidation.isStructurallySafe(journalPlan(frozen)) else {
            lastSetupError = "The saved retry flags or invocation are unsafe — retry refused"
            return nil
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: engineRoot, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastSetupError = "The current engine folder is missing — retry refused"
            return nil
        }
        guard fm.fileExists(atPath: enginePython, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fm.attributesOfItem(atPath: enginePython),
              let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o111 != 0 else {
            lastSetupError = "The current engine Python is missing or not executable — retry refused"
            return nil
        }
        var retryArguments = frozen.args
        if retryUsesCurrentSettings {
            switch buildPlan(src: frozen.src, rawRoots: frozen.rawRoots, cardLabel: frozen.cardLabel) {
            case .failure(let error): lastSetupError = error.message; return nil
            case .success(let fresh):
                guard fresh.dests == frozen.dests else {
                    lastSetupError = "Retry destination changed. Reselect the folders."; return nil
                }
                retryArguments = fresh.args
            }
        }
        return LaunchPlan(src: frozen.src, rawRoots: frozen.rawRoots,
                          dests: frozen.dests, args: retryArguments,
                          cardLabel: frozen.cardLabel,
                          mirroredFolder: frozen.mirroredFolder,
                          organizationFolder: frozen.organizationFolder,
                          enginePython: enginePython, engineRoot: engineRoot,
                          srcVolumeUUID: frozen.srcVolumeUUID,
                          rootVolumeUUIDs: frozen.rootVolumeUUIDs,
                          srcFileID: frozen.srcFileID,
                          rootFileIDs: frozen.rootFileIDs)
    }

    /// Stop is fail-closed: a running process is allowed to drain its pipe
    /// termination path, while its journal record is already marked as an
    /// incomplete transfer. A queued stop settles immediately and the normal
    /// queue advancement can continue to the next operator-staged job.
    func stop(job: Job) {
        guard job.isRunning else { return }
        if job.phase == .queued {
            queuedParams.removeValue(forKey: job.id)
            _ = stopJobSourceMonitoring(job.id)
            // Recorded like a running Stop so the ending stays quiet (no
            // failure beeper or alert); the FAILED record is unchanged.
            job.stopRequested = true
            job.phase = .failed
            job.fullyVerified = false
            job.safeToWipe = false
            job.error("operator stopped this queued transfer — "
                      + Job.Verdict.failed.displayLine)
            finalizeTerminal(job)
            return
        }
        guard !job.stopRequested else { return }
        job.stopRequested = true
        job.fullyVerified = false
        job.safeToWipe = false
        job.error("operator stopped this transfer — copy is incomplete; "
                  + Job.Verdict.failed.displayLine)
        _ = persistJournal()
        guard let process = runningProcesses[job.id], process.isRunning else {
            job.phase = .failed
            finalizeTerminal(job)
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        let jobID = job.id
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let process, process.isRunning,
                  self.runningProcesses[jobID] === process,
                  process.processIdentifier == pid else { return }
            _ = kill(pid, SIGKILL)
        }
    }

    /// A queued record may be removed before it has touched media. It is a
    /// journal edit, not a silent in-memory disappearance; active transfers
    /// are never removable by this method.
    func removeQueued(job: Job) {
        guard job.phase == .queued else {
            lastSetupError = "Only a queued transfer can be removed from the queue"
            return
        }
        queuedParams.removeValue(forKey: job.id)
        _ = stopJobSourceMonitoring(job.id)
        jobs.removeAll { $0.id == job.id }
        _ = persistJournal()
        updateSleepAssertion()
        updateDockTile()
        startNextQueued()
    }

    // MARK: - Queue controls

    @Published var isDispatchPaused = false

    var queuedJobs: [Job] {
        jobs.filter { $0.phase == .queued }
    }

    func queuePosition(of job: Job) -> Int? {
        guard job.phase == .queued else { return nil }
        guard let idx = queuedJobs.firstIndex(where: { $0.id == job.id }) else { return nil }
        return idx + 1
    }

    func canMoveQueuedEarlier(job: Job) -> Bool {
        guard let pos = queuePosition(of: job) else { return false }
        return pos > 1
    }

    func canMoveQueuedLater(job: Job) -> Bool {
        guard let pos = queuePosition(of: job) else { return false }
        return pos < queuedJobs.count
    }

    @discardableResult
    func moveQueuedEarlier(job: Job) -> Bool {
        guard job.phase == .queued else { return false }
        let queued = jobs.enumerated().filter { $0.element.phase == .queued }
        guard let currentQueueIndex = queued.firstIndex(where: { $0.element.id == job.id }),
              currentQueueIndex > 0 else { return false }
        let currentJobsIndex = queued[currentQueueIndex].offset
        let targetJobsIndex = queued[currentQueueIndex - 1].offset
        jobs.swapAt(currentJobsIndex, targetJobsIndex)
        _ = persistJournal()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func moveQueuedLater(job: Job) -> Bool {
        guard job.phase == .queued else { return false }
        let queued = jobs.enumerated().filter { $0.element.phase == .queued }
        guard let currentQueueIndex = queued.firstIndex(where: { $0.element.id == job.id }),
              currentQueueIndex < queued.count - 1 else { return false }
        let currentJobsIndex = queued[currentQueueIndex].offset
        let targetJobsIndex = queued[currentQueueIndex + 1].offset
        jobs.swapAt(currentJobsIndex, targetJobsIndex)
        _ = persistJournal()
        objectWillChange.send()
        return true
    }

    func pauseDispatch() {
        guard !isDispatchPaused else { return }
        isDispatchPaused = true
        objectWillChange.send()
    }

    func resumeDispatch() {
        guard isDispatchPaused else { return }
        isDispatchPaused = false
        objectWillChange.send()
        startNextQueued()
    }

    func toggleDispatchPause() {
        if isDispatchPaused {
            resumeDispatch()
        } else {
            pauseDispatch()
        }
    }

    private func containingVolume(for path: String) -> Volume? {
        volumes
            .filter { pathIsContained(path, in: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    private func pathIsContained(_ path: String, in root: String) -> Bool {
        let p = (URL(fileURLWithPath: path).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        let r = (URL(fileURLWithPath: root).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        return p == r || p.hasPrefix(r + "/")
    }

    private var inspectionToken = 0

    private func inspect(_ path: String) {
        inspecting = true
        inspection = nil
        inspectionError = nil
        lastSetupError = nil
        // Never carry the PREVIOUS card's label onto a new source. A name the
        // operator typed for THIS card is theirs: setSource already reset the
        // flag for any other card, so a set flag here means the same card.
        if !labelEditedByUser { label = "" }
        inspectionToken += 1
        let token = inspectionToken
        runEngine(["inspect", path]) { [weak self] data in
            guard let self else { return }
            // A LATE result for a source the operator has moved on from must
            // never overwrite the current card's inspection or label.
            guard token == self.inspectionToken, self.sourcePath == path else { return }
            self.inspecting = false
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // A broken/absent engine must be VISIBLE, never a plausible
                // volume-name label that silently misfiles the continuation.
                if !self.labelEditedByUser { self.label = "" }
                let message = "Could not inspect this source — check the engine folder "
                    + "(Settings > Engine), then re-select the source."
                self.inspectionError = message
                self.lastSetupError = message
                return
            }
            guard (obj["protocol"] as? Int) == EngineContract.protocolVersion else {
                // Version-skewed engines default-decay fields; suggested_label
                // is the CONTINUATION KEY, so refuse rather than guess.
                if !self.labelEditedByUser { self.label = "" }
                let message = "engine mismatch: update the engine folder "
                    + "(Settings > Engine), then re-select the source"
                self.inspectionError = message
                self.lastSetupError = message
                return
            }
            if let engineError = obj["error"] as? String, !engineError.isEmpty {
                // The engine refused the source for a stated reason — show
                // THAT, never the generic install hint (which sent the first
                // alpha field report chasing a healthy engine).
                if !self.labelEditedByUser { self.label = "" }
                let message = "Cannot use this source: \(engineError)"
                self.inspectionError = message
                self.lastSetupError = message
                return
            }
            var ins = CardInspection()
            ins.format = obj["format"] as? String ?? ""
            ins.formatName = obj["format_name"] as? String ?? "?"
            ins.reelName = obj["reel_name"] as? String ?? ""
            ins.suggestedLabel = obj["suggested_label"] as? String ?? ""
            ins.known = obj["known"] as? Bool ?? false
            ins.mounts = obj["mounts"] as? Int ?? 0
            ins.files = obj["files"] as? Int ?? 0
            ins.bytes = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            ins.previousDestinations = obj["previous_destinations"] as? [String] ?? []
            if LooseSourceStaging.isStagedSet(path) {
                // The engine sees a generic folder; the operator dropped files.
                ins.format = "loose"
                ins.formatName = "Loose files"
                ins.known = false
                ins.mounts = 0
                ins.previousDestinations = []
            }
            self.inspection = ins
            self.label = Self.labelAfterInspection(
                current: self.label,
                editedByUser: self.labelEditedByUser,
                retryLabel: self.stagedRetryPlan?.src == path
                    ? self.stagedRetryPlan?.cardLabel : nil,
                suggested: ins.suggestedLabel)
            self.inspectionError = nil
            // "Reading card…" was the only thing Start could say; the read
            // is done, so that explanation is stale. Any other refusal stays.
            if let explained = self.startGateExplanation,
               self.lastSetupError == explained,
               self.startBlockedReason != explained {
                self.lastSetupError = nil
            }
        }
    }

    /// Which name the bench shows once an inspection lands. The operator's
    /// typed name wins (Joshua, 2026-09-28: a name typed while the card was
    /// still being read was replaced when the read finished). Then a staged
    /// historical retry's frozen continuation key, which a late inspect must
    /// not replace with today's registry suggestion. Then the suggestion.
    /// An empty field is never kept: it only means "not named yet".
    nonisolated static func labelAfterInspection(current: String,
                                                 editedByUser: Bool,
                                                 retryLabel: String?,
                                                 suggested: String) -> String {
        if editedByUser, !current.isEmpty { return current }
        return retryLabel ?? suggested
    }

    nonisolated static func inspectionResponse(_ data: Data, exitStatus: Int32) -> Data? {
        if exitStatus == 0 { return data }
        // A rejected source exits nonzero but still supplies a protocol error.
        // Preserve that explanation without accepting a failed inspection.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["protocol"] as? Int) == EngineContract.protocolVersion,
              let error = obj["error"] as? String,
              !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return data
    }

    private func runEngine(
        _ args: [String],
        done: @escaping @Sendable @MainActor (Data?) -> Void
    ) {
        // A superseded inspect is not useful work. Token checks prevent stale
        // UI writes, but without termination every source change could leave a
        // 30–45 second removable-volume child running in the background.
        inspectionProcess?.terminate()
        inspectionProcess = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: enginePython)
        p.arguments = ["-m", "dumptruck.cli"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: engineRoot)
        p.environment = EngineRootResolver.processEnvironment(root: engineRoot)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice  // never let an undrained pipe block the child
        // A blocking reader on a background queue still drains WHILE the child
        // runs, but gives one owner exclusive access to the file descriptor.
        // Mixing readabilityHandler reads with a termination-time readToEnd()
        // races two consumers and can lose/truncate the final JSON object.
        do {
            try p.run()
            inspectionProcess = p
            try? pipe.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // Cap DURING accumulation (round-9 finding 10) — but keep
                // draining past the cap so the child never blocks on a full
                // pipe; a runaway warning list costs I/O, not app memory.
                var collected = Data()
                let cap = 16 * 1024 * 1024
                let fh = pipe.fileHandleForReading
                while let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    if collected.count < cap {
                        collected.append(chunk.prefix(cap - collected.count))
                    }
                }
                p.waitUntilExit()
                let capped = collected
                Task { @MainActor in
                    if self?.inspectionProcess === p { self?.inspectionProcess = nil }
                    done(Self.inspectionResponse(capped, exitStatus: p.terminationStatus))
                }
            }
        } catch {
            Task { @MainActor in done(nil) }
        }
    }

    // MARK: offload

    var canStart: Bool { startBlockedReason == nil }

    /// The UI may offer quarantine only for an invalid regular journal whose
    /// identity was pinned during load. Save failures, symlinks, and other
    /// unsafe entries remain manual-recovery cases.
    var canQuarantineJournal: Bool { journal.canQuarantineInvalidJournal }

    /// Called only from the UI's explicit confirmation action. Invalid
    /// records were never restored, and clearing the in-memory cards here
    /// makes that invariant obvious even if a future caller invokes this
    /// method after another state transition.
    func quarantineInvalidJournal() {
        guard journalError != nil, journal.canQuarantineInvalidJournal else { return }
        switch journal.quarantineInvalidJournal() {
        case .success(let quarantineURL):
            // Unreachable while monitored jobs exist today (both monitor
            // creators are gated on a healthy journal), but dropping jobs
            // must never strand their FSEvents streams if that gate moves.
            for id in jobSourceMonitors.keys { _ = stopJobSourceMonitoring(id) }
            stopAllDestinationMonitoring()
            jobs.removeAll()
            stagedRetryPlan = nil
        continuationFreeze = nil
            stagedRetryJobID = nil
            journalError = nil
            journalQuarantineNotice = "The unusable journal was retained at \(quarantineURL.path). "
                + "A new empty ledger is ready; its historical records cannot authorize wipe or eject."
            objectWillChange.send()
        case .failure(let error):
            // Prefer the operation's concrete failure (including the
            // retained sibling path after a rename/fsync failure) over the
            // original decode error, so the operator can recover safely.
            journalError = error.localizedDescription
            objectWillChange.send()
        }
    }

    /// Single source for this reason string: BenchCard's collapse exception
    /// compares against it by identity, so a rewording here can never silently
    /// change collapse behavior (Kimi K3 workbench audit finding 5).
    static let runningTransferReason = "This source already has a running transfer"
    var startBlockedByRunningTransferOnly: Bool {
        startBlockedReason == Self.runningTransferReason
    }

    static let pickSourceReason = "Pick a source disk or folder first"
    static let noDestinationReason = "Add at least one destination"
    static let readingCardReason = "Reading card…"
    static let nameCardReason = "Name the card"
    static let sourceChangedReason = "The card changed after it was read — "
        + "re-read it before starting"

    /// Reasons that are simply the next step of ordinary setup, not a
    /// problem. The bench footer showed them in warning orange right after a
    /// card was staged, which read as an error (Joshua, 2026-09-28); they
    /// render quietly, and everything else keeps the warning color.
    static func isNextStepReason(_ reason: String) -> Bool {
        reason == pickSourceReason || reason == noDestinationReason
            || reason == readingCardReason || reason == nameCardReason
    }

    var startBlockedReason: String? {
        if journalError != nil {
            return "Job journal unavailable — resolve it before starting a transfer"
        }
        if let orphanRecoveryError {
            return "Interrupted engine recovery is blocked — \(orphanRecoveryError)"
        }
        if let engineConfigurationError { return engineConfigurationError }
        if sourcePath == nil { return Self.pickSourceReason }
        if let inspectionError { return inspectionError }
        if sourceChangedSinceVerification { return Self.sourceChangedReason }
        if destinationPaths.isEmpty { return Self.noDestinationReason }
        // Before the name check: while the card is read the field may still
        // be empty, and "Name the card" told the operator to do something
        // the read was about to do for them. It also keeps Start from
        // launching on a name typed before the card's facts are in.
        if inspecting { return Self.readingCardReason }
        if label.isEmpty { return Self.nameCardReason }
        if let reason = CardLabelRules.validate(label) { return reason }
        // OVERLAP, not equality: a staged CHILD of a running source (or the
        // parent of one) must also refuse — batch staging could otherwise
        // queue a child of the staged source and run parent and child
        // concurrently (codex v0.4.x review, F4). LEXICAL containment: this
        // property is read from view bodies, and pathIsAtOrInside resolves
        // symlinks on disk (codex verify F2 caught the first version doing
        // exactly the I/O it claimed not to).
        if let src = sourcePath, jobs.contains(where: { job in
            job.isRunning && (pathIsAtOrInsideLexically(src, root: job.sourcePath)
                              || pathIsAtOrInsideLexically(job.sourcePath, root: src))
        }) {
            return Self.runningTransferReason
        }
        let d = UserDefaults.standard
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        if !template.isEmpty, let src = sourcePath {
            if stagedRetryPlan == nil {
                let context = TemplateContext(
                    project: d.string(forKey: Pref.projectName) ?? "",
                    volumeName: URL(fileURLWithPath: src).lastPathComponent,
                    cardLabel: label,
                    date: Date(),
                    cameraFormat: (inspection?.formatName == "?" ? "" : (inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
                    reel: inspection?.reelName ?? "",
                    jobID: "VALIDATION"
                )
                if let err = TemplateRenderer.validate(template, context: context) {
                    return err
                }
            }
        }
        return nil
    }

    /// Everything a transfer needs, frozen at Start time. A job that waits in
    /// the queue must run with the card, template, project, and verification
    /// settings that were in effect when the operator pressed Start — never
    /// whatever the UI shows when its turn finally comes.
    struct LaunchPlan {
        let src: String
        let rawRoots: [String]   // as picked (existence re-checked at drain time)
        let dests: [String]      // effective: template-rendered, symlink-resolved
        let args: [String]       // the complete frozen CLI invocation
        let cardLabel: String
        let mirroredFolder: String
        let organizationFolder: String
        let enginePython: String // frozen: engineRoot changes must not retarget a queued job
        let engineRoot: String
        // Volume identity pins: a path string is not an identity — Card A can
        // be pulled and Card B can mount at the SAME "/Volumes/NO NAME" while
        // this plan waits in the queue. UUID when the volume has one, PLUS the
        // root directory's device:inode (always obtainable) so UUID-less
        // volumes fail CLOSED on any replacement or remount.
        let srcVolumeUUID: String?
        let rootVolumeUUIDs: [String?]
        let srcFileID: String?
        let rootFileIDs: [String?]
    }

    static func volumeUUID(_ path: String) -> String? {
        (try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// device:inode of a path — the identity pin that works on every
    /// filesystem, UUID or not. nil only when the path is unreadable.
    static func fileID(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let dev = attrs[.systemNumber] as? NSNumber,
              let ino = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return "\(dev):\(ino)"
    }

    func journalPlan(_ plan: LaunchPlan) -> JournalLaunchPlan {
        JournalLaunchPlan(src: plan.src, rawRoots: plan.rawRoots,
                          destinations: plan.dests, args: plan.args,
                          enginePython: plan.enginePython,
                          engineRoot: plan.engineRoot,
                          sourceVolumeUUID: plan.srcVolumeUUID,
                          rootVolumeUUIDs: plan.rootVolumeUUIDs,
                          sourceFileID: plan.srcFileID,
                          rootFileIDs: plan.rootFileIDs,
                          mirroredFolder: plan.mirroredFolder,
                          organizationFolder: plan.organizationFolder,
                          cardLabel: plan.cardLabel)
    }

    private func launchPlan(_ plan: JournalLaunchPlan) -> LaunchPlan {
        LaunchPlan(src: plan.src, rawRoots: plan.rawRoots,
                   dests: plan.destinations, args: plan.args,
                   cardLabel: plan.cardLabel,
                   mirroredFolder: plan.mirroredFolder,
                   organizationFolder: plan.organizationFolder,
                   enginePython: plan.enginePython, engineRoot: plan.engineRoot,
                   srcVolumeUUID: plan.sourceVolumeUUID,
                   rootVolumeUUIDs: plan.rootVolumeUUIDs,
                   srcFileID: plan.sourceFileID,
                   rootFileIDs: plan.rootFileIDs)
    }

    private var queuedParams: [UUID: LaunchPlan] = [:]

    // MARK: durable journal / crash recovery

    private func journalRecords() -> [JobJournalRecord] {
        jobs.map { job in
            JobJournalRecord(job: job, plan: job.launchPlanSnapshot)
        }
    }

    static func isFileActivityEvent(_ event: String?) -> Bool {
        ["file_started", "file_progress", "file_done", "file_skipped_duplicate",
         "file_skipped_content_match", "source_reread_progress", "verify_progress",
         "verification_failed", "source_inconsistent", "name_collision",
         "file_failed"].contains(event ?? "")
    }

    private static func journalRelevantEvent(_ event: String?) -> Bool {
        switch event {
        case "job_started", "source_warning", "identity_ambiguous",
             "refused_label_collision", "job_failed", "finalizing",
             "finalizing_started", "source_reread_started", "attestation",
             "manifests_written", "report_written", "report_failed",
             "offload_complete":
            return true
        default:
            return false
        }
    }

    /// Journal writes are intentionally synchronous on the main actor: the
    /// document is bounded and the rename/fsync boundary must precede an
    /// engine launch or a terminal safety surface. A failed write blocks the
    /// next transfer and remains visible instead of becoming a best-effort log.
    @discardableResult
    private func persistJournal() -> Bool {
        switch journal.save(records: journalRecords()) {
        case .success:
            journalError = nil
            return true
        case .failure:
            journalError = journal.failure ?? "job journal unavailable"
            objectWillChange.send()
            return false
        }
    }

    private func loadJournalAndRecover() {
        orphanRecoveryError = nil
        guard journal.acquireInstanceLock() else {
            journalError = journal.failure ?? "another Dumptruck instance owns the job journal"
            return
        }
        switch journal.load() {
        case .empty:
            journalError = nil
        case .invalid(let message):
            journalError = message
            return
        case .loaded(let document):
            var restored: [Job] = []
            var recoveryBlocks: [String] = []
            for record in document.records {
                let wasLive = JobPhase(rawValue: record.phase).map {
                    $0 == .queued || $0 == .starting || $0 == .copying
                        || $0 == .sourceVerify || $0 == .reports
                } ?? true
                if wasLive {
                    guard let plan = record.plan else {
                        recoveryBlocks.append("job \(record.label) has no frozen launch plan")
                        restored.append(restoreJob(record, interrupted: true))
                        continue
                    }
                    let identity = OrphanEngineLaunchIdentity(
                        executablePath: plan.enginePython,
                        currentDirectory: plan.engineRoot,
                        arguments: plan.args,
                        runID: record.runID)
                    switch OrphanEngineRecovery().recover(identity: identity) {
                    case .noMatchingProcess, .terminated:
                        break
                    case .blocked(let reason):
                        recoveryBlocks.append("job \(record.label): \(reason)")
                        // Not ruled out: keep the record live in the journal
                        // so the next launch recovers it (round 7, R7-02).
                        let job = restoreJob(record, interrupted: true)
                        job.unresolvedRecoveryPhase = record.phase
                        restored.append(job)
                        continue
                    }
                }
                restored.append(restoreJob(record, interrupted: wasLive))
            }
            jobs = restored
            journalError = nil
            if !recoveryBlocks.isEmpty {
                orphanRecoveryError = recoveryBlocks.joined(separator: " ")
            }
            // Recovery is itself a durable state transition. If this save
            // fails, the in-memory failed cards remain visible but no new run
            // can start because journalError/orphanRecoveryError remains visible.
            if restored.contains(where: { !$0.isRunning && $0.errorCount > 0 }) {
                _ = persistJournal()
            }
        }
    }

    private func restoreJob(_ record: JobJournalRecord, interrupted: Bool) -> Job {
        let phase = JobPhase(rawValue: record.phase) ?? .failed
        let job = Job(label: record.label, sourcePath: record.sourcePath,
                      destinations: record.destinations,
                      // A relaunched app has no source assignment session in
                      // common with a historical run. Nil prevents any old
                      // completion from authorizing a newly mounted card.
                      sourceAssignmentID: nil, id: record.id,
                      runID: record.runID, createdDate: record.createdDate)
        job.markRestoredFromJournal()
        // The interrupted marker must survive LATER relaunches too: once the
        // recovered record persists as terminal-failed, the next restore no
        // longer classifies it live, so the fact rides in the record itself
        // (codex verify F5).
        if interrupted || record.interrupted == true {
            job.markRestoredInterrupted()
            job.recoveredAt = record.recoveredAt ?? (interrupted ? Date() : nil)
        }
        job.launchPlanSnapshot = record.plan
        job.currentFile = record.currentFile
        job.bytesTotal = record.bytesTotal
        job.bytesFinished = record.bytesFinished
        job.currentFileDone = record.currentFileDone
        job.filesTotal = record.filesTotal
        job.filesCopied = record.filesCopied
        job.filesSkipped = record.filesSkipped
        job.filesFailed = record.filesFailed
        job.trustedPrior = record.trustedPrior
        job.fullyVerified = interrupted ? false : record.fullyVerified
        job.safeToWipe = interrupted ? false : record.safeToWipe
        job.physicalDevices = record.physicalDevices
        job.wipeBlockers = record.wipeBlockers
        job.reportPath = record.reportPath
        job.reportFailed = record.reportFailed
        job.reportPaths = record.reportPaths ?? (record.reportPath.map { [$0] } ?? [])
        job.manifestPaths = record.manifestPaths ?? []
        job.receiptPath = record.receiptPath ?? record.reportPath.map { ($0 as NSString).deletingPathExtension + ".receipt.json" }
        job.laneRoots = record.laneRoots
        job.laterVerification = record.laterVerification
        job.custodyFailures = record.custodyFailures ?? [:]
        if let later = record.laterVerification, !later.isClean {
            job.custodyFailures[later.folder] = later
        }
        job.destProgress = record.destinationSummary.mapValues(\.progress)
        job.startedDate = record.startedDate
        job.finishedDate = record.finishedDate
        job.rereadDone = record.rereadDone
        job.rereadTotal = record.rereadTotal
        job.sourceMutatedAfterStart = record.sourceMutatedAfterStart
        job.stopRequested = record.stopRequested
        job.replaceMessages(record.messages.map { message in
            JobMessage(severity: message.severity == "error" ? .error : .warning,
                       text: message.text)
        })
        if interrupted {
            let recoveryBlocker = "transfer interrupted before terminal verification"
            job.stopRequested = false
            job.pendingTerminalOk = false
            job.pendingFullyVerified = false
            job.pendingSafeToWipe = false
            job.phase = .failed
            job.fullyVerified = false
            job.safeToWipe = false
            if !job.wipeBlockers.contains(recoveryBlocker) {
                job.wipeBlockers.append(recoveryBlocker)
            }
            if phase == .queued {
                // Still "queued" in the journal means no engine ever ran for
                // it: launchQueued commits the move out of the queue before
                // launching. Saying "relaunched before this transfer settled"
                // over a card that never started read as a failed copy. The
                // verdict stays FAILED so it can never pass for a backup
                // (Joshua, 2026-09-28).
                job.error("Never started: Dumptruck quit while this card was queued. "
                          + "Nothing was copied — " + Job.Verdict.failed.displayLine)
            } else {
                job.error("Dumptruck was relaunched before this transfer settled — "
                          + Job.Verdict.failed.displayLine)
            }
            // finishedDate stays NIL: the relaunch instant is a recovery,
            // not a completion, and stamping it here made History and the
            // CSV export present a fabricated finish time (codex verify F5).
            // `recoveredAt` (set above) carries the recovery moment.
        } else {
            job.phase = phase
            if !job.safeToWipe, job.wipeBlockers.isEmpty, !job.isRunning {
                job.wipeBlockers.append("terminal verification did not authorize wiping")
            }
        }
        return job
    }

    /// Whether a settled job is still authoritative for the card currently
    /// staged in the source rail. Centralized because the rail echo, the job-
    /// card eject button, and notification actions must all fail closed on a
    /// remount or a later same-source run.
    func isCurrentSourceVerdict(_ job: Job) -> Bool {
        // A current mount identity is necessary but not sufficient: the
        // terminal verdict must also have crossed the durable journal commit.
        guard journalError == nil else { return false }
        // And the copies the verdict rests on must still be where it put
        // them, unchanged since the verdict settled (round-3 R3-01: an
        // unmounted or rewritten destination left "this card can be wiped"
        // on the rail).
        guard job.destinationAuthorityWithdrawn == nil else { return false }
        if job.verdict == .safeToWipe, !destinationWatchersReady(for: job) { return false }
        if sourcePath == job.sourcePath {
            guard sourceMutationMonitoringActive,
                  job.verdictIsFresh(for: sourceAssignmentID) else { return false }
        } else {
            // Batch flow: the path was never staged, so authority comes from
            // the batch session registry — and only while a post-terminal
            // mutation watcher is live on that path. No watcher, no currency.
            guard let session = batchSourceSessions[job.sourcePath],
                  batchAuthorityMonitors[job.sourcePath] != nil,
                  job.verdictIsFresh(for: session) else { return false }
        }
        return runsNewestFirst({ $0.sourcePath == job.sourcePath }).first?.id == job.id
    }

    /// A mutation, unmount, or re-stage of a batch source retires its session:
    /// every surface reading `isCurrentSourceVerdict` fails closed at once.
    private func retireBatchSourceAuthority(for path: String) {
        guard batchSourceSessions[path] != nil || batchAuthorityMonitors[path] != nil
        else { return }
        batchSourceSessions[path] = UUID()
        batchAuthorityMonitors.removeValue(forKey: path)?.stop()
        stopDestinationMonitoring(forSource: path)
        retireSafeNotifications(for: path)
        objectWillChange.send()
        updateDockTile()
    }

    /// Called from finalizeTerminal for batch jobs that settled SAFE while
    /// their session is still live. Failing to start the watcher fails closed:
    /// the verdict simply never becomes current.
    private func startBatchAuthorityMonitoring(for job: Job) {
        guard sourcePath != job.sourcePath,
              job.verdict == .safeToWipe,
              let session = batchSourceSessions[job.sourcePath],
              job.verdictIsFresh(for: session),
              batchAuthorityMonitors[job.sourcePath] == nil else { return }
        let path = job.sourcePath
        guard let monitor = SourceMutationMonitor(
            path: path, filter: .sourceJunk(root: path), handler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.retireBatchSourceAuthority(for: path)
            }
        }) else { return }
        batchAuthorityMonitors[path] = monitor
    }

    /// Toolbar entry point: never a silent no-op. SwiftUI toolbar items cache
    /// their disabled state past our invalidations (smoke-test finding: a
    /// stale-disabled Start ate clicks after Settings changes and completed
    /// jobs), so the button stays clickable and EXPLAINS itself when blocked.
    func startOrExplain() {
        if let reason = startBlockedReason {
            // A card read in progress settles by itself in seconds; pressing
            // Start a moment early must not throw away a staged retry.
            if stagedRetryPlan != nil, reason != Self.readingCardReason { clearStagedRetry() }
            lastSetupError = reason
            startGateExplanation = reason
            return
        }
        start()
    }

    func start(fast: Bool = false) {
        guard canStart else {
            // A staged historical retry is one-shot safety context. Any
            // refusal before the identity check (source mutation, recovery
            // interlock, journal failure, etc.) must disarm it rather than
            // let a later Settings change accidentally launch it.
            if stagedRetryPlan != nil { clearStagedRetry() }
            return
        }
        guard let src = sourcePath else { return }
        lastSetupError = nil
        lastEjectError = nil
        let plan: LaunchPlan
        if let staged = stagedRetryPlan,
           staged.src == src,
           staged.rawRoots == destinationPaths,
           staged.mirroredFolder == destinationFolderRelativePath,
           staged.cardLabel == label {
            // Keep the pinned roots and rendered folder. The visible retry
            // choice decides whether current or saved settings supply flags.
            guard validateRetryPlan(staged),
                  let current = currentEnginePlanForRetry(staged) else {
                clearStagedRetry()
                return
            }
            plan = current
        } else {
            // Capture the one-click continuation's frozen render BEFORE
            // clearStagedRetry(), which — like every staging invalidation —
            // clears it, then restore it for the build. Without this the
            // override died one line before buildPlan read it, silently
            // reverting Continue to a fresh render (codex F1's hazard,
            // re-found by inspection the same day the fix shipped: fix-wave
            // regressions are why every fix batch gets its own review).
            let frozenContinuationRender = continuationFreeze
            clearStagedRetry()
            continuationFreeze = frozenContinuationRender
            switch buildPlan(src: src, rawRoots: destinationPaths,
                             cardLabel: label, fast: fast) {
            case .failure(let e):
                lastSetupError = e.message
                return
            case .success(let p):
                plan = p
            }
        }
        // One-shot consumed: the plan (fresh or retry) is frozen now.
        continuationFreeze = nil
        sourceChangedSinceVerification = false
        // Queue check happens BEFORE the job is inserted: the predicate must
        // never count the job being started (round-4: every first job queued
        // itself forever and nothing could ever drain the queue).
        let isRunningTransfer = jobs.contains { $0.isRunning && $0.phase != .queued }
        // A dispatch pause is global: Start may stage more work, but it must
        // not launch an engine even if the ordinary queue preference is Off.
        let mustQueue = isDispatchPaused
            || (UserDefaults.standard.string(forKey: Pref.queueMode) == "single"
                && isRunningTransfer)
        let job = Job(label: label, sourcePath: src, destinations: plan.dests,
                      sourceAssignmentID: sourceAssignmentID)
        job.launchPlanSnapshot = journalPlan(plan)
        // The journal validates every record it saves and, by design, a
        // failed save disables writes for the rest of the process. That gate
        // is for disk failures. A record the journal would refuse on shape
        // (label, paths, plan) must never be inserted in the first place:
        // it used to be, and one bad card name locked every later transfer
        // until relaunch (Codex desktop QA 2026-09-15, DT-QA-02).
        guard JobJournal.recordShapeIsValid(
            JobJournalRecord(job: job, plan: job.launchPlanSnapshot)) else {
            lastSetupError = "This transfer cannot be recorded as written: check the card name "
                + "and destination folders, then try again."
            clearStagedRetry()
            return
        }
        if mustQueue {
            job.phase = .queued
            if let lastQueued = jobs.lastIndex(where: { $0.phase == .queued }) {
                jobs.insert(job, at: lastQueued + 1)
            } else {
                jobs.insert(job, at: 0)
            }
        } else {
            jobs.insert(job, at: 0)
        }
        guard startJobSourceMonitoring(job) else {
            job.phase = .failed
            job.error("could not monitor the source for changes — run refused")
            finalizeTerminal(job)
            return
        }
        guard persistJournal() else {
            _ = stopJobSourceMonitoring(job.id)
            jobs.removeAll { $0.id == job.id }
            queuedParams.removeValue(forKey: job.id)
            lastSetupError = journalError ?? "job journal unavailable"
            updateSleepAssertion()
            updateDockTile()
            return
        }
        updateSleepAssertion()
        updateDockTile()
        if mustQueue {
            queuedParams[job.id] = plan
            _ = persistJournal()
            return
        }
        launch(job: job, plan: plan)
    }

    /// Drains the queue by the Queueing preference. "One transfer at a
    /// time" launches the first queued job, and only when nothing else is
    /// active. "Off" launches every queued job: a batch used to ignore the
    /// preference and always ran its cards one after another (Joshua,
    /// 2026-09-21).
    private func startNextQueued() {
        guard !isDispatchPaused else { return }
        guard orphanRecoveryError == nil else { return }
        let oneAtATime = UserDefaults.standard.string(forKey: Pref.queueMode) == "single"
        // The where clause is re-evaluated per element: a launch that fails
        // its preflight re-enters here through finalizeTerminal and may have
        // already launched (or failed) the jobs after it.
        for job in jobs where job.phase == .queued {
            if oneAtATime, jobs.contains(where: { $0.isRunning && $0.phase != .queued }) { return }
            launchQueued(job)
        }
    }

    private func launchQueued(_ job: Job) {
        guard let plan = queuedParams.removeValue(forKey: job.id)
                ?? (job.launchPlanSnapshot.map(launchPlan)) else { return }
        // The world may have changed while this job waited: never launch at a
        // vanished source/destination (the engine would refuse, but refuse
        // here with a clearer message and keep the queue draining).
        let fm = FileManager.default
        if !fm.fileExists(atPath: plan.src) {
            job.phase = .failed
            job.error("source disappeared while queued: \(plan.src)")
            finalizeTerminal(job)
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: plan.src),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            job.phase = .failed
            job.error("source became a symbolic link while queued — refused")
            finalizeTerminal(job)
            return
        }
        if let gone = plan.rawRoots.first(where: { !fm.fileExists(atPath: $0) }) {
            job.phase = .failed
            job.error("destination disappeared while queued: \(gone)")
            finalizeTerminal(job)
            return
        }
        // Existence is not identity: the same PATH can now be a different
        // volume (card swapped, drive replaced). Pins must match — and an
        // identity we can no longer ESTABLISH fails closed, so UUID-less
        // volumes (network/FUSE/odd removables) can't slip a swap through.
        func identityHolds(_ path: String, uuid: String?, fid: String?) -> Bool {
            if let uuid, Self.volumeUUID(path) != uuid { return false }
            guard let fid else { return false }  // never pinned = never queued-launchable
            return Self.fileID(path) == fid
        }
        if !identityHolds(plan.src, uuid: plan.srcVolumeUUID, fid: plan.srcFileID) {
            job.phase = .failed
            job.error("the volume at \(plan.src) was replaced or remounted while this "
                      + "job was queued — this is not the card that was queued. "
                      + "Re-insert it and start again.")
            finalizeTerminal(job)
            return
        }
        for (i, root) in plan.rawRoots.enumerated() {
            if !identityHolds(root, uuid: plan.rootVolumeUUIDs[i], fid: plan.rootFileIDs[i]) {
                job.phase = .failed
                job.error("the destination volume at \(root) was replaced or remounted "
                          + "while this job was queued. Check destinations and start again.")
                finalizeTerminal(job)
                return
            }
        }
        // Re-contain the rendered destinations: a symlink planted at the
        // template path while the job waited must never redirect the engine.
        for dest in plan.dests where (dest as NSString).resolvingSymlinksInPath != dest {
            job.phase = .failed
            job.error("the destination folder \(dest) changed to a symlink while this "
                      + "job was queued. Refused.")
            finalizeTerminal(job)
            return
        }
        // Commit the move out of the queue before any engine can touch
        // media, as start() does for a direct launch. After a crash, a record
        // still reading "queued" is then provably one that never started,
        // which is what the relaunch message tells the operator
        // (Joshua, 2026-09-28).
        job.phase = .starting
        guard persistJournal() else {
            job.phase = .failed
            job.error("job journal could not record the launch — not started; "
                      + Job.Verdict.failed.displayLine)
            finalizeTerminal(job)
            return
        }
        launch(job: job, plan: plan)
    }

    /// Every terminal transition funnels here: notification, sleep assertion,
    /// and queue advancement must happen on ALL endings, launch failures included.
    /// Every ending passes through here exactly once. The guard makes that a
    /// property of the code, not of the callers: a Stop click racing a clean
    /// exit reached this funnel twice (round-24 finding — duplicate sounds,
    /// notification, persist; no safety impact, contract violation only).
    private var finalizedJobIDs: Set<UUID> = []

    private func finalizeTerminal(_ job: Job) {
        guard finalizedJobIDs.insert(job.id).inserted else { return }
        let monitorSawMutation = stopJobSourceMonitoring(job.id)
        if monitorSawMutation || job.sourceMutatedAfterStart {
            job.noteSourceMutation()
            job.enforceSourceMutationFailure()
            retireCurrentSourceAuthority(for: job.sourcePath)
        }
        job.finishedDate = Date()
        // Copying today's source does not prove that every entry from an old
        // damaged custody check was covered. Only a clean custody reread
        // retires that warning, including on a trusted continuation.
        if job.hasCustodyFailure {
            job.safeToWipe = false
            let reason = "a previous custody check found damage; run Verify Existing Custody before wiping"
            if !job.wipeBlockers.contains(reason) { job.wipeBlockers.append(reason) }
        }
        if !persistJournal() {
            let detail = journalError ?? "job journal unavailable"
            job.enforceJournalPersistenceFailure(detail)
            retireCurrentSourceAuthority(for: job.sourcePath)
        }
        // A SAFE batch verdict earns currency only under a live post-terminal
        // watcher on its card; starting it here, after the durable commit and
        // the mutation checks above, keeps every surface fail-closed.
        startBatchAuthorityMonitoring(for: job)
        // Any earlier verdict for this card is superseded whatever this one
        // says; its watchers go with it.
        stopDestinationMonitoring(forSource: job.sourcePath, except: job.id)
        armDestinationAuthority(for: job)
        job.verifiedFileHashes.removeAll()
        objectWillChange.send()  // re-gate the Start button + eject locks NOW
        playSound(for: job)
        switch job.verdict {
        case .safeToWipe: Haptics.verdictSuccess()
        case .failed where !job.stopRequested: Haptics.verdictFailure()
        case .running, .failed, .verifiedKeepCard, .unverified: break
        }
        if job.verdict == .safeToWipe, !destinationWatchersReady(for: job),
           jobDestinationMonitors[job.id] != nil {
            pendingDestinationNotifications.insert(job.id)
        } else { notify(job: job) }
        updateSleepAssertion()
        updateDockTile()
        refreshVolumes()  // free-space gauges reflect the bytes just written
        // A mutation event during the active run already retired every safety
        // surface. Once the engine owns no file handles, refresh the staged
        // card metadata too; otherwise its file/byte count remains pre-change.
        if sourceChangedSinceVerification,
           sourcePath == job.sourcePath {
            inspect(job.sourcePath)
        }
        // A verified loose set has done its job: the originals never moved
        // and the copies are proven, so the clones go and the rail clears
        // (clearing first stops the source monitor, which would otherwise
        // report the removal as a source mutation). A failed run keeps its
        // set so a retry can re-run the same files.
        if LooseSourceStaging.isStagedSet(job.sourcePath),
           job.phase == .done, job.fullyVerified {
            if sourcePath == job.sourcePath { clearSource() }
            if LooseSourceStaging.remove(job.sourcePath) {
                folderEndpoints.removeAll { $0.path == job.sourcePath }
            }
        }
        startNextQueued()
    }

    // MARK: dock presence

    /// One shared settled-presence result for the Dock and menu-bar HUD.
    /// Outstanding failed/unverified work wins.  Otherwise only the newest
    /// settled SAFE verdict for the currently staged, actively monitored source
    /// may remain visible; journal-restored or unassigned history is silent.
    /// The job whose outstanding bad verdict drives the Dock "!" and the HUD
    /// warning. Journal-restored history is silent here (it already fails
    /// closed on every action surface, and a cross-session FAILED pinned as a
    /// present-tense warning forever is alert fatigue, not safety — round-24
    /// finding, both reviewers). Failures from THIS app session keep warning
    /// until the operator quits or removes the record, or until a later run
    /// of the same card settles without a bad verdict: a failure the DIT
    /// already retried successfully is history, and the "!" pinned to it
    /// all session taught people to ignore the "!" (Joshua, 2026-09-28).
    /// An unretried failure, or one whose retry also failed or is still
    /// running, keeps warning.
    var settledBadVerdictJob: Job? {
        let settled = jobs.filter { !$0.isRunning && !$0.restoredFromJournal }
        let outstanding = settled.filter { !Self.badVerdictIsSuperseded($0, in: settled) }
        return outstanding.first(where: { $0.verdict == .failed })
            ?? outstanding.first(where: { $0.verdict == .unverified })
    }

    /// Whether a later settled run of the same source path ended without a
    /// bad verdict. "Later" is creation order in this session: `jobs` is not
    /// strictly newest-first once a retry queues behind waiting cards, and
    /// a tie never supersedes.
    static func badVerdictIsSuperseded(_ bad: Job, in settled: [Job]) -> Bool {
        settled.contains { later in
            later.id != bad.id
                && later.sourcePath == bad.sourcePath
                && later.createdUptime > bad.createdUptime
                && !later.isRunning
                && later.verdict != .failed && later.verdict != .unverified
        }
    }

    var settledBadVerdict: Job.Verdict? {
        settledBadVerdictJob?.verdict
    }

    var latestCurrentSafeVerdict: Job.Verdict? {
        guard settledBadVerdict == nil else { return nil }
        // Only the staged card's history competes for the staged card's ✓ —
        // a newer SAFE on a different (batch) card must not hide it.
        let latest = jobs
            .filter { !$0.isRunning && $0.sourcePath == sourcePath }
            .max { ($0.finishedDate ?? .distantPast) < ($1.finishedDate ?? .distantPast) }
        guard let latest,
              latest.verdict == .safeToWipe,
              latest.filesFailed == 0,
              isCurrentSourceVerdict(latest) else { return nil }
        return latest.verdict
    }

    var settledPresenceVerdict: Job.Verdict? {
        settledBadVerdict ?? latestCurrentSafeVerdict
    }

    /// Badge arbitration is independent of whether the Dock is also drawing
    /// live progress.  A safety warning must survive a newer active job; only
    /// when no bad verdict is outstanding may the active-count badge win.
    func dockBadge(activeJobCount: Int) -> String? {
        if settledBadVerdict != nil { return "!" }
        if activeJobCount > 0 { return "\(activeJobCount)" }
        return latestCurrentSafeVerdict == .safeToWipe ? "✓" : nil
    }

    /// Updated by the existing one-second throughput tick. Determinate bars
    /// use only the active phase's byte counters; starting, queued, and report
    /// phases use a moving segment because the engine grants no percentage.
    private func updateDockTile() {
        guard let app = NSApp else { return }
        let tile = app.dockTile
        let running = jobs.filter { $0.isRunning }
        if !running.isEmpty {
            dockProgressView.frame = NSRect(origin: .zero, size: tile.size)
            dockProgressView.advance(progress: dockProgress(for: running))
            tile.contentView = dockProgressView
            // Queued jobs are not "working" — badge only active transfers
            // (Kimi F6/F7: one surface, one meaning). An older outstanding
            // failed/unverified verdict remains the higher-priority warning.
            let active = running.filter { $0.phase != .queued }.count
            tile.badgeLabel = dockBadge(activeJobCount: active)
            tile.display()
            return
        }

        // A dock checkmark is readable across a room as "safe to wipe" — so
        // ONLY .safeToWipe earns it. VERIFIED · KEEP CARD gets no badge: its
        // caveat cannot ride on a one-character glyph (agy audit, CRITICAL 2).
        let badge = dockBadge(activeJobCount: 0)
        // Idle gating: no running jobs and nothing to change — skip the
        // WindowServer round-trip entirely (1 Hz timer keeps firing).
        if tile.contentView == nil && tile.badgeLabel == badge { return }
        tile.contentView = nil
        tile.badgeLabel = badge
        tile.display()
    }

    private func dockProgress(for jobs: [Job]) -> Double? {
        let values: [Double?] = jobs.map { job in
            switch job.phase {
            case .copying:
                return job.fraction
            case .sourceVerify where job.rereadTotal > 0:
                return min(1, Double(job.rereadDone) / Double(job.rereadTotal))
            default:
                return nil
            }
        }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +) / Double(values.count)
    }

    // MARK: sound effects

    /// Bundled truck SFX (Magnific-generated, assets/sfx/): engine start on
    /// launch, gravel-dump + chime on a verified finish, backup beeper on
    /// failure. Held strongly so playback survives the call.
    private var activeSound: NSSound?

    private func playSound(named name: String) {
        guard UserDefaults.standard.bool(forKey: Pref.soundEffects),
              let url = Bundle.main.url(forResource: name, withExtension: "mp3",
                                        subdirectory: "sfx") else { return }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.35
        activeSound = sound
        sound?.play()
    }

    /// Uptime of the last job launch, sounded or not.
    private var lastJobStartUptime: TimeInterval?

    /// A batch launching eight cards at once played eight overlapping
    /// engine starts. One start sound per burst: skip it when another job
    /// started within the last second (Joshua, 2026-09-28).
    func playStartSound() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastJobStartUptime = now }
        if let last = lastJobStartUptime, now - last < 1 { return }
        playSound(named: "offload_start")
    }

    private func playSound(for job: Job) {
        switch job.verdict {
        case .safeToWipe, .verifiedKeepCard: playSound(named: "offload_done")
        // The operator pressed Stop; the backup beeper is for failures
        // nobody asked for. The card still reads FAILED (Joshua, 2026-09-28).
        case .failed where job.stopRequested: break
        case .unverified, .failed: playSound(named: "offload_failed")
        case .running: break
        }
    }

    /// Destination anchors with the shared mirrored folder and Organize
    /// template applied for display
    /// previews (the engine appends the card-name folder itself — the
    /// continuation key). {VolumeName} renders from the given source.
    func effectiveDestinations(_ roots: [String], forSource src: String?) -> [String] {
        let d = UserDefaults.standard
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""
        let volName = src.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        // A staged historical retry owns the rendered organization path. Do
        // not let a later Settings edit silently redirect it before Start.
        let sub: String
        if let staged = stagedRetryPlan {
            sub = staged.organizationFolder
        } else {
            let context = TemplateContext(
                project: project,
                volumeName: volName,
                cardLabel: label,
                date: Date(),
                cameraFormat: (inspection?.formatName == "?" ? "" : (inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
                reel: inspection?.reelName ?? "",
                jobID: stagedRetryJobID?.uuidString.prefix(8).uppercased() ?? "PREVIEW"
            )
            sub = TemplateRenderer.render(template, context: context)
        }
        return roots.map {
            DestinationFolderProjection.project(
                root: $0,
                mirroredFolder: destinationFolderRelativePath,
                organizationFolder: sub)
        }
    }

    struct PlanError: Error { let message: String }

    func buildPlan(
        src: String,
        rawRoots: [String],
        cardLabel: String,
        fast: Bool = false,
        inspection: CardInspection? = nil,
        context: TemplateContext? = nil
    ) -> Result<LaunchPlan, PlanError> {
        let d = UserDefaults.standard
        let targetInspection = inspection ?? self.inspection
        // Freeze one context before rendering any destination. In particular,
        // Date/JobID must not be sampled once for the preview and again for
        // the actual argv; a queued job must have one immutable organization
        // path across UI, journal, and engine.
        let frozenContext = context ?? TemplateContext(
            project: d.string(forKey: Pref.projectName) ?? "",
            volumeName: URL(fileURLWithPath: src).lastPathComponent,
            cardLabel: cardLabel,
            date: Date(),
            cameraFormat: (targetInspection?.formatName == "?" ? "" : (targetInspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: targetInspection?.reelName ?? "",
            jobID: UUID().uuidString.prefix(8).uppercased()
        )
        // Precedence: a staged retry's frozen path, then a one-click
        // continuation's MATCHED render (codex F1 — never re-render what the
        // banner already promised), then a fresh render. Batch plans pass
        // their own context and take neither. The freeze is consumed ONLY
        // when every frozen field still matches the plan being built —
        // anything drifted (codex verify F3) falls through to a fresh
        // render instead of resurrecting a stale promise.
        let freezeRender: String? = {
            guard context == nil, let f = continuationFreeze,
                  f.sourcePath == src,
                  f.label == cardLabel,
                  f.relativePath == destinationFolderRelativePath,
                  Set(f.anchors) == Set(rawRoots) else { return nil }
            return f.organizationRender
        }()
        let organizationFolder = (context == nil
                ? (stagedRetryPlan?.organizationFolder ?? freezeRender)
                : nil)
            ?? TemplateRenderer.render(
                d.string(forKey: Pref.folderTemplate) ?? "",
                context: frozenContext)
        // Render + containment-check each destination. Template text cannot
        // traverse (the renderer strips . / ..), but a rendered folder that
        // already exists as a SYMLINK can point anywhere — resolve and require
        // the real path to stay under the real root, and store the resolved
        // path so the eject interlock guards the volume actually written to.
        var dests: [String] = []
        for root in rawRoots {
            let rendered = DestinationFolderProjection.project(
                root: root,
                mirroredFolder: destinationFolderRelativePath,
                organizationFolder: organizationFolder)
            let resolvedRoot = (root as NSString).resolvingSymlinksInPath
            let mirroredBase = DestinationFolderProjection.project(
                root: root,
                mirroredFolder: destinationFolderRelativePath,
                organizationFolder: "")
            if !destinationFolderRelativePath.isEmpty,
               FileManager.default.fileExists(atPath: mirroredBase),
               (mirroredBase as NSString).resolvingSymlinksInPath != mirroredBase {
                return .failure(PlanError(message:
                    "Mirrored destination folder changed to a symlink: \(mirroredBase). "
                    + "Choose the real folder again."))
            }
            let resolved = (rendered as NSString).resolvingSymlinksInPath
            guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
                return .failure(PlanError(message:
                    "Destination folder escapes its drive through a symlink: "
                    + "\(rendered) resolves to \(resolved). Refused."))
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
                  isDir.boolValue else {
                return .failure(PlanError(message:
                    "Destination \(root) is not a folder that exists — is the drive mounted?"))
            }
            // Planning only VALIDATES — rendered template folders are created
            // in launch(), immediately before the engine runs, so a plan that
            // fails or waits in the queue leaves no artifacts behind.
            dests.append(resolved)
        }

        var args = ["-m", "dumptruck.cli", "offload", src] + dests
        args += ["--label", cardLabel, "--json"]
        if LooseSourceStaging.isStagedSet(src) { args.append("--loose-files") }
        if fast || d.string(forKey: Pref.verifyMode) == "fast" { args.append("--fast") }
        if d.object(forKey: Pref.sourceReread) != nil, !d.bool(forKey: Pref.sourceReread) {
            args.append("--no-source-verify")
        }
        if d.bool(forKey: Pref.reverifyExisting) { args.append("--reverify-existing") }
        if let extras = d.string(forKey: Pref.extraHashes), !extras.isEmpty {
            args += ["--hash", extras]
        }
        if d.object(forKey: Pref.makeReports) != nil, !d.bool(forKey: Pref.makeReports) {
            args.append("--no-report")
        } else {
            if d.object(forKey: Pref.thumbnails) != nil, !d.bool(forKey: Pref.thumbnails) {
                args.append("--no-thumbs")
            }
            if d.bool(forKey: Pref.slateFirst) { args.append("--slate-first") }
        }
        return .success(LaunchPlan(src: src, rawRoots: rawRoots, dests: dests, args: args,
                                   cardLabel: cardLabel,
                                   mirroredFolder: destinationFolderRelativePath,
                                   organizationFolder: organizationFolder,
                                   enginePython: enginePython, engineRoot: engineRoot,
                                   srcVolumeUUID: Self.volumeUUID(src),
                                   rootVolumeUUIDs: rawRoots.map { Self.volumeUUID($0) },
                                   srcFileID: Self.fileID(src),
                                   rootFileIDs: rawRoots.map { Self.fileID($0) }))
    }

    @discardableResult
    func queueBatch(plans: [(candidate: BatchSourceCandidate, plan: LaunchPlan)]) -> Result<[Job], BatchQueueError> {
        guard !plans.isEmpty else { return .failure(.emptyBatch) }
        guard journalError == nil else {
            return .failure(.journalPersistenceFailed(journalError ?? "Job journal unavailable"))
        }
        guard orphanRecoveryError == nil else {
            return .failure(.recoveryBlocked(orphanRecoveryError ?? "Interrupted engine recovery is blocked"))
        }

        var newJobs: [Job] = []
        for item in plans {
            let job = Job(
                label: item.candidate.effectiveLabel,
                sourcePath: item.candidate.path,
                destinations: item.plan.dests,
                sourceAssignmentID: item.candidate.assignmentID
            )
            job.phase = .queued
            job.launchPlanSnapshot = journalPlan(item.plan)
            newJobs.append(job)
        }

        let priorJobs = jobs
        if let lastQueued = jobs.lastIndex(where: { $0.phase == .queued }) {
            jobs.insert(contentsOf: newJobs, at: lastQueued + 1)
        } else {
            jobs.insert(contentsOf: newJobs, at: 0)
        }

        var startedMonitorIDs: [UUID] = []
        var monitorFailed = false
        for job in newJobs {
            if startJobSourceMonitoring(job) {
                startedMonitorIDs.append(job.id)
            } else {
                monitorFailed = true
                break
            }
        }

        if monitorFailed {
            for id in startedMonitorIDs {
                _ = stopJobSourceMonitoring(id)
            }
            jobs = priorJobs
            lastSetupError = "could not monitor the source for changes — batch queue refused"
            return .failure(.monitorFailed("Failed to monitor candidate source changes"))
        }

        // Register each candidate's session so its eventual verdict can prove
        // currency. Any prior authority on the same path is superseded.
        var priorSessions: [String: UUID?] = [:]
        for item in plans {
            let path = item.candidate.path
            if priorSessions[path] == nil {
                priorSessions[path] = .some(batchSourceSessions[path])
            }
            batchAuthorityMonitors.removeValue(forKey: path)?.stop()
            batchSourceSessions[path] = item.candidate.assignmentID
        }

        for (index, job) in newJobs.enumerated() {
            queuedParams[job.id] = plans[index].plan
        }

        guard persistJournal() else {
            for job in newJobs {
                _ = stopJobSourceMonitoring(job.id)
                queuedParams.removeValue(forKey: job.id)
            }
            for (path, prior) in priorSessions {
                if let prior { batchSourceSessions[path] = prior }
                else { batchSourceSessions.removeValue(forKey: path) }
            }
            jobs = priorJobs
            lastSetupError = journalError ?? "job journal unavailable"
            updateSleepAssertion()
            updateDockTile()
            return .failure(.journalPersistenceFailed(journalError ?? "job journal unavailable"))
        }

        // A staged card that was promoted into this batch (drop onto an
        // occupied rail) now belongs to its batch job: the batch session is
        // the authority, and isCurrentSourceVerdict's single-source branch
        // would otherwise fail closed forever on the assignment mismatch.
        if let src = sourcePath, plans.contains(where: { $0.candidate.path == src }) {
            clearSource()
        }

        updateSleepAssertion()
        updateDockTile()
        objectWillChange.send()

        startNextQueued()

        return .success(newJobs)
    }

    func chooseBatchSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Stage Batch Sources"
        if panel.runModal() == .OK {
            let paths = panel.urls.map(\.path)
            guard !paths.isEmpty else { return }
            stageBatchSources(paths: paths)
        }
    }

    func stageBatchSources(paths: [String], openWindow: Bool = true) {
        // Same ingress standardization as every drop entry (codex verify
        // rounds 3-4) — with order-preserving dedupe.
        let standardized = Self.standardizedDropPaths(paths)
        batchStagingModel.addCandidates(paths: standardized, appModel: self)
        if openWindow { openBatchWindow() }
    }

    /// Bring the Batch Sources window forward. Explicit actions only (the
    /// Batch Sources… picker, the rail's Review button): fronting it on every
    /// rail drop stole focus from the main window, so the next drag off the
    /// Connected shelf only re-activated that window and never started
    /// (Joshua, 2026-09-28: "doesnt let me continue dragging drives").
    func openBatchWindow() {
        batchStagingShown = true
        batchStagingOpenRequests += 1
    }

    /// Where a drop on the sources rail goes.
    enum SourceDropRoute: Equatable {
        /// One item onto an empty rail (or the staged card dropped again,
        /// which re-mints its session): the direct single-source path.
        case assign(String)
        /// Everything else: the batch sheet, staged card first so the
        /// order on screen matches the order the cards were dragged. A
        /// staged card that already ran is left out (see routeSourceDrop).
        case batch([String])
    }

    /// Pure routing for a sources-rail drop. Joshua (2026-09-14): cards get
    /// plugged in several at a time and dragged over one after another, and
    /// the second drag REPLACED the first. A drop onto an occupied rail now
    /// promotes the staged card and the new item together into the batch
    /// sheet, which keeps accepting drops, so nothing already on the rail is
    /// ever silently swapped out. Batch candidates already pending (the
    /// sheet is open) join the same list.
    ///
    /// `stagedAlreadyRan`: the staged card's current session already has a
    /// job (queued, running or settled). Pulling THAT card into the batch
    /// was wrong (Joshua, 2026-09-28): its lane folder already exists, so
    /// the batch refused it and stalled, and as a batch candidate its SAFE
    /// eject locked. It is never a batch candidate. One dropped card is
    /// simply the next card and takes the bench: a finished SAFE card keeps
    /// its verdict through handOffStagedVerdict, so nothing is lost. Several
    /// dropped cards batch without it.
    static func routeSourceDrop(_ rawPaths: [String],
                                staged: String?,
                                pendingBatch: [String],
                                stagedAlreadyRan: Bool = false) -> SourceDropRoute? {
        let dropped = standardizedDropPaths(rawPaths)
        guard !dropped.isEmpty else { return nil }
        if dropped.count == 1, pendingBatch.isEmpty,
           staged == nil || staged == dropped[0] || stagedAlreadyRan {
            return .assign(dropped[0])
        }
        var ordered: [String] = []
        if let staged, !stagedAlreadyRan { ordered.append(staged) }
        ordered.append(contentsOf: pendingBatch)
        ordered.append(contentsOf: dropped)
        return .batch(standardizedDropPaths(ordered))
    }

    /// True when the staged card's CURRENT session already produced a job,
    /// queued, running or settled. The job carries the session it was
    /// started under, so a remount or a write to the card (which mint a new
    /// session) makes it a fresh card again.
    var stagedSourceAlreadyRan: Bool {
        guard let src = sourcePath, let session = sourceAssignmentID else { return false }
        return jobs.contains { $0.sourcePath == src && $0.verdictIsFresh(for: session) }
    }

    /// A drop on the sources rail, any count. Returns false with
    /// lastSetupError set when an item cannot be a source at all; the card
    /// already on the rail is untouched either way and stays staged until
    /// the batch it joined is actually queued (see queueBatch), so a
    /// cancelled sheet loses nothing.
    @discardableResult
    func stageDroppedSources(_ rawPaths: [String]) -> SourceDropRoute? {
        let split: (ordered: [String], stagedSet: String?)
        do {
            split = try Self.splitDroppedPaths(rawPaths)
        } catch {
            lastSetupError = error.localizedDescription
            return nil
        }
        let ordered = split.ordered
        let stagedSet = split.stagedSet
        guard !ordered.isEmpty else { return nil }
        func discardStagedSet() {
            if let stagedSet { LooseSourceStaging.remove(stagedSet) }
        }
        releaseStaged(ordered, except: .source)
        guard let route = Self.routeSourceDrop(
            ordered, staged: sourcePath,
            pendingBatch: batchStagingModel.candidates.map(\.path),
            stagedAlreadyRan: stagedSourceAlreadyRan) else {
            discardStagedSet()
            return nil
        }
        switch route {
        case .assign(let path):
            if assign(path, as: .source) { return route }
            discardStagedSet()
            return nil
        case .batch(let paths):
            // Refuse the whole drop on the first item that can never be a
            // source (a running transfer's tree, a destination), same
            // all-or-nothing rule as the destinations rail.
            for path in ordered {
                if let reason = assignmentBlockedReason(path, as: .source) {
                    lastSetupError = reason
                    discardStagedSet()
                    return nil
                }
            }
            lastSetupError = nil
            // The cards collect in the rail's batch list; the window stays
            // where it is so the next drag works (see openBatchWindow).
            stageBatchSources(paths: paths, openWindow: false)
            return route
        }
    }

    /// One drop, two kinds of item. Loose files (2026-09-15) become ONE
    /// staged set, a real folder of clones the engine treats as a card , 
    /// and take the first file's place in drag order. Folders pass straight
    /// through. A refused set throws and stages nothing. Shared by the rail
    /// and the batch sheet so files behave the same wherever they land
    /// (Opus review 2026-09-15, finding 3).
    static func splitDroppedPaths(_ rawPaths: [String]) throws
        -> (ordered: [String], stagedSet: String?) {
        let dropped = standardizedDropPaths(rawPaths)
        var ordered: [String] = []
        var files: [String] = []
        var fileSlot: Int?
        for path in dropped {
            var st = stat()
            if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG {
                if fileSlot == nil { fileSlot = ordered.count; ordered.append("") }
                files.append(path)
            } else {
                ordered.append(path)
            }
        }
        guard !files.isEmpty, let slot = fileSlot else { return (ordered, nil) }
        let set = try LooseSourceStaging.stage(files: files)
        ordered[slot] = set
        return (ordered, set)
    }

    /// A staged loose set is scratch: once nothing refers to it (no job of
    /// any phase, not on the rail, not a batch candidate) its clones go.
    /// The originals were never touched. Removal refuses anything outside
    /// the staging root, so this can never delete real footage.
    func releaseLooseSourceIfUnused(_ path: String?) {
        guard let path, LooseSourceStaging.isStagedSet(path) else { return }
        guard sourcePath != path,
              !jobs.contains(where: { $0.sourcePath == path }),
              !batchStagingModel.candidates.contains(where: { $0.path == path }) else { return }
        if LooseSourceStaging.remove(path) {
            folderEndpoints.removeAll { $0.path == path }
        }
    }

    /// Engine children by job — the app must never lose ownership of a
    /// process it started (quit guard + protocol-mismatch termination).
    private var runningProcesses: [UUID: Process] = [:]

    func terminateAllEngines() {
        stopAllDestinationMonitoring()
        if let p = inspectionProcess, p.isRunning { p.terminate() }
        inspectionProcess = nil
        for p in runningProcesses.values where p.isRunning { p.terminate() }
    }

    private func launch(job: Job, plan: LaunchPlan) {
        job.phase = .starting

        // Create the rendered template folders NOW — validated at plan time,
        // materialized only when a run actually begins. Failure cleans up any
        // directories this call itself created (empty ones only).
        var createdRoots: [(path: String, fileID: String)] = []
        for (i, dest) in plan.dests.enumerated() where dest != plan.rawRoots[i] {
            if !FileManager.default.fileExists(atPath: dest) {
                // remember the topmost missing component for cleanup
                var top = dest
                while true {
                    let parent = (top as NSString).deletingLastPathComponent
                    if parent == plan.rawRoots[i] || FileManager.default.fileExists(atPath: parent) { break }
                    top = parent
                }
                do {
                    try FileManager.default.createDirectory(
                        atPath: dest, withIntermediateDirectories: true)
                    if let fid = Self.fileID(top) {
                        createdRoots.append((top, fid))
                    }
                } catch {
                    for c in createdRoots {
                        self.cleanupCreatedRoot(c, for: job.id)
                    }
                    job.phase = .failed
                    job.error("could not create \(dest): \(error.localizedDescription)")
                    finalizeTerminal(job)
                    return
                }
            }
        }

        // The run token is only appended at the process boundary. It is
        // persisted separately and lets a future launch find this exact
        // orphan without trusting a PID.
        let args = plan.args + ["--gui-run-id", job.runID.uuidString]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: plan.enginePython)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: plan.engineRoot)
        p.environment = EngineRootResolver.processEnvironment(root: plan.engineRoot)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // All pipe handling funnels through one serial queue (bug-hunt finding:
        // concurrent mutation of the line buffer + events lost at termination).
        let stream = EnginePipeState(jobID: job.id)
        let jobID = job.id

        @Sendable nonisolated func processBuffer(final: Bool) {
            while let nl = stream.buffer.firstIndex(of: 0x0A) {
                let line = stream.buffer.prefix(upTo: nl)
                stream.buffer.removeSubrange(...nl)
                dispatchLine(line)
            }
            if final, !stream.buffer.isEmpty {
                dispatchLine(stream.buffer)
                stream.buffer.removeAll()
            }
            if stream.buffer.count > 16 * 1024 * 1024, !stream.streamFailed {
                stream.streamFailed = true
                stream.buffer.removeAll()
                p.terminate()
            }
        }
        @Sendable nonisolated func dispatchLine(_ line: Data) {
            guard !line.isEmpty else { return }
            let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            let prior = stream.eventTail
            let next = Task { @MainActor [weak self] in
                if let prior { await prior.value }
                guard let self,
                      let job = self.jobs.first(where: { $0.id == jobID }) else { return }
                // Strict stream framing (round-11 finding 5): a malformed
                // nonempty line, a second hello, or ANY event after the
                // terminal one is a protocol violation — fail closed, never
                // silently skip or re-apply.
                guard let obj = parsed else {
                    job.engineProtocolOK = false
                    if job.errorCount == 0 {
                        job.error("engine emitted a malformed protocol line — result NOT trusted")
                    }
                    p.terminate()
                    return
                }
                let event = obj["event"] as? String
                if job.sawOffloadComplete {
                    job.engineProtocolOK = false
                    job.error("engine sent events after its terminal event — result NOT trusted")
                    p.terminate()
                    return
                }
                if event == "engine_hello" {
                    if job.sawEngineHello {
                        job.engineProtocolOK = false
                        job.error("engine repeated its handshake — result NOT trusted")
                        p.terminate()
                        return
                    }
                    job.sawEngineHello = true
                    job.engineProtocolOK = (obj["protocol"] as? Int)
                        == EngineContract.protocolVersion
                    if !job.engineProtocolOK {
                        job.error("engine protocol mismatch — this app needs protocol "
                                  + "\(EngineContract.protocolVersion). "
                                  + "Update the engine folder (Settings > Engine).")
                        p.terminate()
                    }
                    return
                }
                // The hello is a handshake, not decoration: no engine event is
                // meaningful until the required protocol was established, and the hello
                // must be the first event in the stream.
                guard job.sawEngineHello, job.engineProtocolOK else {
                    if job.errorCount == 0 {
                        job.error("engine sent data before the required protocol handshake — "
                                  + "result NOT trusted")
                    }
                    p.terminate()
                    return
                }
                if event == "offload_complete",
                   (obj["protocol"] as? Int) != EngineContract.protocolVersion {
                    job.engineProtocolOK = false
                    job.error("terminal event protocol mismatch — result NOT trusted")
                    p.terminate()
                    return
                }
                guard Self.apply(event: obj, to: job) else {
                    // A safety-bearing event with missing/mistyped required
                    // fields is a protocol violation, not a default: a v3
                    // terminal event without its verdict Booleans used to
                    // leave earlier optimistic state standing (round-15 PR
                    // review finding 2 — fail-open on malformed terminal).
                    job.engineProtocolOK = false
                    job.error("engine sent a malformed \(event ?? "?") event — "
                              + "result NOT trusted")
                    p.terminate()
                    return
                }
                if event == "job_started" {
                    for previous in self.jobs where previous.id != job.id {
                        for (lane, failure) in previous.custodyFailures where job.laneRoots.contains(lane) {
                            if job.custodyFailures[lane].map({ $0.date < failure.date }) ?? true {
                                job.custodyFailures[lane] = failure
                            }
                        }
                    }
                }
                // Job is its OWN ObservableObject: views observing the MODEL
                // (toolbar Start gate, eject locks) never see job mutations
                // unless we forward them (smoke-test finding: Start stayed
                // disabled forever after a job completed). Progress floods
                // are skipped — nothing model-level depends on them.
                let e = event
                if !Self.isFileActivityEvent(e) {
                    self.objectWillChange.send()
                }
                if Self.journalRelevantEvent(e) {
                    _ = self.persistJournal()
                }
            }
            stream.eventTail = next
        }

        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                // `read(upToCount:)` waits for the requested byte count or
                // EOF on a Pipe on macOS. Engine protocol traffic is usually
                // far smaller than 64 KiB, so that made a live copy remain at
                // "Starting" until the child exited. availableData returns as
                // soon as any bytes arrive while still using empty Data for
                // EOF, which is the streaming behavior this reader needs.
                let data = EnginePipeReader.nextChunk(from: outPipe.fileHandleForReading)
                guard !data.isEmpty else { break }
                stream.queue.async {
                    stream.buffer.append(data)
                    processBuffer(final: false)
                }
            }
            readers.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = EnginePipeReader.nextChunk(from: errPipe.fileHandleForReading)
                guard !data.isEmpty else { break }
                stream.queue.async {
                    let chunk = String(data: data, encoding: .utf8) ?? ""
                    stream.stderrText = String((stream.stderrText + chunk).suffix(1_048_576))
                }
            }
            readers.leave()
        }
        // Destination preparation is complete before the child starts; freeze
        // the cleanup list so the termination queue never captures a mutable
        // task-local variable across actor boundaries.
        let rootsCreatedForJob = createdRoots
        p.terminationHandler = { [weak self] proc in
            // Both descriptors have a single streaming owner. Finalization is
            // queued only after both reached EOF and all earlier chunks are on
            // the parser queue, so terminal events cannot be lost or reordered.
            readers.notify(queue: stream.queue) {
                processBuffer(final: true)
                let stderrSnapshot = stream.stderrText
                let tail = stream.eventTail
                Task { @MainActor in
                    if let tail { await tail.value }
                    guard let self,
                          let job = self.jobs.first(where: { $0.id == jobID }) else { return }
                    self.runningProcesses.removeValue(forKey: job.id)
                    if job.stopRequested {
                        // An operator Stop is authoritative even if the child
                        // happened to finish cleanly before SIGTERM landed.
                        // A racing terminal frame must never upgrade an
                        // explicitly abandoned attempt back to DONE/SAFE.
                        job.phase = .failed
                        job.fullyVerified = false
                        job.safeToWipe = false
                        if job.errorCount == 0 {
                            job.error("operator stopped this transfer — copy is incomplete; "
                                      + Job.Verdict.failed.displayLine)
                        }
                    } else if proc.terminationStatus != 0 || stream.streamFailed {
                        // Exit code is authority: a nonzero exit can never
                        // leave a verified/ejectable state behind.
                        if job.phase != .refused { job.phase = .failed }
                        job.fullyVerified = false
                        job.safeToWipe = false
                        if job.errorCount == 0 {
                            if stream.streamFailed {
                                job.error("engine emitted an oversized/non-delimited protocol line — "
                                          + "result NOT trusted")
                            } else if !stderrSnapshot.isEmpty {
                                job.error(String(stderrSnapshot.suffix(600)))
                            } else if proc.terminationReason == .uncaughtSignal {
                                job.error("engine was terminated by signal \(proc.terminationStatus) "
                                          + "before a trusted terminal result — copy is incomplete")
                            } else {
                                job.error("engine exited with status \(proc.terminationStatus) "
                                          + "before a trusted terminal result — copy is incomplete")
                            }
                        }
                    } else if !job.sawEngineHello || !job.sawOffloadComplete
                                || !job.engineProtocolOK {
                        // Exit 0 WITHOUT the terminal event is an engine that
                        // never finished its protocol (version skew, wedged
                        // run): whatever flags arrived, nothing is proven.
                        job.phase = .failed
                        job.fullyVerified = false
                        job.safeToWipe = false
                        if job.engineProtocolOK {
                            job.error("engine exited without its terminal event — "
                                      + "result NOT trusted (engine/app version skew?)")
                        }
                    } else if job.isRunning {
                        // ONLY NOW — clean exit, protocol complete — apply the
                        // pending terminal result and unlock eject/quit state.
                        // (A job already terminal via refused/job_failed events
                        // keeps that phase.)
                        if let fv = job.pendingFullyVerified { job.fullyVerified = fv }
                        if let sw = job.pendingSafeToWipe { job.safeToWipe = sw }
                        job.phase = job.pendingTerminalOk ? .done : .failed
                        if job.pendingTerminalOk,
                           UserDefaults.standard.bool(forKey: Pref.openReportWhenDone),
                           let r = job.reportPath {
                            // Open behind the current app: in a batch every
                            // finished card stole focus from whatever the
                            // DIT was typing (Joshua, 2026-09-28).
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.activates = false
                            NSWorkspace.shared.open(URL(fileURLWithPath: r),
                                                    configuration: configuration,
                                                    completionHandler: nil)
                        }
                    }
                    if job.phase == .failed || job.phase == .refused {
                        for c in rootsCreatedForJob {
                            self.cleanupCreatedRoot(c, for: job.id)
                        }
                    }
                    self.finalizeTerminal(job)
                }
            }
        }
        do {
            try p.run()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            runningProcesses[job.id] = p
            // Only the bench's own card folds the bench away. A queued or
            // batch job launching must not hide a different card the
            // operator is setting up (Joshua, 2026-09-28).
            if job.sourcePath == sourcePath, job.verdictIsFresh(for: sourceAssignmentID) {
                benchCollapsed = true
            }
            playStartSound()
            if job.stopRequested {
                p.terminate()
            }
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            for c in createdRoots {
                cleanupCreatedRoot(c, for: job.id)
            }
            job.phase = .failed
            job.error("could not launch engine: \(error.localizedDescription)")
            // A launch failure is a terminal transition like any other: it
            // must advance the queue, not strand every job behind it.
            finalizeTerminal(job)
        }
    }

    /// Remove a directory only when its whole subtree contains no files AT
    /// ALL — including .dumptruck-job.lock: a locked directory belongs to an
    /// engine (possibly another job's, in its pre-copy window) and is NEVER
    /// garbage (round-9 finding 1: the lock exemption let one job's cleanup
    /// delete a running peer's live card folder). The cost is a leftover
    /// empty template tree after some failures — cosmetic, and conservative.
    private static func removeIfEmptyTree(_ path: String, expectedFileID: String) {
        // Bottom-up ATOMIC rmdir only — never a recursive removeItem after an
        // emptiness check (check-then-delete race: a file created by anyone
        // between the scan and the delete would be destroyed; round-10
        // finding 4). rmdir(2) fails ENOTEMPTY the instant anything exists,
        // so a concurrent creation preserves the tree by construction.
        let fm = FileManager.default
        guard fileID(path) == expectedFileID else { return }
        var dirs: [String] = []
        if let e = fm.enumerator(atPath: path) {
            for case let sub as String in e {
                var isDir: ObjCBool = false
                let full = (path as NSString).appendingPathComponent(sub)
                if fm.fileExists(atPath: full, isDirectory: &isDir) {
                    if isDir.boolValue {
                        dirs.append(full)
                    } else {
                        return  // ANY file lives here — never delete
                    }
                }
            }
        }
        for d in dirs.sorted(by: { $0.count > $1.count }) {
            Darwin.rmdir(d)  // ENOTEMPTY = something appeared: leave it
        }
        if fileID(path) == expectedFileID { Darwin.rmdir(path) }
    }

    /// Cleanup gate: never touch a created root that any OTHER job — running
    /// or finished — uses as a source or destination.
    private func cleanupCreatedRoot(_ c: (path: String, fileID: String), for jobID: UUID) {
        let inUse = jobs.contains { other in
            other.id != jobID && ([other.sourcePath] + other.destinations).contains {
                pathsOverlap($0, c.path)
            }
        }
        guard !inUse else { return }
        Self.removeIfEmptyTree(c.path, expectedFileID: c.fileID)
    }

    /// The Mac must never sleep mid-transfer (a suspended copy is an ambiguous copy).
    private func updateSleepAssertion() {
        let anyRunning = jobs.contains { $0.isRunning }
        if anyRunning, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Dumptruck transfer in progress")
        } else if !anyRunning, let token = sleepAssertion {
            ProcessInfo.processInfo.endActivity(token)
            sleepAssertion = nil
        }
    }

    /// Returns false when a safety-bearing event is missing required fields —
    /// the caller must treat that as a protocol violation and fail closed.
    static func apply(event obj: [String: Any], to job: Job) -> Bool {
        defer { job.publishProgress() }
        switch obj["event"] as? String {
        case "card_recognized", "camera_history_preserved":
            break
        case "finalizing", "finalizing_started":
            job.phase = .reports
            job.currentFile = ""
            job.stopThroughput()
        case "identity_ambiguous":
            job.warn("card matches multiple known cards ambiguously — treated as NEW; check the label")
        case "refused_label_collision", "job_failed":
            job.phase = obj["event"] as? String == "job_failed" ? .failed : .refused
            job.error((obj["message"] ?? obj["error"]) as? String ?? "engine refused/failed")
        case "job_started":
            job.phase = .copying
            job.bytesTotal = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            job.filesTotal = obj["files"] as? Int ?? 0
            // Ordered card roots — the lane group's spine (one lane per
            // destination, engine-authoritative order).
            job.laneRoots = obj["destinations"] as? [String] ?? []
            job.startedDate = Date()
            job.recordThroughput(0, phase: "copy")
        case "source_warning":
            if let msg = obj["message"] as? String { job.warn(msg) }
        case "file_started":
            job.currentFile = obj["path"] as? String ?? ""
            job.currentFileDone = 0
            job.noteFileActivity()
        case "file_progress":
            // path and done are REQUIRED in protocol 3: a pathless event used
            // to charge its bytes to whatever file happened to be displayed
            // (round-15 PR review finding 5).
            guard let path = obj["path"] as? String,
                  let done = (obj["done"] as? NSNumber)?.int64Value else {
                return false
            }
            if path == job.currentFile { job.currentFileDone = done }
            job.recordCopyProgress(path: path, done: done)
            job.recordThroughput(job.copyBytesRead, phase: "copy")
        case "file_done":
            if let path = obj["path"] as? String,
               let text = obj["xxh64"] as? String, text.count == 16,
               let hash = UInt64(text, radix: 16) {
                job.verifiedFileHashes[path] = hash
            }
            job.bytesFinished += (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            job.notePipelineActivity(verifyingCopy: false)
            // Pipelined verification: file N's done event lands while file N+1
            // is already streaming — never zero the counter of a LATER file.
            if let donePath = obj["path"] as? String {
                if donePath == job.currentFile { job.currentFileDone = 0 }
                // Nothing legitimate follows a file's done event — drop its
                // progress entry so 100k-file cards stay bounded (round-15
                // PR review finding 4).
                job.finishCopyProgress(path: donePath)
            }
            switch obj["outcome"] as? String {
            case "verified", "size-only": job.filesCopied += 1
            case "skipped": job.filesSkipped += 1
            default: job.filesFailed += 1
            }
            // Per-destination VERIFIED accumulation for the lanes — the
            // engine already ships the per-root status map on every
            // file_done; no engine change, no protocol change.
            if let status = obj["status"] as? [String: String] {
                let bytes = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
                for (root, s) in status {
                    job.recordDestinationStatus(root: root, status: s, bytes: bytes)
                }
            }
        case "file_skipped_duplicate":
            let bytes = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            job.bytesFinished += bytes
            job.filesSkipped += 1
            job.recordTrustedSkipForAllDestinations(bytes: bytes)
        case "file_skipped_content_match":
            break  // bytes for this file arrive with its file_done event
        case "verify_progress":
            // Heartbeat only: bytes read back from a destination. Never
            // evidence, never counted into any total — it just tells the
            // stall readout the pipeline is moving.
            job.notePipelineActivity(verifyingCopy: true)
        case "verification_failed", "source_inconsistent", "name_collision", "file_failed":
            let path = obj["path"] as? String ?? "?"
            let dest = (obj["destination"] as? String).map { " at \($0)" } ?? ""
            let detail = (obj["error"] as? String).map { " (\($0))" } ?? ""
            job.error("\(obj["event"] as? String ?? "error"): \(path)\(dest)\(detail)")
        case "source_reread_started":
            job.phase = .sourceVerify
            job.currentFile = ""
            job.rereadTotal = (obj["total"] as? NSNumber)?.int64Value ?? 0
            job.rereadDone = 0
            job.recordThroughput(0, phase: "reread")
        case "source_reread_progress":
            job.rereadDone = (obj["done"] as? NSNumber)?.int64Value ?? job.rereadDone
            if job.rereadTotal == 0 {
                job.rereadTotal = (obj["total"] as? NSNumber)?.int64Value ?? 0
            }
            job.recordThroughput(job.rereadDone, phase: "reread")
            job.noteFileActivity()
        case "job_done":
            job.phase = .reports
            job.stopThroughput()
            job.fullyVerified = obj["fully_verified"] as? Bool ?? false
            if let errs = obj["errors"] as? [String] {
                let seen = Set(job.messages.map(\.text))
                job.appendMessages(errs.filter { !seen.contains($0) }.map { JobMessage(severity: .error, text: $0) })
            }
            if let warns = obj["warnings"] as? [String] {
                let seen = Set(job.messages.map(\.text))
                job.appendMessages(warns.filter { !seen.contains($0) }.map { JobMessage(severity: .warning, text: $0) })
            }
        case "attestation":
            // Strict v3 decode: the verdict and its reasons must BOTH be
            // present and must agree (the engine guarantees safe iff no
            // blockers) — a contradiction means a skewed/faulty engine, and
            // silently defaulting either field could overstate safety
            // (round-15 PR review finding 2).
            guard let safe = obj["safe_to_wipe_source"] as? Bool,
                  let blockers = obj["safe_to_wipe_blockers"] as? [String],
                  job.acceptAttestation(safe: safe, blockers: blockers) else {
                return false
            }
            job.physicalDevices = obj["distinct_physical_devices"] as? Int ?? 0
            job.trustedPrior = obj["files_trusted_from_prior_generations"] as? Int ?? 0
        case "manifests_written":
            guard let paths = obj["paths"] as? [String],
                  // The helper above validates the persisted Job state, so
                  // validate this untrusted engine payload against the same
                  // frozen scopes before accepting it.
                  let incoming = JobEvidenceParser.validatedManifestPaths(
                    paths, label: job.label, destinations: job.destinations,
                    laneRoots: job.laneRoots),
                  incoming == paths else {
                return false
            }
            job.manifestPaths = paths
        case "report_written":
            guard let paths = obj["paths"] as? [String],
                  let incoming = JobEvidenceParser.validatedReportPaths(
                    paths, label: job.label, destinations: job.destinations,
                    laneRoots: job.laneRoots),
                  incoming == paths else {
                return false
            }
            job.reportPaths = paths
            job.reportPath = paths.first(where: {
                ($0 as NSString).pathExtension.lowercased() == "html"
            }) ?? paths.first
            if let htmlPath = paths.first(where: {
                ($0 as NSString).pathExtension.lowercased() == "html"
            }) {
                let receiptCandidate = (htmlPath as NSString).deletingPathExtension + ".receipt.json"
                job.receiptPath = receiptCandidate
            }
            // Protocol 3 engines from round 6 on name the receipts they
            // wrote; with reports off that is the only evidence pointer.
            if let receiptPaths = obj["receipt_paths"] as? [String],
               let validated = JobEvidenceParser.validatedReceiptPaths(
                    receiptPaths, label: job.label, destinations: job.destinations,
                    laneRoots: job.laneRoots),
               let first = validated.first {
                job.receiptPath = first
            }
        case "report_failed":
            job.reportFailed = true
            job.warn("report failed: \(obj["error"] as? String ?? "?") (copy state unaffected)")
        case "offload_complete":
            // THE terminal event — but only a PENDING result until the process
            // exits cleanly. Unlocking .done/safeToWipe here would open eject
            // and quit while a (possibly skewed/faulty) engine is still alive
            // and may yet exit nonzero (round-10 finding 3). The termination
            // handler applies this after EOF + protocol + exit-status checks.
            // Strict v3 decode: every terminal verdict field is REQUIRED. A
            // terminal event missing them used to skip the pending
            // assignments and leave earlier optimistic values standing —
            // missing authority failed OPEN (round-15 PR review finding 2).
            guard let ok = obj["ok"] as? Bool,
                  let fv = obj["fully_verified"] as? Bool,
                  let sw = obj["safe_to_wipe_source"] as? Bool,
                  job.acceptTerminal(ok: ok, fullyVerified: fv, safeToWipe: sw) else {
                return false
            }
        default:
            break
        }
        return true
    }

    private func notify(job: Job) {
        // Completion channels must not send a fresh SAFE claim after the
        // destination check refused current authority, including webhooks.
        if job.verdict == .safeToWipe, !isCurrentSourceVerdict(job) { return }
        // Auto-eject only on the strongest outcome, never on anything lesser.
        if UserDefaults.standard.bool(forKey: Pref.autoEjectWhenSafe),
           job.verdict == .safeToWipe,
           let vol = volumes.first(where: { $0.path == job.sourcePath }),
           canEject(vol) {
            eject(vol)
        }
        dispatchWebhookNotification(for: job)
        // A Stop the operator pressed a moment ago needs no time-sensitive
        // "FAILED — DO NOT WIPE" banner. The webhook above still reports it:
        // someone watching remotely did not press Stop (Joshua, 2026-09-28).
        guard !job.stopRequested else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard UserDefaults.standard.object(forKey: Pref.notifyOnCompletion) == nil
              || UserDefaults.standard.bool(forKey: Pref.notifyOnCompletion) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Dumptruck — \(job.label)"
        let hasReport = job.reportPath != nil
        switch job.verdict {
        case .safeToWipe:
            content.body = job.verdict.displayLine
            content.categoryIdentifier = hasReport
                ? CompletionNotification.safeCategory
                : CompletionNotification.safeNoReportCategory
        // Bodies come from Verdict.displayLine — the one shared mapping
        // (agy audit HIGH 3; Kimi F15).
        case .verifiedKeepCard:
            content.body = job.verdict.displayLine
            content.categoryIdentifier = hasReport
                ? CompletionNotification.reportCategory
                : CompletionNotification.noReportCategory
        case .unverified:
            content.body = job.verdict.displayLine
            content.categoryIdentifier = hasReport
                ? CompletionNotification.reportCategory
                : CompletionNotification.noReportCategory
        case .failed:
            content.body = job.verdict.displayLine
            content.categoryIdentifier = hasReport
                ? CompletionNotification.reportCategory
                : CompletionNotification.noReportCategory
            content.interruptionLevel = .timeSensitive
        case .running:
            return
        }
        var userInfo: [String: Any] = [
            CompletionNotification.jobIDKey: job.id.uuidString
        ]
        if let reportPath = job.reportPath {
            // Lets Open Report survive an app relaunch. Eject never uses this
            // fallback; it still requires a live, current source assignment.
            userInfo[CompletionNotification.reportPathKey] = reportPath
        }
        content.userInfo = userInfo
        // One sound per completion. With the truck effects on, finalize
        // already played the done or failure clip, and the system chime on
        // top of it was a second sound for the same event. With them off,
        // the system sound is the only audible cue, and macOS lets the
        // operator silence it per app in Notifications settings
        // (Joshua, 2026-09-28). AppDelegate.willPresent follows the same rule.
        content.sound = UserDefaults.standard.bool(forKey: Pref.soundEffects)
            ? nil
            : .default
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Self.notificationCategories)
        let request = UNNotificationRequest(
            identifier: job.id.uuidString, content: content, trigger: nil)
        let jobID = job.id
        let requiresCurrentSourceAuthority = job.verdict == .safeToWipe
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                    if allowed {
                        self.addNotificationIfStillAuthoritative(
                            request, jobID: jobID,
                            requiresCurrentSourceAuthority: requiresCurrentSourceAuthority)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                self.addNotificationIfStillAuthoritative(
                    request, jobID: jobID,
                    requiresCurrentSourceAuthority: requiresCurrentSourceAuthority)
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func dispatchWebhookNotification(for job: Job) {
        guard UserDefaults.standard.bool(forKey: Pref.webhookEnabled) else { return }
        let endpoint = UserDefaults.standard.string(forKey: Pref.webhookURL) ?? ""
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            recordWebhookWarning("Remote webhook enabled but endpoint URL is empty", for: job)
            return
        }
        let payload = WebhookPayload.from(job: job)
        let secret = KeychainWebhookSecretStore.shared.loadSecret()
        let jobID = job.id
        Task { @MainActor [weak self, weak job] in
            let result = await WebhookNotificationService.shared.deliver(
                payload: payload,
                endpointURLString: trimmedEndpoint,
                bearerSecret: secret
            )
            if case .failed(let warning) = result {
                guard let self, let job,
                      self.jobs.contains(where: { $0.id == jobID }) else { return }
                self.recordWebhookWarning(warning, for: job)
            }
        }
    }

    /// Webhook delivery is an observability side effect. Its failure is a
    /// warning, never an engine error: this helper persists the warning after
    /// terminal finalization without touching verdict, report, queue, or
    /// eject authority.
    private func recordWebhookWarning(_ warning: String, for job: Job) {
        guard jobs.contains(where: { $0.id == job.id }) else { return }
        job.warn(warning)
        _ = persistJournal()
        objectWillChange.send()
    }

    private nonisolated func addNotificationIfStillAuthoritative(
        _ request: UNNotificationRequest,
        jobID: UUID,
        requiresCurrentSourceAuthority: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let job = self.jobs.first(where: { $0.id == jobID }) else { return }
            if requiresCurrentSourceAuthority,
               !self.isCurrentSourceVerdict(job) { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A SAFE notification is another eject-authority surface, not merely a
    /// historical log line. Remove it when this mount path is re-assigned or
    /// changes in place; its action is independently guarded as defense in depth.
    private func retireSafeNotifications(for sourcePath: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let identifiers = jobs
            .filter { $0.sourcePath == sourcePath && $0.verdict == .safeToWipe }
            .map { $0.id.uuidString }
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static let notificationCategories: Set<UNNotificationCategory> = {
        let open = UNNotificationAction(
            identifier: CompletionNotification.openReportAction,
            title: "Open Report", options: [.foreground])
        let eject = UNNotificationAction(
            identifier: CompletionNotification.ejectCardAction,
            title: "Eject Card", options: [.foreground])
        return [
            UNNotificationCategory(identifier: CompletionNotification.reportCategory,
                                   actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: CompletionNotification.noReportCategory,
                                   actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: CompletionNotification.safeCategory,
                                   actions: [open, eject], intentIdentifiers: []),
            UNNotificationCategory(identifier: CompletionNotification.safeNoReportCategory,
                                   actions: [eject], intentIdentifiers: []),
        ]
    }()

    func handleNotificationAction(
        _ actionIdentifier: String,
        jobID: String?,
        reportPath: String?
    ) {
        let job = jobID
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in jobs.first(where: { $0.id == id }) }
        switch actionIdentifier {
        case CompletionNotification.openReportAction:
            guard let report = job?.reportPath ?? reportPath,
                  FileManager.default.fileExists(atPath: report) else {
                lastSetupError = "That completion report is no longer available."
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: report))
        case CompletionNotification.ejectCardAction:
            guard let job else {
                lastEjectError = "Eject blocked: the completed job is no longer available."
                return
            }
            guard job.verdict == .safeToWipe else {
                lastEjectError = "Eject blocked: this job is no longer "
                    + Job.Verdict.safeToWipe.displayLine + "."
                return
            }
            // Notification actions can live for hours. Never let an old SAFE
            // notification act on a later same-path mount or on a card that
            // has since started another run. The current assignment session
            // and newest job must both still be the notification's job.
            guard isCurrentSourceVerdict(job) else {
                lastEjectError = "Eject blocked: this notification is stale for the card now mounted."
                return
            }
            guard let volume = volumes.first(where: { $0.path == job.sourcePath }) else {
                lastEjectError = "Eject blocked: the source volume is no longer mounted."
                return
            }
            guard canEject(volume) else {
                lastEjectError = "Eject blocked: the source is in use or its verified state changed."
                return
            }
            eject(volume)
        default:
            break
        }
    }

    // MARK: eject

    /// The interlock: a volume participating in ANY running job — as source OR
    /// destination, at any depth — never ejects silently; a source ejects only
    /// once every one of its jobs reached a terminal verified state.
    /// Whether a rail shows an eject control at all (one-click or forced).
    /// External drives count whatever Cocoa's "ejectable" flag says: it is
    /// false for every USB hard drive, so the two round-3 QA destinations
    /// had no eject control (R3-05). A whole-volume source stays ejectable
    /// regardless, as before.
    func offersEject(_ volume: Volume) -> Bool {
        // diskutil eject operates on local disks, not SMB/NFS mounts.
        volume.isLocal && (volume.isEjectable || volume.isExternal
            || jobs.contains(where: { $0.sourcePath == volume.path }))
    }

    /// The jobs matching `include`, newest run first. `jobs` is DISPLAY
    /// order, and a retry queued behind waiting cards is inserted below its
    /// own older failure, so "first match" read the failure as the latest
    /// run: the retry's SAFE could never become current, eject stayed
    /// locked and the rail stayed silent (Joshua, 2026-09-28). This
    /// session's jobs order by creation time; records restored from the
    /// journal are older than all of them and keep their saved order.
    func runsNewestFirst(_ include: (Job) -> Bool) -> [Job] {
        jobs.enumerated()
            .filter { include($0.element) }
            .sorted { a, b in
                let aRestored = a.element.restoredFromJournal
                let bRestored = b.element.restoredFromJournal
                if aRestored != bRestored { return !aRestored }
                if !aRestored, a.element.createdUptime != b.element.createdUptime {
                    return a.element.createdUptime > b.element.createdUptime
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// The end-of-day pile: every mounted card that a settled job read as
    /// its source and that one-click eject already allows. Drives that only
    /// received copies are not cards and stay mounted; a card whose verdict
    /// is stale, running, or force-eject-only is left for its own control.
    /// Joshua, 2026-10-05: "an eject all for stuff that's dumped".
    var dumpedCardVolumes: [Volume] {
        volumes.filter { volume in
            jobs.contains { !$0.isRunning && pathsOverlap($0.sourcePath, volume.path) }
                && offersEject(volume) && canEject(volume)
        }
    }

    /// One click for the whole pile. Each eject re-checks its own gate, so a
    /// card whose verdict moved between render and click is skipped, not
    /// forced.
    func ejectDumpedCards() {
        for volume in dumpedCardVolumes where canEject(volume) {
            eject(volume)
        }
    }

    func canEject(_ volume: Volume) -> Bool {
        // A confirmed force eject remains available, but no one-click or
        // automatic eject may rely on an undurable terminal verdict.
        guard journalError == nil else { return false }
        // Batch candidates are staged sources too. An older SAFE job at the
        // same path cannot authorize eject while a new batch is being prepared.
        if batchStagingModel.candidates.contains(where: { pathsOverlap($0.path, volume.path) }) {
            return false
        }
        let stagedAsSource = sourcePath.map { pathsOverlap($0, volume.path) } == true
        let involved = runsNewestFirst { job in
            pathsOverlap(job.sourcePath, volume.path)
                || job.destinations.contains(where: { pathsOverlap($0, volume.path) })
        }
        // A source staged but never verified (or re-staged/re-written since
        // verification) requires the explicit force-eject wall. Historical
        // jobs at the same mount path do not make this assignment safe.
        if involved.isEmpty { return !stagedAsSource }
        if involved.contains(where: { $0.isRunning }) { return false }
        // jobs is newest-first. A later verified retry supersedes an older
        // failure for the same source; the reverse ordering must stay locked.
        let sourceJobs = involved.filter { pathsOverlap($0.sourcePath, volume.path) }
        // A historical source record is evidence for the searchable history,
        // not a current mount assignment. One-click source eject needs live
        // identity proof: either the staged session or a batch session with
        // its post-terminal watcher — both enforced by isCurrentSourceVerdict,
        // which restored or superseded records can never satisfy. Destination-
        // only history may still be ejected once no transfer is running.
        if let latest = sourceJobs.first {
            guard isCurrentSourceVerdict(latest) else { return false }
        } else {
            guard !stagedAsSource else { return false }
        }
        return Job.latestSourceRunsAllowEject(sourceJobs)
    }

    /// Why `canEject` withheld the one-click eject. The eject control's
    /// tooltip and the warning sheet both read this one answer. The sheet
    /// used to know only "running" and "not fully verified", so a card
    /// verified to ONE drive fell through to "Eject an UNVERIFIED card?"
    /// with Force Eject as the only way out (Joshua, 2026-09-28).
    enum EjectHold {
        /// A transfer is reading this card or writing this drive right now.
        case transferRunning(Job, asSource: Bool)
        /// The newest run touching this volume ended FAILED or UNVERIFIED.
        case copiesUnverified(Job, asSource: Bool)
        /// A later Verify Existing Custody run found damage in a copy.
        case custodyDamaged(Job)
        /// Verified, but the engine withheld SAFE TO WIPE. `singleDrive`
        /// only when the sole blocker is "one known physical device".
        case verifiedNotSafe(Job, singleDrive: Bool)
        /// A SAFE verdict exists but no longer vouches for this mount.
        case verdictNotCurrent(Job)
        /// A SAFE verdict whose post-verdict re-check of the copies has not
        /// finished yet. Ejecting the card is harmless; wiping must wait.
        case destinationCheckPending(Job)
        /// Staged for an offload that has not run.
        case notOffloaded
        /// The job journal failed, so no verdict is durable.
        case journalUnavailable

        var job: Job? {
            switch self {
            case .transferRunning(let job, _), .copiesUnverified(let job, _),
                 .custodyDamaged(let job), .verifiedNotSafe(let job, _),
                 .verdictNotCurrent(let job), .destinationCheckPending(let job):
                return job
            case .notOffloaded, .journalUnavailable:
                return nil
            }
        }

        /// One line for the eject control's tooltip.
        var summary: String {
            switch self {
            case .transferRunning: return "A transfer is using this drive — eject asks first"
            case .copiesUnverified: return "Copies not verified — eject asks first"
            case .custodyDamaged: return "A later check found a damaged copy — eject asks first"
            case .verifiedNotSafe(_, let singleDrive):
                return singleDrive ? "Verified to one drive only — keep the card"
                                   : "Verified, but not safe to wipe — keep the card"
            case .verdictNotCurrent: return "The earlier verdict no longer covers this card — eject asks first"
            case .destinationCheckPending: return "Still re-checking the copies — don't wipe yet"
            case .notOffloaded: return "Not offloaded yet — eject asks first"
            case .journalUnavailable: return "Job journal unavailable — eject asks first"
            }
        }
    }

    /// Labels of SAFE cards whose live copy watch has a lane on this drive:
    /// ejecting it ends that watch and the verdict stops being current. The
    /// one-click eject tooltip says so up front (Joshua, 2026-09-28).
    func safeWatchesEndedByEjecting(_ volume: Volume) -> [String] {
        jobs.filter { job in
            jobDestinationMonitors[job.id] != nil
                && job.destinationAuthorityWithdrawn == nil
                && verdictLaneRoots(job).contains { pathsOverlap($0, volume.path) }
        }
        .map(\.label)
    }

    func ejectHold(_ volume: Volume) -> EjectHold? {
        guard !canEject(volume) else { return nil }
        let involved = runsNewestFirst { job in
            pathsOverlap(job.sourcePath, volume.path)
                || job.destinations.contains(where: { pathsOverlap($0, volume.path) })
        }
        if let running = involved.first(where: { $0.isRunning }) {
            return .transferRunning(running, asSource: pathsOverlap(running.sourcePath, volume.path))
        }
        if journalError != nil { return .journalUnavailable }
        // Same newest-per-source rule as latestSourceRunsAllowEject: an older
        // failure superseded by a later verified retry is history.
        var latestBySource: [String: Job] = [:]
        let sourceJobs = involved.filter { pathsOverlap($0.sourcePath, volume.path) }
        for job in sourceJobs where latestBySource[job.sourcePath] == nil {
            latestBySource[job.sourcePath] = job
        }
        let latest = sourceJobs.filter { latestBySource[$0.sourcePath]?.id == $0.id }
        if let bad = latest.first(where: { $0.verdict == .failed || $0.verdict == .unverified }) {
            return .copiesUnverified(bad, asSource: true)
        }
        // Before the staged check: re-staging a card that already has a
        // verified run must still say what that run proved.
        // Custody damage revokes SAFE but leaves fullyVerified standing, so
        // it would otherwise read as a proven copy with a benign blocker.
        if let damaged = latest.first(where: { $0.hasCustodyFailure
            || $0.wipeBlockers.contains { $0.contains("found damage") } }) {
            return .custodyDamaged(damaged)
        }
        if let kept = latest.first(where: { $0.verdict == .verifiedKeepCard }) {
            // "Backed up to one drive" only when that is the WHOLE story: the
            // engine also writes "span only 0" for unknown topology, and a
            // failed flush beside the device count is not a one-drive case.
            let singleDrive = kept.wipeBlockers
                == ["copies span only 1 known physical device(s); 2+ required"]
            return .verifiedNotSafe(kept, singleDrive: singleDrive)
        }
        if let stale = latest.first(where: { $0.verdict == .safeToWipe }) {
            // Only the live re-check is missing: its watchers are still up
            // (every retirement path clears the flag) and nothing has
            // withdrawn the verdict. "No longer covers this card" was the
            // wrong alarm for a check that is simply still running.
            if stale.destinationCheckPending, stale.destinationAuthorityWithdrawn == nil {
                return .destinationCheckPending(stale)
            }
            return .verdictNotCurrent(stale)
        }
        if let unverifiedCopy = involved.first(where: { !$0.fullyVerified }) {
            return .copiesUnverified(unverifiedCopy, asSource: false)
        }
        return .notOffloaded
    }

    func eject(_ volume: Volume) {
        guard !ejectingVolumePaths.contains(volume.path) else { return }
        lastEjectError = nil
        ejectingVolumePaths.insert(volume.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.arguments = ["eject", volume.path]
        p.terminationHandler = { [weak self] proc in
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            Task { @MainActor in
                if proc.terminationStatus != 0 {
                    self?.lastEjectError = "Eject failed for \(volume.name): \(text.suffix(200))"
                }
                self?.refreshVolumes()
                self?.ejectingVolumePaths.remove(volume.path)
            }
        }
        do {
            try p.run()
            // Same EOF rule as every other Pipe here: without closing the
            // parent's write end, the termination handler's read never sees
            // EOF and silently strands one hung thread per eject (Kimi K3 PR
            // review F1's sibling — masked by the unmount notification also
            // refreshing the volume list).
            try? out.fileHandleForWriting.close()
        } catch {
            try? out.fileHandleForWriting.close()
            try? out.fileHandleForReading.close()
            lastEjectError = "Eject failed: \(error.localizedDescription)"
            ejectingVolumePaths.remove(volume.path)
        }
    }
}
