import AppKit
import Foundation

enum HistoryExportCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Assertion failed: \(message)")
    }
}

static func requireThrows(_ body: () throws -> Void, _ message: String) {
    do {
        try body()
        fatalError("Expected error but none thrown: \(message)")
    } catch {
        // Expected
    }
}

    @MainActor
    static func run() throws {
        print("Running HistoryExportCheck...")

        Self.testRFC4180HeadersAndColumns()
        Self.testSpreadsheetFormulaInjectionNeutralization()
        Self.testStrictPrivacyInvariants()
        Self.testBoundedTextLimits()
        Self.testDeterministicSortingAndUUIDTieBreak()
        Self.testSafeMetadataSearchAndFilters()
        try Self.testAtomicFreshFileWriteAndOverwriteConfirmation()
        Self.testRestoredRowsSafetyAuthorityInvariant()

        print("HistoryExportCheck: all assertions passed!")
    }

    // MARK: - 1. RFC 4180 Compliance & Fixed Columns

    static func testRFC4180HeadersAndColumns() {
        print("  Testing RFC 4180 headers, column escaping, and CRLF format...")

        let expectedHeaders = [
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
        require(HistoryExport.headers == expectedHeaders, "Headers mismatch")

        let jobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let runID = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        let created = Date(timeIntervalSince1970: 1700000000)
        let started = Date(timeIntervalSince1970: 1700000010)
        let finished = Date(timeIntervalSince1970: 1700000100)

        let job = Job(
            label: "A_CARD,with,commas and \"quotes\"\nand newlines",
            sourcePath: "/Volumes/CONFIDENTIAL_SOURCE",
            destinations: ["/Volumes/DEST_1", "/Volumes/DEST_2"],
            sourceAssignmentID: UUID(),
            id: jobID,
            runID: runID,
            createdDate: created
        )
        job.startedDate = started
        job.finishedDate = finished
        job.phase = .done
        job.fullyVerified = true
        job.safeToWipe = true
        job.physicalDevices = 2
        job.filesTotal = 10
        job.filesCopied = 10
        job.filesSkipped = 0
        job.filesFailed = 0
        job.bytesTotal = 104857600
        job.bytesFinished = 104857600
        job.wipeBlockers = ["Blocker 1", "Blocker 2, with comma"]

        let record = JobJournalRecord(job: job, plan: nil)
        let csv = HistoryExport.generateCSV(records: [record])

        // Verify CRLF line ending delimiter per RFC 4180
        require(csv.contains("\r\n"), "CSV must use CRLF delimiter")
        require(csv.hasSuffix("\r\n"), "CSV must terminate with CRLF")

        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        require(lines.count >= 2, "Expected at least header and row")

        // Escaped quotes inside fields should become double quotes ""
        require(csv.contains("\"\"quotes\"\""), "Quotes must be escaped per RFC 4180")
    }

    // MARK: - 2. Spreadsheet Formula Injection Neutralization

    static func testSpreadsheetFormulaInjectionNeutralization() {
        print("  Testing spreadsheet formula injection neutralization (=, +, -, @, \\t, \\r, |, %)...")

        let dangerousPrefixes = ["=", "+", "-", "@", "\t", "\r", "|", "%"]
        for prefix in dangerousPrefixes {
            let formula = "\(prefix)SUM(A1:A10)"
            let sanitized = HistoryExport.sanitizeForSpreadsheet(formula)
            require(sanitized.hasPrefix("'"), "Prefix \(prefix) was not prepended with single quote")
            require(sanitized == "'\(formula)", "Sanitized text mismatch for \(formula)")
        }

        // Test with leading spaces then dangerous prefix
        let spacedFormula = "  =HYPERLINK(\"http://evil.com\")"
        let sanitizedSpaced = HistoryExport.sanitizeForSpreadsheet(spacedFormula)
        require(sanitizedSpaced.hasPrefix("'"), "Leading spaced formula must be prepended with single quote")

        // Ordinary text must NOT be prefixed
        let safeText = "CARD_A_001"
        require(HistoryExport.sanitizeForSpreadsheet(safeText) == safeText, "Safe text was modified unexpectedly")

        let formulaJob = Job(label: "=HYPERLINK(\"https://evil.example\")",
                             sourcePath: "/Volumes/S", destinations: ["/Volumes/D"])
        let formulaCSV = HistoryExport.generateCSV(jobs: [formulaJob])
        require(formulaCSV.contains("'=HYPERLINK"), "CSV formula cell was not neutralized")
    }

    // MARK: - 3. Strict Privacy Invariants

    static func testStrictPrivacyInvariants() {
        print("  Testing strict privacy invariants (NO absolute paths, NO per-file names, NO secrets)...")

        let secretSourcePath = "/Volumes/PRIVATE_CARD_ROOT/MAG_SECRET"
        let secretDest1 = "/Volumes/CONFIDENTIAL_BACKUP_1/PROJECT_SECRET"
        let secretDest2 = "/Volumes/CONFIDENTIAL_BACKUP_2/PROJECT_SECRET"
        let secretFilename = "SECRET_INTERVIEW_TAKE_01.MOV"
        let secretReportPath = "/Volumes/CONFIDENTIAL_BACKUP_1/PROJECT_SECRET/Reports/report.html"
        let secretMessage = "CRITICAL: Internal secret credential leaked"
        let secretBlocker = "source path " + secretSourcePath + "/PRIVATE_TOKEN"

        let job = Job(
            label: "NORMAL_LABEL_001",
            sourcePath: secretSourcePath,
            destinations: [secretDest1, secretDest2],
            sourceAssignmentID: UUID(),
            id: UUID(),
            runID: UUID(),
            createdDate: Date()
        )
        job.currentFile = secretFilename
        job.reportPath = secretReportPath
        job.reportPaths = [secretReportPath]
        job.manifestPaths = ["\(secretDest1)/ascmhl/manifest.mhl"]
        job.receiptPath = "\(secretDest1)/receipt.json"
        job.wipeBlockers = [secretBlocker]
        job.error(secretMessage)
        job.warn("Another internal warning text")

        let record = JobJournalRecord(job: job, plan: nil)
        let csv = HistoryExport.generateCSV(records: [record])

        // Verify that NONE of the confidential paths, filenames, reports, or messages appear in CSV
        require(!csv.contains(secretSourcePath), "CSV MUST NOT contain source absolute path")
        require(!csv.contains(secretDest1), "CSV MUST NOT contain destination absolute path 1")
        require(!csv.contains(secretDest2), "CSV MUST NOT contain destination absolute path 2")
        require(!csv.contains(secretFilename), "CSV MUST NOT contain currentFilename or per-file paths")
        require(!csv.contains(secretReportPath), "CSV MUST NOT contain report paths")
        require(!csv.contains("ascmhl"), "CSV MUST NOT contain manifest paths")
        require(!csv.contains("receipt.json"), "CSV MUST NOT contain receipt paths")
        require(!csv.contains(secretMessage), "CSV MUST NOT contain message texts")
        require(!csv.contains("Internal secret"), "CSV MUST NOT contain error message bodies")
        require(!csv.contains(secretBlocker), "CSV MUST NOT contain blocker text")
        require(!csv.contains("PRIVATE_TOKEN"), "CSV MUST NOT contain blocker path fragments")

        let recordSearch = JobHistoryFilterEngine.safeSearchText(for: record)
        require(!recordSearch.contains(secretSourcePath.lowercased()), "Search index MUST NOT contain blocker paths")
        require(!JobHistoryFilterEngine.matchesSearch(record: record, query: "PRIVATE_TOKEN"),
                "Search MUST NOT match blocker text")
        require(JobHistoryFilterEngine.matchesSearch(record: record, query: "1 wipe blockers"),
                "Search should expose the bounded blocker count only")

        // However, counts must be accurately exported
        let fields = HistoryExport.fields(for: record)
        // Indices shifted by one when "Recovered At" was inserted after
        // "Finished At" (codex verify F5 schema addition).
        require(fields[12] == "2", "Destination count must be exported as 2")
        require(fields[19] == "1", "Error count must be exported as 1")
        require(fields[20] == "1", "Warning count must be exported as 1")
        require(fields[21] == "1", "Wipe blocker count must be exported as 1")
    }

    // MARK: - 4. Bounded Text Limits

    static func testBoundedTextLimits() {
        print("  Testing bounded text limits for fields...")

        let hugeLabel = String(repeating: "L", count: 1000)
        let boundedLabel = HistoryExport.boundField(hugeLabel, maxLength: HistoryExport.maxLabelLength)
        require(boundedLabel.count == HistoryExport.maxLabelLength, "Label was not bounded to \(HistoryExport.maxLabelLength)")

        let hugeBlocker = String(repeating: "B", count: 2000)
        let boundedBlocker = HistoryExport.boundField(hugeBlocker, maxLength: HistoryExport.maxBlockersLength)
        require(boundedBlocker.count == HistoryExport.maxBlockersLength, "Blocker was not bounded to \(HistoryExport.maxBlockersLength)")

        let blockerList = Array(repeating: hugeBlocker, count: HistoryExport.maxBlockerCount + 17)
        require(HistoryExport.boundedBlockerCount(blockerList) == HistoryExport.maxBlockerCount,
                "Blocker count was not bounded")

        let unicodeControl = "café 🚚\u{0000}\u{001B}\nline"
        let escaped = HistoryExport.escapeCSVField(unicodeControl)
        require(escaped.contains("café 🚚"), "Unicode CSV content was lost")
        require(escaped.contains("\n"), "RFC 4180 quoted newline was lost")
        require(!escaped.contains("\u{0000}") && !escaped.contains("\u{001B}"),
                "Unsafe control characters were not removed")

        let rowJob = Job(label: "ROW_BOUND", sourcePath: "/Volumes/S", destinations: ["/Volumes/D"])
        let rowRecord = JobJournalRecord(job: rowJob, plan: nil)
        let overLimitCSV = HistoryExport.generateCSV(
            records: Array(repeating: rowRecord, count: HistoryExport.maxHistoryRows + 1)
        )
        let nonEmptyRows = overLimitCSV.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        require(nonEmptyRows.count == HistoryExport.maxHistoryRows + 1,
                "CSV row generation was not bounded")
    }

    // MARK: - 5. Deterministic Sorting & UUID Tie-Breaking

    static func testDeterministicSortingAndUUIDTieBreak() {
        print("  Testing deterministic sorting with UUID tie-breaking...")

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        let uuidA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let uuidB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let jobEarlyA = Job(label: "LABEL_A", sourcePath: "/Volumes/S", destinations: ["/Volumes/D"], id: uuidA, createdDate: date1)
        jobEarlyA.finishedDate = date1
        let jobEarlyB = Job(label: "LABEL_B", sourcePath: "/Volumes/S", destinations: ["/Volumes/D"], id: uuidB, createdDate: date1)
        jobEarlyB.finishedDate = date1

        let jobLateA = Job(label: "LABEL_C", sourcePath: "/Volumes/S", destinations: ["/Volumes/D"], id: uuidA, createdDate: date2)
        jobLateA.finishedDate = date2

        // Sort Newest First
        let sortedNewest = JobHistoryFilterEngine.sort(jobs: [jobEarlyA, jobLateA, jobEarlyB], by: .newestFirst)
        require(sortedNewest[0].id == uuidA && sortedNewest[0].finishedDate == date2, "Newest date must come first")
        // Between jobEarlyA and jobEarlyB (same date), uuidB > uuidA tie-breaker
        require(sortedNewest[1].id == uuidB, "UUID B must win tie-break over UUID A in newestFirst")
        require(sortedNewest[2].id == uuidA, "UUID A must come third")

        // Sort Oldest First
        let sortedOldest = JobHistoryFilterEngine.sort(jobs: [jobLateA, jobEarlyB, jobEarlyA], by: .oldestFirst)
        require(sortedOldest[0].id == uuidA && sortedOldest[0].finishedDate == date1, "Oldest date with lower UUID must come first")
        require(sortedOldest[1].id == uuidB && sortedOldest[1].finishedDate == date1, "Oldest date with higher UUID must come second")
        require(sortedOldest[2].id == uuidA && sortedOldest[2].finishedDate == date2, "Latest date must come last")
    }

    // MARK: - 6. Safe Metadata Search & Filters

    static func testSafeMetadataSearchAndFilters() {
        print("  Testing safe metadata search queries and status/date filters...")

        let now = Date()
        let jobSafe = Job(label: "A001_CARD", sourcePath: "/Volumes/S", destinations: ["/Volumes/D1", "/Volumes/D2"], createdDate: now)
        jobSafe.phase = .done
        jobSafe.fullyVerified = true
        jobSafe.safeToWipe = true
        jobSafe.finishedDate = now

        let jobFailed = Job(label: "B002_CARD", sourcePath: "/Volumes/S", destinations: ["/Volumes/D1"], createdDate: now.addingTimeInterval(-3600))
        jobFailed.phase = .failed
        jobFailed.fullyVerified = false
        jobFailed.safeToWipe = false
        jobFailed.finishedDate = now.addingTimeInterval(-3600)

        let jobs = [jobSafe, jobFailed]

        // 1. Search by label
        let searchLabel = JobHistoryFilterEngine.filterAndSort(jobs: jobs, query: "A001")
        require(searchLabel.count == 1 && searchLabel[0].label == "A001_CARD", "Search by label failed")

        // 2. Search by verdict
        let searchVerdict = JobHistoryFilterEngine.filterAndSort(jobs: jobs, query: "SAFE TO WIPE")
        require(searchVerdict.count == 1 && searchVerdict[0].label == "A001_CARD", "Search by verdict failed")

        // 3. Search by destination count
        let searchDest = JobHistoryFilterEngine.filterAndSort(jobs: jobs, query: "2 destinations")
        require(searchDest.count == 1 && searchDest[0].label == "A001_CARD", "Search by destination count failed")

        let boundedQuery = "A001" + String(repeating: " ", count: HistoryExport.maxSearchQueryLength + 64)
        let searchBounded = JobHistoryFilterEngine.filterAndSort(jobs: jobs, query: boundedQuery)
        require(searchBounded.count == 1 && searchBounded[0].label == "A001_CARD",
                "Search query input was not bounded safely")

        // 4. Filter by status: safeToWipe
        let filteredSafe = JobHistoryFilterEngine.filterAndSort(jobs: jobs, statusFilter: .safeToWipe)
        require(filteredSafe.count == 1 && filteredSafe[0].label == "A001_CARD", "Status filter safeToWipe failed")

        // 5. Filter by status: failedOrUnverified
        let filteredFailed = JobHistoryFilterEngine.filterAndSort(jobs: jobs, statusFilter: .failedOrUnverified)
        require(filteredFailed.count == 1 && filteredFailed[0].label == "B002_CARD", "Status filter failedOrUnverified failed")

        // 6. Filter by date: past 24 hours
        let filteredDate = JobHistoryFilterEngine.filterAndSort(jobs: jobs, dateFilter: .last24Hours, now: now)
        require(filteredDate.count == 2, "Date filter last24Hours failed")
    }

    // MARK: - 7. Atomic Fresh-File Write & Overwrite Confirmation

    static func testAtomicFreshFileWriteAndOverwriteConfirmation() throws {
        print("  Testing atomic fresh-file write and overwrite safety interlocks...")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-history-export-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("export.csv")
        let job = Job(label: "EXPORT_TEST", sourcePath: "/Volumes/S", destinations: ["/Volumes/D"])
        let records = [JobJournalRecord(job: job, plan: nil)]

        requireThrows({
            try HistoryExport.export(records: [], to: targetURL, overwrite: false)
        }, "Empty history export must be rejected")

        // 1. Fresh file write should succeed
        try HistoryExport.export(records: records, to: targetURL, overwrite: false)
        require(FileManager.default.fileExists(atPath: targetURL.path), "Fresh file was not created")

        // 2. Overwrite without permission must throw fileAlreadyExists error
        requireThrows({
            try HistoryExport.export(records: records, to: targetURL, overwrite: false)
        }, "Writing over an existing file without overwrite flag must throw")

        // 3. Overwrite with overwrite=true must succeed
        try HistoryExport.export(records: records, to: targetURL, overwrite: true)
        require(FileManager.default.fileExists(atPath: targetURL.path), "Overwritten file must exist")

        let existingDirectory = tempDir.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        requireThrows({
            try HistoryExport.export(records: records, to: existingDirectory, overwrite: true)
        }, "Export must reject a directory destination")

        // The destination appears after the preflight check but before the
        // atomic commit. Fresh exports must preserve that file rather than
        // silently replacing it.
        let raceURL = tempDir.appendingPathComponent("appeared-after-preflight.csv")
        let preexistingContents = Data("operator-created-after-preflight".utf8)
        requireThrows({
            try HistoryExport.export(records: records, to: raceURL, overwrite: false,
                                     beforeCommit: {
                                         try preexistingContents.write(to: raceURL,
                                                                       options: .atomic)
                                     })
        }, "Fresh export must reject a destination that appears before commit")
        require(FileManager.default.contents(atPath: raceURL.path) == preexistingContents,
                "Exclusive fresh commit must preserve a racing destination")
        let leftovers = try FileManager.default.contentsOfDirectory(at: tempDir,
                                                                      includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".appeared-after-preflight.csv.") }
        require(leftovers.isEmpty, "Failed exclusive commit must clean its temp file")
    }

    // MARK: - 8. Restored Rows Safety Authority Invariant

    static func testRestoredRowsSafetyAuthorityInvariant() {
        print("  Testing restored rows authority invariant (never grant eject/wipe authority)...")

        let job = Job(label: "RESTORED_CARD", sourcePath: "/Volumes/CARD_A", destinations: ["/Volumes/DEST_1"])
        job.phase = .done
        job.fullyVerified = true
        job.safeToWipe = true
        job.markRestoredFromJournal()

        // Restored rows have restoredFromJournal == true and sourceAssignmentID == nil
        require(job.restoredFromJournal, "Job must be marked restoredFromJournal")
        require(!job.verdictIsFresh(for: UUID()), "Restored job must never match fresh source assignment ID")
    }
}
