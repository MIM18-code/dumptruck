import AppKit
import QuickLook
import SwiftUI

/// Sheet displaying recorded checksum evidence and Finder/Quick Look actions
/// loaded directly from the engine-generated receipt JSON.
///
/// INVARIANTS:
/// - Checksums are loaded only from receipt evidence; never invented or
///   recomputed on the UI thread.
/// - The receipt is not cryptographically signed/sealed and never grants
///   source-card wipe or eject authority.
struct JobEvidenceView: View {
    @ObservedObject var job: Job
    @Environment(\.dismiss) private var dismiss

    @State private var loadResult: Result<JobReceiptEvidence, ReceiptParseError>?
    @State private var searchQuery = ""
    @State private var filterOutcome = "all"
    @State private var quickLookURL: URL?
    @State private var copiedChecksumPath: String?
    @State private var sortOrder: [KeyPathComparator<FileChecksumRecord>] = [
        KeyPathComparator(\FileChecksumRecord.path)
    ]
    /// Cached filter+sort result — see evidenceContent.
    @State private var shownFiles: [FileChecksumRecord] = []

    init(job: Job) {
        self.job = job
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            safetyDisclaimer
            artifactsSection

            switch loadResult {
            case .none:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading receipt evidence…").font(Typo.safety)
                }
                .padding(.vertical, 12)
                Spacer()

            case let .failure(error):
                failureView(error)
                Spacer()

            case let .success(evidence):
                evidenceContent(evidence)
            }

            footer
        }
        .padding(20)
        // Bounded to the screen: an unbounded sheet grew past a 700pt main
        // window with ten artifact rows and macOS clipped BOTH the header
        // and the Close button (2026-09-04 UI audit). The artifact list
        // scrolls once it is tall; the table absorbs the rest.
        .frame(minWidth: 780, idealWidth: 860,
               minHeight: 520, idealHeight: 640, maxHeight: Self.sheetHeightCap)
        .quickLookPreview($quickLookURL)
        .onAppear {
            loadEvidence()
        }
        .onChange(of: searchQuery) { _, _ in recomputeShown() }
        .onChange(of: filterOutcome) { _, _ in recomputeShown() }
        .onChange(of: sortOrder) { _, _ in recomputeShown() }
    }

    /// Tallest the sheet may be and still clear the title bar and a
    /// margin on the screen that hosts it.
    private static var sheetHeightCap: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(520, screen - 140)
    }

    // MARK: - Header & Safety

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Evidence & Recorded Checksums")
                        .font(.title2.weight(.semibold))
                    Text(job.label)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Semantics.sourceText)
                }
                Text("Inspection of an engine-generated receipt and ASC MHL artifact paths.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VerdictBadge(verdict: job.verdict, phaseText: job.phase.rawValue)
        }
    }

    private var safetyDisclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Semantics.destinationText)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recorded evidence — receipt is not cryptographically sealed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Semantics.destinationText)
                Text("Recorded checksums are useful copy evidence, but this unsigned receipt is not a source-wipe or eject authority. Only the current Job verdict and engine protocol can establish that safety.")
                    .font(Typo.safety)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Semantics.destination.opacity(Semantics.wash), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Semantics.destination.opacity(0.25)))
    }

    // MARK: - Artifacts & Finder Actions

    private var artifactsSection: some View {
        GroupBox("Emitted artifacts & locations") {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Emitted Reports
                let reports = JobEvidenceParser.validatedReportPaths(for: job) ?? []
                if !reports.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reports")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(reports, id: \.self) { path in
                            artifactRow(
                                title: (path as NSString).lastPathComponent,
                                path: path,
                                icon: path.hasSuffix(".pdf") ? "doc.richtext.fill" : "doc.text.fill",
                                canQuickLook: true
                            )
                        }
                    }
                }

                // ASC MHL manifests. Only paths validated against this job's
                // frozen destination/card roots are exposed to Finder.
                let manifests = JobEvidenceParser.validatedManifestPaths(for: job) ?? []
                if !manifests.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ASC MHL Manifests")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(manifests, id: \.self) { path in
                            artifactRow(
                                title: (path as NSString).lastPathComponent,
                                path: path,
                                icon: "checkmark.seal.fill",
                                canQuickLook: true
                            )
                        }
                    }
                }

                // Destination Folders
                let dests = job.destinations.isEmpty ? job.laneRoots : job.destinations
                if !dests.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destination Folders")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(dests, id: \.self) { path in
                            artifactRow(
                                title: (path as NSString).lastPathComponent,
                                path: path,
                                icon: "folder.fill",
                                canQuickLook: false
                            )
                        }
                    }
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 210)
          .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func artifactRow(title: String, path: String, icon: String, canQuickLook: Bool) -> some View {
        let exists = FinderEvidenceActions.isSafeExistingPath(path)
        // The same report and manifest names recur once per destination;
        // the volume is the only thing that tells the rows apart, so it
        // leads the row instead of hiding inside a head-truncated path.
        let location = path.hasPrefix("/Volumes/") ? endpointName(path) : "This Mac"
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(exists ? Semantics.destinationText : .secondary)
            Text(location)
                .font(Typo.evidence)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 88, alignment: .leading)
            Text(title)
                .font(Typo.evidence.monospaced())
                .lineLimit(1).truncationMode(.middle)
            Text(path)
                .font(Typo.evidenceQuiet.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)

            if exists {
                Button("Open") {
                    FinderEvidenceActions.openFileOrFolder(path)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .font(.caption)

                if canQuickLook {
                    Button("Quick Look") {
                        quickLookURL = URL(fileURLWithPath: path)
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .font(.caption)
                }

                Button("Reveal") {
                    FinderEvidenceActions.revealInFinder(path)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .font(.caption)
            } else {
                Text("unavailable")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }

            Button {
                FinderEvidenceActions.copyToPasteboard(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .help("Copy path to clipboard")
        }
    }

    // MARK: - Evidence Content & Checksum Table

    @ViewBuilder
    private func evidenceContent(_ evidence: JobReceiptEvidence) -> some View {
        // `shownFiles` is CACHED state, recomputed only when an actual input
        // changes (query, outcome filter, sort, load). Receipts carry up to
        // 50k rows, and computing in body made every body evaluation — the
        // copy-button feedback and its 1.5s revert included — pay a full
        // filter + sort (Opus final bugcheck).
        let shown = shownFiles
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Filter files or checksums…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.evidence)
                    .frame(maxWidth: 280)

                Picker("Outcome", selection: $filterOutcome) {
                    Text("All (\(evidence.files.count))").tag("all")
                    Text("Verified").tag("verified")
                    Text("Skipped").tag("skipped")
                    Text("Failed").tag("failed")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()

                if evidence.isTruncated {
                    Text("Showing first \(evidence.files.count) of \(evidence.totalFilesInReceipt) files")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.warningText)
                } else {
                    Text("\(shown.count) files")
                        .font(Typo.evidenceQuiet.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            checksumTable(shown)
        }
    }

    /// The comparator chain the table displays: the clicked column first,
    /// path as a fixed tiebreaker so equal sizes/statuses stay deterministic.
    private var displayComparators: [KeyPathComparator<FileChecksumRecord>] {
        sortOrder + [KeyPathComparator(\FileChecksumRecord.path)]
    }

    private func recomputeShown() {
        guard case let .success(evidence) = loadResult else { shownFiles = []; return }
        shownFiles = filteredFiles(evidence.files).sorted(using: displayComparators)
    }

    private func filteredFiles(_ files: [FileChecksumRecord]) -> [FileChecksumRecord] {
        files.filter { item in
            if filterOutcome != "all" && item.outcome != filterOutcome {
                // "Failed" matches the DISPLAY group, driven by the same rank
                // the Status badge and sort use — so an "unknown" outcome that
                // renders as FAILED is reachable from the FAILED filter, not
                // only from All (Opus final bugcheck).
                if filterOutcome == "failed" && item.outcomeDisplayRank != 3 {
                    return false
                } else if filterOutcome != "failed" {
                    return false
                }
            }
            if searchQuery.isEmpty { return true }
            let query = searchQuery.lowercased()
            if item.path.lowercased().contains(query) { return true }
            if item.hashes.values.contains(where: { $0.lowercased().contains(query) }) { return true }
            return false
        }
    }

    /// `files` arrives already filtered and sorted (see evidenceContent).
    private func checksumTable(_ files: [FileChecksumRecord]) -> some View {
        Table(files, sortOrder: $sortOrder) {
            TableColumn("File", value: \.path) { file in
                Text(file.path)
                    .font(Typo.evidence.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy Path") {
                            FinderEvidenceActions.copyToPasteboard(file.path)
                        }
                    }
            }

            TableColumn("Size", value: \.size) { file in
                Text(file.formattedSize)
                    .font(Typo.evidenceQuiet.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("Algorithm") { file in
                Text(file.primaryChecksum?.algorithm.uppercased() ?? "—")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 75, max: 110)

            TableColumn("Recorded Checksum") { file in
                checksumCell(file)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Status", value: \.outcomeDisplayRank) { file in
                statusBadge(file.outcome)
            }
            .width(min: 60, ideal: 70, max: 100)
        }
        .alternatingRowBackgrounds(.enabled)
        // The artifacts section above grows with manifests/destinations;
        // the floor keeps the evidence rows from being squeezed to just a
        // header row at the sheet's minimum height.
        .frame(minHeight: 200, maxHeight: .infinity)
        .layoutPriority(1)
        .overlay {
            if files.isEmpty {
                Text("No files match the filter.")
                    .font(Typo.evidenceQuiet)
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .background(.background, in: .rect(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func checksumCell(_ file: FileChecksumRecord) -> some View {
        if let checksum = file.primaryChecksum {
            HStack(spacing: 4) {
                Text(checksum.hex)
                    .font(Typo.evidenceQuiet.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    FinderEvidenceActions.copyToPasteboard(checksum.hex)
                    copiedChecksumPath = file.path
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedChecksumPath == file.path { copiedChecksumPath = nil }
                    }
                } label: {
                    Image(systemName: copiedChecksumPath == file.path ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedChecksumPath == file.path ? Semantics.successText : .secondary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .help("Copy checksum")
                .accessibilityLabel(copiedChecksumPath == file.path
                                    ? "Checksum copied" : "Copy checksum")
            }
        } else {
            Text("no checksum recorded")
                .font(Typo.evidenceQuiet)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func statusBadge(_ outcome: String) -> some View {
        switch outcome {
        case "verified":
            Text("verified")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Semantics.successText)
        case "skipped":
            Text("skipped")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Semantics.warningText)
        case "size-only":
            Text("size-only")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Semantics.warningText)
        default:
            Text("FAILED")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Semantics.dangerText)
        }
    }

    // MARK: - Failure State

    private func failureView(_ error: ReceiptParseError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Receipt evidence unavailable or malformed", systemImage: "exclamationmark.octagon.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Semantics.dangerText)
            Text(error.localizedDescription)
                .font(Typo.safetyBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("No checksums are displayed because the engine receipt cannot be verified safely.")
                .font(Typo.safety)
                .foregroundStyle(Semantics.warningText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Semantics.danger.opacity(Semantics.wash), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Semantics.danger.opacity(0.35)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case let .success(evidence) = loadResult {
                Button("Copy All Checksums") {
                    copyAllChecksums(evidence)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy formatted list of all file checksums to clipboard")

                Button("Copy Receipt Path") {
                    FinderEvidenceActions.copyToPasteboard(evidence.receiptFilePath)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.regular)
        }
        .padding(.top, 4)
    }

    private func copyAllChecksums(_ evidence: JobReceiptEvidence) {
        // Copy in the order the table displays (still ALL files, unfiltered).
        let lines = evidence.files.sorted(using: displayComparators).compactMap { file -> String? in
            guard let checksum = file.primaryChecksum else { return nil }
            return "\(checksum.hex)  \(file.path)"
        }
        let text = lines.joined(separator: "\n")
        FinderEvidenceActions.copyToPasteboard(text)
    }

    private func loadEvidence() {
        loadResult = JobEvidenceParser.loadEvidence(for: job)
        recomputeShown()
    }
}
