import AppKit
import Darwin
import Foundation

// MARK: - Evidence Data Types

/// Per-file checksum and copy results recorded by the Dumptruck report writer.
///
/// INVARIANTS:
/// 1. Checksums are loaded only from the engine-generated receipt; they are
///    never recomputed or invented on the UI thread.
/// 2. The receipt is a normal JSON report artifact. It is not cryptographically
///    signed or sealed, and it can never authorize source wiping or eject.
struct FileChecksumRecord: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let size: Int64
    let outcome: String
    let hashes: [String: String]
    let destinationStatus: [String: String]

    init(path: String, size: Int64, outcome: String,
         hashes: [String: String] = [:],
         destinationStatus: [String: String] = [:]) {
        self.id = path
        self.path = path
        self.size = size
        self.outcome = outcome
        self.hashes = hashes
        self.destinationStatus = destinationStatus
    }

    var primaryChecksum: (algorithm: String, hex: String)? {
        // Dictionary iteration order is deliberately unspecified. Keep the
        // display/copy choice stable across launches and receipt order.
        for algorithm in JobEvidenceParser.checksumPriority {
            if let value = hashes[algorithm], !value.isEmpty {
                return (algorithm, value)
            }
        }
        return nil
    }

    /// Sort key that groups outcomes the way the Status badge renders them:
    /// failed, conflict, and unknown all display as FAILED, so they must
    /// sort together rather than by raw string.
    var outcomeDisplayRank: Int {
        switch outcome {
        case "verified": return 0
        case "skipped": return 1
        case "size-only": return 2
        default: return 3
        }
    }

    var formattedSize: String {
        let n = Double(size)
        if n < 1024 { return "\(size) B" }
        let kb = n / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}

/// Engine-generated receipt evidence. This is useful report data, not a
/// cryptographic attestation and never a source-wipe authority.
struct JobReceiptEvidence: Identifiable, Hashable, Sendable {
    let id: String
    let tool: String
    let generatedDate: Date?
    let generatedRaw: String
    let operatorName: String
    let host: String
    let label: String
    let source: String
    let destinations: [String]
    let verdict: String
    /// These are values the unsigned receipt reported. They are intentionally
    /// named as claims: the UI and eject gate must use Job.verdict/engine
    /// protocol state, never receipt contents, for current safety authority.
    let receiptClaimedSafeToWipe: Bool
    let receiptClaimedWipeBlockers: [String]
    let manifests: [String]
    let filesTotal: Int
    let filesCopied: Int
    let bytesCopied: Int64
    let errors: [String]
    let files: [FileChecksumRecord]
    let isTruncated: Bool
    let totalFilesInReceipt: Int
    let receiptFilePath: String

    init(id: String, tool: String, generatedDate: Date?, generatedRaw: String,
         operatorName: String, host: String, label: String, source: String,
         destinations: [String], verdict: String, receiptClaimedSafeToWipe: Bool,
         receiptClaimedWipeBlockers: [String], manifests: [String], filesTotal: Int,
         filesCopied: Int, bytesCopied: Int64, errors: [String],
         files: [FileChecksumRecord], isTruncated: Bool = false,
         totalFilesInReceipt: Int? = nil, receiptFilePath: String) {
        self.id = id
        self.tool = tool
        self.generatedDate = generatedDate
        self.generatedRaw = generatedRaw
        self.operatorName = operatorName
        self.host = host
        self.label = label
        self.source = source
        self.destinations = destinations
        self.verdict = verdict
        self.receiptClaimedSafeToWipe = receiptClaimedSafeToWipe
        self.receiptClaimedWipeBlockers = receiptClaimedWipeBlockers
        self.manifests = manifests
        self.filesTotal = filesTotal
        self.filesCopied = filesCopied
        self.bytesCopied = bytesCopied
        self.errors = errors
        self.files = files
        self.isTruncated = isTruncated
        self.totalFilesInReceipt = totalFilesInReceipt ?? files.count
        self.receiptFilePath = receiptFilePath
    }
}

enum ReceiptParseError: LocalizedError, Equatable {
    case fileNotFound(String)
    case unreadableFile(String)
    case receiptNotRegular(String)
    case receiptChangedDuringRead(String)
    case invalidReceiptPath(String)
    case fileTooLarge(current: Int64, maximum: Int64)
    case tooManyItems(field: String, count: Int, maximum: Int)
    case pathOutsideJobScope(path: String, scope: String)
    case pathTraversalDetected(String)
    case invalidJSON(String)
    case missingRequiredField(String)
    case invalidField(String)
    case duplicateValue(field: String, value: String)
    case labelMismatch(expected: String, found: String)
    case destinationMismatch(expected: [String], found: [String])
    case sourceMismatch(expected: String, found: String)
    case staleOrMismatchedRun(expected: String, found: String)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "Receipt file not found at \(path)."
        case let .unreadableFile(reason):
            return "Cannot read receipt file: \(reason)"
        case let .receiptNotRegular(path):
            return "Receipt path is not a regular file: \(path)."
        case let .receiptChangedDuringRead(path):
            return "Receipt changed while it was being read: \(path). Evidence was discarded."
        case let .invalidReceiptPath(path):
            return "Receipt path is not a canonical, authorized receipt path: \(path)."
        case let .fileTooLarge(current, max):
            return "Receipt file size (\(current) bytes) exceeds safe parsing cap of \(max) bytes."
        case let .tooManyItems(field, count, maximum):
            return "Receipt field '\(field)' contains \(count) items; the safe limit is \(maximum)."
        case let .pathOutsideJobScope(path, scope):
            return "Evidence path '\(path)' escapes authorized job scope '\(scope)'."
        case let .pathTraversalDetected(path):
            return "Path traversal ('..' or invalid characters) detected in '\(path)'."
        case let .invalidJSON(detail):
            return "Receipt contains invalid JSON: \(detail)"
        case let .missingRequiredField(field):
            return "Receipt is missing required evidence field: '\(field)'."
        case let .invalidField(field):
            return "Receipt field '\(field)' has an invalid or unsafe value."
        case let .duplicateValue(field, value):
            return "Receipt field '\(field)' contains a duplicate value: '\(value)'."
        case let .labelMismatch(expected, found):
            return "Receipt label '\(found)' does not match job label '\(expected)'."
        case let .destinationMismatch(expected, found):
            return "Receipt destinations \(found) do not match job destinations \(expected)."
        case let .sourceMismatch(expected, found):
            return "Receipt source '\(found)' does not match this job's source '\(expected)'."
        case let .staleOrMismatchedRun(expected, found):
            return "Receipt job ID '\(found)' does not match active job '\(expected)'."
        }
    }
}

// MARK: - Parser & Discovery

enum JobEvidenceParser {
    // Denial-of-service bounds, not workload limits: a 60,001-file card
    // writes a 21 MB receipt that the 16 MB cap refused to inspect (desktop
    // QA round 5, R5-03). Mirrors MAX_RECEIPT_BYTES / MAX_FILES_PER_RECEIPT
    // in dumptruck/report.py.
    static let maxReceiptFileSizeBytes: Int64 = 128 * 1024 * 1024
    static let maxParsedFiles: Int = 400_000
    static let maxPathBytes = 8 * 1024
    static let maxRelativePathBytes = 4 * 1024
    static let maxDestinations = 32
    static let maxManifests = 256
    static let maxErrors = 10_000
    static let maxBlockers = 256
    static let maxStringBytes = 8 * 1024
    static let maxHashEntries = 8
    static let maxStatusEntries = 64
    static let checksumPriority = [
        "xxh64", "sha256", "sha1", "md5", "xxh128", "xxh3", "sha512", "c4"
    ]

    private static let hashLengths: [String: Int] = [
        "xxh64": 16, "xxh3": 16, "xxh128": 32,
        "md5": 32, "sha1": 40, "sha256": 64, "sha512": 128
    ]
    private static let hashAlgorithms = Set(
        ["xxh64", "xxh3", "xxh128", "md5", "sha1", "sha256", "sha512", "c4"])
    private static let c4Alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let fileOutcomes = Set(["verified", "skipped", "size-only", "failed", "conflict"])
    private static let destinationStatuses = Set(["verified", "skipped", "trusted", "size-only", "failed", "conflict"])

    /// Parse an unsigned report receipt against the job's frozen identity.
    /// `expectedSource` and `expectedCardRoots` are optional for small parser
    /// fixtures; production loading always supplies both from Job.
    static func parse(data: Data,
                      expectedLabel: String,
                      expectedDestinations: [String],
                      receiptFilePath: String,
                      expectedSource: String? = nil,
                      expectedCardRoots: [String]? = nil) throws -> JobReceiptEvidence {
        guard Int64(data.count) <= maxReceiptFileSizeBytes else {
            throw ReceiptParseError.fileTooLarge(current: Int64(data.count),
                                                 maximum: maxReceiptFileSizeBytes)
        }
        let receiptPath = try canonicalAbsolutePath(receiptFilePath, field: "receipt path")
        guard receiptPath.hasSuffix(".receipt.json") else {
            throw ReceiptParseError.invalidReceiptPath(receiptFilePath)
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ReceiptParseError.invalidJSON(error.localizedDescription)
        }
        guard let dict = jsonObject as? [String: Any] else {
            throw ReceiptParseError.invalidJSON("Top-level JSON is not a dictionary.")
        }

        guard let label = dict["label"] as? String, !label.isEmpty else {
            throw ReceiptParseError.missingRequiredField("label")
        }
        try validateLabel(label, field: "label")
        guard label == expectedLabel else {
            throw ReceiptParseError.labelMismatch(expected: expectedLabel, found: label)
        }

        guard let rawDestinations = dict["destinations"] as? [String],
              !rawDestinations.isEmpty else {
            throw ReceiptParseError.missingRequiredField("destinations")
        }
        guard rawDestinations.count <= maxDestinations else {
            throw ReceiptParseError.tooManyItems(field: "destinations",
                                                 count: rawDestinations.count,
                                                 maximum: maxDestinations)
        }
        let destinations = try canonicalUniquePaths(rawDestinations, field: "destinations")
        let normalizedExpected = try canonicalUniquePaths(expectedDestinations,
                                                           field: "job destinations")
        if !normalizedExpected.isEmpty,
           Set(destinations) != Set(normalizedExpected) {
            throw ReceiptParseError.destinationMismatch(expected: normalizedExpected,
                                                        found: destinations)
        }

        let jobID = try optionalString(dict["job_id"], field: "job_id") ?? ""
        let tool = try optionalString(dict["tool"], field: "tool") ?? "Dumptruck"
        let generatedRaw = try optionalString(dict["generated"], field: "generated") ?? ""
        let operatorName = try optionalString(dict["operator"], field: "operator") ?? ""
        let host = try optionalString(dict["host"], field: "host") ?? ""
        let verdict = try optionalString(dict["verdict"], field: "verdict") ?? ""

        var generatedDate: Date?
        if generatedRaw.isEmpty {
            generatedDate = nil
        } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            generatedDate = iso.date(from: generatedRaw) ?? ISO8601DateFormatter().date(from: generatedRaw)
            guard generatedDate != nil else {
                throw ReceiptParseError.invalidField("generated")
            }
        }

        let rawSource = try optionalString(dict["source"], field: "source") ?? ""
        let source: String
        if let expectedSource {
            let normalizedExpectedSource = try canonicalAbsolutePath(expectedSource,
                                                                     field: "job source")
            guard !rawSource.isEmpty else {
                throw ReceiptParseError.missingRequiredField("source")
            }
            source = try canonicalAbsolutePath(rawSource, field: "source")
            guard source == normalizedExpectedSource else {
                throw ReceiptParseError.sourceMismatch(expected: normalizedExpectedSource,
                                                       found: source)
            }
        } else if rawSource.isEmpty {
            source = ""
        } else {
            source = try canonicalAbsolutePath(rawSource, field: "source")
        }

        let att: [String: Any]
        if let rawAttestation = dict["attestation"] {
            guard let value = rawAttestation as? [String: Any] else {
                throw ReceiptParseError.invalidField("attestation")
            }
            att = value
        } else {
            att = [:]
        }
        let safeToWipe = try optionalBool(att["safe_to_wipe_source"],
                                          field: "attestation.safe_to_wipe_source") ?? false
        let blockers = try boundedStringArray(att["safe_to_wipe_blockers"],
                                              field: "attestation.safe_to_wipe_blockers",
                                              maximum: maxBlockers,
                                              stringLimit: maxStringBytes)

        let cardRoots: [String]
        if let expectedCardRoots {
            cardRoots = try expectedCardRoots.map {
                try canonicalAbsolutePath($0, field: "job card root")
            }
        } else {
            cardRoots = cardRootsForDestinations(destinations: normalizedExpected,
                                                 label: expectedLabel)
        }
        if !normalizedExpected.isEmpty, cardRoots.count != normalizedExpected.count {
            throw ReceiptParseError.invalidField("job card roots")
        }

        let rawManifests = try boundedStringArray(dict["manifests"],
                                                   field: "manifests",
                                                   maximum: maxManifests,
                                                   stringLimit: maxPathBytes)
        var manifests: [String] = []
        manifests.reserveCapacity(rawManifests.count)
        for rawManifest in rawManifests {
            let manifest = try canonicalAbsolutePath(rawManifest, field: "manifests[]")
            guard manifest.hasSuffix(".mhl"),
                  cardRoots.contains(where: { isPathInside(manifest, root: $0) }) else {
                throw ReceiptParseError.pathOutsideJobScope(
                    path: manifest,
                    scope: cardRoots.joined(separator: ", "))
            }
            guard !manifests.contains(manifest) else {
                throw ReceiptParseError.duplicateValue(field: "manifests", value: manifest)
            }
            manifests.append(manifest)
        }

        let filesTotal = try boundedNonNegativeInt(dict["files_total"],
                                                   field: "files_total",
                                                   defaultValue: 0,
                                                   maximum: Int64(maxParsedFiles))
        let filesCopied = try boundedNonNegativeInt(dict["files_copied"],
                                                    field: "files_copied",
                                                    defaultValue: 0,
                                                    maximum: Int64(maxParsedFiles))
        let bytesCopied = try boundedNonNegativeInt(dict["bytes_copied"],
                                                    field: "bytes_copied",
                                                    defaultValue: 0,
                                                    maximum: Int64.max)
        guard filesCopied <= filesTotal || filesTotal == 0 else {
            throw ReceiptParseError.invalidField("files_copied")
        }
        let errors = try boundedStringArray(dict["errors"], field: "errors",
                                            maximum: maxErrors, stringLimit: maxStringBytes)

        guard let rawFiles = dict["files"] as? [[String: Any]] else {
            throw ReceiptParseError.missingRequiredField("files")
        }
        guard rawFiles.count <= maxParsedFiles else {
            throw ReceiptParseError.tooManyItems(field: "files", count: rawFiles.count,
                                                 maximum: maxParsedFiles)
        }
        if filesTotal != 0, filesTotal < rawFiles.count {
            throw ReceiptParseError.invalidField("files_total")
        }

        // FileResult.dest_status is keyed by the engine's actual card roots
        // (destination root + label), while the receipt-level destinations
        // field is the frozen destination-root set.
        let expectedStatusDestinations = Set(cardRoots)
        var parsedFiles: [FileChecksumRecord] = []
        parsedFiles.reserveCapacity(rawFiles.count)
        var seenFilePaths = Set<String>()

        for item in rawFiles {
            guard let rawPath = item["path"] as? String, !rawPath.isEmpty else {
                throw ReceiptParseError.missingRequiredField("files[].path")
            }
            let path = try canonicalRelativePath(rawPath, field: "files[].path")
            guard seenFilePaths.insert(path).inserted else {
                throw ReceiptParseError.duplicateValue(field: "files[].path", value: path)
            }
            let size = try boundedNonNegativeInt(item["size"], field: "files[].size",
                                                 defaultValue: 0, maximum: Int64.max)
            let outcome = try optionalString(item["outcome"], field: "files[].outcome") ?? "unknown"
            guard outcome == "unknown" || fileOutcomes.contains(outcome) else {
                throw ReceiptParseError.invalidField("files[].outcome")
            }
            let hashes = try validatedHashes(item["hashes"])
            let status = try validatedDestinationStatus(item["status"],
                                                        expectedDestinations: expectedStatusDestinations)

            parsedFiles.append(FileChecksumRecord(path: path, size: size,
                                                  outcome: outcome, hashes: hashes,
                                                  destinationStatus: status))
        }

        return JobReceiptEvidence(
            id: jobID,
            tool: tool,
            generatedDate: generatedDate,
            generatedRaw: generatedRaw,
            operatorName: operatorName,
            host: host,
            label: label,
            source: source,
            destinations: destinations,
            verdict: verdict,
            receiptClaimedSafeToWipe: safeToWipe,
            receiptClaimedWipeBlockers: blockers,
            manifests: manifests,
            filesTotal: filesTotal == 0 ? parsedFiles.count : Int(filesTotal),
            filesCopied: Int(filesCopied),
            bytesCopied: bytesCopied,
            errors: errors,
            files: parsedFiles,
            isTruncated: false,
            totalFilesInReceipt: parsedFiles.count,
            receiptFilePath: receiptPath
        )
    }

    // MARK: Artifact path validation / discovery

    /// Return only paths that could have been emitted by this job. This is
    /// shared by event handling, journal validation, and Finder actions; a
    /// label/date directory scan is intentionally never part of discovery.
    static func validatedReportPaths(for job: Job) -> [String]? {
        let paths = job.reportPaths.isEmpty
            ? (job.reportPath.map { [$0] } ?? [])
            : job.reportPaths
        return validatedReportPaths(paths, label: job.label,
                                    destinations: job.destinations,
                                    laneRoots: job.laneRoots)
    }

    static func validatedManifestPaths(for job: Job) -> [String]? {
        validatedManifestPaths(job.manifestPaths, label: job.label,
                               destinations: job.destinations,
                               laneRoots: job.laneRoots)
    }

    static func persistedArtifactPathsAreValid(
        label: String,
        destinations: [String],
        laneRoots: [String],
        reportPath: String?,
        reportPaths: [String],
        manifestPaths: [String],
        receiptPath: String?) -> Bool {
        let effectiveReports = reportPaths.isEmpty
            ? (reportPath.map { [$0] } ?? [])
            : reportPaths
        guard let reports = validatedReportPaths(effectiveReports, label: label,
                                                 destinations: destinations,
                                                 laneRoots: laneRoots),
              let manifests = validatedManifestPaths(manifestPaths, label: label,
                                                     destinations: destinations,
                                                     laneRoots: laneRoots) else {
            return false
        }
        if let reportPath {
            guard reports.contains(reportPath) else { return false }
        }
        if let receiptPath {
            guard let canonicalReceipt = try? canonicalAbsolutePath(receiptPath,
                                                                    field: "receipt path"),
                  canonicalReceipt.hasSuffix(".receipt.json") else { return false }
            // Either the sibling of an emitted report, or a standalone
            // receipt scoped to this job's report directories: with reports
            // off there is no HTML, and the journal refused every such
            // record as unsafe (desktop QA round 7, R7-01).
            let derived = Set(reports.map(receiptPath(forReport:)))
            guard derived.contains(canonicalReceipt)
                    || validatedReceiptPaths([canonicalReceipt], label: label,
                                             destinations: destinations,
                                             laneRoots: laneRoots) != nil else { return false }
        }
        _ = manifests
        return true
    }

    static func validatedReportPaths(_ paths: [String], label: String,
                                     destinations: [String], laneRoots: [String]) -> [String]? {
        guard paths.count <= maxManifests,
              let reportDirs = try? reportDirectories(label: label,
                                                      destinations: destinations,
                                                      laneRoots: laneRoots) else {
            return nil
        }
        var result: [String] = []
        for rawPath in paths {
            guard let path = try? canonicalAbsolutePath(rawPath, field: "report path"),
                  ["html", "pdf"].contains((path as NSString).pathExtension.lowercased()),
                  reportDirs.contains(where: { isPathInside(path, root: $0) }),
                  !result.contains(path) else { return nil }
            result.append(path)
        }
        return result
    }

    /// Receipt paths the engine emitted: inside a report directory of this
    /// job and named `*.receipt.json`. Reports off still writes these
    /// (desktop QA round 6, R6-01).
    static func validatedReceiptPaths(_ paths: [String], label: String,
                                      destinations: [String], laneRoots: [String]) -> [String]? {
        guard paths.count <= maxManifests,
              let reportDirs = try? reportDirectories(label: label,
                                                      destinations: destinations,
                                                      laneRoots: laneRoots) else {
            return nil
        }
        var result: [String] = []
        for rawPath in paths {
            guard let path = try? canonicalAbsolutePath(rawPath, field: "receipt path"),
                  path.hasSuffix(".receipt.json"),
                  reportDirs.contains(where: { isPathInside(path, root: $0) }),
                  !result.contains(path) else { return nil }
            result.append(path)
        }
        return result
    }

    static func validatedManifestPaths(_ paths: [String], label: String,
                                       destinations: [String], laneRoots: [String]) -> [String]? {
        guard paths.count <= maxManifests,
              let roots = try? cardRoots(label: label, destinations: destinations,
                                         laneRoots: laneRoots) else { return nil }
        var result: [String] = []
        for rawPath in paths {
            guard let path = try? canonicalAbsolutePath(rawPath, field: "manifest path"),
                  path.hasSuffix(".mhl"),
                  roots.contains(where: { isPathInside(path, root: $0) }),
                  !result.contains(path) else { return nil }
            result.append(path)
        }
        return result
    }

    static func findReceiptURL(for job: Job) -> URL? {
        let reports = validatedReportPaths(for: job) ?? []
        let candidates = reports.map(receiptPath(forReport:))
        // A persisted receiptPath is a hint. It is accepted when it is the
        // receipt sibling of an emitted report, or when it validates on its
        // own as an engine-emitted receipt inside this job's report
        // directories: with reports off there is no HTML sibling at all
        // (desktop QA round 6, R6-01).
        let explicitValid = job.receiptPath.flatMap { explicit -> String? in
            if candidates.contains(explicit) { return explicit }
            return validatedReceiptPaths([explicit], label: job.label,
                                         destinations: job.destinations,
                                         laneRoots: job.laneRoots)?.first
        }
        let ordered = explicitValid.map { [$0] } ?? []
        let all = ordered + candidates.filter { !ordered.contains($0) }
        for candidate in all where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    static func loadEvidence(for job: Job) -> Result<JobReceiptEvidence, ReceiptParseError> {
        guard let url = findReceiptURL(for: job) else {
            return .failure(.fileNotFound("No receipt sibling exists for this job's emitted reports"))
        }
        do {
            let data = try readStableReceipt(url)
            let expectedDestinations = job.destinations.isEmpty ? job.laneRoots : job.destinations
            let evidence = try parse(
                data: data,
                expectedLabel: job.label,
                expectedDestinations: expectedDestinations,
                receiptFilePath: url.path,
                expectedSource: job.sourcePath,
                expectedCardRoots: try cardRoots(label: job.label,
                                                 destinations: expectedDestinations,
                                                 laneRoots: job.laneRoots))
            return .success(evidence)
        } catch let err as ReceiptParseError {
            return .failure(err)
        } catch {
            return .failure(.unreadableFile(error.localizedDescription))
        }
    }

    // MARK: Strict JSON/path helpers

    private static func optionalString(_ value: Any?, field: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String, !string.isEmpty || field == "generated" else {
            throw ReceiptParseError.invalidField(field)
        }
        guard string.utf8.count <= maxStringBytes,
              !string.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ReceiptParseError.invalidField(field)
        }
        return string
    }

    private static func optionalBool(_ value: Any?, field: String) throws -> Bool? {
        guard let value else { return nil }
        guard let bool = value as? Bool else { throw ReceiptParseError.invalidField(field) }
        return bool
    }

    private static func boundedStringArray(_ value: Any?, field: String,
                                           maximum: Int, stringLimit: Int) throws -> [String] {
        guard let value else { return [] }
        guard let values = value as? [String] else { throw ReceiptParseError.invalidField(field) }
        guard values.count <= maximum else {
            throw ReceiptParseError.tooManyItems(field: field, count: values.count, maximum: maximum)
        }
        for item in values {
            guard !item.isEmpty, item.utf8.count <= stringLimit,
                  !item.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw ReceiptParseError.invalidField(field)
            }
        }
        return values
    }

    private static func boundedNonNegativeInt(_ value: Any?, field: String,
                                              defaultValue: Int64,
                                              maximum: Int64) throws -> Int64 {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber else { throw ReceiptParseError.invalidField(field) }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.down) == double,
              double <= Double(maximum) else {
            throw ReceiptParseError.invalidField(field)
        }
        let integer = number.int64Value
        guard integer >= 0, integer <= maximum else { throw ReceiptParseError.invalidField(field) }
        return integer
    }

    private static func validatedHashes(_ value: Any?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let raw = value as? [String: Any] else {
            throw ReceiptParseError.invalidField("files[].hashes")
        }
        guard raw.count <= maxHashEntries else {
            throw ReceiptParseError.tooManyItems(field: "files[].hashes", count: raw.count,
                                                 maximum: maxHashEntries)
        }
        var result: [String: String] = [:]
        for (algorithm, value) in raw {
            guard hashAlgorithms.contains(algorithm), let text = value as? String,
                  !text.isEmpty else { throw ReceiptParseError.invalidField("files[].hashes") }
            guard text.utf8.count <= 256 else { throw ReceiptParseError.invalidField("files[].hashes") }
            if algorithm == "c4" {
                guard text.utf8.count == 90, text.hasPrefix("c4"),
                      text.dropFirst(2).allSatisfy({ c4Alphabet.contains($0) }) else {
                    throw ReceiptParseError.invalidField("files[].hashes.c4")
                }
            } else {
                guard hashLengths[algorithm] == text.utf8.count,
                      text == text.lowercased(),
                      text.unicodeScalars.allSatisfy({
                          ($0.value >= 48 && $0.value <= 57)
                              || ($0.value >= 97 && $0.value <= 102)
                      }) else {
                    throw ReceiptParseError.invalidField("files[].hashes.\(algorithm)")
                }
            }
            result[algorithm] = text
        }
        return result
    }

    private static func validatedDestinationStatus(_ value: Any?,
                                                   expectedDestinations: Set<String>) throws -> [String: String] {
        guard let value else { return [:] }
        guard let raw = value as? [String: Any] else {
            throw ReceiptParseError.invalidField("files[].status")
        }
        guard raw.count <= maxStatusEntries else {
            throw ReceiptParseError.tooManyItems(field: "files[].status", count: raw.count,
                                                 maximum: maxStatusEntries)
        }
        var result: [String: String] = [:]
        for (rawPath, value) in raw {
            let path = try canonicalAbsolutePath(rawPath, field: "files[].status path")
            guard let status = value as? String, destinationStatuses.contains(status) else {
                throw ReceiptParseError.invalidField("files[].status")
            }
            guard expectedDestinations.isEmpty || expectedDestinations.contains(path) else {
                throw ReceiptParseError.pathOutsideJobScope(path: path,
                                                            scope: expectedDestinations.joined(separator: ", "))
            }
            result[path] = status
        }
        if !expectedDestinations.isEmpty, !result.isEmpty,
           Set(result.keys) != expectedDestinations {
            throw ReceiptParseError.destinationMismatch(expected: expectedDestinations.sorted(),
                                                        found: result.keys.sorted())
        }
        return result
    }

    private static func validateLabel(_ value: String, field: String) throws {
        guard value.utf8.count <= 512, !value.contains("/"), !value.contains("\\"),
              value != ".", value != "..",
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ReceiptParseError.invalidField(field)
        }
    }

    private static func canonicalAbsolutePath(_ value: String, field: String) throws -> String {
        guard value.utf8.count <= maxPathBytes, value.hasPrefix("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ReceiptParseError.invalidField(field)
        }
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard standardized == value else { throw ReceiptParseError.pathTraversalDetected(value) }
        return value
    }

    private static func canonicalRelativePath(_ value: String, field: String) throws -> String {
        guard value.utf8.count <= maxRelativePathBytes, !value.isEmpty,
              !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ReceiptParseError.pathTraversalDetected(value)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReceiptParseError.pathTraversalDetected(value)
        }
        return value
    }

    private static func canonicalUniquePaths(_ values: [String], field: String) throws -> [String] {
        guard values.count <= maxDestinations else {
            throw ReceiptParseError.tooManyItems(field: field, count: values.count,
                                                 maximum: maxDestinations)
        }
        var result: [String] = []
        for value in values {
            let path = try canonicalAbsolutePath(value, field: field)
            guard !result.contains(path) else {
                throw ReceiptParseError.duplicateValue(field: field, value: path)
            }
            result.append(path)
        }
        return result
    }

    private static func isPathInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func cardRootsForDestinations(destinations: [String], label: String) -> [String] {
        destinations.map { destination in
            let path = URL(fileURLWithPath: destination).standardizedFileURL.path
            return (path as NSString).lastPathComponent == label
                ? path
                : (path as NSString).appendingPathComponent(label)
        }
    }

    private static func cardRoots(label: String, destinations: [String],
                                  laneRoots: [String]) throws -> [String] {
        if !laneRoots.isEmpty, laneRoots.count == destinations.count {
            let roots = try canonicalUniquePaths(laneRoots, field: "lane roots")
            guard roots.allSatisfy({ (URL(fileURLWithPath: $0).lastPathComponent == label) }) else {
                throw ReceiptParseError.invalidField("lane roots")
            }
            return roots
        }
        let normalized = try canonicalUniquePaths(destinations, field: "job destinations")
        return cardRootsForDestinations(destinations: normalized, label: label)
    }

    private static func reportDirectories(label: String, destinations: [String],
                                          laneRoots: [String]) throws -> [String] {
        let cards = try cardRoots(label: label, destinations: destinations, laneRoots: laneRoots)
        let destinationDirs = cards.map { card in
            URL(fileURLWithPath: card).deletingLastPathComponent()
                .appendingPathComponent("Reports", isDirectory: true)
                .appendingPathComponent(label, isDirectory: true).path
        }
        let appHome = ProcessInfo.processInfo.environment["DUMPTRUCK_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Dumptruck").path
        let local = URL(fileURLWithPath: appHome)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true).path
        return try canonicalUniquePaths(destinationDirs + [local], field: "report directories")
    }

    private static func receiptPath(forReport report: String) -> String {
        (report as NSString).deletingPathExtension + ".receipt.json"
    }

    private struct ReceiptFileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private static func snapshot(_ value: stat) -> ReceiptFileSnapshot {
        ReceiptFileSnapshot(
            device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }

    private static func readStableReceipt(_ url: URL) throws -> Data {
        let path = try canonicalAbsolutePath(url.path, field: "receipt path")
        guard path.hasSuffix(".receipt.json"),
              url.resolvingSymlinksInPath().path == path else {
            throw ReceiptParseError.invalidReceiptPath(path)
        }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { throw ReceiptParseError.fileNotFound(path) }
            if errno == ELOOP { throw ReceiptParseError.receiptNotRegular(path) }
            throw ReceiptParseError.unreadableFile(String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(fd) }

        var beforeStat = stat()
        guard fstat(fd, &beforeStat) == 0 else {
            throw ReceiptParseError.unreadableFile("Cannot inspect receipt file identity")
        }
        guard (beforeStat.st_mode & S_IFMT) == S_IFREG else {
            throw ReceiptParseError.receiptNotRegular(path)
        }
        let before = snapshot(beforeStat)
        guard before.size >= 0, before.size <= maxReceiptFileSizeBytes else {
            throw ReceiptParseError.fileTooLarge(current: before.size,
                                                 maximum: maxReceiptFileSizeBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(before.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                throw ReceiptParseError.unreadableFile(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            let next = Int64(data.count) + Int64(count)
            guard next <= maxReceiptFileSizeBytes else {
                throw ReceiptParseError.fileTooLarge(current: next,
                                                     maximum: maxReceiptFileSizeBytes)
            }
            data.append(buffer, count: count)
        }

        var afterStat = stat()
        guard fstat(fd, &afterStat) == 0 else {
            throw ReceiptParseError.unreadableFile("Cannot recheck receipt file identity")
        }
        let after = snapshot(afterStat)
        var namedStat = stat()
        guard lstat(path, &namedStat) == 0,
              (namedStat.st_mode & S_IFMT) == S_IFREG,
              snapshot(namedStat) == before,
              after == before,
              Int64(data.count) == before.size else {
            throw ReceiptParseError.receiptChangedDuringRead(path)
        }
        return data
    }
}

// MARK: - Finder Actions Helper

enum FinderEvidenceActions {
    /// Finder actions are deliberately limited to canonical, non-symlink
    /// paths. A receipt/event path is untrusted input even after its lexical
    /// scope check; never let Quick Look or NSWorkspace follow a redirect.
    static func isSafeExistingPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            return false
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG || (info.st_mode & S_IFMT) == S_IFDIR
    }

    @discardableResult
    static func revealInFinder(_ path: String) -> Bool {
        guard isSafeExistingPath(path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    @discardableResult
    static func openFileOrFolder(_ path: String) -> Bool {
        guard isSafeExistingPath(path) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
