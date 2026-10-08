import Foundation
import Darwin

/// The on-disk history is deliberately a small, versioned document rather
/// than a cache.  A queued/running record is evidence that a transfer may have
/// been interrupted; it must survive a crash long enough for the next launch
/// to turn it into a visible FAILED / DO NOT WIPE job.
enum JobJournalSchema {
    static let current = 1
    static let defaultHistoryLimit = 200
    static let maximumLiveRecords = 256
    static let maximumDiskBytes = 64 * 1024 * 1024
}

struct JournalMessage: Codable, Hashable {
    let severity: String
    let text: String
}

struct JournalDestinationSummary: Codable, Hashable {
    let bytesVerified: Int64
    let bytesTrusted: Int64
    let bytesSizeOnly: Int64
    let filesVerified: Int
    let filesTrusted: Int
    let filesFailed: Int
    let sizeOnly: Int

    init(_ value: DestProgress) {
        bytesVerified = value.bytesVerified
        bytesTrusted = value.bytesTrusted
        bytesSizeOnly = value.bytesSizeOnly
        filesVerified = value.filesVerified
        filesTrusted = value.filesTrusted
        filesFailed = value.filesFailed
        sizeOnly = value.sizeOnly
    }

    var progress: DestProgress {
        var value = DestProgress()
        value.bytesVerified = bytesVerified
        value.bytesTrusted = bytesTrusted
        value.bytesSizeOnly = bytesSizeOnly
        value.filesVerified = filesVerified
        value.filesTrusted = filesTrusted
        value.filesFailed = filesFailed
        value.sizeOnly = sizeOnly
        return value
    }
}

struct JobJournalRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let runID: UUID
    let label: String
    let sourcePath: String
    let destinations: [String]
    let sourceAssignmentID: UUID?
    let phase: String
    let currentFile: String
    let bytesTotal: Int64
    let bytesFinished: Int64
    let currentFileDone: Int64
    let filesTotal: Int
    let filesCopied: Int
    let filesSkipped: Int
    let filesFailed: Int
    let trustedPrior: Int
    let fullyVerified: Bool
    let safeToWipe: Bool
    let physicalDevices: Int
    let wipeBlockers: [String]
    let messages: [JournalMessage]
    let reportPath: String?
    let reportFailed: Bool
    let reportPaths: [String]?
    let manifestPaths: [String]?
    let receiptPath: String?
    let laneRoots: [String]
    let destinationSummary: [String: JournalDestinationSummary]
    let startedDate: Date?
    let finishedDate: Date?
    /// True once this record was ever recovered from a live interruption —
    /// persisted so the interrupted marker survives later relaunches, and
    /// finishedDate can stay honestly nil (codex verify F5).
    let interrupted: Bool?
    let recoveredAt: Date?
    let rereadDone: Int64
    let rereadTotal: Int64
    let sourceMutatedAfterStart: Bool
    let stopRequested: Bool
    let plan: JournalLaunchPlan?
    /// Optional and additive: journals written before it decode unchanged.
    let laterVerification: LaterVerification?
    let custodyFailures: [String: LaterVerification]?
    let createdDate: Date

    init(job: Job, plan: JournalLaunchPlan?, createdDate: Date? = nil) {
        id = job.id
        runID = job.runID
        label = job.label
        sourcePath = job.sourcePath
        destinations = job.destinations
        sourceAssignmentID = job.sourceAssignmentID
        phase = job.unresolvedRecoveryPhase ?? job.phase.rawValue
        currentFile = job.currentFile
        bytesTotal = job.bytesTotal
        bytesFinished = job.bytesFinished
        currentFileDone = job.currentFileDone
        filesTotal = job.filesTotal
        filesCopied = job.filesCopied
        filesSkipped = job.filesSkipped
        filesFailed = job.filesFailed
        trustedPrior = job.trustedPrior
        fullyVerified = job.fullyVerified
        safeToWipe = job.safeToWipe
        physicalDevices = job.physicalDevices
        wipeBlockers = job.wipeBlockers
        messages = job.messages.map {
            JournalMessage(severity: $0.severity == .error ? "error" : "warning",
                           text: $0.text)
        }
        reportPath = job.reportPath
        reportFailed = job.reportFailed
        reportPaths = job.reportPaths.isEmpty ? nil : job.reportPaths
        manifestPaths = job.manifestPaths.isEmpty ? nil : job.manifestPaths
        receiptPath = job.receiptPath
        laneRoots = job.laneRoots
        destinationSummary = job.destProgress.mapValues(JournalDestinationSummary.init)
        startedDate = job.startedDate
        finishedDate = job.finishedDate
        interrupted = (job.restoredInterrupted && job.unresolvedRecoveryPhase == nil) ? true : nil
        recoveredAt = job.recoveredAt
        rereadDone = job.rereadDone
        rereadTotal = job.rereadTotal
        sourceMutatedAfterStart = job.sourceMutatedAfterStart
        stopRequested = job.stopRequested
        laterVerification = job.laterVerification
        custodyFailures = job.custodyFailures
        self.plan = plan
        self.createdDate = createdDate ?? job.createdDate
    }
}

struct JobJournalDocument: Codable, Hashable {
    let schema: Int
    let generation: UInt64
    let updatedAt: Date
    let records: [JobJournalRecord]
}

enum JobJournalLoadResult {
    case empty
    case loaded(JobJournalDocument)
    case invalid(String)
}

/// A journal can only be quarantined when the directory entry that was
/// rejected at launch is still the same regular file.  Device/inode is the
/// important identity pin; the other fields make replacement and in-place
/// mutation visible to the confirmation path as well.
private struct JournalFileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var isRegular: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFREG)
    }

    /// rename(2) updates ctime even though it preserves the file itself.
    /// Keep ctime in the pre-rename replacement check, but ignore it when
    /// confirming the identity of the entry after the move.
    var stableAfterRename: (device: Int64, inode: UInt64, size: Int64,
                             mode: UInt16, modifiedSeconds: Int64,
                             modifiedNanoseconds: Int64) {
        (device, inode, size, mode, modifiedSeconds, modifiedNanoseconds)
    }
}

/// Crash-safe, bounded journal.  The path can be overridden in deterministic
/// model tests with `DUMPTRUCK_JOB_JOURNAL`; production uses Application
/// Support and never writes into the project checkout or a source volume.
final class JobJournal {
    let url: URL
    let historyLimit: Int
    private(set) var writable = true
    private(set) var failure: String?
    private(set) var lastQuarantineURL: URL?
    private var generation: UInt64 = 0
    private var invalidIdentity: JournalFileIdentity?
    private let quarantineNameFactory: () -> String

    init(url: URL? = nil,
         historyLimit: Int = JobJournalSchema.defaultHistoryLimit,
         quarantineNameFactory: @escaping () -> String = {
             "quarantine-\(UUID().uuidString)"
         }) {
        if let url {
            self.url = url
        } else if let override = ProcessInfo.processInfo.environment["DUMPTRUCK_JOB_JOURNAL"],
                  !override.isEmpty {
            self.url = URL(fileURLWithPath: override)
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.url = appSupport
                .appendingPathComponent("tv.mindinmotion.dumptruck", isDirectory: true)
                .appendingPathComponent("jobs.json", isDirectory: false)
        }
        self.historyLimit = max(1, historyLimit)
        self.quarantineNameFactory = quarantineNameFactory
    }

    var isHealthy: Bool { writable && failure == nil }

    /// Exclusive advisory lock beside the journal, held for the process
    /// lifetime. Without it a second app instance's whole-document save
    /// silently erases verdict records the first instance just committed
    /// (round-24 finding: last-renamer-wins with no conflict detection).
    private var instanceLockFD: Int32 = -1

    /// Take the lock, or explain who has it. Fail-closed: a journal that
    /// cannot be exclusively owned is treated like an unwritable journal.
    func acquireInstanceLock() -> Bool {
        guard instanceLockFD < 0 else { return true }
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lock")
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            _ = invalidate("job journal lock could not be created at "
                           + "\(lockURL.path); refusing shared writes")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            _ = invalidate("another Dumptruck instance owns the job journal — "
                           + "quit the other instance first; this window is "
                           + "read-only to protect its verdict records")
            return false
        }
        instanceLockFD = fd
        return true
    }

    /// True only for an invalid regular journal whose exact directory entry
    /// was pinned during load.  Save failures and symlink/non-regular files
    /// deliberately do not get a one-click recovery path.
    var canQuarantineInvalidJournal: Bool {
        !isHealthy && invalidIdentity?.isRegular == true
    }

    func load() -> JobJournalLoadResult {
        sweepOrphanedTempFiles()
        var initialStat = stat()
        guard lstat(url.path, &initialStat) == 0 else {
            guard errno == ENOENT else {
                invalidIdentity = nil
                return invalidate("job journal could not be inspected safely; "
                                  + "the journal was preserved and no history was loaded")
            }
            invalidIdentity = nil
            return .empty
        }
        do {
            guard let identity = Self.identity(from: initialStat) else {
                invalidIdentity = nil
                return invalidate("job journal identity could not be read; "
                                  + "the journal was preserved and no history was loaded")
            }
            invalidIdentity = identity
            guard identity.isRegular else {
                return invalidate("job journal is not a regular file; it was preserved and must be inspected manually")
            }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                return invalidate("job journal could not be opened without following a symlink; "
                                  + "the journal was preserved and no history was loaded")
            }
            defer { _ = close(fd) }
            let openedIdentity = try Self.identity(fileDescriptor: fd)
            guard openedIdentity == identity else {
                invalidIdentity = nil
                return invalidate("job journal changed while it was being opened; "
                                  + "the journal was preserved and no history was loaded")
            }
            guard identity.size <= Int64(JobJournalSchema.maximumDiskBytes) else {
                return invalidate("job journal exceeds its on-disk safety bound; "
                                  + "the journal was preserved and no history was loaded")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.read(upToCount: JobJournalSchema.maximumDiskBytes + 1) ?? Data()
            guard data.count <= JobJournalSchema.maximumDiskBytes else {
                return invalidate("job journal exceeds its on-disk safety bound; "
                                  + "the journal was preserved and no history was loaded")
            }
            let finalIdentity = try Self.identity(fileDescriptor: fd)
            guard finalIdentity == openedIdentity else {
                invalidIdentity = nil
                return invalidate("job journal changed while it was being read; "
                                  + "the journal was preserved and no history was loaded")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(JobJournalDocument.self, from: data)
            guard document.schema == JobJournalSchema.current else {
                return invalidate("job journal schema \(document.schema) is not supported; "
                                  + "the journal was preserved and no history was loaded")
            }
            let liveCount = document.records.filter(Self.isLive).count
            guard liveCount <= JobJournalSchema.maximumLiveRecords,
                  document.records.count <= max(historyLimit, liveCount) else {
                return invalidate("job journal exceeds its history bound; "
                                  + "the journal was preserved and no history was loaded")
            }
            let ids = document.records.map(\.id)
            let runIDs = document.records.map(\.runID)
            guard Set(ids).count == ids.count, Set(runIDs).count == runIDs.count,
                  document.records.allSatisfy(Self.recordShapeIsValid) else {
                return invalidate("job journal contains duplicate or incomplete records; "
                                  + "the journal was preserved and no history was loaded")
            }
            generation = document.generation
            invalidIdentity = nil
            return .loaded(document)
        } catch {
            return invalidate("job journal is corrupt or unreadable: \(error.localizedDescription); "
                              + "the journal was preserved and no history was loaded")
        }
    }

    /// Explicit operator recovery for a corrupt/future journal.  The old
    /// file is never decoded into live jobs, deleted, or overwritten.  Its
    /// exact regular-file identity is checked again immediately before an
    /// exclusive, atomic sibling rename; a new empty ledger is then created
    /// with an exclusive rename so a replacement cannot be overwritten.
    @discardableResult
    func quarantineInvalidJournal() -> Result<URL, Error> {
        guard !isHealthy, let expected = invalidIdentity else {
            return .failure(JournalError.quarantineUnavailable(
                "no invalid journal is awaiting explicit quarantine"))
        }
        guard expected.isRegular else {
            return .failure(JournalError.quarantineUnavailable(
                "the journal is not a regular file; quarantine is blocked"))
        }

        let directory = url.deletingLastPathComponent()
        let sourceName = url.lastPathComponent
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else {
            return .failure(Self.posixError("open journal directory"))
        }
        defer { _ = close(dirFD) }

        var quarantineName: String?
        var renamed = false
        var lastCollision: Error?
        for _ in 0..<8 {
            let candidate = quarantineNameFactory()
            guard Self.isSafeSiblingName(candidate) else {
                return .failure(JournalError.quarantineUnavailable(
                    "journal quarantine produced an unsafe sibling name"))
            }
            var current = stat()
            guard fstatat(dirFD, sourceName, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
                return .failure(JournalError.quarantineRace(
                    "the invalid journal disappeared or changed before confirmation"))
            }
            guard let currentIdentity = Self.identity(from: current),
                  currentIdentity == expected,
                  currentIdentity.isRegular else {
                return .failure(JournalError.quarantineRace(
                    "the invalid journal was replaced or changed before confirmation"))
            }
            let result = renameatx_np(dirFD, sourceName, dirFD, candidate, UInt32(RENAME_EXCL))
            if result == 0 {
                quarantineName = candidate
                renamed = true
                break
            }
            let code = errno
            if code == EEXIST {
                lastCollision = Self.posixError("reserve journal quarantine sibling")
                continue
            }
            if code == ENOENT {
                return .failure(JournalError.quarantineRace(
                    "the invalid journal was replaced or removed before confirmation"))
            }
            return .failure(Self.posixError("atomically quarantine journal"))
        }
        guard renamed, let quarantineName else {
            return .failure(lastCollision ?? JournalError.quarantineUnavailable(
                "could not reserve a unique journal quarantine sibling"))
        }

        // The rename itself is atomic, but it is not durable until the
        // containing directory is flushed.  Leave health blocked if this
        // fails; the evidence remains at the reported sibling path.
        guard fsync(dirFD) == 0 else {
            let message = "journal was moved to \(directory.appendingPathComponent(quarantineName).path), "
                + "but the directory could not be flushed; recovery remains blocked"
            return .failure(JournalError.quarantineFailed(message))
        }

        var moved = stat()
        guard fstatat(dirFD, quarantineName, &moved, AT_SYMLINK_NOFOLLOW) == 0,
              let movedIdentity = Self.identity(from: moved),
              movedIdentity.stableAfterRename == expected.stableAfterRename,
              movedIdentity.isRegular else {
            return .failure(JournalError.quarantineRace(
                "the quarantined journal did not retain the pinned identity; recovery remains blocked"))
        }
        var sourceAfter = stat()
        guard fstatat(dirFD, sourceName, &sourceAfter, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            return .failure(JournalError.quarantineRace(
                "a replacement appeared at the journal path; recovery remains blocked"))
        }

        let quarantineURL = directory.appendingPathComponent(quarantineName)
        do {
            // This is the first point at which the old journal has been
            // durably renamed.  Reset in-memory health only now, and create
            // the fresh ledger with an exclusive rename that cannot clobber a
            // file that appeared during confirmation.
            writable = true
            failure = nil
            generation = 0
            invalidIdentity = nil
            lastQuarantineURL = quarantineURL
            try persistEmptyLedgerExclusively()
            return .success(quarantineURL)
        } catch {
            writable = false
            failure = "journal evidence was preserved at \(quarantineURL.path), "
                + "but the new empty ledger could not be persisted: \(error.localizedDescription)"
            return .failure(error)
        }
    }

    /// Save a complete snapshot.  A failed save permanently disables further
    /// writes for this process; silently replacing a file that just failed is
    /// worse than showing the operator that the safety ledger is unavailable.
    @discardableResult
    func save(records: [JobJournalRecord]) -> Result<Void, Error> {
        guard isHealthy else {
            return .failure(JournalError.unavailable(failure ?? "job journal unavailable"))
        }
        do {
            try ensureParentDirectory()
            let ids = records.map(\.id)
            let runIDs = records.map(\.runID)
            guard Set(ids).count == ids.count,
                  Set(runIDs).count == runIDs.count,
                  records.allSatisfy(Self.recordShapeIsValid) else {
                throw JournalError.unavailable(
                    "job journal snapshot contains duplicate or unsafe records")
            }
            let liveCount = records.filter(Self.isLive).count
            guard liveCount <= JobJournalSchema.maximumLiveRecords else {
                throw JournalError.unavailable(
                    "too many live jobs to persist safely; stop or remove queued jobs")
            }
            generation &+= 1
            let limited = bounded(records)
            let document = JobJournalDocument(schema: JobJournalSchema.current,
                                              generation: generation,
                                              updatedAt: Date(), records: limited)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try atomicWrite(data)
            return .success(())
        } catch {
            writable = false
            failure = "job journal could not be saved: \(error.localizedDescription); "
                + "new transfers are blocked and the existing journal was preserved"
            return .failure(error)
        }
    }

    private func bounded(_ records: [JobJournalRecord]) -> [JobJournalRecord] {
        // A history cap may discard only terminal history. Losing an older
        // queued/running record would lose crash recovery and orphan cleanup.
        // Live records preserve caller order (e.g. operator-chosen queue order).
        let liveIDs = Set(records.filter(Self.isLive).map(\.id))
        // Retention recency includes `recoveredAt`: an interrupted record no
        // longer carries a finishedDate (the relaunch instant is a recovery,
        // not a completion), and ranking it by its old startedDate let the
        // recovery save itself push fresh DO-NOT-WIPE evidence past the cap
        // (codex verify round 3, NEW 1).
        let terminalSorted = records.filter { !Self.isLive($0) }.sorted {
            ($0.finishedDate ?? $0.recoveredAt ?? $0.startedDate ?? $0.createdDate)
                > ($1.finishedDate ?? $1.recoveredAt ?? $1.startedDate ?? $1.createdDate)
        }
        let terminalBudget = max(0, historyLimit - liveIDs.count)
        let allowedTerminalIDs = Set(terminalSorted.prefix(terminalBudget).map(\.id))
        return records.filter { liveIDs.contains($0.id) || allowedTerminalIDs.contains($0.id) }
    }

    private static func isLive(_ record: JobJournalRecord) -> Bool {
        guard let phase = JobPhase(rawValue: record.phase) else { return true }
        switch phase {
        case .queued, .starting, .copying, .sourceVerify, .reports:
            return true
        case .done, .failed, .refused:
            return false
        }
    }

    static func recordShapeIsValid(_ record: JobJournalRecord) -> Bool {
        let expectedLaneRoots = record.destinations.map {
            ($0 as NSString).appendingPathComponent(record.label)
        }
        let laneRootsAreValid = record.laneRoots.isEmpty
            || record.laneRoots == expectedLaneRoots
        let allowedProgressRoots = Set(expectedLaneRoots)
        guard let phase = JobPhase(rawValue: record.phase),
              isSafeAbsolutePath(record.sourcePath),
              !record.label.isEmpty,
              !containsControl(record.label),
              !record.destinations.isEmpty,
              record.destinations.allSatisfy(isSafeAbsolutePath),
              Set(record.destinations).count == record.destinations.count,
              laneRootsAreValid,
              Set(record.destinationSummary.keys).isSubset(of: allowedProgressRoots),
              Set((record.custodyFailures ?? [:]).keys).isSubset(of: allowedProgressRoots),
              (record.custodyFailures ?? [:]).allSatisfy({ lane, failure in
                  failure.folder == lane && !failure.isClean
                    && [failure.passed, failure.failed, failure.missing, failure.new,
                        failure.unverifiable, failure.chainProblems].allSatisfy { $0 >= 0 }
              }),
              record.messages.allSatisfy({ $0.severity == "warning" || $0.severity == "error" }),
              JobEvidenceParser.persistedArtifactPathsAreValid(
                label: record.label,
                destinations: record.destinations,
                laneRoots: record.laneRoots,
                reportPath: record.reportPath,
                reportPaths: record.reportPaths ?? [],
                manifestPaths: record.manifestPaths ?? [],
                receiptPath: record.receiptPath) else { return false }
        if record.safeToWipe {
            guard (record.custodyFailures ?? [:]).isEmpty,
                  phase == .done, record.fullyVerified, record.filesFailed == 0,
                  record.physicalDevices >= 2, record.wipeBlockers.isEmpty,
                  !record.sourceMutatedAfterStart, !record.stopRequested else { return false }
        }
        if let plan = record.plan {
            guard plan.src == record.sourcePath,
                  plan.cardLabel == record.label,
                  plan.destinations == record.destinations,
                  LaunchPlanValidation.isStructurallySafe(plan) else { return false }
        } else if isLive(record) {
            // A live record without a frozen invocation cannot be associated
            // with an orphan safely after a crash. Preserve the evidence but
            // refuse to load/overwrite it as if recovery were possible.
            return false
        }
        return true
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !containsControl(value), value.count <= 8_192 else {
            return false
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    // NOTE: launch-plan argv canonicality lives ONLY in
    // LaunchPlanValidation.argumentsAreCanonical (the load path reaches it
    // via isStructurallySafe). A private copy here drifted weaker and was
    // deleted in round 25 — do not reintroduce one.

    /// A crash mid-atomicWrite leaves ".jobs.json.<UUID>.tmp" behind forever;
    /// in-process cleanup only covers the non-crash paths. Day-old orphans in
    /// the evidence directory are litter, never evidence — sweep them.
    private func sweepOrphanedTempFiles() {
        let dir = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let candidate = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private func ensureParentDirectory() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    private func atomicWrite(_ data: Data, exclusive: Bool = false) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            handle.synchronizeFile()
            try handle.close()
            let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard dirFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let result: Int32
            if exclusive {
                result = renameatx_np(dirFD, temp.lastPathComponent,
                                      dirFD, url.lastPathComponent, UInt32(RENAME_EXCL))
            } else {
                result = renameat(dirFD, temp.lastPathComponent,
                                  dirFD, url.lastPathComponent)
            }
            guard result == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                _ = close(dirFD)
                throw POSIXError(code)
            }
            guard fsync(dirFD) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                _ = close(dirFD)
                throw POSIXError(code)
            }
            _ = close(dirFD)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private func persistEmptyLedgerExclusively() throws {
        try ensureParentDirectory()
        let document = JobJournalDocument(schema: JobJournalSchema.current,
                                          generation: 1,
                                          updatedAt: Date(), records: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(encoder.encode(document), exclusive: true)
        generation = 1
    }

    private static func identity(fileDescriptor: Int32) throws -> JournalFileIdentity {
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let result = identity(from: value) else {
            throw JournalError.quarantineUnavailable("could not read journal file identity")
        }
        return result
    }

    private static func identity(from value: stat) -> JournalFileIdentity? {
        JournalFileIdentity(
            device: Int64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            mode: UInt16(value.st_mode),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }

    private static func isSafeSiblingName(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value.count <= 255,
              !value.contains("/"), !containsControl(value) else { return false }
        return true
    }

    private static func posixError(_ operation: String) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return JournalError.quarantineFailed("\(operation) failed: \(String(describing: POSIXError(code)))")
    }

    private func invalidate(_ message: String) -> JobJournalLoadResult {
        writable = false
        failure = message
        return .invalid(message)
    }

    enum JournalError: LocalizedError {
        case unavailable(String)
        case quarantineUnavailable(String)
        case quarantineRace(String)
        case quarantineFailed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .quarantineUnavailable(let message),
                 .quarantineRace(let message), .quarantineFailed(let message):
                return message
            }
        }
    }
}
