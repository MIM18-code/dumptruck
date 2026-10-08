import Foundation
import Combine

enum ThroughputCheck {

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

    @MainActor
    static func run() {
        let bulk = Job(label: "ERRORS", sourcePath: "/source", destinations: ["/dest"])
        let begin = Date()
        for i in 0..<72000 { bulk.error("failure \(i)") }
        require(bulk.errorCount == 72000 && bulk.warningCount == 0, "cached counts lost errors")
        require(bulk.messagePage(0).count == 100 && bulk.messagePage(719).last?.text == "failure 71999",
                "bounded pages must retain the final error")
        require(bulk.messagePage(Int.max).count == 100, "out-of-range page must clamp safely")
        require(Date().timeIntervalSince(begin) < 5, "message append must not copy or scan the entire history per row")
        let progress = Job(label: "PROGRESS", sourcePath: "/source", destinations: ["/dest"])
        var updates = 0
        let subscription = progress.objectWillChange.sink { updates += 1 }
        for i in 0..<1000 {
            require(AppModel.apply(event: ["event": "file_done", "path": "f\(i)", "bytes": 4,
                "outcome": "verified", "status": ["/dest": "verified"]], to: progress), "file event rejected")
        }
        require(progress.filesCopied == 1000 && progress.bytesFinished == 4000
            && progress.destProgress["/dest"]?.filesVerified == 1000,
            "coalescing view updates must never lose accounting")
        require(updates == 0, "file events must not synchronously publish each counter change")
        progress.phase = .failed
        require(updates > 0, "terminal safety state must still publish immediately")
        withExtendedLifetime(subscription) {}
        require(AppModel.isFileActivityEvent("file_done") && !AppModel.isFileActivityEvent("offload_complete"),
                "terminal events must still refresh global controls")

        // A pipe reader used to request 64 KiB and therefore withheld the
        // engine's short JSON lines until EOF. Prove the launch primitive
        // returns while the writer is deliberately still alive.
        let streamProbe = Pipe()
        let probeWriter = streamProbe.fileHandleForWriting
        let probeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            try? probeWriter.write(contentsOf: Data("live\n".utf8))
            Thread.sleep(forTimeInterval: 0.75)
            try? probeWriter.close()
            probeFinished.signal()
        }
        let probeStart = Date()
        let probeData = EnginePipeReader.nextChunk(from: streamProbe.fileHandleForReading)
        let probeElapsed = Date().timeIntervalSince(probeStart)
        require(probeData == Data("live\n".utf8),
                "engine pipe reader lost the first live protocol chunk")
        require(probeElapsed < 0.5,
                "engine pipe reader waited for EOF instead of streaming live protocol")
        probeFinished.wait()

        let stalled = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
stalled.recordThroughput(0, phase: "copy")
stalled.noteFileActivity()
stalled.recordCopyProgress(path: "A.mov", done: 100)
stalled.recordThroughput(stalled.copyBytesRead, phase: "copy")
let firstTick = Date().addingTimeInterval(1.1)
stalled.sampleThroughput(at: firstTick)
require(stalled.copyBytesRead == 100, "copy counter included unobserved bytes")
require(stalled.currentSpeed > 0, "observed progress did not produce throughput")

// A trusted skip emits no source progress. The wall-clock tick must age the
// rate to zero rather than converting the skipped file's logical size into a
// fictitious speed or retaining the previous healthy sample through a stall.
stalled.sampleThroughput(at: firstTick.addingTimeInterval(1.0))
require(stalled.currentSpeed == 0, "stalled throughput did not age to zero")

let pipelined = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
pipelined.recordCopyProgress(path: "A.mov", done: 100)
pipelined.recordCopyProgress(path: "B.mov", done: 40)
pipelined.recordCopyProgress(path: "A.mov", done: 100) // duplicate late event
pipelined.recordCopyProgress(path: "B.mov", done: 70)
require(pipelined.copyBytesRead == 170,
        "pipelined progress double-counted or lost source bytes")

pipelined.recordThroughput(0, phase: "copy")
pipelined.recordThroughput(1_000, phase: "copy")
pipelined.sampleThroughput(at: Date().addingTimeInterval(1.1))
require(pipelined.currentSpeed > 0, "copy sample was not recorded")
pipelined.recordThroughput(0, phase: "reread")
pipelined.noteFileActivity()
require(pipelined.currentSpeed == 0, "phase change retained stale speed")
require(pipelined.speedHistory.isEmpty, "phase change mixed copy and reread history")

// Mixed continuations report `trusted` for a destination that already held a
// sealed copy and `verified` for a destination filled this run. Neither lane is
// a failure; trusted evidence stays separately disclosed.
let continuation = Job(label: "CARD", sourcePath: "/source",
                       destinations: ["/old", "/new"])
continuation.laneRoots = ["/old", "/new"]
continuation.recordDestinationStatus(root: "/old", status: "trusted", bytes: 100)
continuation.recordDestinationStatus(root: "/new", status: "verified", bytes: 100)
require(continuation.destProgress["/old"]?.filesFailed == 0,
        "trusted continuation status was painted as a lane failure")
require(continuation.destProgress["/old"]?.filesTrusted == 1,
        "trusted continuation evidence was not disclosed separately")
require(continuation.destProgress["/new"]?.filesVerified == 1,
        "newly verified destination evidence was lost")
require(continuation.destProgress["/old"]?.completionBytes == 100,
        "trusted bytes were omitted from lane completion/laggard math")
continuation.bytesTotal = 300
continuation.recordTrustedSkipForAllDestinations(bytes: 100)
continuation.recordCopyProgress(path: "new.mov", done: 50)
require(continuation.copySourceBytesAccounted == 150,
        "copy ETA mixed verification completion with observed/trusted source bytes")

// A terminal event may never upgrade the earlier engine attestation. This was
// a direct presentation fail-open: unsafe+blocked followed by terminal safe
// could previously end with a green SAFE TO WIPE badge.
let protocolJob = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
require(protocolJob.acceptAttestation(safe: false, blockers: ["one device"]),
        "valid unsafe attestation was rejected")
require(!protocolJob.acceptTerminal(ok: true, fullyVerified: true, safeToWipe: true),
        "contradictory terminal event upgraded an unsafe attestation")

// A verdict belongs to one staging session, not to a reusable mount path.
// Remounting the same card after recording more footage must not resurrect the
// prior session's "can be wiped" rail echo before a continuation run.
let priorAssignment = UUID()
let remountedAssignment = UUID()
let priorRun = Job(label: "CARD", sourcePath: "/Volumes/CARD",
                   destinations: ["/dest"], sourceAssignmentID: priorAssignment)
priorRun.phase = .done
priorRun.fullyVerified = true
priorRun.safeToWipe = true
require(priorRun.verdictIsFresh(for: priorAssignment),
        "a verdict was not available to its own staging session")
require(!priorRun.verdictIsFresh(for: remountedAssignment),
        "a prior verdict leaked onto a remounted same-path card")
let inPlaceMutationAssignment = UUID()
require(!priorRun.verdictIsFresh(for: inPlaceMutationAssignment),
        "a prior verdict survived an in-place source mutation")
require(!priorRun.verdictIsFresh(for: nil),
        "a verdict without a current source assignment was treated as fresh")

// A stopped watcher's callback can arrive after a new card is assigned at the
// same mount path. Watch identity—not path text or the changing verdict UUID—
// decides which callbacks still belong to the live watcher.
var monitorSession = SourceMonitorSession()
let oldMonitor = monitorSession.begin()
require(monitorSession.accepts(oldMonitor),
        "a live source watcher rejected its own callback")
let replacementMonitor = monitorSession.begin()
require(!monitorSession.accepts(oldMonitor),
        "a stopped same-path watcher callback reached the replacement source")
require(monitorSession.accepts(replacementMonitor),
        "the replacement source watcher did not accept repeated events")
monitorSession.end()
require(!monitorSession.accepts(replacementMonitor),
        "a source watcher callback survived explicit teardown")

// GUI-side filesystem evidence is independent of the engine protocol. Even a
// later well-formed optimistic terminal event cannot upgrade a source that the
// recursive watcher saw mutate after Start.
let sourceMutationJob = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
require(sourceMutationJob.noteSourceMutation(),
        "first source-mutation observation was not recorded")
require(!sourceMutationJob.noteSourceMutation(),
        "an event burst duplicated the source-mutation error")
require(sourceMutationJob.acceptAttestation(safe: true, blockers: []),
        "setup: safe attestation was rejected")
require(sourceMutationJob.acceptTerminal(ok: true, fullyVerified: true, safeToWipe: true),
        "setup: valid terminal event was rejected")
sourceMutationJob.enforceSourceMutationFailure()
require(sourceMutationJob.verdict == .failed,
        "terminal success upgraded a source that changed after Start")
require(!sourceMutationJob.safeToWipe && !sourceMutationJob.fullyVerified,
        "source mutation left an eject-authorizing Boolean set")

// A terminal verdict that cannot cross the durable journal boundary is not
// wipe authority. Every published and pending safety bit must be revoked
// before the UI, notifications, or eject controls can observe it.
let journalFailureJob = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
require(journalFailureJob.acceptAttestation(safe: true, blockers: []),
        "setup: journal-failure attestation was rejected")
require(journalFailureJob.acceptTerminal(ok: true, fullyVerified: true, safeToWipe: true),
        "setup: journal-failure terminal event was rejected")
journalFailureJob.phase = .done
journalFailureJob.fullyVerified = true
journalFailureJob.safeToWipe = true
journalFailureJob.enforceJournalPersistenceFailure("simulated durable-write failure")
require(journalFailureJob.verdict == .failed,
        "journal failure left the job in an eject-authorizing verdict")
require(!journalFailureJob.safeToWipe && !journalFailureJob.fullyVerified,
        "journal failure left a published safety bit set")
require(journalFailureJob.pendingTerminalOk == false
            && journalFailureJob.pendingFullyVerified == false
            && journalFailureJob.pendingSafeToWipe == false,
        "journal failure left a pending terminal upgrade available")

// One nested destination choice is a relative folder projected under every
// destination anchor, before the standing organization template. It must not
// confuse a similarly-prefixed sibling for a child or manufacture traversal.
require(DestinationFolderProjection.relativePath(
    selected: "/Volumes/DEST_A/Productions/Show 01/Media",
    under: "/Volumes/DEST_A") == "Productions/Show 01/Media",
    "nested destination folder did not become a drive-relative mirror path")
require(DestinationFolderProjection.relativePath(
    selected: "/Volumes/DEST_A", under: "/Volumes/DEST_A") == "",
    "choosing the destination root did not clear the mirrored folder")
require(DestinationFolderProjection.relativePath(
    selected: "/Volumes/DEST_AB/Media", under: "/Volumes/DEST_A") == nil,
    "component-prefix sibling escaped destination containment")
require(DestinationFolderProjection.relativePath(
    selected: "/Volumes/DEST_A/../DEST_B/Media", under: "/Volumes/DEST_A") == nil,
    "standardized parent traversal escaped destination containment")
require(DestinationFolderProjection.project(
    root: "/Volumes/DEST_B", mirroredFolder: "Productions/Show 01/Media",
    organizationFolder: "PROJECT/Raws")
    == "/Volumes/DEST_B/Productions/Show 01/Media/PROJECT/Raws",
    "mirrored folder and organization template were projected out of order")

// Eject history is attempt-ordered: a clean retry repairs an older failed
// attempt, while a newer failure must still lock a previously clean card.
let failedAttempt = Job(label: "CARD", sourcePath: "/Volumes/CARD", destinations: ["/dest"])
failedAttempt.phase = .failed
let cleanRetry = Job(label: "CARD", sourcePath: "/Volumes/CARD", destinations: ["/dest"])
cleanRetry.phase = .done
cleanRetry.fullyVerified = true
cleanRetry.safeToWipe = true
require(Job.latestSourceRunsAllowEject([cleanRetry, failedAttempt]),
        "a SAFE TO WIPE retry did not supersede an older failed attempt")
require(!Job.latestSourceRunsAllowEject([failedAttempt, cleanRetry]),
        "a newer failed attempt was hidden by an older clean run")

// Copy verification alone is not eject authority. A pure continuation can
// finish fully verified while its blockers still require KEEP CARD; that
// verdict must remain force-eject-only even when an older attempt was SAFE.
let olderSafe = Job(label: "CARD", sourcePath: "/Volumes/CARD-KEEP",
                    destinations: ["/dest"])
olderSafe.phase = .done
olderSafe.fullyVerified = true
olderSafe.safeToWipe = true
let newerKeepCard = Job(label: "CARD", sourcePath: "/Volumes/CARD-KEEP",
                        destinations: ["/dest"])
newerKeepCard.phase = .done
newerKeepCard.fullyVerified = true
newerKeepCard.safeToWipe = false
require(newerKeepCard.verdict == .verifiedKeepCard,
        "fully verified continuation did not preserve its KEEP CARD verdict")
require(!Job.latestSourceRunsAllowEject([newerKeepCard, olderSafe]),
        "a newer KEEP CARD attempt unlocked an older SAFE attempt")

let incomplete = Job(label: "CARD", sourcePath: "/Volumes/CARD-INCOMPLETE",
                     destinations: ["/dest"])
incomplete.phase = .done
incomplete.fullyVerified = false
require(incomplete.verdict == .unverified,
        "incomplete terminal evidence did not remain UNVERIFIED")
require(!Job.latestSourceRunsAllowEject([incomplete]),
        "an UNVERIFIED attempt received one-click eject authority")

let earlyFailure = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
require(earlyFailure.acceptTerminal(ok: false, fullyVerified: false, safeToWipe: false),
        "all-false early failure terminal should be accepted without attestation")

// Stall escalator: consecutive zero-byte seconds count up while the job is
// actually moving bytes, and any arrival resets them. A stall that silently
// keeps its last healthy speed is how 20 minutes disappear on a bumped cable.
let stallCounter = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
stallCounter.phase = .copying
stallCounter.recordThroughput(0, phase: "copy")
let stallT0 = Date()
// The engine's silent pre-copy window (history validation, preflight) emits
// no file events; zero-rate samples there must not escalate (round-24: a
// healthy continuation preflight climbed to "engine may have hung").
let preflightJob = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
preflightJob.phase = .copying
preflightJob.recordThroughput(0, phase: "copy")
preflightJob.sampleThroughput(at: stallT0.addingTimeInterval(30))
preflightJob.sampleThroughput(at: stallT0.addingTimeInterval(150))
require(preflightJob.stallSeconds == 0 && preflightJob.stallObservation == nil,
        "preflight zero-rate samples escalated before any file activity")
preflightJob.noteFileActivity()  // first file_started — escalators arm
preflightJob.sampleThroughput(at: stallT0.addingTimeInterval(151))
require(preflightJob.stallSeconds == 1,
        "armed escalator did not count after the first file event")
stallCounter.noteFileActivity()
var stallRead: Int64 = 0
@MainActor
func stallFeed(_ bytes: Int64, at offset: TimeInterval) {
    if bytes > 0 {
        stallRead += bytes
        stallCounter.recordCopyProgress(path: "A.mov", done: stallRead)
        stallCounter.recordThroughput(stallCounter.copyBytesRead, phase: "copy")
    }
    stallCounter.sampleThroughput(at: stallT0.addingTimeInterval(offset))
}
stallFeed(1_000_000, at: 1)
require(stallCounter.stallSeconds == 0, "a sample with bytes reported a stall")
stallFeed(0, at: 2)
require(stallCounter.stallSeconds == 1, "first zero-byte second did not count")
stallFeed(0, at: 3)
stallFeed(0, at: 4)
require(stallCounter.stallSeconds == 3, "consecutive zero-byte seconds did not accumulate")
stallFeed(1_000_000, at: 5)
require(stallCounter.stallSeconds == 0, "byte arrival did not clear the stall counter")
stallFeed(0, at: 6)
require(stallCounter.stallSeconds == 1, "stall counter did not restart after recovery")
// Sealing manifests runs at 0 B/s by design — that is not a stall.
stallCounter.phase = .reports
stallFeed(0, at: 7)
require(stallCounter.stallSeconds == 0, "the sealing phase was reported as an I/O stall")

// The existing 20-second observation stays intact, then a distinct 120-second
// tier says the engine MAY have hung. Any byte arrival removes it immediately.
let stallTier = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
stallTier.phase = .copying
stallTier.recordThroughput(0, phase: "copy")
stallTier.noteFileActivity()
let tierT0 = Date()
stallTier.sampleThroughput(at: tierT0.addingTimeInterval(20))
require(stallTier.stallObservation == "I/O stalled 20s — check cables and drives",
        "the existing 20-second stall tier changed")
stallTier.sampleThroughput(at: tierT0.addingTimeInterval(120))
require(stallTier.stallObservation == "engine may have hung — no bytes for 2 minutes",
        "the 120-second engine-hang observation did not raise")
stallTier.recordThroughput(1, phase: "copy")
require(stallTier.stallSeconds == 0 && stallTier.stallObservation == nil,
        "byte movement waited for the sampler before clearing the 120-second tier")
stallTier.sampleThroughput(at: tierT0.addingTimeInterval(121))
require(stallTier.stallSeconds == 0 && stallTier.stallObservation == nil,
        "byte movement did not clear the 120-second stall tier immediately")

// The engine stops reading the card while it reads the last copies back.
// Its verify heartbeat (and each settled file) is pipeline motion, not a
// stall: a healthy final verify once showed "I/O stalled — check cables and
// drives" and then finished verified (Joshua, 2026-09-28). Silence after the
// heartbeat must still escalate.
let verifyTail = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
verifyTail.phase = .copying
verifyTail.recordThroughput(0, phase: "copy")
verifyTail.noteFileActivity()
let tailT0 = Date()
for second in 1...30 {
    verifyTail.notePipelineActivity(verifyingCopy: true,
                                    at: tailT0.addingTimeInterval(Double(second) - 0.5))
    verifyTail.sampleThroughput(at: tailT0.addingTimeInterval(Double(second)))
}
require(verifyTail.stallSeconds == 0 && verifyTail.stallObservation == nil,
        "a destination verify heartbeat was reported as an I/O stall")
require(verifyTail.verifyingCopies, "the verify heartbeat did not say copies are verifying")
verifyTail.sampleThroughput(at: tailT0.addingTimeInterval(33))
require(verifyTail.stallSeconds == 3 && !verifyTail.verifyingCopies,
        "silence after the verify heartbeat did not count as a stall")
verifyTail.sampleThroughput(at: tailT0.addingTimeInterval(53))
require(verifyTail.stallObservation == "I/O stalled 23s — check cables and drives",
        "a real stall after the verify tail did not escalate")

let heartbeatEvent = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
heartbeatEvent.phase = .copying
heartbeatEvent.recordThroughput(0, phase: "copy")
heartbeatEvent.noteFileActivity()
require(AppModel.apply(event: ["event": "verify_progress", "path": "A.mov",
                               "destination": "/dest", "done": 4, "size": 8],
                       to: heartbeatEvent),
        "verify_progress was rejected")
heartbeatEvent.sampleThroughput(at: Date().addingTimeInterval(1))
require(heartbeatEvent.stallSeconds == 0 && heartbeatEvent.verifyingCopies,
        "a verify_progress event did not hold off the stall readout")
require(heartbeatEvent.bytesFinished == 0 && heartbeatEvent.copyBytesRead == 0
        && heartbeatEvent.filesCopied == 0,
        "a verify heartbeat was counted as copy evidence")
require(AppModel.isFileActivityEvent("verify_progress"),
        "verify heartbeats must not refresh global controls per event")

// Throttle advisory: only a SUSTAINED drop below a quarter of the phase's own
// cumulative average raises it, and a recovered rate clears it.
let throttled = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
throttled.phase = .copying
throttled.recordThroughput(0, phase: "copy")
throttled.noteFileActivity()
let throttleT0 = Date()
var throttleRead: Int64 = 0
@MainActor
func throttleFeed(_ bytes: Int64, at offset: TimeInterval) {
    throttleRead += bytes
    throttled.recordCopyProgress(path: "big.mov", done: throttleRead)
    throttled.recordThroughput(throttled.copyBytesRead, phase: "copy")
    throttled.sampleThroughput(at: throttleT0.addingTimeInterval(offset))
}
// 100 s of healthy 100 MB/s establishes the phase average.
throttleFeed(10_000_000_000, at: 100)
require(!throttled.throttleAdvisory, "a healthy rate raised the throttle advisory")
var clock: TimeInterval = 100
for _ in 0..<44 {
    clock += 1
    throttleFeed(1_000_000, at: clock)     // 1 MB/s — far under a quarter
}
require(!throttled.throttleAdvisory,
        "the advisory fired before the sustained-drop window elapsed")
for _ in 0..<3 {
    clock += 1
    throttleFeed(1_000_000, at: clock)
}
require(throttled.throttleAdvisory, "a sustained drop did not raise the advisory")
// Between the 25% raise line and the 40% release line, the raised advisory
// must hold. This is the no-flap band.
for _ in 0..<5 {
    clock += 1
    throttleFeed(20_000_000, at: clock)
}
require(throttled.throttleAdvisory,
        "the advisory flapped off inside the 25%-to-40% hysteresis band")
// Even a strong recovery must last ten consecutive seconds.
for _ in 0..<9 {
    clock += 1
    throttleFeed(100_000_000, at: clock)
}
require(throttled.throttleAdvisory,
        "the advisory cleared before ten seconds above the recovery threshold")
clock += 1
throttleFeed(100_000_000, at: clock)
require(!throttled.throttleAdvisory,
        "ten seconds above the 40% recovery threshold did not clear the advisory")

// ETA presentation holds the projected finish through a full plus-or-minus
// two-minute jitter band. It still counts down by minute and switches to raw
// seconds below 90 seconds; no rate or byte counters participate here.
let etaT0 = Date(timeIntervalSince1970: 2_000_000_000)
var etaHold = ETADisplayHold()
let etaFirst = etaHold.project(secondsRemaining: 180, now: etaT0)!
require(etaFirst.relativeText == "3 min", "a three-minute ETA was not minute-bucketed")
let etaAtMinute = etaHold.project(secondsRemaining: 120,
                                  now: etaT0.addingTimeInterval(60))!
require(etaAtMinute.relativeText == "2 min"
        && etaAtMinute.finishDate == etaFirst.finishDate,
        "a stable held ETA did not count down from the same finish time")
let etaPlusTwo = etaHold.project(secondsRemaining: 240,
                                 now: etaT0.addingTimeInterval(60))!
require(etaPlusTwo.finishDate == etaFirst.finishDate,
        "an ETA exactly two minutes later escaped the hold band")
let etaBeyond = etaHold.project(secondsRemaining: 241,
                                now: etaT0.addingTimeInterval(60))!
require(etaBeyond.finishDate != etaFirst.finishDate,
        "an ETA more than two minutes later did not update")
let etaMinusTwo = etaHold.project(secondsRemaining: 120,
                                  now: etaT0.addingTimeInterval(61))!
require(etaMinusTwo.finishDate == etaBeyond.finishDate,
        "an ETA exactly two minutes earlier escaped the hold band")
let etaSeconds = etaHold.project(secondsRemaining: 89,
                                 now: etaT0.addingTimeInterval(62))!
require(etaSeconds.relativeText == "89s",
        "an ETA under 90 seconds did not return to seconds")

// The HELD projection, not only the raw estimate, eventually reaches the
// 90-second boundary.  A noisy raw estimate may still say three minutes while
// its proposed finish remains inside the hold band.  Crossing the boundary
// must continue from the held clock instead of jumping backward to the raw
// minutes estimate.
var etaBoundaryHold = ETADisplayHold()
let etaBoundaryFirst = etaBoundaryHold.project(secondsRemaining: 180, now: etaT0)!
let etaBoundaryCrossing = etaBoundaryHold.project(
    secondsRemaining: 180, now: etaT0.addingTimeInterval(91))!
require(etaBoundaryCrossing.relativeText == "89s"
        && etaBoundaryCrossing.finishDate == etaBoundaryFirst.finishDate,
        "held ETA jumped backward when its finish crossed the 90-second boundary")

// The menu-bar HUD and Dock are the same safety-presence surface.  A settled
// SAFE job with no current source assignment is historical evidence only; it
// must not leave a stale green verdict in the HUD after unassignment/relaunch.
let hudJournalURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("dumptruck-hud-check-\(UUID().uuidString).json")
let hudModel = AppModel(journal: JobJournal(url: hudJournalURL))
let staleHUDSafe = Job(label: "CARD", sourcePath: "/Volumes/CARD",
                       destinations: ["/dest"], sourceAssignmentID: UUID())
staleHUDSafe.phase = .done
staleHUDSafe.fullyVerified = true
staleHUDSafe.safeToWipe = true
staleHUDSafe.filesFailed = 0
staleHUDSafe.finishedDate = etaT0
hudModel.jobs = [staleHUDSafe]
require(hudModel.settledPresenceVerdict == nil,
        "HUD retained SAFE TO WIPE without current-source authority")

let outstandingFailure = Job(label: "BAD", sourcePath: "/Volumes/BAD",
                             destinations: ["/dest"])
outstandingFailure.phase = .failed
outstandingFailure.finishedDate = etaT0
let newerActive = Job(label: "NEW", sourcePath: "/Volumes/NEW",
                      destinations: ["/dest"])
newerActive.phase = .copying
hudModel.jobs = [outstandingFailure, newerActive]
require(hudModel.dockBadge(activeJobCount: 1) == "!"
        && hudModel.settledPresenceVerdict == .failed,
        "active-job count erased the outstanding Dock/HUD warning")
require(hudModel.hudPresenceLine == "\(Job.Verdict.failed.displayLine) · BAD",
        "HUD warning line lost its referent label")

// Journal-restored history already fails closed on every action surface;
// it must not pin a present-tense warning forever either (round-24: a
// Monday sleep-interrupted job kept the dock "!" for weeks).
let restoredFailure = Job(label: "OLD", sourcePath: "/Volumes/OLD",
                          destinations: ["/dest"])
restoredFailure.phase = .failed
restoredFailure.finishedDate = etaT0
restoredFailure.markRestoredFromJournal()
hudModel.jobs = [restoredFailure]
require(hudModel.settledBadVerdict == nil && hudModel.dockBadge(activeJobCount: 0) == nil,
        "journal-restored failure pinned the Dock/HUD warning across sessions")

// A failure the DIT already retried successfully is history: the Dock "!"
// and the menu-bar FAILED line pinned to it all session (Joshua,
// 2026-09-28). A retry that queued behind waiting cards sits AFTER the
// failed record in `jobs`, so the fixture uses that order on purpose.
// The uptime clock ticks in tens of nanoseconds; the pauses keep creation
// order unambiguous.
let failedFirst = Job(label: "A001", sourcePath: "/Volumes/A001", destinations: ["/dest"])
failedFirst.phase = .failed
usleep(1_000)
let retryOfFailed = Job(label: "A001", sourcePath: "/Volumes/A001", destinations: ["/dest"])
retryOfFailed.phase = .done
retryOfFailed.fullyVerified = true
retryOfFailed.safeToWipe = true
retryOfFailed.physicalDevices = 2
hudModel.jobs = [failedFirst, retryOfFailed]
require(hudModel.settledBadVerdict == nil && hudModel.dockBadge(activeJobCount: 0) == nil
        && hudModel.hudPresenceLine == nil,
        "a failure superseded by a successful retry kept the Dock/HUD warning")
retryOfFailed.phase = .copying
require(hudModel.settledBadVerdictJob === failedFirst,
        "a retry still running cleared the outstanding failure")
retryOfFailed.phase = .failed
require(hudModel.settledBadVerdict == .failed,
        "a retry that failed too cleared the warning")
let otherCardSafe = Job(label: "B001", sourcePath: "/Volumes/B001", destinations: ["/dest"])
otherCardSafe.phase = .done
otherCardSafe.fullyVerified = true
otherCardSafe.safeToWipe = true
otherCardSafe.physicalDevices = 2
hudModel.jobs = [otherCardSafe, failedFirst]
require(hudModel.settledBadVerdictJob === failedFirst,
        "a SAFE run of a different card cleared an unretried failure")
let olderHUDSafe = Job(label: "C001", sourcePath: "/Volumes/C001", destinations: ["/dest"])
olderHUDSafe.phase = .done
olderHUDSafe.fullyVerified = true
olderHUDSafe.safeToWipe = true
olderHUDSafe.physicalDevices = 2
usleep(1_000)
let newerFailure = Job(label: "C001", sourcePath: "/Volumes/C001", destinations: ["/dest"])
newerFailure.phase = .failed
hudModel.jobs = [olderHUDSafe, newerFailure]
require(hudModel.settledBadVerdictJob === newerFailure,
        "an OLDER successful run hid a newer failure of the same card")
let unverifiedFirst = Job(label: "D001", sourcePath: "/Volumes/D001", destinations: ["/dest"])
unverifiedFirst.phase = .done
usleep(1_000)
let keepCardRetry = Job(label: "D001", sourcePath: "/Volumes/D001", destinations: ["/dest"])
keepCardRetry.phase = .done
keepCardRetry.fullyVerified = true
keepCardRetry.wipeBlockers = ["copies span only 1 known physical device(s); 2+ required"]
hudModel.jobs = [keepCardRetry, unverifiedFirst]
require(unverifiedFirst.verdict == .unverified && keepCardRetry.verdict == .verifiedKeepCard,
        "fixture: unverified then verified-keep-card")
require(hudModel.settledBadVerdict == nil,
        "a verified retry did not supersede an UNVERIFIED run")

// Engine resolution has four strict tiers: explicit override, a valid embedded
// Cellar root, bundle walking, and finally the legacy development path. A stale
// embedded path must be ignored, while a broken override remains authoritative
// and produces a concrete error instead of silently falling through.
let resolverRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("dumptruck-resolver-check-\(UUID().uuidString)")
let resolverCLI = resolverRoot.appendingPathComponent("dumptruck/cli.py")
let resolverBundle = resolverRoot.appendingPathComponent("DumptruckApp/build/Dumptruck.app")
let resolverResources = resolverBundle.appendingPathComponent("Contents/Resources")
let embeddedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("dumptruck-embedded-check-\(UUID().uuidString)")
let embeddedCLI = embeddedRoot.appendingPathComponent("dumptruck/cli.py")
let embeddedFile = resolverResources.appendingPathComponent("engine_root.txt")
try! FileManager.default.createDirectory(
    at: resolverCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: resolverResources, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(
    at: embeddedCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
require(FileManager.default.createFile(atPath: resolverCLI.path, contents: Data()),
        "setup: could not create bundle-walk engine marker")
require(FileManager.default.createFile(atPath: embeddedCLI.path, contents: Data()),
        "setup: could not create embedded engine marker")
try! "  \(embeddedRoot.path)\n".write(to: embeddedFile, atomically: true, encoding: .utf8)
let resolverSuite = "dumptruck-resolver-\(UUID().uuidString)"
let resolverDefaults = UserDefaults(suiteName: resolverSuite)!
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults) == embeddedRoot.path,
        "valid embedded engine root did not outrank bundle walking")
require(EngineRootResolver.processEnvironment(root: embeddedRoot.path,
                                              base: ["PATH": "/usr/bin"])["PATH"]
        == "\(embeddedRoot.path)/.venv/bin:/usr/bin",
        "packaged engine tools were not prepended to the child PATH")
resolverDefaults.set("/nonexistent/dumptruck-round23", forKey: "engineRoot")
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults)
        == "/nonexistent/dumptruck-round23",
        "explicit engine override did not outrank the embedded root")
require(EngineRootResolver.configurationError(
    root: "/nonexistent/dumptruck-round23")?.contains("Settings > Engine") == true,
        "bogus engine override did not produce a visible, actionable error")
resolverDefaults.removeObject(forKey: "engineRoot")
try! "/nonexistent/stale-dumptruck-engine\n".write(
    to: embeddedFile, atomically: true, encoding: .utf8)
resolverDefaults.set(resolverRoot.path, forKey: "engineRoot")
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults) == resolverRoot.path,
        "explicit engine override stopped winning when the embedded root was stale")
require(EngineRootResolver.embeddedRejectionNotice?
            .contains("operator-selected engine at \(resolverRoot.path)") == true,
        "stale embedded root stayed silent behind an explicit engine override")
resolverDefaults.removeObject(forKey: "engineRoot")
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults) == resolverRoot.path,
        "stale embedded engine root did not fall through to bundle walking")

// Self-contained (DMG) tier: an engine carried INSIDE the bundle at
// Contents/Resources/engine wins over bundle walking, loses to a valid
// absolute pointer, and never resolves through a stale one.
let internalEngineRoot = resolverResources.appendingPathComponent("engine")
let internalEngineCLI = internalEngineRoot.appendingPathComponent("dumptruck/cli.py")
try! FileManager.default.createDirectory(
    at: internalEngineCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
require(FileManager.default.createFile(atPath: internalEngineCLI.path, contents: Data()),
        "setup: could not create internal bundle engine marker")
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults)
        == internalEngineRoot.standardizedFileURL.path,
        "internal bundle engine did not outrank bundle walking past a stale pointer")
try! "  \(embeddedRoot.path)\n".write(to: embeddedFile, atomically: true, encoding: .utf8)
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults) == embeddedRoot.path,
        "valid embedded pointer did not outrank the internal bundle engine")
try! FileManager.default.removeItem(at: embeddedFile)
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults)
        == internalEngineRoot.standardizedFileURL.path,
        "internal bundle engine was not used once the pointer file was gone")
try! FileManager.default.removeItem(at: internalEngineRoot)
try! "/nonexistent/stale-dumptruck-engine\n".write(
    to: embeddedFile, atomically: true, encoding: .utf8)

try! FileManager.default.removeItem(at: resolverCLI)
require(EngineRootResolver.resolve(bundleURL: resolverBundle,
                                   defaults: resolverDefaults)
        == EngineRootResolver.fallbackRoot,
        "missing embedded and bundle-walk roots did not reach the legacy fallback")
resolverDefaults.removePersistentDomain(forName: resolverSuite)
try? FileManager.default.removeItem(at: resolverRoot)
try? FileManager.default.removeItem(at: embeddedRoot)

// A brand-new phase is never old enough to judge: no advisory from spin-up.
let youngPhase = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
youngPhase.phase = .copying
youngPhase.recordThroughput(0, phase: "copy")
youngPhase.noteFileActivity()
let youngT0 = Date()
youngPhase.recordCopyProgress(path: "A.mov", done: 1_000_000_000)
youngPhase.recordThroughput(youngPhase.copyBytesRead, phase: "copy")
youngPhase.sampleThroughput(at: youngT0.addingTimeInterval(10))
for i in 11...58 {
    youngPhase.sampleThroughput(at: youngT0.addingTimeInterval(TimeInterval(i)))
}
require(!youngPhase.throttleAdvisory,
        "the advisory judged a phase younger than its own guard window")

print("throughput model checks passed")

// Ox review coverage gaps (feature-round correctness pass):
// (a) a phase CHANGE must clear an already-raised advisory via the didSet
// path, not merely wipe speed history.
let phaseClear = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
phaseClear.phase = .copying
phaseClear.recordThroughput(0, phase: "copy")
phaseClear.noteFileActivity()
let pcT0 = Date()
var pcRead: Int64 = 0
@MainActor
func pcFeed(_ bytes: Int64, at offset: TimeInterval) {
    pcRead += bytes
    phaseClear.recordCopyProgress(path: "big.mov", done: pcRead)
    phaseClear.recordThroughput(phaseClear.copyBytesRead, phase: "copy")
    phaseClear.sampleThroughput(at: pcT0.addingTimeInterval(offset))
}
for s in 1...70 { pcFeed(50_000_000, at: TimeInterval(s)) }        // healthy 50 MB/s
for s in 71...120 { pcFeed(2_000_000, at: TimeInterval(s)) }       // sustained crawl
require(phaseClear.throttleAdvisory, "setup: advisory did not raise before phase change")
phaseClear.phase = .sourceVerify
require(!phaseClear.throttleAdvisory, "phase change did not clear a raised throttle advisory")

// (b) counter-decrease re-baseline: recovery must not spike currentSpeed and
// the PHASE anchors must move too (post-reset ETA math stays live).
let resetJob = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
resetJob.phase = .copying
resetJob.recordThroughput(0, phase: "copy")
resetJob.noteFileActivity()
let rsT0 = Date()
resetJob.recordThroughput(500_000_000, phase: "copy")
resetJob.sampleThroughput(at: rsT0.addingTimeInterval(1))
resetJob.recordThroughput(100_000_000, phase: "copy")   // counter went BACKWARD
resetJob.sampleThroughput(at: rsT0.addingTimeInterval(2))
require(resetJob.currentSpeed == 0, "counter reset did not zero the live speed")
resetJob.recordThroughput(150_000_000, phase: "copy")
resetJob.sampleThroughput(at: rsT0.addingTimeInterval(3))
require(resetJob.currentSpeed <= 50_000_000 + 1,
        "post-reset recovery spiked currentSpeed instead of measuring the delta")

// (c) recordCopyProgress must reject a DECREASING done value outright.
let regress = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
regress.recordCopyProgress(path: "a.mov", done: 100)
regress.recordCopyProgress(path: "a.mov", done: 40)
require(regress.copyBytesRead == 100, "a decreasing done value changed observed bytes")

// (d) the slow-media floor: a phase averaging under 10 MB/s never raises the
// advisory no matter how far below its own average it drops.
let slowMedia = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
slowMedia.phase = .copying
slowMedia.recordThroughput(0, phase: "copy")
slowMedia.noteFileActivity()
let smT0 = Date()
var smRead: Int64 = 0
@MainActor
func smFeed(_ bytes: Int64, at offset: TimeInterval) {
    smRead += bytes
    slowMedia.recordCopyProgress(path: "slow.mov", done: smRead)
    slowMedia.recordThroughput(slowMedia.copyBytesRead, phase: "copy")
    slowMedia.sampleThroughput(at: smT0.addingTimeInterval(offset))
}
for s in 1...70 { smFeed(4_000_000, at: TimeInterval(s)) }         // 4 MB/s USB stick
for s in 71...130 { smFeed(500_000, at: TimeInterval(s)) }         // drops to 0.5 MB/s
require(!slowMedia.throttleAdvisory,
        "sub-10MB/s media raised a throttle advisory (floor guard missing)")

// Verification-level presets are pinned data. A curated level that weakened
// verification would be a safety bug wearing a convenience label.
require(VerificationLevel.classify(VerificationLevel.standardValues) == .standard
        && VerificationLevel.classify(VerificationLevel.maximumValues) == .maximum,
        "verification levels do not round-trip through classify")
require(VerificationLevel.standardValues.verifyMode == "full"
        && VerificationLevel.standardValues.sourceReread
        && VerificationLevel.maximumValues.verifyMode == "full"
        && VerificationLevel.maximumValues.sourceReread
        && VerificationLevel.maximumValues.reverifyExisting,
        "a curated verification level weakened the verification bar")
require(VerificationLevel.custom.values == nil,
        "selecting Custom must not overwrite the operator's toggles")
require(VerificationLevel.classify(.init(verifyMode: "fast", sourceReread: true,
                                         reverifyExisting: false,
                                         extraHashes: "")) == .custom,
        "a weakened mix classified as a curated level")

// R3-03 (desktop QA round 3): one 16 GiB file beside 60,000 small files.
// Bytes were 99% done once the big file landed, so the byte-only estimate
// said "1 second" for minutes while the file counter crawled. The copy ETA
// is the slower of the byte and file predictions.
let mixed = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let sixteenGiB: Int64 = 16 * 1024 * 1024 * 1024
mixed.filesTotal = 60_001
mixed.bytesTotal = sixteenGiB + 60_000 * 4
mixed.recordThroughput(0, phase: "copy", at: t0)
require(mixed.copyETASeconds(at: t0.addingTimeInterval(1)) == nil,
        "no estimate before three seconds of evidence")
mixed.recordCopyProgress(path: "BIG.mov", done: sixteenGiB)
mixed.recordThroughput(mixed.copyBytesRead, phase: "copy", at: t0.addingTimeInterval(80))
mixed.filesCopied = 4_402
let etaAt80 = mixed.copyETASeconds(at: t0.addingTimeInterval(80))
require((etaAt80 ?? 0) >= 900,
        "55,599 files at ~55 files/s must read minutes, not ~1 s: \(String(describing: etaAt80))")
mixed.filesCopied = 24_898
let etaAt224 = mixed.copyETASeconds(at: t0.addingTimeInterval(224))
require((etaAt224 ?? 0) >= 250 && (etaAt224 ?? 0) < (etaAt80 ?? 0),
        "the file-driven estimate shrinks as files settle: \(String(describing: etaAt224))")
// Bytes still rule when they are the slower predictor.
let bulky = Job(label: "CARD", sourcePath: "/source", destinations: ["/dest"])
bulky.filesTotal = 2
bulky.bytesTotal = 3 * 1024 * 1024 * 1024
bulky.recordThroughput(0, phase: "copy", at: t0)
bulky.recordCopyProgress(path: "A.mov", done: 1024 * 1024 * 1024)
bulky.recordThroughput(bulky.copyBytesRead, phase: "copy", at: t0.addingTimeInterval(10))
bulky.filesCopied = 1
let bulkyETA = bulky.copyETASeconds(at: t0.addingTimeInterval(10))
require(bulkyETA == 20, "2 GiB left at 0.1 GiB/s is 20 s, not the 10 s the file count says: \(String(describing: bulkyETA))")

// A held finish must move forward once its clock has expired, even when
// the proposed update remains inside the two-minute jitter band.
var expiredHold = ETADisplayHold()
_ = expiredHold.project(secondsRemaining: 180, now: t0)
let expiredProjection = expiredHold.project(secondsRemaining: 100, now: t0.addingTimeInterval(181))!
require(expiredProjection.finishDate > t0.addingTimeInterval(181),
        "held finish remained in the past")
let emptyETA = Job(label: "EMPTY", sourcePath: "/source", destinations: ["/dest"])
emptyETA.recordThroughput(0, phase: "copy", at: t0)
require(emptyETA.copyETASeconds(at: t0.addingTimeInterval(10)) == nil,
        "an empty transfer manufactured an ETA")
mixed.recordThroughput(0, phase: "reread", at: t0.addingTimeInterval(225))
require(mixed.fileRate(at: t0.addingTimeInterval(235)) == nil,
        "copy file rate leaked into source reread")
mixed.recordThroughput(0, phase: "copy", at: t0.addingTimeInterval(240))
mixed.filesCopied += 10
require(mixed.fileRate(at: t0.addingTimeInterval(250)) == 1,
        "phase transition failed to reset the file baseline")
mixed.recordThroughput(100, phase: "copy", at: t0.addingTimeInterval(251))
mixed.recordThroughput(0, phase: "copy", at: t0.addingTimeInterval(252))
require(mixed.fileRate(at: t0.addingTimeInterval(262)) == nil,
        "byte-counter reset retained old file throughput")
let restoredETA = Job(label: "RESTORED", sourcePath: "/source", destinations: ["/dest"])
restoredETA.filesTotal = 100
restoredETA.filesSkipped = 80
require(restoredETA.copyETASeconds(at: t0) == nil, "restored counts manufactured live throughput")
restoredETA.recordThroughput(0, phase: "copy", at: t0)
restoredETA.filesSkipped = 90
require(restoredETA.copyETASeconds(at: t0.addingTimeInterval(10)) == 10,
        "trusted continuation lost its file-driven ETA")

        print("ThroughputCheck: all assertions passed")
    }
}
