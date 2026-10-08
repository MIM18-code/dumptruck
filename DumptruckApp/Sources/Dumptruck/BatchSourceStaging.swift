//
//  BatchSourceStaging.swift
//  Dumptruck
//
//  Pure and injectable batch preflight staging core.
//

import Foundation

// MARK: - Identity & Metadata Types

/// Stable device/file identity pinning to verify storage mounts and avoid duplicate device/file ingestion.
public struct FileIdentityPin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let deviceId: UInt64
    public let fileId: UInt64
    public let volumeUUID: String?

    public init(deviceId: UInt64, fileId: UInt64, volumeUUID: String? = nil) {
        self.deviceId = deviceId
        self.fileId = fileId
        self.volumeUUID = volumeUUID
    }

    public var description: String {
        if let volumeUUID {
            return "Pin(dev: \(deviceId), file: \(fileId), vol: \(volumeUUID))"
        }
        return "Pin(dev: \(deviceId), file: \(fileId))"
    }
}

/// Inspection metadata returned by an injected inspector for a source volume/card.
public struct CardInspectionMetadata: Hashable, Sendable, Codable {
    public let label: String?
    public let totalBytes: Int64
    public let fileCount: Int
    public let customProperties: [String: String]
    /// The card folders the engine's registry says this card wrote before
    /// (`previous_destinations`). Only meaningful when the card is known;
    /// it is how the batch tells a re-inserted card continuing into its own
    /// folder from a different card that happens to share the name.
    public let previousDestinations: [String]

    public init(
        label: String? = nil,
        totalBytes: Int64 = 0,
        fileCount: Int = 0,
        customProperties: [String: String] = [:],
        previousDestinations: [String] = []
    ) {
        self.label = label
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.customProperties = customProperties
        self.previousDestinations = previousDestinations
    }

    /// The engine recognized this card from an earlier offload.
    public var isKnownCard: Bool { customProperties["known"] == "true" }
}

/// Result returned from the card inspector including protocol version for compatibility checking.
public struct BatchInspectionResult: Hashable, Sendable {
    public let protocolVersion: Int
    public let metadata: CardInspectionMetadata

    public init(protocolVersion: Int, metadata: CardInspectionMetadata) {
        self.protocolVersion = protocolVersion
        self.metadata = metadata
    }
}

/// Destination lane representing a deterministic output directory for a specific staged item under a destination root.
public struct BatchDestinationLane: Hashable, Sendable, Codable {
    public let destinationRoot: String
    public let lanePath: String
    public let label: String

    public init(destinationRoot: String, lanePath: String, label: String) {
        self.destinationRoot = destinationRoot
        self.lanePath = lanePath
        self.label = label
    }
}

/// Pure projection of the card-name lane below one validated destination
/// root.  Batch preflight and the sheet's cheap revalidation must use the
/// same path math: a placeholder (or a path from a different destination
/// context) can make two otherwise independent mirrors look colliding.
public enum BatchDestinationLanePath {
    /// Returns a concrete lane path for an absolute root and a path-safe
    /// single-component label.  Invalid inputs return nil so UI revalidation
    /// can refuse the candidate rather than manufacture a plausible path.
    public static func make(destinationRoot: String, label: String) -> String? {
        let trimmedRoot = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty, trimmedRoot.hasPrefix("/") else { return nil }
        guard !label.isEmpty,
              label != ".",
              label != "..",
              !label.contains("/"),
              !label.contains("\\"),
              !label.contains(":"),
              !label.contains("\0") else { return nil }

        let normalizedRoot = StandardPurePathNormalizer.normalize(trimmedRoot)
        guard normalizedRoot.hasPrefix("/") else { return nil }
        if normalizedRoot == "/" {
            return "/\(label)"
        }
        return "\(normalizedRoot)/\(label)"
    }
}

/// Fully validated and staged item ready for downstream queueing or offloading.
public struct BatchStagedSourceItem: Hashable, Sendable, Identifiable {
    public var id: String { normalizedSourcePath }
    public let originalPath: String
    public let normalizedSourcePath: String
    public let label: String
    public let identityPin: FileIdentityPin
    public let metadata: CardInspectionMetadata
    public let destinationLanes: [BatchDestinationLane]
    /// The engine's suggestion before the batch made it unique. Equal to
    /// `label` unless `renamedBecause` is set.
    public let suggestedLabel: String
    public let renamedBecause: BatchLabelAllocator.RenameReason?
    /// Set when no usable name could be picked for this card. The card is
    /// inspected but not stageable, and has no lanes; the rest of the batch
    /// is unaffected.
    public let refusal: String?

    public init(
        originalPath: String,
        normalizedSourcePath: String,
        label: String,
        identityPin: FileIdentityPin,
        metadata: CardInspectionMetadata,
        destinationLanes: [BatchDestinationLane],
        suggestedLabel: String? = nil,
        renamedBecause: BatchLabelAllocator.RenameReason? = nil,
        refusal: String? = nil
    ) {
        self.originalPath = originalPath
        self.normalizedSourcePath = normalizedSourcePath
        self.label = label
        self.identityPin = identityPin
        self.metadata = metadata
        self.destinationLanes = destinationLanes
        self.suggestedLabel = suggestedLabel ?? label
        self.renamedBecause = renamedBecause
        self.refusal = refusal
    }
}

// MARK: - Batch card names

/// Pure helpers for naming cards in a batch. Shared by the core preflight
/// and the sheet's revalidation so both reach the same names.
public enum BatchCardNaming {
    /// How far the numbered names go before a card is refused instead.
    public static let maxSuffix = 999

    /// One key per folder name: 'A001' and 'a001' are one folder on APFS
    /// and exFAT (the engine's `identity._label_key`).
    public static func labelKey(_ label: String) -> String {
        label.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// "NO NAME", "NO NAME_2", "NO NAME_3"… An underscore and a number keep
    /// the camera's own name readable in Finder and sort next to it. The
    /// engine has no numbering convention of its own to follow: it suggests
    /// the known label, then the reel, then the volume name. The base is
    /// trimmed, never the number, when the result would pass the byte limit.
    public static func numbered(_ base: String, _ n: Int, maxLength: Int = 255) -> String {
        guard n > 1 else { return base }
        let tail = "_\(n)"
        var head = base
        while !head.isEmpty, head.utf8.count + tail.utf8.count > maxLength {
            head.removeLast()
        }
        return head + tail
    }

    /// True when this card wrote `lanePath` itself on an earlier offload,
    /// so writing there again is the engine's continuation, which the
    /// single-card Start allows: a known card resumes into its own folder.
    /// Compared the way the engine's `identity._path_key` compares (symlinks
    /// resolved, case folded, Unicode normalized). The engine records
    /// realpath() spellings and Foundation drops a leading /private, so both
    /// spellings count.
    public static func laneBelongsToCard(
        _ lanePath: String,
        known: Bool,
        previousDestinations: [String],
        resolve: (String) -> String
    ) -> Bool {
        guard known, !previousDestinations.isEmpty else { return false }
        let lane = pathKeys(lanePath, resolve: resolve)
        return previousDestinations.contains { !pathKeys($0, resolve: resolve).isDisjoint(with: lane) }
    }

    static func pathKeys(_ path: String, resolve: (String) -> String) -> Set<String> {
        var keys = Set<String>()
        for spelling in [path, resolve(path)] {
            let key = StandardPurePathNormalizer.normalize(spelling)
                .precomposedStringWithCanonicalMapping.lowercased()
            keys.insert(key)
            if key.hasPrefix("/private/") {
                keys.insert(String(key.dropFirst("/private".count)))
            } else {
                keys.insert("/private" + key)
            }
        }
        return keys
    }
}

/// Picks every card's folder name in a batch. The caller does the disk
/// work: it asks `nextRequest()` which name to try, projects that name's
/// lanes, and reports back through `answer(_:)`. The core preflight (async
/// file system) and the sheet's revalidation (synchronous) drive the same
/// rules this way.
///
/// Rules (Joshua, 2026-09-28: "if it's a bunch of Sony A7S3s, gonna be a
/// lot of bullshit with the same default name"):
/// - A fixed name is never changed: one the operator typed, or a known
///   card's own name, which is the engine's continuation key. Two fixed
///   cards with one name refuse both; a fixed name whose folder already
///   exists and was not written by this card refuses that card.
/// - Every other card starts from the engine's suggestion. In drag order,
///   the first card with a name keeps it; a later card, or one whose folder
///   on a destination belongs to a different card, takes the next free
///   numbered name ("NO NAME_2"). Numbered names skip any name that another
///   card in the batch carries on its own.
/// - Only that card is refused when naming fails. Two cards never get one
///   lane, and no card is given a lane that exists and is not its own.
public struct BatchLabelAllocator {
    public struct Entry: Equatable {
        public let source: String
        /// What the operator calls the card in messages (its volume name).
        public let displayName: String
        /// A usable base name, already checked by the caller.
        public let label: String
        public let fixed: Bool

        public init(source: String, displayName: String, label: String, fixed: Bool) {
            self.source = source
            self.displayName = displayName
            self.label = label
            self.fixed = fixed
        }
    }

    public struct Request: Equatable {
        public let index: Int
        public let label: String
    }

    public struct LaneProbe: Equatable {
        public let path: String
        /// The folder exists and this card did not write it.
        public let foreign: Bool

        public init(path: String, foreign: Bool) {
            self.path = path
            self.foreign = foreign
        }
    }

    public enum Answer: Equatable {
        case lanes([LaneProbe])
        /// No other name would help either (a folder template refusal, an
        /// invalid destination root): refuse the card now.
        case refuse(String)
    }

    public enum RenameReason: Equatable, Hashable, Sendable {
        case sameNameInBatch
        case folderTaken(lanePath: String)
    }

    public enum Outcome: Equatable {
        case assigned(label: String, lanes: [String], renamedFrom: String?, reason: RenameReason?)
        case refused(String)
    }

    public private(set) var outcomes: [Outcome?]
    private let entries: [Entry]
    private let order: [Int]
    private let maxLabelLength: Int
    private var naturalOwner: [String: Int] = [:]
    private var claimedLabels: [String: Int] = [:]
    private var claimedLanes: [String: Int] = [:]
    private var cursor = 0
    private var attempt = 1
    private var firstRejection: RenameReason?
    private var pending: Request?

    public init(entries: [Entry], maxLabelLength: Int = 255) {
        self.entries = entries
        self.maxLabelLength = maxLabelLength
        self.outcomes = Array(repeating: nil, count: entries.count)
        let fixed = entries.indices.filter { entries[$0].fixed }
        let rest = entries.indices.filter { !entries[$0].fixed }
        self.order = fixed + rest
        // A name belongs to the first card that carries it: fixed cards
        // before the rest, then drag order.
        for index in order {
            let key = BatchCardNaming.labelKey(entries[index].label)
            if naturalOwner[key] == nil { naturalOwner[key] = index }
        }
        var fixedByKey: [String: [Int]] = [:]
        for index in fixed {
            fixedByKey[BatchCardNaming.labelKey(entries[index].label), default: []].append(index)
        }
        for index in fixed {
            let key = BatchCardNaming.labelKey(entries[index].label)
            guard let group = fixedByKey[key], group.count > 1,
                  let other = group.first(where: { $0 != index }) else { continue }
            outcomes[index] = .refused(Self.sameNameRefusal(
                label: entries[index].label, other: entries[other].displayName))
        }
    }

    /// The next name to probe, or nil when every card has an outcome.
    public mutating func nextRequest() -> Request? {
        if let pending { return pending }
        while cursor < order.count {
            let index = order[cursor]
            let entry = entries[index]
            if outcomes[index] != nil {
                advance()
                continue
            }
            if entry.fixed {
                let request = Request(index: index, label: entry.label)
                pending = request
                return request
            }
            while attempt <= BatchCardNaming.maxSuffix {
                let label = BatchCardNaming.numbered(entry.label, attempt, maxLength: maxLabelLength)
                let key = BatchCardNaming.labelKey(label)
                let owner = naturalOwner[key]
                if claimedLabels[key] != nil || (owner != nil && owner != index) {
                    if attempt == 1 { firstRejection = .sameNameInBatch }
                    attempt += 1
                    continue
                }
                let request = Request(index: index, label: label)
                pending = request
                return request
            }
            outcomes[index] = .refused(Self.exhaustedRefusal(label: entry.label))
            advance()
        }
        return nil
    }

    public mutating func answer(_ answer: Answer) {
        guard let request = pending else { return }
        pending = nil
        let entry = entries[request.index]
        switch answer {
        case .refuse(let reason):
            outcomes[request.index] = .refused(reason)
            advance()
        case .lanes(let probes):
            let collision = probes.first { claimedLanes[BatchCardNaming.labelKey($0.path)] != nil }
            let taken = probes.first { $0.foreign }
            if collision != nil || taken != nil {
                if entry.fixed {
                    if let taken {
                        outcomes[request.index] = .refused(Self.existingFolderRefusal(
                            label: request.label, lanePath: taken.path))
                    } else if let collision,
                              let other = claimedLanes[BatchCardNaming.labelKey(collision.path)] {
                        outcomes[request.index] = .refused(
                            "Its destination folder \(collision.path) is also the folder of "
                            + "\(entries[other].displayName). Rename one of them.")
                    }
                    advance()
                } else {
                    if attempt == 1 {
                        firstRejection = taken.map { .folderTaken(lanePath: $0.path) } ?? .sameNameInBatch
                    }
                    attempt += 1
                }
                return
            }
            claimedLabels[BatchCardNaming.labelKey(request.label)] = request.index
            for probe in probes {
                claimedLanes[BatchCardNaming.labelKey(probe.path)] = request.index
            }
            let renamed = request.label != entry.label
            outcomes[request.index] = .assigned(
                label: request.label,
                lanes: probes.map(\.path),
                renamedFrom: renamed ? entry.label : nil,
                reason: renamed ? firstRejection : nil)
            advance()
        }
    }

    private mutating func advance() {
        cursor += 1
        attempt = 1
        firstRejection = nil
        pending = nil
    }

    // Refusals say what to do next: the fix is always a different name.

    public static func sameNameRefusal(label: String, other: String) -> String {
        "Another card in this batch (\(other)) is also named \"\(label)\". Rename one of them."
    }

    public static func existingFolderRefusal(label: String, lanePath: String) -> String {
        "A folder named \"\(label)\" already exists at \(lanePath) and this card did not "
            + "write it. Rename this card."
    }

    public static func exhaustedRefusal(label: String) -> String {
        "Every name from \"\(label)\" to \"\(label)_\(BatchCardNaming.maxSuffix)\" is already "
            + "taken. Rename this card."
    }

    /// The note under an automatically renamed card.
    public static func renameNote(from original: String, reason: RenameReason?) -> String {
        switch reason {
        case .folderTaken?:
            return "Renamed from \"\(original)\": a different card already has a folder with that name on the destination."
        case .sameNameInBatch?, nil:
            return "Renamed from \"\(original)\": another card in this batch has the same name."
        }
    }
}

// MARK: - Configuration & Options

public struct BatchSourceStagingOptions: Sendable {
    public let maxCandidates: Int
    public let maxPathLength: Int
    public let maxLabelLength: Int
    public let expectedProtocolVersion: Int
    /// Base budget for the whole preflight. The engine inspects one card at
    /// a time, so the real budget also grows by `perCandidateTimeoutSeconds`
    /// for every candidate (see `timeoutBudget`): a flat 15 s shared by the
    /// whole pile refused every card when one slow reader ate the clock
    /// (Joshua, 2026-09-28).
    public let timeoutSeconds: TimeInterval
    public let perCandidateTimeoutSeconds: TimeInterval
    public let disallowExistingDestinationLanes: Bool
    public let maxInspectionBytes: Int
    public let maxMetadataStringLength: Int
    public let maxMetadataListCount: Int

    public init(
        maxCandidates: Int = 64,
        maxPathLength: Int = 4096,
        maxLabelLength: Int = 255,
        expectedProtocolVersion: Int = 3,
        timeoutSeconds: TimeInterval = 15.0,
        perCandidateTimeoutSeconds: TimeInterval = 15.0,
        disallowExistingDestinationLanes: Bool = true,
        maxInspectionBytes: Int = 4 * 1024 * 1024,
        maxMetadataStringLength: Int = 1024,
        maxMetadataListCount: Int = 256
    ) {
        self.maxCandidates = maxCandidates
        self.maxPathLength = maxPathLength
        self.maxLabelLength = maxLabelLength
        self.expectedProtocolVersion = expectedProtocolVersion
        self.timeoutSeconds = timeoutSeconds
        self.perCandidateTimeoutSeconds = perCandidateTimeoutSeconds
        self.disallowExistingDestinationLanes = disallowExistingDestinationLanes
        self.maxInspectionBytes = maxInspectionBytes
        self.maxMetadataStringLength = maxMetadataStringLength
        self.maxMetadataListCount = maxMetadataListCount
    }

    /// The preflight's whole-batch deadline for this many candidates.
    public func timeoutBudget(candidateCount: Int) -> TimeInterval {
        timeoutSeconds + perCandidateTimeoutSeconds * Double(max(0, candidateCount))
    }
}

// MARK: - Error Types

public enum BatchSourceStagingError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyCandidates
    case emptyDestinations
    case candidateLimitExceeded(count: Int, limit: Int)
    case invalidPath(path: String, reason: String)
    case pathLengthExceeded(path: String, length: Int, limit: Int)
    case labelLengthExceeded(label: String, length: Int, limit: Int)
    case emptyLabel(path: String)
    case invalidLabel(label: String, reason: String)
    case sourceNotFound(path: String)
    case sourceNotDirectory(path: String)
    case sourceIsSymlink(path: String)
    case sourceIdentityChanged(path: String)
    case duplicateCandidatePath(path: String)
    case duplicateCandidatePin(pin: FileIdentityPin, firstSource: String, secondSource: String)
    case mutualSourceOverlap(source1: String, source2: String)
    case sourceDestinationOverlap(source: String, destination: String)
    case activeSourceOverlap(source: String, activeSource: String)
    case duplicateLabel(label: String, path1: String, path2: String)
    case destinationLaneCollision(lanePath: String, source1: String, source2: String)
    case existingDestinationLaneConflict(lanePath: String, source: String)
    case protocolMismatch(expected: Int, actual: Int, path: String)
    case timeout(seconds: TimeInterval)
    case cancelled
    case inspectionFailed(path: String, message: String)
    case inspectionMetadataOutOfBounds(path: String)

    public var description: String {
        switch self {
        case .emptyCandidates:
            return "Candidate source list is empty."
        case .emptyDestinations:
            return "Destination list is empty."
        case let .candidateLimitExceeded(count, limit):
            return "Candidate count (\(count)) exceeds maximum allowed bound of \(limit)."
        case let .invalidPath(path, reason):
            return "Invalid path '\(path)': \(reason)"
        case let .pathLengthExceeded(path, length, limit):
            return "Path '\(path)' length (\(length)) exceeds maximum allowed limit of \(limit)."
        case let .labelLengthExceeded(label, length, limit):
            return "Label '\(label)' length (\(length)) exceeds maximum allowed limit of \(limit)."
        case let .emptyLabel(path):
            return "Resolved label for source '\(path)' is empty."
        case let .invalidLabel(label, reason):
            return "Invalid label '\(label)': \(reason)"
        case let .sourceNotFound(path):
            return "Source directory does not exist at '\(path)'."
        case let .sourceNotDirectory(path):
            return "Source at '\(path)' is not a directory."
        case let .sourceIsSymlink(path):
            return "Source at '\(path)' is a symbolic link, which is not permitted."
        case let .sourceIdentityChanged(path):
            return "Source identity changed while inspecting '\(path)'; batch staging was refused."
        case let .duplicateCandidatePath(path):
            return "Duplicate candidate source path detected: '\(path)'."
        case let .duplicateCandidatePin(pin, firstSource, secondSource):
            return "Duplicate storage identity pin (\(pin)) detected between '\(firstSource)' and '\(secondSource)'."
        case let .mutualSourceOverlap(source1, source2):
            return "Candidate sources overlap hierarchically: '\(source1)' and '\(source2)'."
        case let .sourceDestinationOverlap(source, destination):
            return "Source '\(source)' overlaps with destination root '\(destination)'."
        case let .activeSourceOverlap(source, activeSource):
            return "Candidate source '\(source)' overlaps with active or queued source '\(activeSource)'."
        case let .duplicateLabel(label, path1, path2):
            return "Duplicate label '\(label)' generated for '\(path1)' and '\(path2)'."
        case let .destinationLaneCollision(lanePath, source1, source2):
            return "Destination lane collision at '\(lanePath)' between '\(source1)' and '\(source2)'."
        case let .existingDestinationLaneConflict(lanePath, source):
            return "Destination lane '\(lanePath)' already exists for candidate '\(source)'."
        case let .protocolMismatch(expected, actual, path):
            return "Protocol mismatch for '\(path)': expected \(expected), got \(actual)."
        case let .timeout(seconds):
            return "Batch staging preflight timed out after \(seconds)s."
        case .cancelled:
            return "Batch staging preflight was cancelled."
        case let .inspectionFailed(path, message):
            return "Card inspection failed for '\(path)': \(message)"
        case let .inspectionMetadataOutOfBounds(path):
            return "Card inspection metadata for '\(path)' exceeded the allowed bounds."
        }
    }
}

// MARK: - Injected Abstractions

/// File system abstraction enabling testability without disk access.
public protocol BatchSourceFileSystem: Sendable {
    func normalizePath(_ path: String) throws -> String
    func fileExists(atPath path: String) async throws -> Bool
    func isDirectory(atPath path: String) async throws -> Bool
    func isSymlink(atPath path: String) async throws -> Bool
    func fileIdentity(forPath path: String) async throws -> FileIdentityPin
    func destinationLaneExists(atPath path: String) async throws -> Bool
    /// The path with symlinks resolved, for comparing a lane with the card
    /// folders the engine recorded. The default is the path unchanged.
    func resolvedPath(_ path: String) -> String
}

public extension BatchSourceFileSystem {
    func resolvedPath(_ path: String) -> String { path }
}

/// Card inspector protocol returning metadata and protocol version.
public protocol BatchSourceInspector: Sendable {
    func inspect(sourcePath: String, pin: FileIdentityPin) async throws -> BatchInspectionResult
}

// MARK: - Core Implementation

public final class BatchSourceStagingCore: Sendable {
    public let fileSystem: BatchSourceFileSystem
    public let inspector: BatchSourceInspector
    public let options: BatchSourceStagingOptions

    public init(
        fileSystem: BatchSourceFileSystem,
        inspector: BatchSourceInspector,
        options: BatchSourceStagingOptions = BatchSourceStagingOptions()
    ) {
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.options = options
    }

    /// Performs strict preflight verification and all-or-nothing staging of candidate sources.
    /// Where a candidate's lane sits under a destination root. The default
    /// is root/label; the app supplies the folder-template projection the
    /// launch will actually use, so collision and existing-lane checks look
    /// at the real path (Codex desktop QA round 2, 2026-09-15, R2-03).
    public typealias LaneBase = (_ destinationRoot: String, _ label: String,
                                 _ inspection: BatchInspectionResult, _ sourcePath: String) -> String

    public func stageBatch(
        candidateSourcePaths: [String],
        destinationRoots: [String],
        existingActiveSourcePaths: [String] = [],
        laneBase: LaneBase? = nil
    ) async throws -> [BatchStagedSourceItem] {
        try Task.checkCancellation()

        // 1. Bound check candidates
        guard !candidateSourcePaths.isEmpty else {
            throw BatchSourceStagingError.emptyCandidates
        }

        guard !destinationRoots.isEmpty else {
            throw BatchSourceStagingError.emptyDestinations
        }

        guard candidateSourcePaths.count <= options.maxCandidates else {
            throw BatchSourceStagingError.candidateLimitExceeded(
                count: candidateSourcePaths.count,
                limit: options.maxCandidates
            )
        }

        // Execute preflight under timeout bound, scaled to the pile size.
        let budget = options.timeoutBudget(candidateCount: candidateSourcePaths.count)
        return try await withThrowingTaskGroup(of: [BatchStagedSourceItem].self) { group in
            group.addTask {
                try await self.performStaging(
                    candidateSourcePaths: candidateSourcePaths,
                    destinationRoots: destinationRoots,
                    existingActiveSourcePaths: existingActiveSourcePaths,
                    laneBase: laneBase
                )
            }

            group.addTask {
                let nanoseconds = UInt64(budget * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
                throw BatchSourceStagingError.timeout(seconds: budget)
            }

            guard let firstResult = try await group.next() else {
                throw BatchSourceStagingError.cancelled
            }
            group.cancelAll()
            return firstResult
        }
    }

    // MARK: - Private Preflight Pipeline

    private func performStaging(
        candidateSourcePaths: [String],
        destinationRoots: [String],
        existingActiveSourcePaths: [String],
        laneBase: LaneBase?
    ) async throws -> [BatchStagedSourceItem] {
        try Task.checkCancellation()

        // Step A: Normalize and validate destination roots
        var normalizedDestRoots: [String] = []
        for dest in destinationRoots {
            let normDest = try validateAndNormalizePath(dest)
            normalizedDestRoots.append(normDest)
        }

        // Step B: Normalize and validate active source paths
        var normalizedActiveSources: [String] = []
        for active in existingActiveSourcePaths {
            let normActive = try validateAndNormalizePath(active)
            normalizedActiveSources.append(normActive)
        }

        // Step C: Normalize and validate candidate paths while preserving input order
        var normalizedCandidatePaths: [String] = []
        var seenCandidatePaths: Set<String> = []

        for original in candidateSourcePaths {
            try Task.checkCancellation()
            let normalized = try validateAndNormalizePath(original)

            guard !seenCandidatePaths.contains(normalized) else {
                throw BatchSourceStagingError.duplicateCandidatePath(path: normalized)
            }
            seenCandidatePaths.insert(normalized)
            normalizedCandidatePaths.append(normalized)
        }

        // Step D: Mutual Candidate Overlap Check
        for i in 0..<normalizedCandidatePaths.count {
            for j in (i + 1)..<normalizedCandidatePaths.count {
                let p1 = normalizedCandidatePaths[i]
                let p2 = normalizedCandidatePaths[j]
                if pathsOverlap(p1, p2) {
                    throw BatchSourceStagingError.mutualSourceOverlap(source1: p1, source2: p2)
                }
            }
        }

        // Step E: Source / Destination Overlap Check
        for source in normalizedCandidatePaths {
            for dest in normalizedDestRoots {
                if pathsOverlap(source, dest) {
                    throw BatchSourceStagingError.sourceDestinationOverlap(source: source, destination: dest)
                }
            }
        }

        // Step F: Candidate / Active Source Overlap Check
        for source in normalizedCandidatePaths {
            for active in normalizedActiveSources {
                if pathsOverlap(source, active) {
                    throw BatchSourceStagingError.activeSourceOverlap(source: source, activeSource: active)
                }
            }
        }

        // Step G: Inspect File System Properties (Existence, Directory, Non-symlink, Identity Pins)
        struct VerifiedSource {
            let originalPath: String
            let normalizedPath: String
            let pin: FileIdentityPin
        }

        var verifiedSources: [VerifiedSource] = []
        var seenPins: [FileIdentityPin: String] = [:]

        for i in 0..<normalizedCandidatePaths.count {
            try Task.checkCancellation()
            let normPath = normalizedCandidatePaths[i]
            let origPath = candidateSourcePaths[i]

            // Exists check
            let exists = try await fileSystem.fileExists(atPath: normPath)
            guard exists else {
                throw BatchSourceStagingError.sourceNotFound(path: normPath)
            }

            // Symlink check
            let isSym = try await fileSystem.isSymlink(atPath: normPath)
            guard !isSym else {
                throw BatchSourceStagingError.sourceIsSymlink(path: normPath)
            }

            // Directory check
            let isDir = try await fileSystem.isDirectory(atPath: normPath)
            guard isDir else {
                throw BatchSourceStagingError.sourceNotDirectory(path: normPath)
            }

            // Pin lookup
            let pin = try await fileSystem.fileIdentity(forPath: normPath)
            if let priorSource = seenPins[pin] {
                throw BatchSourceStagingError.duplicateCandidatePin(
                    pin: pin,
                    firstSource: priorSource,
                    secondSource: normPath
                )
            }
            seenPins[pin] = normPath

            verifiedSources.append(VerifiedSource(originalPath: origPath, normalizedPath: normPath, pin: pin))
        }

        // Step H: Card Inspection & Protocol Verification
        struct InspectedItem {
            let verified: VerifiedSource
            let inspection: BatchInspectionResult
            let safeLabel: String
        }

        var inspectedItems: [InspectedItem] = []

        for item in verifiedSources {
            try Task.checkCancellation()
            let inspectionResult: BatchInspectionResult
            do {
                inspectionResult = try await inspector.inspect(sourcePath: item.normalizedPath, pin: item.pin)
            } catch let error as BatchSourceStagingError {
                throw error
            } catch {
                throw BatchSourceStagingError.inspectionFailed(
                    path: item.normalizedPath,
                    message: error.localizedDescription
                )
            }

            // An inspection can take long enough for a card to be removed and
            // another volume to mount at the same path. Re-pin and re-check
            // the path after the engine returns; a pin obtained only before
            // inspection is not evidence about the bytes that were inspected.
            let postInspectionIsSymlink = try await fileSystem.isSymlink(atPath: item.normalizedPath)
            guard !postInspectionIsSymlink else {
                throw BatchSourceStagingError.sourceIsSymlink(path: item.normalizedPath)
            }
            let postInspectionPin = try await fileSystem.fileIdentity(forPath: item.normalizedPath)
            guard postInspectionPin == item.pin else {
                throw BatchSourceStagingError.sourceIdentityChanged(path: item.normalizedPath)
            }

            guard inspectionResult.metadata.totalBytes >= 0,
                  inspectionResult.metadata.fileCount >= 0,
                  inspectionResult.metadata.customProperties.count <= options.maxMetadataListCount,
                  inspectionResult.metadata.customProperties.allSatisfy({ key, value in
                      key.utf8.count <= options.maxMetadataStringLength
                      && value.utf8.count <= options.maxMetadataStringLength
                  }),
                  inspectionResult.metadata.previousDestinations.count <= options.maxMetadataListCount,
                  inspectionResult.metadata.previousDestinations.allSatisfy({
                      $0.utf8.count <= options.maxMetadataStringLength
                  }) else {
                throw BatchSourceStagingError.inspectionMetadataOutOfBounds(path: item.normalizedPath)
            }

            // Protocol compatibility verification
            guard inspectionResult.protocolVersion == options.expectedProtocolVersion else {
                throw BatchSourceStagingError.protocolMismatch(
                    expected: options.expectedProtocolVersion,
                    actual: inspectionResult.protocolVersion,
                    path: item.normalizedPath
                )
            }

            // Safe unique label determination
            let rawLabel = inspectionResult.metadata.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateLabel: String
            if let rawLabel, !rawLabel.isEmpty {
                candidateLabel = rawLabel
            } else {
                candidateLabel = (item.normalizedPath as NSString).lastPathComponent
            }

            // A shared name is no longer a reason to refuse the pile: cards
            // of one camera model mount with one default name, and one throw
            // here refused every card with no way to rename out of it
            // (Joshua, 2026-09-28). Step I names each card instead.
            let safeLabel = try sanitizeAndValidateLabel(candidateLabel, forPath: item.normalizedPath)

            inspectedItems.append(InspectedItem(
                verified: item,
                inspection: inspectionResult,
                safeLabel: safeLabel
            ))
        }

        // Step I: Name every card, then project its lanes. The allocator
        // keeps two cards off one lane and keeps a card out of an existing
        // lane it did not write; a card it cannot name is refused on its
        // own, with its inspection kept, instead of refusing the batch.
        // A known card keeps its name (the continuation key) and may write
        // into its own existing folder, as single-card Start allows.
        let entries = inspectedItems.map { item in
            BatchLabelAllocator.Entry(
                source: item.verified.normalizedPath,
                displayName: (item.verified.normalizedPath as NSString).lastPathComponent,
                label: item.safeLabel,
                fixed: item.inspection.metadata.isKnownCard)
        }
        var allocator = BatchLabelAllocator(entries: entries, maxLabelLength: options.maxLabelLength)
        while let request = allocator.nextRequest() {
            try Task.checkCancellation()
            let item = inspectedItems[request.index]
            var probes: [BatchLabelAllocator.LaneProbe] = []
            for destRoot in normalizedDestRoots {
                let base = laneBase?(destRoot, request.label, item.inspection,
                                     item.verified.normalizedPath) ?? destRoot
                guard let lanePath = BatchDestinationLanePath.make(
                    destinationRoot: base,
                    label: request.label
                ) else {
                    // The inputs above are already validated, so this is an
                    // invariant guard.  Keep the refusal fail-closed if a
                    // future caller changes that validation contract.
                    throw BatchSourceStagingError.invalidPath(
                        path: destRoot,
                        reason: "Destination lane could not be projected safely."
                    )
                }
                var foreign = false
                if options.disallowExistingDestinationLanes,
                   try await fileSystem.destinationLaneExists(atPath: lanePath) {
                    foreign = !BatchCardNaming.laneBelongsToCard(
                        lanePath,
                        known: item.inspection.metadata.isKnownCard,
                        previousDestinations: item.inspection.metadata.previousDestinations,
                        resolve: fileSystem.resolvedPath)
                }
                probes.append(BatchLabelAllocator.LaneProbe(path: lanePath, foreign: foreign))
            }
            allocator.answer(.lanes(probes))
        }

        var stagedItems: [BatchStagedSourceItem] = []
        for (index, item) in inspectedItems.enumerated() {
            switch allocator.outcomes[index] {
            case let .assigned(label, lanes, _, reason)?:
                stagedItems.append(BatchStagedSourceItem(
                    originalPath: item.verified.originalPath,
                    normalizedSourcePath: item.verified.normalizedPath,
                    label: label,
                    identityPin: item.verified.pin,
                    metadata: item.inspection.metadata,
                    destinationLanes: zip(normalizedDestRoots, lanes).map {
                        BatchDestinationLane(destinationRoot: $0, lanePath: $1, label: label)
                    },
                    suggestedLabel: item.safeLabel,
                    renamedBecause: reason
                ))
            case let .refused(reason)?:
                stagedItems.append(BatchStagedSourceItem(
                    originalPath: item.verified.originalPath,
                    normalizedSourcePath: item.verified.normalizedPath,
                    label: item.safeLabel,
                    identityPin: item.verified.pin,
                    metadata: item.inspection.metadata,
                    destinationLanes: [],
                    suggestedLabel: item.safeLabel,
                    refusal: reason
                ))
            case nil:
                // The allocator settles every entry before nextRequest()
                // returns nil; fail closed if that ever stops being true.
                throw BatchSourceStagingError.invalidLabel(
                    label: item.safeLabel, reason: "No card name could be settled.")
            }
        }

        return stagedItems
    }

    // MARK: - Validation & Normalization Helpers

    public func validateAndNormalizePath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BatchSourceStagingError.invalidPath(path: rawPath, reason: "Path cannot be empty or whitespace only.")
        }

        guard trimmed.utf8.count <= options.maxPathLength else {
            throw BatchSourceStagingError.pathLengthExceeded(
                path: trimmed,
                length: trimmed.utf8.count,
                limit: options.maxPathLength
            )
        }

        // Path must be absolute
        guard trimmed.hasPrefix("/") else {
            throw BatchSourceStagingError.invalidPath(path: rawPath, reason: "Path must be an absolute path starting with '/'.")
        }

        // Canonical normalization without disk access (resolves ., .., repeated slashes)
        let normalized = try fileSystem.normalizePath(trimmed)
        guard normalized.hasPrefix("/") else {
            throw BatchSourceStagingError.invalidPath(path: rawPath, reason: "Normalized path must be absolute.")
        }
        return normalized
    }

    public func sanitizeAndValidateLabel(_ rawLabel: String, forPath sourcePath: String) throws -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BatchSourceStagingError.emptyLabel(path: sourcePath)
        }

        guard trimmed.utf8.count <= options.maxLabelLength else {
            throw BatchSourceStagingError.labelLengthExceeded(
                label: trimmed,
                length: trimmed.utf8.count,
                limit: options.maxLabelLength
            )
        }

        // Disallow dangerous path navigation or path delimiters
        if trimmed == "." || trimmed == ".." {
            throw BatchSourceStagingError.invalidLabel(label: trimmed, reason: "Label cannot be '.' or '..'.")
        }

        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("\0") || trimmed.contains(":") {
            throw BatchSourceStagingError.invalidLabel(label: trimmed, reason: "Label contains illegal path characters ('/', '\\', ':', or null byte).")
        }

        // Ensure label contains at least one printable non-whitespace character
        let containsPrintable = trimmed.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
        }
        guard containsPrintable else {
            throw BatchSourceStagingError.invalidLabel(label: trimmed, reason: "Label contains no printable non-control characters.")
        }

        return trimmed
    }

    public func pathsOverlap(_ p1: String, _ p2: String) -> Bool {
        if p1 == p2 {
            return true
        }
        let prefix1 = p1.hasSuffix("/") ? p1 : p1 + "/"
        let prefix2 = p2.hasSuffix("/") ? p2 : p2 + "/"

        if p2.hasPrefix(prefix1) || p1.hasPrefix(prefix2) {
            return true
        }
        return false
    }

}

// MARK: - Default Pure Path Normalizer

public struct StandardPurePathNormalizer {
    public static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var resolved: [Substring] = []

        for component in components {
            if component == "." {
                continue
            } else if component == ".." {
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
            } else {
                resolved.append(component)
            }
        }

        if resolved.isEmpty {
            return "/"
        }
        return "/" + resolved.joined(separator: "/")
    }
}

// MARK: - Standard Live File System Implementation

public final class StandardBatchSourceFileSystem: BatchSourceFileSystem, @unchecked Sendable {
    public init() {}

    public func normalizePath(_ path: String) throws -> String {
        return StandardPurePathNormalizer.normalize(path)
    }

    public func fileExists(atPath path: String) async throws -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    }

    public func isDirectory(atPath path: String) async throws -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    public func isSymlink(atPath path: String) async throws -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let fileType = attrs?[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    public func fileIdentity(forPath path: String) async throws -> FileIdentityPin {
        var statBuf = stat()
        let res = stat(path, &statBuf)
        guard res == 0 else {
            throw BatchSourceStagingError.sourceNotFound(path: path)
        }

        let url = URL(fileURLWithPath: path)
        let volValues = try? url.resourceValues(forKeys: [.volumeIdentifierKey, .volumeUUIDStringKey])
        let volUUID = volValues?.volumeUUIDString

        return FileIdentityPin(
            deviceId: UInt64(statBuf.st_dev),
            fileId: UInt64(statBuf.st_ino),
            volumeUUID: volUUID
        )
    }

    public func destinationLaneExists(atPath path: String) async throws -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    public func resolvedPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}

// MARK: - Live bounded card inspector

/// The batch UI must use the same protocol as a normal Start. This inspector
/// is deliberately separate from AppModel's single-card pipe: a batch never
/// mutates AppModel.sourcePath/inspection while it is looking at another
/// card, and each child is cancellable when the sheet closes or a new batch is
/// selected.
public final class StandardBatchSourceInspector: BatchSourceInspector, @unchecked Sendable {
    public let enginePython: String
    public let engineRoot: String
    public let maxOutputBytes: Int
    public let maxStringLength: Int
    public let maxListCount: Int

    public init(
        enginePython: String,
        engineRoot: String,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        maxStringLength: Int = 1024,
        maxListCount: Int = 256
    ) {
        self.enginePython = enginePython
        self.engineRoot = engineRoot
        self.maxOutputBytes = maxOutputBytes
        self.maxStringLength = maxStringLength
        self.maxListCount = maxListCount
    }

    public func inspect(sourcePath: String, pin: FileIdentityPin) async throws -> BatchInspectionResult {
        try Task.checkCancellation()
        let state = BatchInspectionProcessState()
        let data: Data
        do {
            data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    state.start(
                        executablePath: enginePython,
                        engineRoot: engineRoot,
                        sourcePath: sourcePath,
                        maxOutputBytes: maxOutputBytes,
                        continuation: continuation
                    )
                }
            }, onCancel: {
                state.cancel()
            })
        } catch is CancellationError {
            throw BatchSourceStagingError.cancelled
        } catch let error as BatchSourceStagingError {
            throw error
        } catch {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "engine inspection process failed"
            )
        }
        try Task.checkCancellation()
        return try parseInspection(data, sourcePath: sourcePath)
    }

    private func parseInspection(_ data: Data, sourcePath: String) throws -> BatchInspectionResult {
        try Self.parseInspectionData(
            data,
            sourcePath: sourcePath,
            maxOutputBytes: maxOutputBytes,
            maxStringLength: maxStringLength,
            maxListCount: maxListCount
        )
    }

    /// Parses the protocol-3 `inspect` object without treating a missing or
    /// nullable required field as a plausible default.  This is public only
    /// so the standalone contract check can exercise the exact same parser
    /// used by the live inspector; production callers should use `inspect`.
    public static func parseInspectionData(
        _ data: Data,
        sourcePath: String,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        maxStringLength: Int = 1024,
        maxListCount: Int = 256
    ) throws -> BatchInspectionResult {
        guard maxOutputBytes >= 0, maxStringLength >= 0, maxListCount >= 0 else {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "invalid inspection parser bounds"
            )
        }

        guard data.count <= maxOutputBytes else {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "inspection output exceeded the allowed bound"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "engine returned invalid inspection JSON"
            )
        }

        // Foundation bridges JSON booleans and numbers through NSNumber.  In
        // particular, `0 is Bool` can be true on macOS, so checking Swift's
        // `is Bool` alone would either accept a boolean as a count or reject
        // a legitimate zero.  The ObjC type code cleanly separates
        // __NSCFBoolean (`c`) from JSON integer/float numbers.
        func isJSONBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return String(cString: number.objCType) == "c"
        }

        guard let protocolValue = dict["protocol"],
              !isJSONBoolean(protocolValue),
              let protocolNumber = protocolValue as? Int else {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "inspection field protocol was invalid"
            )
        }

        func requiredString(_ key: String) throws -> String {
            guard let value = dict[key] as? String,
                  !value.isEmpty else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) was missing or not a non-empty string"
                )
            }
            guard value.utf8.count <= maxStringLength else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) exceeded the allowed bound"
                )
            }
            return value
        }

        /// `reel_name` is camera-embedded metadata and is legitimately null
        /// for generic/DCIM/audio sources.  A JSON `null` is represented by
        /// `NSNull`, so it must be distinguished from a present value of the
        /// wrong type.  Missing/null are both absent optional metadata.
        func nullableString(_ key: String) throws -> String? {
            guard let raw = dict[key], !(raw is NSNull) else { return nil }
            guard let value = raw as? String else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) was not a string"
                )
            }
            guard value.utf8.count <= maxStringLength else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) exceeded the allowed bound"
                )
            }
            return value
        }

        func requiredBool(_ key: String) throws -> Bool {
            guard let value = dict[key],
                  isJSONBoolean(value),
                  let number = value as? NSNumber else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) was invalid"
                )
            }
            return number.boolValue
        }

        func requiredNonNegativeInt(_ key: String) throws -> Int {
            guard let raw = dict[key], !isJSONBoolean(raw),
                  let number = raw as? Int, number >= 0 else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) was invalid"
                )
            }
            return number
        }

        func requiredNonNegativeInt64(_ key: String) throws -> Int64 {
            guard let raw = dict[key], !isJSONBoolean(raw),
                  let number = raw as? Int64, number >= 0 else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field \(key) was invalid"
                )
            }
            return number
        }

        let previous: [String]
        if let value = dict["previous_destinations"], !(value is NSNull) {
            guard let list = value as? [String], list.count <= maxListCount,
                  list.allSatisfy({ $0.utf8.count <= maxStringLength }) else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "previous destination metadata exceeded the allowed bound"
                )
            }
            previous = list
        } else {
            // The field is advisory history only.  Older protocol-3 engines
            // may emit null when no history exists; that is equivalent to an
            // empty list, but a malformed non-list remains a hard failure.
            previous = []
        }

        // These fields are not needed to build the batch plan, but they are
        // part of the protocol-3 inspection envelope.  Validate their types
        // when present so optional/null metadata cannot hide a skewed or
        // malformed identity result.  `last_offload` is null for new cards;
        // warnings are advisory and null is treated as no warnings.
        if let value = dict["last_offload"], !(value is NSNull),
           !(value is [String: Any]) {
            throw BatchSourceStagingError.inspectionFailed(
                path: sourcePath,
                message: "inspection field last_offload was invalid"
            )
        }
        if let value = dict["warnings"], !(value is NSNull) {
            guard let warnings = value as? [String],
                  warnings.count <= maxListCount,
                  warnings.allSatisfy({ $0.utf8.count <= maxStringLength }) else {
                throw BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection field warnings exceeded the allowed bound"
                )
            }
        }

        // Required fields are deliberately read even though some are only
        // carried for identity/diagnostic parity with the single-source
        // inspector.  Do not let `as?` + `?? default` turn a truncated
        // inspection into a queueable batch.
        let format = try requiredString("format")
        let formatName = try requiredString("format_name")
        let suggestedLabel = try requiredString("suggested_label")
        _ = try requiredBool("known")
        _ = try requiredBool("ambiguous")
        let mounts = try requiredNonNegativeInt("mounts")
        let files = try requiredNonNegativeInt("files")
        let bytes = try requiredNonNegativeInt64("bytes")

        let metadata = CardInspectionMetadata(
            label: suggestedLabel,
            totalBytes: bytes,
            fileCount: files,
            customProperties: [
                "format": format,
                "format_name": formatName,
                "reel_name": try nullableString("reel_name") ?? "",
                "known": String(try requiredBool("known")),
                "mounts": String(mounts),
                "previous_destinations_count": String(previous.count)
            ],
            // Kept whole: it is how a known card's existing folder is told
            // apart from a different card's folder with the same name.
            previousDestinations: previous
        )
        return BatchInspectionResult(protocolVersion: protocolNumber, metadata: metadata)
    }
}

private final class BatchInspectionProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var cancelled = false
    // The two halves of a completed inspection. Either can land first: the
    // child usually exits before the reader sees EOF, but a fast exit with a
    // still-draining pipe is normal too. The continuation resumes once both
    // are known. This replaced a reader-thread `waitUntilExit()`, which was
    // seen parked forever with no child left (Codex desktop QA round 2,
    // 2026-09-15, R2-01: a batch sheet stuck at "0 of 3 Ready" until relaunch).
    private var output: (data: Data, exceeded: Bool)?
    private var exitStatus: Int32?

    func start(
        executablePath: String,
        engineRoot: String,
        sourcePath: String,
        maxOutputBytes: Int,
        continuation: CheckedContinuation<Data, Error>
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-m", "dumptruck.cli", "inspect", sourcePath]
        process.currentDirectoryURL = URL(fileURLWithPath: engineRoot)
        process.environment = EngineRootResolver.processEnvironment(root: engineRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Set BEFORE run(): a child that exits before the handler exists
        // would otherwise never be observed.
        process.terminationHandler = { [weak self] proc in
            self?.noteExit(proc.terminationStatus, continuation: continuation, sourcePath: sourcePath)
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: BatchSourceStagingError.cancelled)
            return
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            // A cancel() that landed between storing the process and run()
            // succeeding saw isRunning == false and could not signal the
            // child; catch that window here so the engine never runs a full
            // inspection of a card the operator already walked away from.
            lock.lock()
            let cancelledDuringLaunch = cancelled
            lock.unlock()
            if cancelledDuringLaunch, process.isRunning { process.terminate() }
        } catch {
            finish(continuation: continuation, result: .failure(
                BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "could not start engine inspection"
                )))
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var collected = Data()
            var exceeded = false
            let reader = pipe.fileHandleForReading
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if collected.count < maxOutputBytes {
                    collected.append(chunk.prefix(maxOutputBytes - collected.count))
                }
                if collected.count >= maxOutputBytes && !chunk.isEmpty {
                    exceeded = true
                }
            }
            try? reader.close()
            guard let self else { return }
            self.noteOutput(collected, exceeded: exceeded, continuation: continuation, sourcePath: sourcePath)
            // Belt and braces: if the child is already gone, its status is
            // readable now whether or not the handler has been delivered yet.
            if !process.isRunning {
                self.noteExit(process.terminationStatus, continuation: continuation, sourcePath: sourcePath)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        // cancel() between storing the process and run() succeeding cannot
        // signal here (terminate on an unlaunched Process raises); the run
        // path re-checks the flag right after launch instead.
    }

    private func noteOutput(_ data: Data, exceeded: Bool,
                            continuation: CheckedContinuation<Data, Error>, sourcePath: String) {
        lock.lock()
        if output == nil { output = (data, exceeded) }
        lock.unlock()
        settle(continuation: continuation, sourcePath: sourcePath)
    }

    private func noteExit(_ status: Int32,
                          continuation: CheckedContinuation<Data, Error>, sourcePath: String) {
        lock.lock()
        if exitStatus == nil { exitStatus = status }
        lock.unlock()
        settle(continuation: continuation, sourcePath: sourcePath)
    }

    private func settle(continuation: CheckedContinuation<Data, Error>, sourcePath: String) {
        lock.lock()
        guard !finished, let output, let exitStatus else {
            lock.unlock()
            return
        }
        lock.unlock()
        if output.exceeded {
            finish(continuation: continuation, result: .failure(
                BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "inspection output exceeded the allowed bound"
                )))
        } else if exitStatus == 0 {
            finish(continuation: continuation, result: .success(output.data))
        } else {
            finish(continuation: continuation, result: .failure(
                BatchSourceStagingError.inspectionFailed(
                    path: sourcePath,
                    message: "engine inspection exited unsuccessfully"
                )))
        }
    }

    private func finish(
        continuation: CheckedContinuation<Data, Error>,
        result: Result<Data, Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let wasCancelled = cancelled
        process = nil
        lock.unlock()
        if wasCancelled {
            continuation.resume(throwing: BatchSourceStagingError.cancelled)
        } else {
            continuation.resume(with: result)
        }
    }
}
