import QuickLook
import SwiftUI

/// Persistent Searchable & Filterable Job History with Operator-Initiated CSV Export.
///
/// INVARIANTS:
/// 1. Backed exclusively by JobJournal (via AppModel.jobs) — the single persistent history source.
/// 2. Search operates strictly on safe display metadata without exposing or indexing file lists.
/// 3. Filterable by terminal result and date range with stable deterministic ordering.
/// 4. Historical display/actions never grant eject or wipe authority; restored entries remain historical.
/// 5. CSV export produces RFC 4180 output with formula-injection neutralization and privacy exclusions.
struct JobHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery = ""
    @State private var statusFilter: JobHistoryStatusFilter = .all
    @State private var dateFilter: JobHistoryDateFilter = .allTime
    @State private var customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var sortOrder: JobHistorySortOrder = .newestFirst

    @State private var selectedEvidenceJob: Job?
    @State private var quickLookURL: URL?
    @State private var exportNotification: String?
    @State private var exportError: String?

    @State private var selectedJobIDs: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var isGeneratingWrapReport: Bool = false

    private var customRange: ClosedRange<Date>? {
        if dateFilter == .custom {
            let start = min(customStartDate, customEndDate)
            let end = max(customStartDate, customEndDate)
            return start...end
        }
        return nil
    }

    private var filteredJobs: [Job] {
        JobHistoryFilterEngine.filterAndSort(
            jobs: model.jobs,
            query: searchQuery,
            statusFilter: statusFilter,
            dateFilter: dateFilter,
            customDateRange: customRange,
            sortOrder: sortOrder
        )
    }

    private var totalBytesFiltered: Int64 {
        filteredJobs.reduce(0) { $0 + $1.bytesTotal }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let journalError = model.journalError {
                Label(journalError, systemImage: "exclamationmark.octagon.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.dangerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Semantics.danger.opacity(Semantics.wash))
                Divider()
            }

            if let notice = exportNotification {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.successText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Semantics.success.opacity(Semantics.wash))
                Divider()
            }

            if let err = exportError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.dangerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Semantics.danger.opacity(Semantics.wash))
                Divider()
            }

            filterToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            summaryStrip

            Divider()

            if filteredJobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredJobs) { job in
                            HistoryJobRow(
                                job: job,
                                isSelectionMode: isSelectionMode,
                                isSelected: selectedJobIDs.contains(job.id),
                                onToggleSelect: {
                                    if selectedJobIDs.contains(job.id) {
                                        selectedJobIDs.remove(job.id)
                                    } else {
                                        selectedJobIDs.insert(job.id)
                                    }
                                },
                                onInspectEvidence: { selectedEvidenceJob = job },
                                onQuickLook: { quickLookURL = $0 },
                                onWrapReportSingle: { triggerWrapReport(singleJob: job) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 520, idealHeight: 640)
        .sheet(item: $selectedEvidenceJob) { job in
            JobEvidenceView(job: job)
        }
        .quickLookPreview($quickLookURL)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label("Job History & Wrap Logs", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()

            Button {
                triggerWrapReport()
            } label: {
                Label(selectedJobIDs.isEmpty ? "Wrap Report…" : "Wrap Report (\(selectedJobIDs.count))…",
                      systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(filteredJobs.isEmpty || isGeneratingWrapReport)
            .help(selectedJobIDs.isEmpty
                  ? "Generate shoot-day wrap report (HTML + PDF) for all \(filteredJobs.count) filtered card(s)"
                  : "Generate shoot-day wrap report (HTML + PDF) for \(selectedJobIDs.count) selected card(s)")
            .accessibilityLabel("Generate shoot day wrap report")

            Button {
                triggerCSVExport()
            } label: {
                Label("Export CSV…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(filteredJobs.isEmpty)
            .help("Export the current filtered job history to an RFC 4180 CSV spreadsheet")
            .accessibilityLabel("Export job history to CSV")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var filterToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search transfers…", text: boundedSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(HoverHighlightButtonStyle())
                        .accessibilityLabel("Clear search text")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

                Picker("Status", selection: $statusFilter) {
                    ForEach(JobHistoryStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 170)

                Picker("Date", selection: $dateFilter) {
                    ForEach(JobHistoryDateFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .frame(width: 150)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(JobHistorySortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(width: 180)
            }

            if dateFilter == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $customStartDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                    DatePicker("To", selection: $customEndDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 8) {
            Text("Showing \(filteredJobs.count) of \(model.jobs.count) transfers")
                .font(Typo.evidence.weight(.medium))
                .foregroundStyle(.secondary)

            if !filteredJobs.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(bytesString(totalBytesFiltered)) total data")
                    .font(Typo.evidenceQuiet.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !filteredJobs.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Button(isSelectionMode ? "Done Selecting" : "Select Cards") {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedJobIDs.removeAll()
                    }
                }
                .buttonStyle(.link).hoverHighlight()
                .font(.caption)

                if isSelectionMode {
                    Button("Select All (\(filteredJobs.count))") {
                        selectedJobIDs = Set(filteredJobs.map(\.id))
                    }
                    .buttonStyle(.link).hoverHighlight()
                    .font(.caption)

                    if !selectedJobIDs.isEmpty {
                        Button("Clear Selection") {
                            selectedJobIDs.removeAll()
                        }
                        .buttonStyle(.link).hoverHighlight()
                        .font(.caption)
                    }
                }
            }

            Spacer()

            if isFilterActive {
                Button("Reset Filters") {
                    searchQuery = ""
                    statusFilter = .all
                    dateFilter = .allTime
                    sortOrder = .newestFirst
                }
                .buttonStyle(.link).hoverHighlight()
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var isFilterActive: Bool {
        !searchQuery.isEmpty || statusFilter != .all || dateFilter != .allTime || sortOrder != .newestFirst
    }

    /// Keep untrusted paste/automation input bounded before it reaches the
    /// filter engine or participates in view invalidation.
    private var boundedSearchQuery: Binding<String> {
        Binding(
            get: { searchQuery },
            set: { searchQuery = String($0.prefix(HistoryExport.maxSearchQueryLength)) }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Matching Transfers", systemImage: "tray")
                .font(.title3.weight(.medium))
        } description: {
            Text(isFilterActive
                 ? "No transfers match your current search query or filter settings."
                 : "No historical transfers have been recorded in the job journal yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } actions: {
            if isFilterActive {
                Button("Clear All Filters") {
                    searchQuery = ""
                    statusFilter = .all
                    dateFilter = .allTime
                    sortOrder = .newestFirst
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerCSVExport() {
        exportError = nil
        exportNotification = nil

        let recordsToExport = filteredJobs.map { job in
            JobJournalRecord(job: job, plan: job.launchPlanSnapshot)
        }
        guard !recordsToExport.isEmpty else {
            exportError = "No jobs available to export."
            return
        }

        let filename = HistoryExport.defaultFilename(count: recordsToExport.count)
        HistoryExport.exportWithSavePanel(
            records: recordsToExport,
            suggestedFilename: filename,
            parentWindow: NSApp.keyWindow
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    exportNotification = "Exported \(recordsToExport.count) jobs to \(url.lastPathComponent)"
                case .failure(let error):
                    if let csvErr = error as? CSVExportError, csvErr == .exportCancelled {
                        // User clicked cancel in save panel — silent
                        return
                    }
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func triggerWrapReport(singleJob: Job? = nil) {
        exportError = nil
        exportNotification = nil

        let targetJobs: [Job]
        if let singleJob {
            targetJobs = [singleJob]
        } else if !selectedJobIDs.isEmpty {
            targetJobs = filteredJobs.filter { selectedJobIDs.contains($0.id) }
        } else {
            targetJobs = filteredJobs
        }

        guard !targetJobs.isEmpty else {
            exportError = "No cards selected for wrap report."
            return
        }

        var missingLabels: [String] = []
        var receiptPaths: [String] = []
        for job in targetJobs {
            if let url = JobEvidenceParser.findReceiptURL(for: job) {
                receiptPaths.append(url.path)
            } else {
                missingLabels.append(job.label)
            }
        }

        guard missingLabels.isEmpty else {
            let labelList = missingLabels.prefix(3).joined(separator: ", ")
            let extra = missingLabels.count > 3 ? " (and \(missingLabels.count - 3) more)" : ""
            exportError = "Cannot generate wrap report: \(missingLabels.count) card(s) have no valid receipt JSON on record: \(labelList)\(extra)."
            return
        }

        let uniqueReceipts = Array(Set(receiptPaths))
        guard uniqueReceipts.count == receiptPaths.count else {
            exportError = "Duplicate receipts detected among selected cards."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Select Output Folder for Shoot Day Wrap Report"
        panel.prompt = "Save Report Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        let count = targetJobs.count
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let selectedURL = panel.url else { return }
            isGeneratingWrapReport = true
            exportError = nil
            exportNotification = "Generating shoot-day wrap report for \(count) card(s)…"

            let title = count == 1
                ? "Shoot Day Wrap Report — \(targetJobs[0].label)"
                : "Shoot Day Wrap Report — \(count) Cards"

            WrapReportRunner.generate(
                receiptPaths: receiptPaths,
                outputDirectory: selectedURL,
                title: title,
                enginePython: model.enginePython,
                engineRoot: model.engineRoot
            ) { result in
                DispatchQueue.main.async {
                    self.isGeneratingWrapReport = false
                    switch result {
                    case .success(let wrapRes):
                        if wrapRes.pdfGenerated, let pdf = wrapRes.pdfPath {
                            self.exportNotification = "Generated Wrap Report PDF & HTML (\(URL(fileURLWithPath: pdf).lastPathComponent))"
                            self.quickLookURL = URL(fileURLWithPath: pdf)
                        } else {
                            let name = URL(fileURLWithPath: wrapRes.htmlPath).lastPathComponent
                            self.exportNotification = "Generated Wrap Report HTML (\(name))"
                                + (wrapRes.pdfNotice.map { ". No PDF: \($0)" } ?? "")
                            self.quickLookURL = URL(fileURLWithPath: wrapRes.htmlPath)
                        }
                    case .failure(let error):
                        self.exportError = error.localizedDescription
                        self.exportNotification = nil
                    }
                }
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            let response = panel.runModal()
            handleResponse(response)
        }
    }
}

/// One row in the history list representing a persistent historical transfer.
/// Authority invariant: Eject/Wipe authority is NEVER granted here.
private struct HistoryJobRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: Job
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onInspectEvidence: () -> Void
    let onQuickLook: (URL) -> Void
    let onWrapReportSingle: () -> Void

    private var formattedDate: String {
        let date = job.finishedDate ?? job.startedDate ?? job.createdDate
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private var cardStroke: AnyShapeStyle {
        switch job.verdict {
        case .running:
            return AnyShapeStyle(Semantics.running.opacity(0.35))
        case .failed, .unverified:
            return AnyShapeStyle(Semantics.danger.opacity(0.6))
        case .safeToWipe, .verifiedKeepCard:
            return AnyShapeStyle(Color(nsColor: .separatorColor))
        }
    }

    private var cardRail: AnyShapeStyle {
        switch job.verdict {
        case .running:
            return AnyShapeStyle(Semantics.running)
        case .failed, .unverified:
            return AnyShapeStyle(Semantics.danger)
        case .safeToWipe, .verifiedKeepCard:
            return AnyShapeStyle(.quaternary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isSelectionMode {
                    Button {
                        onToggleSelect()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .accessibilityLabel(isSelected ? "Deselect \(job.label)" : "Select \(job.label)")
                }

                Text(job.label)
                    .font(.headline.monospaced())
                    .lineLimit(1)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(formattedDate)
                    .font(Typo.evidenceQuiet)
                    .foregroundStyle(.secondary)

                if job.errorCount > 0 {
                    Label("\(job.errorCount)", systemImage: "xmark.octagon.fill")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Semantics.dangerText)
                }

                Spacer()

                VerdictBadge(verdict: job.verdict, phaseText: job.phase.rawValue)
                    .layoutPriority(1)
            }

            // Summary data strip
            HStack(spacing: 12) {
                let destCount = job.destinations.isEmpty ? job.laneRoots.count : job.destinations.count
                Label("^[\(destCount) destination](inflect: true)", systemImage: "externaldrive.fill")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("\(job.filesCopied) copied · \(job.filesSkipped) skipped"
                     + (job.filesFailed > 0 ? " · \(job.filesFailed) FAILED" : ""))
                    .font(job.filesFailed > 0 ? Typo.safety.monospacedDigit() : Typo.safetyBody.monospacedDigit())
                    .foregroundStyle(job.filesFailed > 0 ? Semantics.dangerText : .secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("\(bytesString(job.bytesFinished)) of \(bytesString(job.bytesTotal))")
                    .font(Typo.evidenceQuiet.monospacedDigit())
                    .foregroundStyle(.secondary)

                if job.physicalDevices > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(job.physicalDevices) physical devices")
                        .font(Typo.evidenceQuiet)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if !job.wipeBlockers.isEmpty {
                Label("\(HistoryExport.boundedBlockerCount(job.wipeBlockers)) wipe blockers recorded",
                      systemImage: "info.circle")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }

            // Action row — strictly inspect / report / retry. NEVER eject authority.
            HStack(spacing: 10) {
                Button {
                    onInspectEvidence()
                } label: {
                    Label("Inspect Evidence", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .help("Inspect recorded checksums, ASC MHL manifests, and emitted reports")

                let safeReports = JobEvidenceParser.validatedReportPaths(for: job) ?? []
                if let report = safeReports.first(where: { $0 == job.reportPath }) ?? safeReports.first {
                    Menu {
                        Button("Open Report") {
                            FinderEvidenceActions.openFileOrFolder(report)
                        }
                        Button("Quick Look Report") {
                            onQuickLook(URL(fileURLWithPath: report))
                        }
                        Button("Reveal in Finder") {
                            FinderEvidenceActions.revealInFinder(report)
                        }
                        Button("Copy Report Path") {
                            FinderEvidenceActions.copyToPasteboard(report)
                        }
                        Divider()
                        Button("Wrap Report for This Card…") {
                            onWrapReportSingle()
                        }
                    } label: {
                        Label("Report", systemImage: "doc.text")
                    } primaryAction: {
                        FinderEvidenceActions.openFileOrFolder(report)
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                }

                if job.launchPlanSnapshot != nil, !job.isRunning {
                    Button {
                        _ = model.stageRetry(job)
                    } label: {
                        Label("Stage Retry", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Stage this historical transfer back onto the workbench (Start remains manual)")
                }

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cardStroke, lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(cardRail)
                .frame(width: 4)
        }
    }
}
