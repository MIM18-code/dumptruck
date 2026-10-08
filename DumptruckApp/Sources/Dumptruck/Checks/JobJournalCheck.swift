import Foundation

enum JobJournalCheck {

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@MainActor
static func run() throws {
let root = URL(fileURLWithPath: "/tmp/dumptruck-job-journal-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let journalURL = root.appendingPathComponent("jobs.json")
let journal = JobJournal(url: journalURL, historyLimit: 2)
let source = root.appendingPathComponent("CARD").path
let dest = root.appendingPathComponent("DEST").path
try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

let plan = JournalLaunchPlan(
    src: source, rawRoots: [dest], destinations: [dest + "/SHOW/Raws"],
    args: ["-m", "dumptruck.cli", "offload", source, dest + "/SHOW/Raws",
           "--label", "CARD", "--json"],
    enginePython: "/engine/.venv/bin/python",
    engineRoot: "/engine", sourceVolumeUUID: "source-uuid",
    rootVolumeUUIDs: ["dest-uuid"], sourceFileID: "1:2",
    rootFileIDs: ["3:4"], mirroredFolder: "SHOW",
    organizationFolder: "Raws", cardLabel: "CARD")
let job = Job(label: "CARD", sourcePath: source, destinations: plan.destinations)
job.launchPlanSnapshot = plan
job.phase = .copying
job.startedDate = Date(timeIntervalSince1970: 100)
job.currentFile = "A.mov"
job.bytesTotal = 100
job.bytesFinished = 25
let cardRoot = (plan.destinations[0] as NSString).appendingPathComponent("CARD")
job.laneRoots = [cardRoot]
job.recordDestinationStatus(root: cardRoot, status: "verified", bytes: 25)
require(journal.save(records: [JobJournalRecord(job: job, plan: plan)]).isSuccess,
        "initial journal save failed")

// Round-22 GUI fixture: a brand-new job using two volume roots, an empty
// mirrored suffix, and a rendered organization folder must be journalable
// before the engine launches. This is the exact shape produced by the normal
// two-destination workbench path.
let stagedJournal = JobJournal(url: root.appendingPathComponent("staged-jobs.json"))
let stagedDestinations = [
    "/Volumes/R22_DST_A/DUMPTRUCK_TEST/Raws",
    "/Volumes/R22_DST_B/DUMPTRUCK_TEST/Raws",
]
let stagedPlan = JournalLaunchPlan(
    src: "/Volumes/R22_CARD",
    rawRoots: ["/Volumes/R22_DST_A", "/Volumes/R22_DST_B"],
    destinations: stagedDestinations,
    args: ["-m", "dumptruck.cli", "offload", "/Volumes/R22_CARD"]
        + stagedDestinations + ["--label", "R22_CARD", "--json"],
    enginePython: "/Users/joshualand/Documents/Claude Video Studio/offloader/.venv/bin/python",
    engineRoot: "/Users/joshualand/Documents/Claude Video Studio/offloader",
    sourceVolumeUUID: nil, rootVolumeUUIDs: [nil, nil],
    sourceFileID: "16777239:5", rootFileIDs: ["16777243:5", "16777245:5"],
    mirroredFolder: "", organizationFolder: "DUMPTRUCK_TEST/Raws",
    cardLabel: "R22_CARD")
let stagedJob = Job(label: "R22_CARD", sourcePath: "/Volumes/R22_CARD",
                    destinations: stagedDestinations)
stagedJob.launchPlanSnapshot = stagedPlan
require(stagedJournal.save(records: [
    JobJournalRecord(job: stagedJob, plan: stagedPlan)
]).isSuccess,
        "ordinary staged two-destination job was rejected before launch: "
        + (stagedJournal.failure ?? "unknown"))

// Regression fixture: a nested-folder offload uses the source folder name as
// the card label, while its effective destinations contain the rendered
// organization path.  The engine reports card roots (destination + label),
// not the GUI destination bases.
let nestedJournalURL = root.appendingPathComponent("nested-jobs.json")
let nestedJournal = JobJournal(url: nestedJournalURL)
let nestedSource = "/Volumes/DT20_CARD/DCIM"
let nestedDestinations = [
    "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws",
    "/Volumes/DT20_DEST_B/SHOW/Raws/DUMPTRUCK_TEST/Raws",
]
let nestedRoots = nestedDestinations.map { $0 + "/DCIM" }
let nested = Job(label: "DCIM", sourcePath: nestedSource,
                 destinations: nestedDestinations)
let nestedPlan = JournalLaunchPlan(
    src: nestedSource,
    rawRoots: ["/Volumes/DT20_DEST_A", "/Volumes/DT20_DEST_B"],
    destinations: nestedDestinations,
    args: ["-m", "dumptruck.cli", "offload", nestedSource] + nestedDestinations
        + ["--label", "DCIM", "--json"],
    enginePython: "/Users/joshualand/Documents/Claude Video Studio/offloader/.venv/bin/python",
    engineRoot: "/Users/joshualand/Documents/Claude Video Studio/offloader",
    sourceVolumeUUID: "02C93CF5-D7CD-3644-BF51-AF5AF77230A7",
    rootVolumeUUIDs: ["F0C0E2C4-A96A-441D-B217-F6C359A753B3",
                     "53E83B79-10D6-42AD-97AB-F58D653520E9"],
    sourceFileID: "16777239:7",
    rootFileIDs: ["16777243:2", "16777247:2"],
    mirroredFolder: "SHOW/Raws",
    organizationFolder: "DUMPTRUCK_TEST/Raws",
    cardLabel: "DCIM")
nested.launchPlanSnapshot = nestedPlan
nested.phase = .done
nested.filesTotal = 1
nested.filesCopied = 1
nested.bytesTotal = 8_388_608
nested.bytesFinished = 8_388_608
nested.fullyVerified = true
nested.safeToWipe = true
nested.physicalDevices = 2
nested.laneRoots = nestedRoots
nested.manifestPaths = [
    nestedRoots[0] + "/ascmhl/0001_DCIM_2026-08-22_032447Z.mhl",
    nestedRoots[0] + "/DCIM_2026-08-22_032447.mhl",
    nestedRoots[1] + "/ascmhl/0001_DCIM_2026-08-22_032447Z.mhl",
    nestedRoots[1] + "/DCIM_2026-08-22_032447.mhl",
]
nested.reportPaths = [
    "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws/Reports/DCIM/DCIM_offload.html",
    "/Volumes/DT20_DEST_B/SHOW/Raws/DUMPTRUCK_TEST/Raws/Reports/DCIM/DCIM_offload.html",
    "/Users/joshualand/Library/Application Support/Dumptruck/reports/DCIM/DCIM_offload.html",
    "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws/Reports/DCIM/DCIM_offload.pdf",
    "/Volumes/DT20_DEST_B/SHOW/Raws/DUMPTRUCK_TEST/Raws/Reports/DCIM/DCIM_offload.pdf",
    "/Users/joshualand/Library/Application Support/Dumptruck/reports/DCIM/DCIM_offload.pdf",
]
nested.reportPath = nested.reportPaths[0]
nested.receiptPath = "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws/Reports/DCIM/DCIM_offload.receipt.json"
for rootPath in nestedRoots {
    nested.recordDestinationStatus(root: rootPath, status: "verified", bytes: 8_388_608)
}
let nestedResult = nestedJournal.save(records: [JobJournalRecord(job: nested, plan: nestedPlan)])
require(nestedResult.isSuccess,
        "nested-folder terminal journal save failed: \(nestedJournal.failure ?? "unknown")")

switch journal.load() {
case .loaded(let document):
    require(document.schema == JobJournalSchema.current, "schema was not persisted")
    require(document.records.count == 1, "record did not round-trip")
    require(document.records[0].plan?.mirroredFolder == "SHOW",
            "mirrored folder was not frozen")
    require(document.records[0].destinationSummary[cardRoot]?.filesVerified == 1,
            "lane summary was not persisted")
default:
    fatalError("valid journal did not load")
}

// A journal record is not trusted merely because its top-level fields decode:
// the frozen plan's destination list and argv must still agree. Mutating the
// persisted argv must fail closed at load rather than produce a retryable job.
let malformedPlanURL = root.appendingPathComponent("malformed-plan.json")
var malformedObject = try JSONSerialization.jsonObject(
    with: Data(contentsOf: journalURL)) as! [String: Any]
var malformedRecords = malformedObject["records"] as! [[String: Any]]
var malformedRecord = malformedRecords[0]
var malformedPlan = malformedRecord["plan"] as! [String: Any]
var malformedArguments = malformedPlan["args"] as! [String]
malformedArguments[4] = dest + "/tampered"
malformedPlan["args"] = malformedArguments
malformedRecord["plan"] = malformedPlan
malformedRecords[0] = malformedRecord
malformedObject["records"] = malformedRecords
try JSONSerialization.data(withJSONObject: malformedObject).write(to: malformedPlanURL)
let malformedPlanJournal = JobJournal(url: malformedPlanURL)
if case .invalid = malformedPlanJournal.load() {
    require(!malformedPlanJournal.isHealthy,
            "plan argv mismatch was reported healthy")
} else {
    fatalError("plan argv mismatch was accepted")
}

// The reciprocal mutation (plan destinations versus the record's effective
// destinations) is independently rejected as well.
let destinationMismatchURL = root.appendingPathComponent("destination-mismatch.json")
var destinationMismatchObject = try JSONSerialization.jsonObject(
    with: Data(contentsOf: journalURL)) as! [String: Any]
var destinationMismatchRecords = destinationMismatchObject["records"] as! [[String: Any]]
var destinationMismatchRecord = destinationMismatchRecords[0]
var destinationMismatchPlan = destinationMismatchRecord["plan"] as! [String: Any]
destinationMismatchPlan["destinations"] = [dest + "/other"]
destinationMismatchRecord["plan"] = destinationMismatchPlan
destinationMismatchRecords[0] = destinationMismatchRecord
destinationMismatchObject["records"] = destinationMismatchRecords
try JSONSerialization.data(withJSONObject: destinationMismatchObject)
    .write(to: destinationMismatchURL)
let destinationMismatchJournal = JobJournal(url: destinationMismatchURL)
if case .invalid = destinationMismatchJournal.load() {
    require(!destinationMismatchJournal.isHealthy,
            "plan destination mismatch was reported healthy")
} else {
    fatalError("plan destination mismatch was accepted")
}

// The cap keeps the file bounded while retaining the newest records.
let older = Job(label: "OLD", sourcePath: source, destinations: [dest],
                createdDate: Date(timeIntervalSince1970: 1))
older.finishedDate = Date(timeIntervalSince1970: 2)
older.phase = .failed
let newer = Job(label: "NEW", sourcePath: source, destinations: [dest],
                createdDate: Date(timeIntervalSince1970: 300))
newer.finishedDate = Date(timeIntervalSince1970: 301)
newer.phase = .done
require(journal.save(records: [JobJournalRecord(job: older, plan: nil),
                               JobJournalRecord(job: job, plan: plan),
                               JobJournalRecord(job: newer, plan: nil)]).isSuccess,
        "bounded save failed")
if case .loaded(let bounded) = journal.load() {
    require(bounded.records.count == 2, "history cap was not enforced")
    require(!bounded.records.contains(where: { $0.label == "OLD" }),
            "oldest history record was not capped")
} else {
    fatalError("bounded journal did not load")
}

// A freshly RECOVERED interruption has no finishedDate (the relaunch
// instant is a recovery, not a completion) — retention must rank it by
// recoveredAt, or the recovery save itself pushes the newest DO-NOT-WIPE
// evidence past the cap while older completed runs survive (codex verify
// round 3, NEW 1).
let recoveredJournal = JobJournal(
    url: root.appendingPathComponent("recovered.json"), historyLimit: 2)
let ancientDone = Job(label: "ANCIENT_DONE", sourcePath: source,
                      destinations: [dest],
                      createdDate: Date(timeIntervalSince1970: 10))
ancientDone.startedDate = Date(timeIntervalSince1970: 11)
ancientDone.finishedDate = Date(timeIntervalSince1970: 12)
ancientDone.phase = .done
let midDone = Job(label: "MID_DONE", sourcePath: source, destinations: [dest],
                  createdDate: Date(timeIntervalSince1970: 100))
midDone.startedDate = Date(timeIntervalSince1970: 101)
midDone.finishedDate = Date(timeIntervalSince1970: 102)
midDone.phase = .done
// Started BEFORE both completions, recovered AFTER them: the old sort key
// (startedDate fallback) ranked it last; recoveredAt must rank it first.
let recovered = Job(label: "RECOVERED", sourcePath: source,
                    destinations: [dest],
                    createdDate: Date(timeIntervalSince1970: 5))
recovered.startedDate = Date(timeIntervalSince1970: 6)
recovered.phase = .failed
recovered.markRestoredFromJournal()
recovered.markRestoredInterrupted()
recovered.recoveredAt = Date(timeIntervalSince1970: 500)
require(recoveredJournal.save(records: [
    JobJournalRecord(job: ancientDone, plan: nil),
    JobJournalRecord(job: midDone, plan: nil),
    JobJournalRecord(job: recovered, plan: nil)]).isSuccess,
        "recovered-retention save failed")
if case .loaded(let kept) = recoveredJournal.load() {
    require(kept.records.contains(where: { $0.label == "RECOVERED" }),
            "recovered interruption fell past the history cap")
    require(kept.records.first(where: { $0.label == "RECOVERED" })?
        .interrupted == true, "interrupted flag was not persisted")
    require(!kept.records.contains(where: { $0.label == "ANCIENT_DONE" }),
            "retention kept the oldest completion over the fresh recovery")
} else {
    fatalError("recovered-retention journal did not load")
}

// Lexical containment must survive the non-canonical strings a dropped URL
// can carry — assignment standardizes at ingress, and the helper cleans
// defensively (codex verify round 3, NEW 3).
require(pathIsAtOrInsideLexically("/Volumes//CARD/./DCIM", root: "/Volumes/CARD"),
        "lexical helper missed a repeated-slash + dot-segment child")
require(pathIsAtOrInsideLexically("/Volumes/CARD/", root: "/Volumes/CARD"),
        "lexical helper missed a trailing-slash self match")
require(!pathIsAtOrInsideLexically("/Volumes/CARD2", root: "/Volumes/CARD"),
        "lexical helper matched across a component boundary")
require(!pathIsAtOrInsideLexically("/Volumes/CARD", root: "/Volumes/CARD/DCIM"),
        "lexical helper inverted containment")

// Drop-path ingress: canonical and noncanonical spellings of one item must
// collapse to a single canonical path, order preserved (codex verify
// round 4 — a noncanonical volume-root spelling became a second logical
// endpoint).
require(AppModel.standardizedDropPaths(
            ["/Volumes//BACKUP/.", "/Volumes/BACKUP", "/Volumes/OTHER/"])
        == ["/Volumes/BACKUP", "/Volumes/OTHER"],
        "dropped-path standardization did not collapse spellings")

// Live records are safety evidence, not evictable history. Even with a cap of
// one, all live jobs must survive so a relaunch can account for every possible
// interrupted engine.
let liveCapURL = root.appendingPathComponent("live-cap.json")
let liveCapJournal = JobJournal(url: liveCapURL, historyLimit: 1)
let liveOne = Job(label: "CARD", sourcePath: source, destinations: plan.destinations)
liveOne.phase = .queued
liveOne.launchPlanSnapshot = plan
let liveTwo = Job(label: "CARD", sourcePath: source, destinations: plan.destinations)
liveTwo.phase = .copying
liveTwo.launchPlanSnapshot = plan
require(liveCapJournal.save(records: [
    JobJournalRecord(job: liveOne, plan: plan),
    JobJournalRecord(job: liveTwo, plan: plan),
    JobJournalRecord(job: older, plan: nil)
]).isSuccess, "live-record cap save failed")
if case .loaded(let liveDocument) = liveCapJournal.load() {
    require(liveDocument.records.count == 2,
            "history cap evicted a live record")
    require(liveDocument.records.allSatisfy {
        $0.phase == JobPhase.queued.rawValue || $0.phase == JobPhase.copying.rawValue
    }, "history cap retained terminal history instead of live records")
} else {
    fatalError("live-record cap journal did not load")
}

// Corruption and future schemas are visible and never overwritten.
let original = Data("{not-json".utf8)
try original.write(to: journalURL)
let corrupt = JobJournal(url: journalURL,
                         quarantineNameFactory: { "jobs.json.quarantine-corrupt" })
if case .invalid = corrupt.load() {
    require(!corrupt.isHealthy, "corrupt journal was reported healthy")
    require(corrupt.canQuarantineInvalidJournal,
            "corrupt regular journal did not offer explicit quarantine")
    require(corrupt.save(records: []).isFailure, "corrupt journal accepted an overwrite")
    let kept = try Data(contentsOf: journalURL)
    require(kept == original,
            "corrupt journal evidence was overwritten")
    switch corrupt.quarantineInvalidJournal() {
    case .success(let quarantineURL):
        require(quarantineURL.lastPathComponent == "jobs.json.quarantine-corrupt",
                "quarantine path was not the requested unique sibling")
        let quarantinedBytes = try Data(contentsOf: quarantineURL)
        require(quarantinedBytes == original,
                "quarantine did not preserve corrupt journal bytes")
        require(corrupt.isHealthy, "successful quarantine did not restore journal health")
        if case .loaded(let empty) = corrupt.load() {
            require(empty.records.isEmpty, "fresh post-quarantine ledger was not empty")
        } else {
            fatalError("fresh post-quarantine ledger did not load")
        }
    case .failure(let error):
        fatalError("explicit corrupt-journal quarantine failed: \(error)")
    }
} else {
    fatalError("corrupt journal was not rejected")
}

let futureURL = root.appendingPathComponent("future.json")
let future = JobJournal(url: futureURL)
try Data("{\"schema\":999,\"generation\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"records\":[]}".utf8)
    .write(to: futureURL)
if case .invalid = future.load() {
    require(!future.isHealthy, "future journal schema was reported healthy")
    require(future.canQuarantineInvalidJournal,
            "future journal did not offer explicit quarantine")
    switch future.quarantineInvalidJournal() {
    case .success(let quarantineURL):
        let quarantinedBytes = try Data(contentsOf: quarantineURL)
        require(String(data: quarantinedBytes, encoding: .utf8)?.contains("999") == true,
                "future journal evidence was not retained")
        require(future.isHealthy, "future journal quarantine did not restore health")
        require(FileManager.default.fileExists(atPath: futureURL.path),
                "empty replacement ledger was not persisted")
    case .failure(let error):
        fatalError("explicit future-journal quarantine failed: \(error)")
    }
} else {
    fatalError("future journal schema was not rejected")
}

// Confirmation is identity-pinned: replacing the invalid file after load
// must fail closed and must not move the replacement or create a new ledger.
let replacementURL = root.appendingPathComponent("replacement.json")
let replacementOriginal = Data("{bad-before-replacement".utf8)
try replacementOriginal.write(to: replacementURL)
let replacement = JobJournal(url: replacementURL,
                             quarantineNameFactory: { "replacement.quarantine" })
if case .invalid = replacement.load() {
    try FileManager.default.removeItem(at: replacementURL)
    let replacementBytes = Data("{bad-after-replacement".utf8)
    try replacementBytes.write(to: replacementURL)
    require(replacement.quarantineInvalidJournal().isFailure,
            "replaced invalid journal was quarantined")
    require(!replacement.isHealthy, "replacement race unexpectedly restored health")
    let currentBytes = try Data(contentsOf: replacementURL)
    require(currentBytes == replacementBytes,
            "replacement race overwrote the newer journal")
    require(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("replacement.quarantine").path),
        "replacement race moved a file despite identity mismatch")
} else {
    fatalError("replacement fixture was not rejected")
}

// A pre-existing quarantine sibling is never overwritten.  A deterministic
// name factory makes the collision adversarial rather than probabilistic.
let collisionURL = root.appendingPathComponent("collision.json")
let collisionOriginal = Data("{bad-collision".utf8)
try collisionOriginal.write(to: collisionURL)
let collisionSibling = root.appendingPathComponent("collision.quarantine")
let collisionSentinel = Data("do-not-overwrite".utf8)
try collisionSentinel.write(to: collisionSibling)
let collision = JobJournal(url: collisionURL,
                           quarantineNameFactory: { "collision.quarantine" })
if case .invalid = collision.load() {
    require(collision.quarantineInvalidJournal().isFailure,
            "quarantine collision unexpectedly succeeded")
    require(!collision.isHealthy, "quarantine collision restored health")
    let collisionCurrentBytes = try Data(contentsOf: collisionURL)
    let collisionSiblingBytes = try Data(contentsOf: collisionSibling)
    require(collisionCurrentBytes == collisionOriginal,
            "quarantine collision overwrote the invalid journal")
    require(collisionSiblingBytes == collisionSentinel,
            "quarantine collision overwrote the existing sibling")
} else {
    fatalError("collision fixture was not rejected")
}

// Symlinks and non-regular entries are never followed or offered for
// one-click quarantine.  The target and the directory remain untouched.
let symlinkTarget = root.appendingPathComponent("symlink-target.json")
let symlinkURL = root.appendingPathComponent("symlink.json")
try Data("{symlink-target".utf8).write(to: symlinkTarget)
try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTarget)
let symlink = JobJournal(url: symlinkURL)
if case .invalid = symlink.load() {
    require(!symlink.canQuarantineInvalidJournal,
            "symlink journal incorrectly offered quarantine")
    require(symlink.quarantineInvalidJournal().isFailure,
            "symlink journal was quarantined")
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)
    let targetBytes = try Data(contentsOf: symlinkTarget)
    require(destination == symlinkTarget.path,
            "symlink journal was followed or moved")
    require(targetBytes == Data("{symlink-target".utf8),
            "symlink target was modified")
} else {
    fatalError("symlink journal was not rejected")
}

let directoryURL = root.appendingPathComponent("directory.json")
try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
let directoryJournal = JobJournal(url: directoryURL)
if case .invalid = directoryJournal.load() {
    require(!directoryJournal.canQuarantineInvalidJournal,
            "directory journal incorrectly offered quarantine")
    require(directoryJournal.quarantineInvalidJournal().isFailure,
            "directory journal was quarantined")
    var isDirectory: ObjCBool = false
    require(FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            "non-regular journal entry disappeared")
    require(isDirectory.boolValue, "non-regular journal entry changed type")
} else {
    fatalError("directory journal was not rejected")
}

print("JobJournalCheck: all assertions passed")
}
}
