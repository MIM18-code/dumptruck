import Foundation

enum EngineContract {
    static let protocolVersion = 3
}

/// Identity for one live recursive source watcher. The source assignment UUID
/// changes after every mutation; this separate token stays stable so the same
/// watcher can report later mutations, while callbacks queued by a stopped
/// same-path watcher are rejected after reassignment.
struct SourceMonitorSession {
    private(set) var id: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        self.id = id
        return id
    }

    mutating func end() {
        id = nil
    }

    func accepts(_ candidate: UUID) -> Bool {
        id == candidate
    }
}

struct Volume: Identifiable, Equatable {
    let path: String
    let name: String
    let isEjectable: Bool
    /// macOS reports a USB hard drive as NOT `volumeIsEjectable` (that key
    /// means removable media such as optical discs), so the eject control
    /// never rendered for the destination drives a DIT actually unplugs
    /// (desktop QA round 3, R3-05). `volumeIsInternal == false` is the
    /// signal that matches diskutil's "Device Location: External".
    var isExternal: Bool = false
    var isLocal: Bool = true
    // Capacity gauge data (agy GUI audit rank 2): a DIT must SEE free space
    // before starting a 1.4 TB offload, not discover it from a refusal.
    let totalBytes: Int64?
    let freeBytes: Int64?
    var id: String { path }

    /// Free/total for any path's volume (destinations may be plain folders,
    /// not /Volumes roots). nil when the path is unreadable.
    ///
    /// statfs, deliberately — NOT volumeAvailableCapacityForImportantUsage.
    /// The purgeable-aware key does synchronous XPC to the CacheDelete
    /// daemon, which can stall for MINUTES while it grinds getattrlist over
    /// busy external drives; this is called on the main actor (and from a
    /// rail view body), and it froze the whole app in the first alpha field
    /// session. statfs answers in microseconds — and its smaller, honest
    /// number is the right one for a copy planner anyway: space that needs
    /// macOS to purge caches first is not space the engine can count on.
    static func capacity(ofPath path: String) -> (free: Int64, total: Int64)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let blockSize = Int64(s.f_bsize)
        return (Int64(s.f_bavail) * blockSize, Int64(s.f_blocks) * blockSize)
    }
}

/// A place bytes can come from or go to: a mounted volume or a chosen folder.
/// Folders get real rows in the rails (they used to vanish after selection).
struct Endpoint: Identifiable, Hashable {
    enum Kind { case volume, folder }
    let path: String
    let kind: Kind
    var id: String { path }
}

enum EndpointRole {
    case source, destination
}

/// Frozen transfer context shared by the in-memory Job and the durable
/// journal. Keeping this value type in Models.swift lets the standalone model
/// regression harness compile without pulling in the AppKit journal writer.
struct JournalLaunchPlan: Codable, Hashable {
    let src: String
    let rawRoots: [String]
    let destinations: [String]
    let args: [String]
    let enginePython: String
    let engineRoot: String
    let sourceVolumeUUID: String?
    let rootVolumeUUIDs: [String?]
    let sourceFileID: String?
    let rootFileIDs: [String?]
    let mirroredFolder: String
    let organizationFolder: String
    let cardLabel: String
}

/// One destination-folder choice, projected onto every selected destination
/// anchor.  The anchors stay as existing folders/volume roots so queued-job
/// identity pins and free-space checks remain meaningful; the projected path
/// is materialized only when the job actually launches.
enum DestinationFolderProjection {
    /// Returns the selected folder's component-safe path below `root`, or nil
    /// when the selection is outside that root. Exact-root selection clears
    /// the mirrored folder and therefore returns an empty string.
    static func relativePath(selected: String, under root: String) -> String? {
        let selectedPath = URL(fileURLWithPath: selected).standardizedFileURL.path
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        guard selectedPath == rootPath || selectedPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        guard selectedPath != rootPath else { return "" }
        return String(selectedPath.dropFirst(rootPath.count + 1))
    }

    /// Destination ordering is intentional and matches the UI preview:
    /// anchor / mirrored folder / organization template. The engine appends
    /// the card-name continuation folder after this base.
    static func project(root: String, mirroredFolder: String,
                        organizationFolder: String) -> String {
        [mirroredFolder, organizationFolder]
            .filter { !$0.isEmpty }
            .reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }
}

/// Per-destination VERIFIED progress, accumulated from file_done's per-root
/// status map (the engine already emits it — zero engine changes). Lanes may
/// only show what was verified-and-committed; source-read progress belongs to
/// the job header, never to a lane.
struct DestProgress {
    var bytesVerified: Int64 = 0
    var bytesTrusted: Int64 = 0
    var bytesSizeOnly: Int64 = 0
    var filesVerified = 0
    var filesTrusted = 0
    var filesFailed = 0
    var sizeOnly = 0   // fast mode: never rendered green

    var completionBytes: Int64 {
        [bytesVerified, bytesTrusted, bytesSizeOnly].reduce(0) { total, bytes in
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? Int64.max : sum
        }
    }
}

struct CardInspection {
    var format = ""
    var formatName = ""
    var reelName = ""
    var suggestedLabel = ""
    var known = false
    var mounts = 0
    var files = 0
    var bytes: Int64 = 0
    var previousDestinations: [String] = []
}

/// Result of a Verify Existing Custody run matched to a job's lane.
struct LaterVerification: Codable, Hashable {
    let date: Date
    let folder: String
    let passed: Int
    let failed: Int
    let missing: Int
    let new: Int
    let unverifiable: Int
    let chainProblems: Int

    var isClean: Bool {
        failed == 0 && missing == 0 && new == 0 && unverifiable == 0 && chainProblems == 0
    }

    /// One line for the card and the journal blocker.
    var line: String {
        let when = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        if isClean { return "Checked again \(when): \(passed) files still verified" }
        var parts = ["\(passed) passed"]
        if failed > 0 { parts.append("\(failed) failed") }
        if missing > 0 { parts.append("\(missing) missing") }
        if new > 0 { parts.append("\(new) new") }
        if unverifiable > 0 { parts.append("\(unverifiable) unverifiable") }
        if chainProblems > 0 { parts.append("\(chainProblems) custody problems") }
        return "Checked again \(when): " + parts.joined(separator: ", ")
    }
}

enum JobPhase: String {
    case queued = "Queued"
    case starting = "Starting"
    case copying = "Copying + verifying"
    case sourceVerify = "Re-reading source"
    case reports = "Sealing manifests + report"
    case done = "Done"
    case failed = "FAILED"
    case refused = "REFUSED"
}

/// Severity-typed message with a stable identity — duplicate strings must
/// never collide (a failure list that can eat entries defeats the app).
struct JobMessage: Identifiable, Hashable {
    enum Severity { case warning, error }
    let id = UUID()
    let severity: Severity
    let text: String
}

final class Job: ObservableObject, Identifiable {
    let id: UUID
    /// Unique run token passed to the GUI engine. Recovery matches this token
    /// in the live argv before terminating anything, so a recycled PID can
    /// never be mistaken for our orphan.
    let runID: UUID
    let createdDate: Date
    /// Monotonic creation order within this app session. Queued jobs are not
    /// kept newest-first in `jobs` (a retry queues behind the waiting cards),
    /// and the wall clock can step backwards, so "a later run of this card"
    /// is decided on this instead (Joshua, 2026-09-28).
    let createdUptime = ProcessInfo.processInfo.systemUptime
    let label: String
    let sourcePath: String
    let destinations: [String]
    /// Identifies the exact staging session that launched this job. A path is
    /// not fresh evidence: the same card can be ejected, record new footage,
    /// and remount at the same `/Volumes/...` path. Rail safety echoes may
    /// only reuse a verdict from the current assignment session.
    let sourceAssignmentID: UUID?
    /// Set only for records reconstructed after an app relaunch. Historical
    /// evidence remains useful in the job history, but it is never a current
    /// source assignment and therefore can never authorize a generic eject.
    private(set) var restoredFromJournal = false
    /// True for a restored record that was LIVE when the app died: its
    /// finishedDate is the recovery stamp (relaunch time), not a real end —
    /// receipt rows must not present or sort by that stamp as if it were.
    private(set) var restoredInterrupted = false
    /// The live phase a journal record still carried when orphan recovery
    /// was BLOCKED (process scan refused, ambiguous match). The card shows
    /// as interrupted, but the journal keeps this phase so the next launch
    /// tries recovery again instead of skipping a record that was never
    /// ruled out (desktop QA round 7, R7-02).
    var unresolvedRecoveryPhase: String?
    /// When recovery happened, for interrupted restores — kept SEPARATE from
    /// finishedDate, which stays nil: the relaunch instant is not a
    /// completion, and History/CSV must never present it as one (codex
    /// verify F5). Persisted, so the marker survives later relaunches.
    var recoveredAt: Date?
    /// Frozen at Start; persisted with the journal so a later retry can stage
    /// the same roots, mirror suffix, and rendered organization path.
    var launchPlanSnapshot: JournalLaunchPlan?
    /// Independent GUI-side evidence that the source changed after Start.
    /// The engine has its own stability gates; either one is sufficient to
    /// fail the run, and neither may be upgraded by a later terminal event.
    var sourceMutatedAfterStart = false
    /// Stop is a request until the process termination handler has drained all
    /// protocol bytes. Persisting it keeps a relaunch fail-closed mid-stop.
    var stopRequested = false

    @Published var phase: JobPhase = .starting {
        didSet {
            if phase != oldValue { resetEscalators() }
        }
    }
    var currentFile = ""
    var bytesTotal: Int64 = 0
    var bytesFinished: Int64 = 0   // completed + skipped files
    var currentFileDone: Int64 = 0
    var filesTotal = 0
    var filesCopied = 0
    var filesSkipped = 0
    var filesFailed = 0
    @Published var trustedPrior = 0  // files NOT re-read this run (prior generations)
    @Published var fullyVerified = false
    @Published var safeToWipe = false
    @Published var physicalDevices = 0
    @Published var wipeBlockers: [String] = []
    private(set) var messages: [JobMessage] = []
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    @Published var reportPath: String?
    @Published var reportFailed = false
    @Published var reportPaths: [String] = []
    @Published var manifestPaths: [String] = []
    @Published var receiptPath: String?
    // Lane model (two-sided workbench): ordered card roots from job_started,
    // and verified-progress per root from file_done's status map.
    @Published var laneRoots: [String] = []
    var destProgress: [String: DestProgress] = [:]
    /// A later Verify Existing Custody run over one of this job's lanes. The
    /// offload verdict stays what the offload proved; this is a separate,
    /// dated result, so the workbench can never show only the happy earlier
    /// one after a newer check found damage (Codex desktop QA 2026-09-15,
    /// DT-QA-04). A damaged result also revokes SAFE TO WIPE.
    @Published var laterVerification: LaterVerification?
    @Published var custodyFailures: [String: LaterVerification] = [:]
    var hasCustodyFailure: Bool { !custodyFailures.isEmpty }
    var currentCustodyEcho: String? {
        hasCustodyFailure ? "custody check failed, keep the card" : verdict.railEcho
    }
    func custodyFailure(for root: String) -> LaterVerification? {
        custodyFailures.first { pathIsAtOrInsideLexically($0.key, root: root)
            || pathIsAtOrInsideLexically(root, root: $0.key) }?.value
    }
    var startedDate: Date?
    var finishedDate: Date?
    var rereadDone: Int64 = 0
    var rereadTotal: Int64 = 0
    // Live throughput (agy GUI audit rank 1): a blank bar can't distinguish
    // 1,200 MB/s from a dying cable at 4 MB/s. Sampled ~1 Hz from progress
    // events; history feeds the sparkline.
    @Published var currentSpeed: Double = 0       // bytes/sec, rolling
    @Published var speedHistory: [Double] = []    // 1 Hz samples, capped
    // Observed-fact escalators. Both report what the byte counters did — a
    // stall is "no bytes arrived for N seconds", not "the cable is bad", and
    // the advisory is "the rate stayed under a quarter of this phase's own
    // average", not a thermal diagnosis. Neither may ever be inferred from
    // phase alone: only a real sample moves them.
    @Published var stallSeconds: Int = 0
    @Published var throttleAdvisory: Bool = false
    /// Source reads are paused but the engine is reading copies back to
    /// verify them. The speed readout says so instead of "waiting for I/O".
    @Published var verifyingCopies: Bool = false
    private var lastPipelineActivity: Date?
    private var stallCarry: TimeInterval = 0
    private var throttleCarry: TimeInterval = 0
    private var throttleRecoveryCarry: TimeInterval = 0
    private var speedCounterBytes: Int64 = 0
    private var speedBaselineBytes: Int64 = 0
    private var speedBaselineTime: Date?
    private var speedPhaseTag = ""
    private var phaseStartBytes: Int64 = 0
    private var phaseStartTime: Date?
    private var phaseStartFiles = 0
    // Runtime evidence from file_done, never restored as current authority.
    var verifiedFileHashes: [String: UInt64] = [:]
    @Published var destinationCheckPending = false
    private var copyProgressByPath: [String: Int64] = [:]
    private(set) var copyBytesRead: Int64 = 0
    private(set) var trustedBytesNotRead: Int64 = 0

    /// Add only bytes actually observed in source-read progress events. Logical
    /// completion counters include trusted skips and late verify completions;
    /// neither is throughput and both used to manufacture speed spikes.
    func recordCopyProgress(path: String, done: Int64) {
        guard done >= 0 else { return }
        let prior = copyProgressByPath[path] ?? 0
        guard done >= prior else { return }
        let delta = done - prior
        copyProgressByPath[path] = done
        let (next, overflow) = copyBytesRead.addingReportingOverflow(delta)
        if !overflow { copyBytesRead = next }
    }

    /// Feed the current phase's monotonic byte counter. Sampling is performed
    /// by AppModel's real 1 Hz timer so a stalled transfer decays to 0 B/s even
    /// when the engine emits no further progress events.
    func recordThroughput(_ totalBytes: Int64, phase tag: String, at now: Date = Date()) {
        if speedPhaseTag != tag || speedBaselineTime == nil {
            speedPhaseTag = tag
            speedCounterBytes = totalBytes
            speedBaselineBytes = totalBytes
            speedBaselineTime = now
            phaseStartBytes = totalBytes
            phaseStartTime = now
            phaseStartFiles = filesFinished
            currentSpeed = 0
            speedHistory.removeAll(keepingCapacity: true)
            resetEscalators()
            return
        }
        if totalBytes < speedCounterBytes {
            // Re-baseline a counter reset without turning the later recovery
            // into an artificial spike. The PHASE anchors re-baseline too —
            // otherwise moved goes negative, the ETA disappears until the
            // counter regains its old peak, and the throttle average reads
            // stale data (Ox review, F4).
            speedCounterBytes = totalBytes
            speedBaselineBytes = totalBytes
            speedBaselineTime = now
            phaseStartBytes = totalBytes
            phaseStartTime = now
            phaseStartFiles = filesFinished
            currentSpeed = 0
            return
        }
        if totalBytes > speedCounterBytes {
            // A progress event is stronger and earlier evidence than the next
            // one-second sampler tick. Remove both stall tiers as soon as the
            // monotonic phase counter moves.
            stallCarry = 0
            if stallSeconds != 0 { stallSeconds = 0 }
        }
        speedCounterBytes = totalBytes
    }

    func sampleThroughput(at now: Date = Date()) {
        guard let baselineTime = speedBaselineTime else { return }
        let dt = now.timeIntervalSince(baselineTime)
        guard dt >= 0.5 else { return }
        let delta = speedCounterBytes - speedBaselineBytes
        speedBaselineBytes = speedCounterBytes
        speedBaselineTime = now
        guard delta >= 0 else {
            currentSpeed = 0
            updateEscalators(rate: 0, dt: dt, at: now)
            return
        }
        let rate = Double(delta) / dt
        currentSpeed = rate
        speedHistory.append(rate)
        if speedHistory.count > 60 { speedHistory.removeFirst(speedHistory.count - 60) }
        updateEscalators(rate: rate, dt: dt, at: now)
    }

    /// Stall + throttle accounting, driven ONLY by real samples of the phase's
    /// own byte counter. Both reset on a phase change and whenever the job is
    /// not actually moving bytes (sealing manifests at 0 B/s is not a stall).
    private func updateEscalators(rate: Double, dt: TimeInterval, at now: Date) {
        guard phase == .copying || phase == .sourceVerify else {
            resetEscalators()
            return
        }
        guard phaseSawFileActivity else { return }
        // Whole consecutive seconds with a zero sample. The epsilon absorbs
        // Date arithmetic drift so a 0.9999s tick still counts as its second.
        if rate > 0 {
            stallCarry = 0
            if stallSeconds != 0 { stallSeconds = 0 }
            if verifyingCopies { verifyingCopies = false }
        } else if let last = lastPipelineActivity,
                  now.timeIntervalSince(last) < Self.pipelineQuietWindow {
            // No source bytes, but the pipeline moved: not a stall.
            stallCarry = 0
            if stallSeconds != 0 { stallSeconds = 0 }
        } else {
            if verifyingCopies { verifyingCopies = false }
            stallCarry += dt
            let whole = Int(stallCarry + 0.001)
            if whole != stallSeconds { stallSeconds = whole }
        }
        // Sustained drop vs THIS phase's cumulative average. Guards keep the
        // advisory off during spin-up and off slow media where a quarter of a
        // small average is meaningless.
        guard let start = phaseStartTime else { clearThrottle(); return }
        let elapsed = now.timeIntervalSince(start)
        let moved = speedCounterBytes - phaseStartBytes
        guard elapsed > 60, moved > 0 else { clearThrottle(); return }
        let average = Double(moved) / elapsed
        guard average > 10_000_000 else { clearThrottle(); return }
        // rate == 0 is a STALL (its own escalator) — only a nonzero crawl
        // below a quarter of the average reads as throttling (agy audit 6).
        if throttleAdvisory {
            // Once raised, a single sample near the 25% boundary must not
            // erase the observation. Only ten consecutive seconds above a
            // separate 40% recovery line clear it.
            if rate > average * 0.40 {
                throttleRecoveryCarry += dt
                if throttleRecoveryCarry + 0.001 >= 10 { clearThrottle() }
            } else {
                throttleRecoveryCarry = 0
            }
            return
        }
        throttleRecoveryCarry = 0
        if rate > 0, rate < average * 0.25 {
            throttleCarry += dt
            if throttleCarry + 0.001 >= 45 { throttleAdvisory = true }
        } else {
            throttleCarry = 0
        }
    }

    private func clearThrottle() {
        throttleCarry = 0
        throttleRecoveryCarry = 0
        if throttleAdvisory { throttleAdvisory = false }
    }

    /// Destination read-back (verify_progress) and settled files (file_done)
    /// are pipeline motion while the source counter holds still: the engine
    /// stops reading the card while it reads the last copies back. Counting
    /// only source bytes put "I/O stalled — check cables and drives" on a
    /// healthy run that then finished verified (Joshua, 2026-09-28).
    func notePipelineActivity(verifyingCopy: Bool, at now: Date = Date()) {
        lastPipelineActivity = now
        stallCarry = 0
        if stallSeconds != 0 { stallSeconds = 0 }
        if verifyingCopy, !verifyingCopies { verifyingCopies = true }
    }

    /// The engine emits a verify heartbeat at most once a second per
    /// destination; three seconds of silence after one is a real pause.
    static let pipelineQuietWindow: TimeInterval = 3

    private func resetEscalators() {
        stallCarry = 0
        if stallSeconds != 0 { stallSeconds = 0 }
        lastPipelineActivity = nil
        if verifyingCopies { verifyingCopies = false }
        phaseSawFileActivity = false
        clearThrottle()
    }

    /// The engine's silent pre-copy window (history validation, pinning,
    /// preflight) emits no file events, so zero-rate samples there are not
    /// I/O stalls. Escalators arm only once the phase touches its first file
    /// (round-24 finding: healthy continuation preflights escalated all the
    /// way to "engine may have hung").
    private(set) var phaseSawFileActivity = false
    func noteFileActivity() { phaseSawFileActivity = true }

    /// Forget a finished file's progress entry. The engine emits all source
    /// progress for a file before submitting it for verification, so nothing
    /// legitimate follows its file_done — dropping the entry keeps the map
    /// bounded on 100k-file cards (round-15 PR review finding 4) while
    /// copyBytesRead retains the phase total.
    func finishCopyProgress(path: String) {
        copyProgressByPath.removeValue(forKey: path)
    }

    /// Apply one engine-authoritative per-root status to a workbench lane.
    /// `trusted` is prior sealed evidence, not a failure and not a byte read in
    /// this run; keeping it separate lets continuations advance honestly
    /// without relabeling old evidence as newly verified throughput.
    func recordDestinationStatus(root: String, status: String, bytes: Int64) {
        let safeBytes = max(0, bytes)
        var p = destProgress[root] ?? DestProgress()
        switch status {
        case "verified", "skipped":
            p.filesVerified += 1
            p.bytesVerified += safeBytes
        case "trusted":
            p.filesTrusted += 1
            p.bytesTrusted += safeBytes
        case "size-only":
            p.sizeOnly += 1
            p.bytesSizeOnly += safeBytes
        default:
            p.filesFailed += 1
        }
        destProgress[root] = p
    }

    /// A pure trusted skip has no `file_done` event because the source was not
    /// opened at all. It is trusted at every lane root by construction.
    func recordTrustedSkipForAllDestinations(bytes: Int64) {
        let safeBytes = max(0, bytes)
        let (next, overflow) = trustedBytesNotRead.addingReportingOverflow(safeBytes)
        if !overflow { trustedBytesNotRead = next }
        for root in laneRoots {
            recordDestinationStatus(root: root, status: "trusted", bytes: safeBytes)
        }
    }

    /// Bytes whose source-read phase is already accounted for: actual observed
    /// reads plus pure trusted skips that intentionally never opened the card.
    /// ETA must not mix the verification-completion counter with a source-read
    /// rate; pipelining otherwise double-counts finished reads and omits staged
    /// files still waiting for destination verification.
    var copySourceBytesAccounted: Int64 {
        let (sum, overflow) = copyBytesRead.addingReportingOverflow(trustedBytesNotRead)
        return min(bytesTotal, overflow ? Int64.max : sum)
    }

    func stopThroughput() {
        currentSpeed = 0
        speedBaselineTime = nil
        speedPhaseTag = ""
        resetEscalators()
        copyProgressByPath.removeAll()
    }
    // Protocol accounting: an engine run that exits 0 WITHOUT the terminal
    // event (older engine, wedged run) must fail closed, never look done.
    var sawEngineHello = false
    var sawOffloadComplete = false
    var sawAttestation = false
    private var attestedSafeToWipe: Bool?
    // offload_complete payload, held PENDING until the process exits 0 with a
    // clean protocol — terminal safety state must never unlock early.
    var pendingTerminalOk = false
    var pendingFullyVerified: Bool?
    var pendingSafeToWipe: Bool?
    var engineProtocolOK = false

    init(label: String, sourcePath: String, destinations: [String],
         sourceAssignmentID: UUID? = nil, id: UUID = UUID(),
         runID: UUID = UUID(), createdDate: Date = Date()) {
        self.id = id
        self.runID = runID
        self.createdDate = createdDate
        self.label = label
        self.sourcePath = sourcePath
        self.destinations = destinations
        self.sourceAssignmentID = sourceAssignmentID
    }

    func markRestoredFromJournal() {
        restoredFromJournal = true
    }

    func markRestoredInterrupted() {
        restoredInterrupted = true
    }

    func verdictIsFresh(for assignmentID: UUID?) -> Bool {
        guard let assignmentID, let sourceAssignmentID else { return false }
        return assignmentID == sourceAssignmentID
    }

    /// Eject eligibility for source history ordered newest-first. A failed or
    /// verified-but-keep-card attempt must lock the card, but a later
    /// authoritative SAFE TO WIPE retry supersedes that attempt for the same
    /// source path. `verdict` is deliberately the only safety authority here:
    /// `phase == .done` plus `fullyVerified` describes copy evidence, not
    /// permission to remove the source.
    static func latestSourceRunsAllowEject(_ jobs: [Job]) -> Bool {
        var latestBySource: [String: Job] = [:]
        for job in jobs where latestBySource[job.sourcePath] == nil {
            latestBySource[job.sourcePath] = job
        }
        return latestBySource.values.allSatisfy { $0.verdict == .safeToWipe }
    }

    private var progressUpdatePending = false

    func publishProgress() {
        guard !progressUpdatePending else { return }
        progressUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.progressUpdatePending = false
            self.objectWillChange.send()
        }
    }

    func replaceMessages(_ values: [JobMessage]) {
        messages = values
        errorCount = values.reduce(0) { $0 + ($1.severity == .error ? 1 : 0) }
        warningCount = values.count - errorCount
        publishProgress()
    }

    func appendMessages(_ values: [JobMessage]) {
        guard !values.isEmpty else { return }
        messages.append(contentsOf: values)
        let errors = values.reduce(0) { $0 + ($1.severity == .error ? 1 : 0) }
        errorCount += errors
        warningCount += values.count - errors
        publishProgress()
    }

    func error(_ text: String) { appendMessages([JobMessage(severity: .error, text: text)]) }
    func warn(_ text: String) { appendMessages([JobMessage(severity: .warning, text: text)]) }

    static let messagePageSize = 100
    func messagePage(_ page: Int) -> [JobMessage] {
        let start = min(max(0, page), max(0, (messages.count - 1) / Self.messagePageSize)) * Self.messagePageSize
        return Array(messages[start..<min(start + Self.messagePageSize, messages.count)])
    }

    /// Record the observation without ending `isRunning`: the engine process
    /// still owns file handles until its termination callback arrives, so quit
    /// and eject interlocks must remain engaged during shutdown.
    @discardableResult
    func noteSourceMutation() -> Bool {
        guard !sourceMutatedAfterStart else { return false }
        sourceMutatedAfterStart = true
        // Finder browsing no longer lands here (source watchers ignore its
        // .DS_Store, "._" sidecars and tags), so this is a real change to a
        // file on the card: say that plainly (Joshua, 2026-09-28).
        error("source changed after Start — a file on the card was added, removed, renamed "
              + "or rewritten while it was copying. This run cannot authorize wiping the card")
        return true
    }

    /// Set once a destination this SAFE verdict rests on unmounted, or a
    /// copied file under it changed, after the verdict settled. The receipt
    /// stays what the offload proved; current wipe authority (rail echo,
    /// one-click eject, Dock checkmark, notification eject) is withdrawn
    /// for good, and a remount does not restore it (desktop QA round 3,
    /// R3-01). Not persisted: a restored record is never current anyway.
    @Published private(set) var destinationAuthorityWithdrawn: String?
    /// The lane root the withdrawal named, so that lane can render the
    /// failure instead of a green summary (desktop QA round 5, R5-01).
    private(set) var destinationAuthorityWithdrawnRoot: String?
    /// True when the withdrawal happened because the drive holding that lane
    /// went away (ejected or unplugged), not because a copied file changed.
    /// Presentation only: authority is withdrawn exactly the same way. At
    /// wrap the DIT ejects the backup drives on purpose, and a red "keep the
    /// card" on every SAFE card read as damage (Joshua, 2026-09-28).
    private(set) var destinationAuthorityWithdrawnByEjection = false

    /// The drive name for the ejected-lane wording, nil unless the
    /// withdrawal was an ejection.
    var ejectedDestinationName: String? {
        guard destinationAuthorityWithdrawnByEjection,
              let root = destinationAuthorityWithdrawnRoot else { return nil }
        return endpointName(root)
    }

    @discardableResult
    func withdrawDestinationAuthority(_ reason: String, root: String? = nil,
                                      ejected: Bool = false) -> Bool {
        guard destinationAuthorityWithdrawn == nil else { return false }
        destinationAuthorityWithdrawn = reason
        destinationAuthorityWithdrawnRoot = root
        destinationAuthorityWithdrawnByEjection = ejected && root != nil
        warn("current wipe authority withdrawn — \(reason). The verdict above "
             + "records what this run proved; verify the copies again before wiping.")
        return true
    }

    /// Terminal fail-closed override. This is deliberately applied after any
    /// pending engine terminal payload so a late optimistic event cannot undo
    /// GUI-side mutation evidence.
    func enforceSourceMutationFailure() {
        sourceMutatedAfterStart = true
        pendingTerminalOk = false
        pendingFullyVerified = false
        pendingSafeToWipe = false
        phase = .failed
        fullyVerified = false
        safeToWipe = false
    }

    /// A terminal result is not durable evidence until the journal commit
    /// succeeds. If that commit fails, revoke every pending and published
    /// safety bit before any badge, notification, webhook, or eject control
    /// can observe the job.
    func enforceJournalPersistenceFailure(_ detail: String) {
        pendingTerminalOk = false
        pendingFullyVerified = false
        pendingSafeToWipe = false
        phase = .failed
        fullyVerified = false
        safeToWipe = false
        let message = "job journal could not record the terminal result — "
            + Job.Verdict.failed.displayLine + " (\(detail))"
        if !messages.contains(where: { $0.text == message }) {
            error(message)
        }
    }

    /// Accept the engine's proof-bearing attestation. Safety and blocker
    /// presence are an equivalence in protocol v3; either side missing or
    /// disagreeing is malformed authority, not a value to default. The value
    /// remains private evidence until a matching terminal frame and clean
    /// process exit publish `safeToWipe`.
    func acceptAttestation(safe: Bool, blockers: [String]) -> Bool {
        guard safe == blockers.isEmpty else { return false }
        sawAttestation = true
        attestedSafeToWipe = safe
        wipeBlockers = blockers
        return true
    }

    /// Hold a terminal result pending process exit. A successful terminal must
    /// agree with the earlier attestation; only an all-false early failure may
    /// legitimately terminate before an attestation exists.
    func acceptTerminal(ok: Bool, fullyVerified: Bool, safeToWipe: Bool) -> Bool {
        guard !safeToWipe || (ok && fullyVerified) else { return false }
        if sawAttestation {
            guard attestedSafeToWipe == safeToWipe else { return false }
        } else {
            guard !ok && !fullyVerified && !safeToWipe else { return false }
        }
        sawOffloadComplete = true
        pendingTerminalOk = ok
        pendingFullyVerified = fullyVerified
        pendingSafeToWipe = safeToWipe
        return true
    }


    /// Settled bytes plus every file still copying or waiting for its
    /// verify. With overlapped verify, file N+1 starts before file N's
    /// file_done, so counting only the current file dropped file N's bytes
    /// and the bar fell back at each boundary (desktop QA round 9, F1).
    /// A record restored from the journal has no per-file map; its saved
    /// currentFileDone still counts.
    var displayedBytesDone: Int64 {
        var inFlight: Int64 = 0
        for done in copyProgressByPath.values {
            let (next, overflow) = inFlight.addingReportingOverflow(done)
            inFlight = overflow ? Int64.max : next
        }
        let (total, overflow) = bytesFinished.addingReportingOverflow(max(inFlight, currentFileDone))
        return overflow ? Int64.max : total
    }

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1.0, Double(displayedBytesDone) / Double(bytesTotal))
    }

    var isRunning: Bool {
        phase != .done && phase != .failed && phase != .refused
    }

    /// THE single source of verdict truth. The badge and any rail echo both
    /// render from this one switch, so they can never drift (Opus spec §3.5 —
    /// this extraction is mandatory, not cosmetic).
    enum Verdict {
        case running, safeToWipe, verifiedKeepCard, unverified, failed

        /// Derive the semantic verdict from persisted protocol facts.  The
        /// user-facing wording remains exclusively in `displayLine`; callers
        /// that only have a journal record can use this helper without
        /// reimplementing (and potentially drifting from) Job's authority
        /// mapping.
        static func from(phase: JobPhase, fullyVerified: Bool,
                         safeToWipe: Bool, filesFailed: Int) -> Verdict {
            switch phase {
            case .failed, .refused:
                return .failed
            case .done:
                if !fullyVerified || filesFailed > 0 { return .unverified }
                return safeToWipe ? .safeToWipe : .verifiedKeepCard
            default:
                return .running
            }
        }

        /// THE user-facing verdict line, shared by every channel (badge,
        /// notification, dock tooltip). Three surfaces hand-writing these
        /// strings is how a notification once said UNVERIFIED for a verified
        /// card — one mapping, no drift (Kimi feature review F15).
        var displayLine: String {
            switch self {
            case .running: return "Running"
            case .safeToWipe: return "SAFE TO WIPE"
            case .verifiedKeepCard: return "VERIFIED · KEEP CARD"
            case .unverified: return "UNVERIFIED — KEEP CARD"
            case .failed: return "FAILED — DO NOT WIPE"
            }
        }
    }
    var verdict: Verdict {
        Verdict.from(phase: phase, fullyVerified: fullyVerified,
                     safeToWipe: safeToWipe, filesFailed: filesFailed)
    }

    /// Display-only observation derived from the consecutive zero-byte
    /// counter. The 120-second tier names a possibility, never a diagnosis.
    var stallObservation: String? {
        if stallSeconds >= 120 {
            return "engine may have hung — no bytes for 2 minutes"
        }
        if stallSeconds >= 20 {
            return "I/O stalled \(stallSeconds)s — check cables and drives"
        }
        return nil
    }

    /// ETA rate: the CUMULATIVE average since the phase began — bytes
    /// observed over wall-clock elapsed, stalls included. Steady where the
    /// instantaneous and short-window rates whipsaw (Joshua: "0 KB/s but the
    /// ETA kept changing"): the pipeline's back-pressure stalls are real
    /// time the estimate must absorb, not noise to react to. nil for the
    /// first 3 seconds so no garbage number ever renders. The sparkline and
    /// the live speed readout keep the raw 1 Hz motion.
    var etaRate: Double? { byteRate(at: Date()) }

    func byteRate(at now: Date) -> Double? {
        guard let start = phaseStartTime else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 3 else { return nil }
        let delta = speedCounterBytes - phaseStartBytes
        guard delta > 0 else { return nil }
        return Double(delta) / elapsed
    }

    /// Every file the engine has settled this run, whatever the outcome.
    var filesFinished: Int { filesCopied + filesSkipped + filesFailed }

    /// Files settled per second since the phase began, same cumulative
    /// discipline as the byte rate. The byte rate is blind to per-file
    /// work: one 16 GiB file beside 60,000 small ones put bytes at 99% and
    /// the copy ETA at "1 second" for minutes while the file counter crawled
    /// (desktop QA round 3, R3-03).
    func fileRate(at now: Date) -> Double? {
        guard let start = phaseStartTime else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 3 else { return nil }
        let delta = filesFinished - phaseStartFiles
        guard delta > 0 else { return nil }
        return Double(delta) / elapsed
    }

    /// Copy ETA in seconds: the SLOWER of the byte-based and file-based
    /// predictions, so whichever kind of work remains sets the estimate.
    /// nil while neither predictor has evidence, which the readout renders
    /// as no estimate rather than a confident wrong one.
    func copyETASeconds(at now: Date = Date()) -> Int? {
        // The rate measures observed SOURCE reads, so the numerator must be
        // remaining source bytes too. Verification-completion bytes are a
        // different pipeline stage and can lag several files behind.
        let done = copySourceBytesAccounted
        var byteETA: Int?
        if let rate = byteRate(at: now), rate > 0, bytesTotal > done {
            byteETA = Int(Double(bytesTotal - done) / rate)
        }
        var fileETA: Int?
        let remainingFiles = filesTotal - filesFinished
        if let rate = fileRate(at: now), rate > 0, remainingFiles > 0 {
            fileETA = Int(Double(remainingFiles) / rate)
        }
        guard byteETA != nil || fileETA != nil else { return nil }
        return max(byteETA ?? 0, fileETA ?? 0)
    }
}
