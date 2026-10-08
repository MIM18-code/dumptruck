import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum CSVExportError: LocalizedError, Equatable {
    case fileAlreadyExists(String)
    case unwriteableDestination(String)
    case invalidDirectory(String)
    case exportCancelled
    case emptyDataset
    case datasetTooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case let .fileAlreadyExists(path):
            return "Export destination '\(path)' already exists and overwrite was not confirmed."
        case let .unwriteableDestination(reason):
            return "Cannot write CSV export: \(reason)"
        case let .invalidDirectory(path):
            return "Destination directory does not exist or is not a directory: '\(path)'."
        case .exportCancelled:
            return "CSV export was cancelled by the operator."
        case .emptyDataset:
            return "No job history records to export."
        case let .datasetTooLarge(actual, maximum):
            return "CSV export contains \(actual) records; the maximum is \(maximum)."
        }
    }
}

/// Status filter for historical transfer queries.
enum JobHistoryStatusFilter: CaseIterable, Identifiable, Hashable {
    case all
    case safeToWipe
    case verifiedOnly
    case failedOrUnverified
    case live

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "All Results"
        case .safeToWipe: return Job.Verdict.safeToWipe.displayLine
        case .verifiedOnly: return Job.Verdict.verifiedKeepCard.displayLine
        case .failedOrUnverified: return "Needs Attention"
        case .live: return "Running / Queued"
        }
    }

    func matches(record: JobJournalRecord) -> Bool {
        guard let phase = JobPhase(rawValue: record.phase) else {
            return self == .all || self == .failedOrUnverified
        }
        switch self {
        case .all:
            return true
        case .safeToWipe:
            return record.safeToWipe && phase == .done && record.filesFailed == 0
                && record.fullyVerified
        case .verifiedOnly:
            return phase == .done && record.fullyVerified && !record.safeToWipe && record.filesFailed == 0
        case .failedOrUnverified:
            return phase == .failed || phase == .refused
                || (phase == .done && (!record.fullyVerified || record.filesFailed > 0))
        case .live:
            return phase == .queued || phase == .starting || phase == .copying
                || phase == .sourceVerify || phase == .reports
        }
    }

    func matches(job: Job) -> Bool {
        switch self {
        case .all:
            return true
        case .safeToWipe:
            return job.verdict == .safeToWipe
        case .verifiedOnly:
            return job.verdict == .verifiedKeepCard
        case .failedOrUnverified:
            return job.verdict == .failed || job.verdict == .unverified
        case .live:
            return job.isRunning
        }
    }
}

/// Date range filter for historical transfer queries.
enum JobHistoryDateFilter: String, CaseIterable, Identifiable {
    case allTime = "All Time"
    case today = "Today"
    case last24Hours = "Past 24 Hours"
    case last7Days = "Past 7 Days"
    case last30Days = "Past 30 Days"
    case custom = "Custom Range"

    var id: String { rawValue }

    func matches(date: Date, now: Date = Date(), customRange: ClosedRange<Date>? = nil, calendar: Calendar = .current) -> Bool {
        switch self {
        case .allTime:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last24Hours:
            return date >= now.addingTimeInterval(-24 * 3600) && date <= now.addingTimeInterval(60)
        case .last7Days:
            return date >= now.addingTimeInterval(-7 * 24 * 3600) && date <= now.addingTimeInterval(60)
        case .last30Days:
            return date >= now.addingTimeInterval(-30 * 24 * 3600) && date <= now.addingTimeInterval(60)
        case .custom:
            if let customRange {
                return customRange.contains(date)
            }
            return true
        }
    }
}

/// Sort order for historical transfer queries with guaranteed deterministic tie-breaking.
enum JobHistorySortOrder: String, CaseIterable, Identifiable {
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case labelAZ = "Card Label (A–Z)"
    case labelZA = "Card Label (Z–A)"
    case bytesLargest = "Data Size (Largest First)"

    var id: String { rawValue }
}

/// RFC 4180-compliant CSV serializer and exporter for persistent job history.
///
/// SAFETY & PRIVACY INVARIANTS:
/// 1. Journal is the single persistent history source.
/// 2. Fixed documented columns with RFC 4180 escaping (double-quote escaping, CRLF line endings).
/// 3. Neutralizes spreadsheet formula injection (=, +, -, @, \t, \r, |, %) by prepending a single quote.
/// 4. ISO-8601 timestamps.
/// 5. Bounded string fields (prevents memory/file inflation).
/// 6. Strict privacy exclusions: NO per-file names, NO source/destination absolute filesystem paths, NO secrets.
/// 7. Operator-initiated export via NSSavePanel or explicit non-silent atomic file write.
enum HistoryExport {
    static let maxLabelLength = 512
    /// Legacy text-field bound retained for source compatibility.  Blocker
    /// text is never serialized or indexed; only the count is used.
    static let maxBlockersLength = 1024
    static let maxGeneralFieldLength = 2048
    static let maxBlockerCount = 1024
    static let maxSearchQueryLength = 512
    static let maxHistoryRows = 10_000

    static let headers: [String] = [
        "Job ID",
        "Run ID",
        "Created At",
        "Started At",
        "Finished At",
        "Recovered At",
        "Card Label",
        "Phase",
        "Verdict",
        "Safe to Wipe",
        "Fully Verified",
        "Physical Devices",
        "Destination Count",
        "Files Total",
        "Files Copied",
        "Files Skipped",
        "Files Failed",
        "Bytes Total",
        "Bytes Finished",
        "Error Count",
        "Warning Count",
        "Wipe Blocker Count"
    ]

    static func defaultFilename(date: Date = Date(), count: Int? = nil) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.timeZone = TimeZone.current
        let dateStr = df.string(from: date)
        if let count {
            return "Dumptruck_History_\(dateStr)_\(count)_jobs.csv"
        }
        return "Dumptruck_History_\(dateStr).csv"
    }

    static func formatISO8601(_ date: Date?) -> String {
        guard let date else { return "" }
        // ISO8601DateFormatter is mutable and not Sendable. Keep it local so
        // the exporter remains valid under Swift 6 strict concurrency.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Neutralize formula injection for spreadsheet safety (Excel, Numbers, LibreOffice Calc, Google Sheets).
    /// If a field starts with =, +, -, @, \t, \r, |, or %, prepend a single quote so spreadsheets treat it as literal text.
    static func sanitizeForSpreadsheet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let dangerousPrefixes: [Character] = ["=", "+", "-", "@", "\t", "\r", "|", "%"]
        if let first = trimmed.first, dangerousPrefixes.contains(first) {
            return "'" + text
        }
        if let firstRaw = text.first, dangerousPrefixes.contains(firstRaw) {
            return "'" + text
        }
        return text
    }

    /// Bounding string length to prevent memory/file DOS.
    static func boundField(_ text: String, maxLength: Int) -> String {
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength))
    }

    /// Keep RFC 4180's meaningful tab/newline/carriage-return characters but
    /// drop NUL/other C0 controls and DEL, which can corrupt spreadsheet
    /// imports or act as terminal/control-channel data.
    private static func removeUnsafeControls(_ text: String) -> String {
        var cleaned = String()
        cleaned.unicodeScalars.append(contentsOf: text.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || (scalar.value >= 0x20 && scalar.value != 0x7F)
        })
        return cleaned
    }

    /// RFC 4180 field escaping.
    static func escapeCSVField(_ rawValue: String, maxLength: Int = maxGeneralFieldLength) -> String {
        let bounded = boundField(rawValue, maxLength: maxLength)
        let sanitized = sanitizeForSpreadsheet(removeUnsafeControls(bounded))
        let needsQuotes = sanitized.contains(",")
            || sanitized.contains("\"")
            || sanitized.contains("\n")
            || sanitized.contains("\r")
            || sanitized.hasPrefix(" ")
            || sanitized.hasSuffix(" ")
            || sanitized.hasPrefix("'")

        if needsQuotes {
            let escaped = sanitized.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return sanitized
    }

    /// Derive a historical record's semantic verdict through the same shared
    /// mapping used by live Job cards. The only user-facing string mapping is
    /// `Job.Verdict.displayLine`.
    static func verdict(for record: JobJournalRecord) -> Job.Verdict {
        guard let phase = JobPhase(rawValue: record.phase) else { return .failed }
        return Job.Verdict.from(phase: phase,
                                fullyVerified: record.fullyVerified,
                                safeToWipe: record.safeToWipe,
                                filesFailed: record.filesFailed)
    }

    /// Verdict display calculation for callers that still use the historical
    /// helper API. It delegates to the shared semantic mapping and never
    /// redefines the display strings here.
    static func verdictDisplay(phase: String, fullyVerified: Bool, safeToWipe: Bool, filesFailed: Int) -> String {
        guard let parsedPhase = JobPhase(rawValue: phase) else {
            return Job.Verdict.failed.displayLine
        }
        return Job.Verdict.from(phase: parsedPhase,
                                fullyVerified: fullyVerified,
                                safeToWipe: safeToWipe,
                                filesFailed: filesFailed).displayLine
    }

    static func boundedBlockerCount(_ blockers: [String]) -> Int {
        min(blockers.count, maxBlockerCount)
    }

    private static func safePhaseText(_ rawPhase: String) -> String {
        JobPhase(rawValue: rawPhase)?.rawValue ?? JobPhase.failed.rawValue
    }

    /// Convert a single JobJournalRecord into fixed CSV fields.
    static func fields(for record: JobJournalRecord) -> [String] {
        let errorCount = record.messages.filter { $0.severity == "error" }.count
        let warningCount = record.messages.filter { $0.severity == "warning" }.count
        let verdict = verdict(for: record).displayLine

        return [
            record.id.uuidString,
            record.runID.uuidString,
            formatISO8601(record.createdDate),
            formatISO8601(record.startedDate),
            formatISO8601(record.finishedDate),
            formatISO8601(record.recoveredAt),
            boundField(record.label, maxLength: maxLabelLength),
            safePhaseText(record.phase),
            verdict,
            record.safeToWipe ? "true" : "false",
            record.fullyVerified ? "true" : "false",
            "\(record.physicalDevices)",
            "\(record.destinations.count)",
            "\(record.filesTotal)",
            "\(record.filesCopied)",
            "\(record.filesSkipped)",
            "\(record.filesFailed)",
            "\(record.bytesTotal)",
            "\(record.bytesFinished)",
            "\(errorCount)",
            "\(warningCount)",
            "\(boundedBlockerCount(record.wipeBlockers))"
        ]
    }

    /// Convert a single live Job into fixed CSV fields.
    static func fields(for job: Job) -> [String] {
        let destCount = job.destinations.isEmpty ? job.laneRoots.count : job.destinations.count

        return [
            job.id.uuidString,
            job.runID.uuidString,
            formatISO8601(job.createdDate),
            formatISO8601(job.startedDate),
            formatISO8601(job.finishedDate),
            formatISO8601(job.recoveredAt),
            boundField(job.label, maxLength: maxLabelLength),
            job.phase.rawValue,
            job.verdict.displayLine,
            job.safeToWipe ? "true" : "false",
            job.fullyVerified ? "true" : "false",
            "\(job.physicalDevices)",
            "\(destCount)",
            "\(job.filesTotal)",
            "\(job.filesCopied)",
            "\(job.filesSkipped)",
            "\(job.filesFailed)",
            "\(job.bytesTotal)",
            "\(job.bytesFinished)",
            "\(job.errorCount)",
            "\(job.warningCount)",
            "\(boundedBlockerCount(job.wipeBlockers))"
        ]
    }

    /// Generate the full RFC 4180 CSV string for records.
    static func generateCSV(records: [JobJournalRecord]) -> String {
        let boundedRecords = records.prefix(maxHistoryRows)
        var lines: [String] = []
        lines.reserveCapacity(boundedRecords.count + 1)

        // Header row
        let headerRow = headers.map { escapeCSVField($0) }.joined(separator: ",")
        lines.append(headerRow)

        // Record rows
        for record in boundedRecords {
            let rowFields = fields(for: record)
            let escapedRow = rowFields.map { escapeCSVField($0) }.joined(separator: ",")
            lines.append(escapedRow)
        }

        // CRLF delimiter per RFC 4180 section 2.1
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Generate the full RFC 4180 CSV string for in-memory Jobs.
    static func generateCSV(jobs: [Job]) -> String {
        let boundedJobs = jobs.prefix(maxHistoryRows)
        var lines: [String] = []
        lines.reserveCapacity(boundedJobs.count + 1)

        let headerRow = headers.map { escapeCSVField($0) }.joined(separator: ",")
        lines.append(headerRow)

        for job in boundedJobs {
            let rowFields = fields(for: job)
            let escapedRow = rowFields.map { escapeCSVField($0) }.joined(separator: ",")
            lines.append(escapedRow)
        }

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Generate CSV data in UTF-8.
    static func generateCSVData(records: [JobJournalRecord]) -> Data {
        Data(generateCSV(records: records).utf8)
    }

    /// Generate CSV data from Jobs in UTF-8.
    static func generateCSVData(jobs: [Job]) -> Data {
        Data(generateCSV(jobs: jobs).utf8)
    }

    /// Atomic file exporter with overwrite protection.
    /// If `overwrite` is false and a file exists at `url`, this call throws `CSVExportError.fileAlreadyExists`.
    static func export(records: [JobJournalRecord], to url: URL, overwrite: Bool = false,
                       beforeCommit: (() throws -> Void)? = nil) throws {
        try validateExportCount(records.count)
        let fm = FileManager.default
        let destinationURL = url.standardizedFileURL
        let path = destinationURL.path

        if destinationEntryExists(path: path) && !overwrite {
            throw CSVExportError.fileAlreadyExists(path)
        }

        let directory = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw CSVExportError.invalidDirectory(directory.path)
        }

        let data = generateCSVData(records: records)
        try atomicWrite(data: data, to: destinationURL, overwrite: overwrite,
                        beforeCommit: beforeCommit)
    }

    /// Atomic file exporter for in-memory Jobs.
    static func export(jobs: [Job], to url: URL, overwrite: Bool = false,
                       beforeCommit: (() throws -> Void)? = nil) throws {
        try validateExportCount(jobs.count)
        let fm = FileManager.default
        let destinationURL = url.standardizedFileURL
        let path = destinationURL.path

        if destinationEntryExists(path: path) && !overwrite {
            throw CSVExportError.fileAlreadyExists(path)
        }

        let directory = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw CSVExportError.invalidDirectory(directory.path)
        }

        let data = generateCSVData(jobs: jobs)
        try atomicWrite(data: data, to: destinationURL, overwrite: overwrite,
                        beforeCommit: beforeCommit)
    }

    private static func validateExportCount(_ count: Int) throws {
        guard count > 0 else { throw CSVExportError.emptyDataset }
        guard count <= maxHistoryRows else {
            throw CSVExportError.datasetTooLarge(count, maxHistoryRows)
        }
    }

    /// `fileExists` follows symlinks and misses a dangling link. Treat any
    /// directory entry at the selected destination as an existing file so a
    /// non-confirmed export can never replace it silently.
    private static func destinationEntryExists(path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Atomic write helper using a directory-pinned temp file, an exclusive
    /// commit for fresh exports, and directory fsync. The optional hook is
    /// internal test instrumentation: it runs after the preflight check and
    /// before commit so the RENAME_EXCL race invariant is deterministic.
    private static func atomicWrite(data: Data, to destinationURL: URL,
                                    overwrite: Bool,
                                    beforeCommit: (() throws -> Void)? = nil) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let destinationName = destinationURL.lastPathComponent
        let tempName = ".\(destinationName).\(UUID().uuidString).tmp"
        // Pin the selected parent and reject a symlink at its final path
        // component. All subsequent open/rename/unlink operations use this
        // descriptor, so a path replacement cannot redirect the commit.
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else {
            throw CSVExportError.unwriteableDestination(
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        var tempCreated = false
        var dirClosed = false
        defer {
            if tempCreated { _ = unlinkat(dirFD, tempName, 0) }
            if !dirClosed { _ = close(dirFD) }
        }

        do {
            // O_EXCL + O_NOFOLLOW closes the temp-file race and keeps the
            // export private until the final same-directory rename.
            let fd = openat(dirFD, tempName,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                            S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            tempCreated = true
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else {
                let code = errno
                try? handle.close()
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try handle.close()

            try beforeCommit?()

            let renameFlags: UInt32 = overwrite ? 0 : UInt32(RENAME_EXCL)
            let renameResult = tempName.withCString { sourceName in
                destinationName.withCString { targetName in
                    renameatx_np(dirFD, sourceName, dirFD, targetName, renameFlags)
                }
            }
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            tempCreated = false

            guard fsync(dirFD) == 0 else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let closeResult = close(dirFD)
            let closeCode = errno
            dirClosed = true
            guard closeResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: closeCode) ?? .EIO)
            }
        } catch {
            throw CSVExportError.unwriteableDestination(error.localizedDescription)
        }
    }

    /// Prompt the operator with an NSSavePanel and export the CSV on main actor.
    @MainActor
    static func exportWithSavePanel(
        records: [JobJournalRecord],
        suggestedFilename: String? = nil,
        parentWindow: NSWindow? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.title = "Export Job History to CSV"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedFilename ?? defaultFilename(count: records.count)
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType.commaSeparatedText]

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let selectedURL = panel.url else {
                completion(.failure(CSVExportError.exportCancelled))
                return
            }
            do {
                // Overwrite is confirmed by the modal NSSavePanel replace prompt
                try export(records: records, to: selectedURL, overwrite: true)
                completion(.success(selectedURL))
            } catch {
                completion(.failure(error))
            }
        }

        if let parentWindow {
            panel.beginSheetModal(for: parentWindow, completionHandler: handleResponse)
        } else {
            let response = panel.runModal()
            handleResponse(response)
        }
    }
}

/// Backwards-compatibility alias.
typealias JobHistoryCSVExporter = HistoryExport

/// Filter, search, and sorting engine for persistent job history.
enum JobHistoryFilterEngine {
    private static func shortDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
    }

    private static func mediumDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func normalizedQuery(_ query: String) -> String {
        String(query.prefix(HistoryExport.maxSearchQueryLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func safeLabel(_ label: String) -> String {
        HistoryExport.boundField(label, maxLength: HistoryExport.maxLabelLength)
    }

    /// Full searchable string summary built strictly from safe metadata.
    /// INVARIANT: Does NOT expose or index per-file names or absolute paths.
    static func safeSearchText(for record: JobJournalRecord) -> String {
        let verdict = HistoryExport.verdict(for: record).displayLine
        let destCount = record.destinations.count
        let destText = destCount == 1 ? "1 destination 1 dest" : "\(destCount) destinations \(destCount) dests"
        let effectiveDate = record.finishedDate ?? record.startedDate ?? record.createdDate
        let shortDate = shortDateString(effectiveDate)
        let medDate = mediumDateString(effectiveDate)
        let isoDate = isoDateString(effectiveDate)
        let blockerText = "\(HistoryExport.boundedBlockerCount(record.wipeBlockers)) wipe blockers"
        let phase = JobPhase(rawValue: record.phase)?.rawValue ?? JobPhase.failed.rawValue
        return "\(safeLabel(record.label)) \(verdict) \(phase) \(destText) \(record.physicalDevices) physical devices \(shortDate) \(medDate) \(isoDate) \(bytesString(record.bytesTotal)) \(blockerText)".lowercased()
    }

    /// Full searchable string summary built strictly from safe metadata on live Job.
    /// INVARIANT: Does NOT expose or index per-file names or absolute paths.
    static func safeSearchText(for job: Job) -> String {
        let destCount = job.destinations.isEmpty ? job.laneRoots.count : job.destinations.count
        let destText = destCount == 1 ? "1 destination 1 dest" : "\(destCount) destinations \(destCount) dests"
        let effectiveDate = job.finishedDate ?? job.startedDate ?? job.createdDate
        let shortDate = shortDateString(effectiveDate)
        let medDate = mediumDateString(effectiveDate)
        let isoDate = isoDateString(effectiveDate)
        let blockerText = "\(HistoryExport.boundedBlockerCount(job.wipeBlockers)) wipe blockers"
        return "\(safeLabel(job.label)) \(job.verdict.displayLine) \(job.phase.rawValue) \(destText) \(job.physicalDevices) physical devices \(shortDate) \(medDate) \(isoDate) \(bytesString(job.bytesTotal)) \(blockerText)".lowercased()
    }

    /// Safe display metadata string tokens for search query matching.
    /// INVARIANT: Does NOT expose or index per-file names or absolute paths.
    static func safeDisplaySearchTokens(for record: JobJournalRecord) -> [String] {
        var tokens: [String] = []

        tokens.append(safeLabel(record.label).lowercased())

        let verdict = HistoryExport.verdict(for: record).displayLine
        tokens.append(verdict.lowercased())
        tokens.append((JobPhase(rawValue: record.phase)?.rawValue ?? JobPhase.failed.rawValue).lowercased())

        let destCount = record.destinations.count
        tokens.append(destCount == 1 ? "1 destination" : "\(destCount) destinations")
        tokens.append(destCount == 1 ? "1 dest" : "\(destCount) dests")

        tokens.append("\(record.physicalDevices) physical devices")
        tokens.append("\(record.physicalDevices) devices")

        let effectiveDate = record.finishedDate ?? record.startedDate ?? record.createdDate
        tokens.append(shortDateString(effectiveDate).lowercased())
        tokens.append(mediumDateString(effectiveDate).lowercased())
        tokens.append(isoDateString(effectiveDate).lowercased())

        tokens.append(bytesString(record.bytesTotal).lowercased())
        tokens.append("\(HistoryExport.boundedBlockerCount(record.wipeBlockers)) wipe blockers")

        return tokens
    }

    /// Safe display metadata string tokens for live in-memory Job.
    /// INVARIANT: Does NOT expose or index per-file names or absolute paths.
    static func safeDisplaySearchTokens(for job: Job) -> [String] {
        var tokens: [String] = []

        tokens.append(safeLabel(job.label).lowercased())
        tokens.append(job.verdict.displayLine.lowercased())
        tokens.append(job.phase.rawValue.lowercased())

        let destCount = job.destinations.isEmpty ? job.laneRoots.count : job.destinations.count
        tokens.append(destCount == 1 ? "1 destination" : "\(destCount) destinations")
        tokens.append(destCount == 1 ? "1 dest" : "\(destCount) dests")

        tokens.append("\(job.physicalDevices) physical devices")
        tokens.append("\(job.physicalDevices) devices")

        let effectiveDate = job.finishedDate ?? job.startedDate ?? job.createdDate
        tokens.append(shortDateString(effectiveDate).lowercased())
        tokens.append(mediumDateString(effectiveDate).lowercased())
        tokens.append(isoDateString(effectiveDate).lowercased())

        tokens.append(bytesString(job.bytesTotal).lowercased())
        tokens.append("\(HistoryExport.boundedBlockerCount(job.wipeBlockers)) wipe blockers")

        return tokens
    }

    /// Check if query matches safe display metadata.
    static func matchesSearch(record: JobJournalRecord, query: String) -> Bool {
        let trimmed = normalizedQuery(query)
        guard !trimmed.isEmpty else { return true }
        let searchText = safeSearchText(for: record)
        if searchText.contains(trimmed) { return true }
        let searchWords = trimmed.split(separator: " ").map(String.init)
        return searchWords.allSatisfy { word in
            searchText.contains(word)
        }
    }

    /// Check if query matches safe display metadata on Job.
    static func matchesSearch(job: Job, query: String) -> Bool {
        let trimmed = normalizedQuery(query)
        guard !trimmed.isEmpty else { return true }
        let searchText = safeSearchText(for: job)
        if searchText.contains(trimmed) { return true }
        let searchWords = trimmed.split(separator: " ").map(String.init)
        return searchWords.allSatisfy { word in
            searchText.contains(word)
        }
    }

    /// Stable deterministic sort for JobJournalRecord with UUID tie-breaker.
    static func sort(records: [JobJournalRecord], by order: JobHistorySortOrder) -> [JobJournalRecord] {
        records.sorted { a, b in
            let dateA = a.finishedDate ?? a.startedDate ?? a.createdDate
            let dateB = b.finishedDate ?? b.startedDate ?? b.createdDate

            switch order {
            case .newestFirst:
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .oldestFirst:
                if dateA != dateB { return dateA < dateB }
                return a.id.uuidString < b.id.uuidString
            case .labelAZ:
                let cmp = a.label.localizedCaseInsensitiveCompare(b.label)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .labelZA:
                let cmp = a.label.localizedCaseInsensitiveCompare(b.label)
                if cmp != .orderedSame { return cmp == .orderedDescending }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .bytesLargest:
                if a.bytesTotal != b.bytesTotal { return a.bytesTotal > b.bytesTotal }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            }
        }
    }

    /// Stable deterministic sort for Job with UUID tie-breaker.
    static func sort(jobs: [Job], by order: JobHistorySortOrder) -> [Job] {
        jobs.sorted { a, b in
            let dateA = a.finishedDate ?? a.startedDate ?? a.createdDate
            let dateB = b.finishedDate ?? b.startedDate ?? b.createdDate

            switch order {
            case .newestFirst:
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .oldestFirst:
                if dateA != dateB { return dateA < dateB }
                return a.id.uuidString < b.id.uuidString
            case .labelAZ:
                let cmp = a.label.localizedCaseInsensitiveCompare(b.label)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .labelZA:
                let cmp = a.label.localizedCaseInsensitiveCompare(b.label)
                if cmp != .orderedSame { return cmp == .orderedDescending }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            case .bytesLargest:
                if a.bytesTotal != b.bytesTotal { return a.bytesTotal > b.bytesTotal }
                if dateA != dateB { return dateA > dateB }
                return a.id.uuidString > b.id.uuidString
            }
        }
    }

    /// Complete filter & sort pipeline for JobJournalRecord.
    static func filterAndSort(
        records: [JobJournalRecord],
        query: String = "",
        statusFilter: JobHistoryStatusFilter = .all,
        dateFilter: JobHistoryDateFilter = .allTime,
        customDateRange: ClosedRange<Date>? = nil,
        sortOrder: JobHistorySortOrder = .newestFirst,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [JobJournalRecord] {
        let filtered = records.filter { record in
            guard statusFilter.matches(record: record) else { return false }
            let date = record.finishedDate ?? record.startedDate ?? record.createdDate
            guard dateFilter.matches(date: date, now: now, customRange: customDateRange, calendar: calendar) else {
                return false
            }
            guard matchesSearch(record: record, query: query) else { return false }
            return true
        }
        return Array(sort(records: filtered, by: sortOrder).prefix(HistoryExport.maxHistoryRows))
    }

    /// Complete filter & sort pipeline for Job.
    static func filterAndSort(
        jobs: [Job],
        query: String = "",
        statusFilter: JobHistoryStatusFilter = .all,
        dateFilter: JobHistoryDateFilter = .allTime,
        customDateRange: ClosedRange<Date>? = nil,
        sortOrder: JobHistorySortOrder = .newestFirst,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Job] {
        let filtered = jobs.filter { job in
            guard statusFilter.matches(job: job) else { return false }
            let date = job.finishedDate ?? job.startedDate ?? job.createdDate
            guard dateFilter.matches(date: date, now: now, customRange: customDateRange, calendar: calendar) else {
                return false
            }
            guard matchesSearch(job: job, query: query) else { return false }
            return true
        }
        return Array(sort(jobs: filtered, by: sortOrder).prefix(HistoryExport.maxHistoryRows))
    }
}

// MARK: - Shoot-Day Wrap Report Execution

public struct WrapReportResult: Sendable {
    public let wrapID: String
    public let htmlPath: String
    public let pdfPath: String?
    public let pdfGenerated: Bool
    public let cardsCount: Int
    public let cards: [String]
    public let totalBytes: Int64
    public let totalFiles: Int
    public let safeCards: Int
    public let allSafe: Bool
    /// Why no PDF was produced, when the HTML is complete and usable
    /// (desktop QA round 6, R6-02).
    public let pdfNotice: String?

    public init(wrapID: String, htmlPath: String, pdfPath: String?, pdfGenerated: Bool,
                cardsCount: Int, cards: [String], totalBytes: Int64, totalFiles: Int,
                safeCards: Int, allSafe: Bool, pdfNotice: String? = nil) {
        self.pdfNotice = pdfNotice
        self.wrapID = wrapID
        self.htmlPath = htmlPath
        self.pdfPath = pdfPath
        self.pdfGenerated = pdfGenerated
        self.cardsCount = cardsCount
        self.cards = cards
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.safeCards = safeCards
        self.allSafe = allSafe
    }
}

public enum WrapReportError: LocalizedError, Equatable, Sendable {
    case noJobsSelected
    case missingReceipts([String])
    case duplicateReceipts
    case pythonExecutableNotFound
    case processFailed(String)
    case invalidOutput(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noJobsSelected:
            return "No jobs selected for wrap report."
        case let .missingReceipts(labels):
            return "Cannot generate wrap report: \(labels.count) card(s) have no valid receipt JSON file on record (\(labels.joined(separator: ", ")))."
        case .duplicateReceipts:
            return "Duplicate receipts detected in the selected jobs."
        case .pythonExecutableNotFound:
            return "Python executable not found to run wrap report generator."
        case let .processFailed(msg):
            return "Wrap report generation failed: \(msg)"
        case let .invalidOutput(msg):
            return "Wrap report returned invalid output: \(msg)"
        case .cancelled:
            return "Wrap report generation was cancelled."
        }
    }
}

public enum WrapReportRunner {
    /// Resolve python binary location using configured enginePython and fallback paths.
    public static func resolvePython(preferred: String? = nil) -> String? {
        let fm = FileManager.default
        if let preferred, fm.isExecutableFile(atPath: preferred) {
            return preferred
        }
        let candidates = [
            preferred,
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        for cand in candidates {
            if fm.isExecutableFile(atPath: cand) {
                return cand
            }
        }
        return nil
    }

    /// Run the wrap report generator subprocess against selected receipt JSON files.
    public static func generate(
        receiptPaths: [String],
        outputDirectory: URL? = nil,
        title: String? = nil,
        enginePython: String? = nil,
        engineRoot: String? = nil,
        completion: @escaping @Sendable (Result<WrapReportResult, WrapReportError>) -> Void
    ) {
        guard !receiptPaths.isEmpty else {
            completion(.failure(.noJobsSelected))
            return
        }
        guard let pythonPath = resolvePython(preferred: enginePython) else {
            completion(.failure(.pythonExecutableNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            var args = ["-m", "dumptruck.cli", "wrap-report"] + receiptPaths + ["--json"]
            if let outDir = outputDirectory?.path {
                args += ["--out", outDir]
            }
            if let title = title {
                args += ["--title", title]
            }
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            if let engineRoot {
                env["PYTHONPATH"] = engineRoot
                env = EngineRootResolver.processEnvironment(root: engineRoot, base: env)
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                // Drain both pipes concurrently. Sequential stdout-then-stderr
                // reads deadlock when the child fills the ~64KB stderr buffer
                // before closing stdout — the one spawn site that kept the
                // sequential pattern (round-24 finding), and the only escape
                // from its stuck "Generating…" sheet was quitting the app.
                var stderrData = Data()
                let stderrDrained = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrDrained.signal()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrDrained.wait()
                process.waitUntilExit()

                let stdoutStr = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let stderrStr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

                guard let lastLine = stdoutStr.split(separator: "\n").last,
                      let lineData = String(lastLine).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    let errDetail = stderrStr.isEmpty ? stdoutStr : stderrStr
                    completion(.failure(.processFailed(errDetail.isEmpty ? "Unknown engine failure" : errDetail)))
                    return
                }

                let ok = (json["ok"] as? Bool) ?? false
                if !ok {
                    // The HTML is the complete report; a PDF the renderer
                    // could not produce is a notice, not a failure.
                    if (json["pdf_unavailable"] as? Bool) == true,
                       let htmlPath = json["html_path"] as? String {
                        let reason = (json["error"] as? String) ?? "PDF not generated"
                        completion(.success(WrapReportResult(
                            wrapID: (json["wrap_id"] as? String) ?? "",
                            htmlPath: htmlPath, pdfPath: nil, pdfGenerated: false,
                            cardsCount: 0, cards: [], totalBytes: 0, totalFiles: 0,
                            safeCards: 0, allSafe: false, pdfNotice: reason)))
                        return
                    }
                    let err = (json["error"] as? String) ?? (stderrStr.isEmpty ? "Wrap report generation failed" : stderrStr)
                    completion(.failure(.processFailed(err)))
                    return
                }

                guard let wrapID = json["wrap_id"] as? String,
                      let htmlPath = json["html_path"] as? String else {
                    completion(.failure(.invalidOutput("Missing wrap_id or html_path in response")))
                    return
                }

                let pdfPath = json["pdf_path"] as? String
                let pdfGenerated = (json["pdf_generated"] as? Bool) ?? false
                let cardsCount = (json["cards_count"] as? Int) ?? (json["total_cards"] as? Int) ?? 0
                let cards = (json["cards"] as? [String]) ?? []
                let totalBytes = (json["total_bytes"] as? NSNumber)?.int64Value ?? 0
                let totalFiles = (json["total_files"] as? Int) ?? 0
                let safeCards = (json["safe_cards"] as? Int) ?? 0
                let allSafe = (json["all_safe"] as? Bool) ?? false

                let result = WrapReportResult(
                    wrapID: wrapID,
                    htmlPath: htmlPath,
                    pdfPath: pdfPath,
                    pdfGenerated: pdfGenerated,
                    cardsCount: cardsCount,
                    cards: cards,
                    totalBytes: totalBytes,
                    totalFiles: totalFiles,
                    safeCards: safeCards,
                    allSafe: allSafe
                )
                completion(.success(result))
            } catch {
                completion(.failure(.processFailed(error.localizedDescription)))
            }
        }
    }
}
