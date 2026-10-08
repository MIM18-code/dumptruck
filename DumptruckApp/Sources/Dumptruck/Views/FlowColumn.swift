import QuickLook
import SwiftUI

/// Center column: the bench (staging) pinned on top, then job cards whose
/// lanes run left-to-right — source side to destination side. Direction of
/// travel is physical, on screen.
struct FlowColumn: View {
    @EnvironmentObject var model: AppModel
    @Binding var forceEjectTarget: Volume?
    @AppStorage(Pref.verifyMode) private var verifyMode = "full"
    @State private var confirmJournalQuarantine = false
    /// Live jobs the operator cleared from the column this window session.
    /// IDs recorded at press time, never a time watermark, for the reasons
    /// ReceiptVisibility gives. History keeps every record.
    @State private var clearedLiveJobIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if let journalError = model.journalError {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(journalError, systemImage: "exclamationmark.octagon.fill")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.dangerText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.canQuarantineJournal {
                        Button("Quarantine & start fresh…") {
                            confirmJournalQuarantine = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Preserve the unusable journal as a sibling file and create an empty ledger")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Semantics.danger.opacity(Semantics.wash))
            }
            if let notice = model.journalQuarantineNotice {
                Label(notice, systemImage: "archivebox.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Semantics.warning.opacity(Semantics.wash))
            }
            if verifyMode == "fast" {
                fastModeStrip
            }
            if !model.queuedJobs.isEmpty || model.isDispatchPaused {
                QueueControlBar()
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            // This session's work owns the stage; journal history opens as
            // quiet receipts at the bottom and connected hardware waits on
            // the ConnectedShelf (2026-08-26 facelift). First paint is never
            // dominated by a days-old alarm: the receipt keeps its verdict
            // chip visible and truthful, while the full-card treatment is
            // reserved for jobs from THIS session.
            let liveJobs = model.jobs.filter { !$0.restoredFromJournal }
            // A cleared job comes back if it stops being clearable (a later
            // custody failure, a changed copy): Clear hides finished good
            // news, never a new alarm.
            let shownLiveJobs = liveJobs.filter {
                !(clearedLiveJobIDs.contains($0.id) && LiveJobClearing.isClearable($0))
            }
            let clearable = shownLiveJobs.filter(LiveJobClearing.isClearable)
            if model.sourcePath == nil && shownLiveJobs.isEmpty {
                EmptyFlowState()
            } else {
                if model.sourcePath != nil {
                    BenchCard()
                        .padding(.horizontal, 14).padding(.top, 12)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !clearable.isEmpty {
                            clearFinishedRow(clearable, allLive: liveJobs)
                        }
                        ForEach(shownLiveJobs) { job in
                            JobCard(job: job)
                        }
                    }
                    .padding(14)
                }
            }
            ConnectedShelf(forceEjectTarget: $forceEjectTarget)
            ReceiptStrip()
        }
        .confirmationDialog("Preserve the unusable journal?",
                            isPresented: $confirmJournalQuarantine,
                            titleVisibility: .visible) {
            Button("Quarantine and create an empty ledger", role: .destructive) {
                model.quarantineInvalidJournal()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current journal is corrupt or from a newer version. Dumptruck will atomically move it to a unique sibling path and retain it as evidence. Historical records will not be loaded, and no old record can authorize wipe or eject.")
        }
    }

    /// A long shooting day stacked every finished card in the column with no
    /// way to put them away short of relaunching (Joshua, 2026-09-28). Only
    /// settled good news is cleared; failures and anything still running
    /// stay on the stage.
    private func clearFinishedRow(_ clearable: [Job], allLive: [Job]) -> some View {
        HStack {
            Spacer()
            Button("Clear Finished (\(clearable.count))") {
                // Pruned to jobs that still exist so the set stays bounded.
                let current = Set(allLive.map(\.id))
                clearedLiveJobIDs = clearedLiveJobIDs.intersection(current)
                    .union(clearable.map(\.id))
            }
            .buttonStyle(.link).hoverHighlight()
            .font(.caption)
            .help("Hide finished SAFE and verified cards from this column. Failed cards stay. Nothing is deleted; every record stays in History.")
            .accessibilityLabel("Clear finished cards from the column; records remain in History")
        }
    }

    /// Fast mode is a day-long trap if it's only visible in Settings (Kimi
    /// K3 review): an ambient strip while it is active.
    private var fastModeStrip: some View {
        Label("Fast mode: size checked only — not verified. No card can be "
              + Job.Verdict.safeToWipe.displayLine,
              systemImage: "hare.fill")
            .font(Typo.safety)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Semantics.warning.opacity(Semantics.chip))
            .foregroundStyle(Semantics.warningText)
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct EmptyFlowState: View {
    @EnvironmentObject var model: AppModel

    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 14) {
                if let logo = Self.logo {
                    Image(nsImage: logo)
                        .resizable().interpolation(.high)
                        .scaledToFit().frame(height: 80)
                        .accessibilityHidden(true)
                }
                Text("Ready to offload")
                    .font(.title2.weight(.semibold))
            }
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Insert a card — it appears on the shelf below")
                step(2, "Stage two drives as destinations")
                step(3, "Name the card, then Start Offload")
            }
            .font(.callout)
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.top, 4)
        } actions: {
            Button("Choose Folder as Source…") { model.chooseFolder(as: "source") }
                .buttonStyle(BrandProminentButtonStyle())
                .help("Copy FROM any folder — not just a whole card")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).monospacedDigit()
                .frame(width: 20, height: 20)
                .background(.quaternary, in: .circle)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Receipts

/// Old news opens quiet (2026-08-26 facelift): journal history renders as
/// one line per prior job — verdict chip intact and truthful, full-bleed
/// treatment reserved for failures happening NOW. A receipt expands into the
/// complete JobCard (evidence, report, Stage Retry — recovery is the
/// workflow, so it is one click away, per Kimi K3's review), and the strip
/// links to the full searchable history. Verdicts still render from
/// Job.verdict only; nothing here re-derives safety state.
/// The one visibility rule for the operator's Clear, shared by the receipt
/// strip and the arcade alarm row (codex verify F1: duplicated logic was a
/// shared failure mode). Clear records the IDs of the receipts on screen —
/// never a timestamp: a time watermark could permanently hide a FAILURE
/// CREATED AFTER the clear, because an interrupted job recovers under its
/// pre-clear startedDate, and a clock rollback does the same to live jobs.
/// An ID can only enter the set by being a visible receipt at press time,
/// so no future record can ever be pre-cleared. A deletion this is not:
/// every record stays in the journal and the History sheet.
enum ReceiptVisibility {
    static let clearedIDsKey = "receipts.clearedIDs"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func isCleared(_ job: Job, raw: String) -> Bool {
        job.restoredFromJournal && decode(raw).contains(job.id.uuidString)
    }
}

/// Which live (this-session) job cards the column's Clear Finished may
/// hide. Stricter than the receipt rule on purpose: a failure happening now
/// keeps its full card (the facelift rule, and the arcade alarm row shows
/// live failures unconditionally). Only a settled SAFE or VERIFIED · KEEP
/// CARD job with no later damage finding qualifies. A SAFE whose copy
/// changed after the verdict stays; one whose backup drive was merely
/// ejected may go (Joshua, 2026-09-28).
enum LiveJobClearing {
    static func isClearable(_ job: Job) -> Bool {
        guard !job.restoredFromJournal, !job.isRunning,
              job.verdict == .safeToWipe || job.verdict == .verifiedKeepCard,
              !job.hasCustodyFailure,
              job.laterVerification?.isClean ?? true else { return false }
        return job.destinationAuthorityWithdrawn == nil
            || job.destinationAuthorityWithdrawnByEjection
    }
}

struct ReceiptStrip: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("focusJobs") private var focusJobs = false
    @AppStorage(ReceiptVisibility.clearedIDsKey) private var clearedIDsRaw = ""
    @State private var expandedIDs: Set<Job.ID> = []

    private static let shownCount = 3

    private var receipts: [Job] {
        model.jobs.filter {
            $0.restoredFromJournal && !$0.isRunning
                && !ReceiptVisibility.isCleared($0, raw: clearedIDsRaw)
        }
        .sorted { receiptDate($0) > receiptDate($1) }
    }

    /// Same fallback chain the journal uses to bound history — except that
    /// an interrupted restore's finishedDate is the recovery stamp (relaunch
    /// time), not a real end, so those fall through to startedDate (facelift
    /// review: an old interrupted job must not sort above newer receipts).
    private func receiptDate(_ job: Job) -> Date {
        if job.restoredInterrupted {
            return job.startedDate ?? job.createdDate
        }
        return job.finishedDate ?? job.startedDate ?? job.createdDate
    }

    /// A standing DO-NOT-WIPE record is never invisible: every failed or
    /// unverified receipt renders — beyond the newest-3 cap, and even in
    /// Focus on Jobs, which collapses chrome, not alarms (facelift review).
    private func isAlarm(_ job: Job) -> Bool {
        job.verdict == .failed || job.verdict == .unverified
    }

    private var visibleReceipts: [Job] {
        let all = receipts
        let alarms = all.filter(isAlarm)
        if focusJobs { return alarms }
        // Alarms are EXEMPT from the cap, not charged against it: the
        // newest-3 budget belongs to the quiet successful receipts.
        var shown = alarms
        var quiet = 0
        for job in all where !isAlarm(job) && quiet < Self.shownCount {
            shown.append(job)
            quiet += 1
        }
        return shown.sorted { receiptDate($0) > receiptDate($1) }
    }

    var body: some View {
        let shown = visibleReceipts
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Earlier")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") {
                        // Record the receipts ON SCREEN NOW (all of them,
                        // not just the visible cap), pruned to jobs that
                        // still exist so the set stays bounded.
                        let current = Set(model.jobs.map { $0.id.uuidString })
                        var ids = ReceiptVisibility.decode(clearedIDsRaw)
                            .intersection(current)
                        ids.formUnion(receipts.map { $0.id.uuidString })
                        clearedIDsRaw = ReceiptVisibility.encode(ids)
                        expandedIDs.removeAll()
                    }
                    .buttonStyle(.link).hoverHighlight()
                    .font(.caption)
                    .help("Hide these receipts from the strip. Nothing is deleted — every record stays in History.")
                    .accessibilityLabel("Clear receipts from the strip; records remain in History")
                    // Counts what the History sheet actually lists — every
                    // job, not just the receipts (facelift review).
                    Button("History (\(model.jobs.count))") {
                        model.historyShown = true
                    }
                    .buttonStyle(.link).hoverHighlight()
                    .font(.caption)
                    .help("Search, filter, and export the full persistent transfer log")
                }
                if expandedIDs.isEmpty && shown.count <= 6 {
                    rows(shown)
                } else {
                    // History scrolls rather than shoving the live stage off
                    // screen: an expanded receipt is a full card, and two
                    // dozen collapsed rows consumed the whole column
                    // (desktop QA round 5, R5-02).
                    ScrollView {
                        rows(shown)
                    }
                    .frame(maxHeight: expandedIDs.isEmpty ? 200 : 320)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func rows(_ shown: [Job]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { job in
                ReceiptRow(job: job, expanded: expandedIDs.contains(job.id)) {
                    if expandedIDs.contains(job.id) {
                        expandedIDs.remove(job.id)
                    } else {
                        expandedIDs.insert(job.id)
                    }
                }
            }
        }
    }
}

struct ReceiptRow: View {
    @ObservedObject var job: Job
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(dateText)
                        .font(Typo.evidenceQuiet.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(job.label)
                        .font(Typo.safety)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(job.filesCopied + job.filesSkipped) files · \(bytesString(job.bytesTotal))")
                        .font(Typo.evidenceQuiet.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let later = job.laterVerification, !later.isClean {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Semantics.dangerText)
                            .help(later.line)
                    }
                    VerdictBadge(verdict: job.verdict, phaseText: job.phase.rawValue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .accessibilityLabel("\(job.label), \(job.verdict.displayLine)"
                + (job.laterVerification.map { ", \($0.line)" } ?? "")
                + ", \(expanded ? "expanded" : "collapsed")")
            .accessibilityHint(expanded ? "Collapses this prior job"
                                        : "Expands this prior job's full card")
            if expanded {
                JobCard(job: job)
            }
        }
    }

    private var dateText: String {
        // Interrupted restores: finishedDate is the recovery stamp, not a
        // real end — show when the job actually ran.
        let d = job.restoredInterrupted
            ? (job.startedDate ?? job.createdDate)
            : (job.finishedDate ?? job.startedDate ?? job.createdDate)
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .short
        df.doesRelativeDateFormatting = true
        return df.string(from: d)
    }
}

// MARK: - Bench

/// The staging bench: card header, continuation banner, card-name field
/// (the continuation key), planned lanes, blocked-reason footer. Collapses
/// to a strip once its job starts — the lanes need the vertical space.
struct BenchCard: View {
    @EnvironmentObject var model: AppModel
    /// The operator asked for the full bench instead of the one-click
    /// continuation — per card, reset when the source changes.
    @State private var proposalDismissed = false

    var body: some View {
        Group {
            // A blocked start must stay legible — never collapse it. The one
            // exception: "this source already has a running transfer" is the
            // NORMAL state right after Start (it is why the bench collapsed),
            // not a problem the operator needs to read.
            if model.benchCollapsed,
               model.startBlockedReason != nil,
               !model.startBlockedByRunningTransferOnly {
                expanded
            } else if model.benchCollapsed {
                collapsed
            } else {
                expanded
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .onChange(of: model.sourcePath) { _, _ in proposalDismissed = false }
    }

    private var collapsed: some View {
        Button {
            model.benchCollapsed = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sdcard.fill").foregroundStyle(Semantics.sourceText)
                // Volume and card name are usually identical (a card named
                // for its label); saying it twice read as a stutter.
                let sourceName = model.sourcePath.map(model.endpointDisplayName) ?? ""
                let identity = sourceName == model.label || model.label.isEmpty
                    ? sourceName : "\(sourceName) · \(model.label)"
                Text("\(identity) · ^[\(model.destinationPaths.count) destination](inflect: true)")
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }

    /// The app makes the first move (2026-08-26 facelift, the DESIGN doc's
    /// "one click or zero clicks" promise made visible): a KNOWN card whose
    /// previous drives are mounted gets one sentence and one button instead
    /// of the staging machinery. Continue runs the ordinary assignment and
    /// start gates; "Set Up Manually…" is the standing escape hatch into the
    /// full bench. Every fact on the banner is an engine fact — card
    /// registry, inspect result, mounted-volume snapshot — never inference.
    @ViewBuilder
    private var expanded: some View {
        if !proposalDismissed, let proposal = model.continuationProposal {
            proposalBanner(proposal)
        } else {
            benchForm
        }
    }

    private func proposalBanner(_ proposal: AppModel.ContinuationProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sdcard").font(.title2)
                    .foregroundStyle(Semantics.sourceText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.inspection?.formatName ?? "Card") \(model.label) — seen \(model.inspection?.mounts ?? 0)× before")
                        .font(.headline)
                    Text(proposalSummary(proposal))
                        .font(Typo.safetyBody)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if proposal.unreachablePriors > 0 {
                // Stated, never silently dropped: the proposal stages fewer
                // copies than this card has had before. "Location", not
                // "drive": an off-volume folder prior is skipped too, and it
                // was never "unmounted" (facelift review).
                Label("^[\(proposal.unreachablePriors) earlier location](inflect: true) for this card \(proposal.unreachablePriors == 1 ? "isn't" : "aren't") reachable right now and won't be staged",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }
            HStack(spacing: 10) {
                Button("Continue \(model.label)") {
                    model.continueKnownCard()
                }
                .buttonStyle(BrandProminentButtonStyle())
                .help("Stage this card's previous drives and start — the same checks as a manual Start run first")
                Button("Set Up Manually…") { proposalDismissed = true }
                    .buttonStyle(.bordered)
                    .help("Open the full bench — pick drives, folders, and the card name yourself")
                Spacer()
            }
        }
        .padding(14)
    }

    private func proposalSummary(_ proposal: AppModel.ContinuationProposal) -> String {
        var parts: [String] = []
        if let ins = model.inspection {
            parts.append("\(ins.files) files · \(bytesString(ins.bytes))")
        }
        let names = proposal.anchors.map(model.endpointDisplayName)
            .joined(separator: " + ")
        parts.append("→ \(names), into its existing card folder")
        return parts.joined(separator: " ")
    }

    private var benchForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sdcard").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    if model.inspecting {
                        Text("Reading card…").font(.headline)
                    } else if let ins = model.inspection {
                        Text("\(ins.formatName) — \(ins.files) files, \(bytesString(ins.bytes))")
                            .font(.headline)
                    } else if let src = model.sourcePath {
                        Text(model.endpointDisplayName(src)).font(.headline)
                    }
                    if let src = model.sourcePath {
                        Text(src)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if model.jobs.contains(where: { $0.isRunning }) {
                    Button {
                        model.benchCollapsed = true
                    } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(HoverHighlightButtonStyle())
                        .foregroundStyle(.secondary)
                        .help("Collapse the bench")
                        .accessibilityLabel("Collapse the bench")
                }
            }
            if let ins = model.inspection {
                if ins.known {
                    // No TopUpPourView here: it rendered a green "previously
                    // verified" stratum from a fraction the engine never
                    // attested (agy feature-round audit, CRITICAL 1). The
                    // banner text carries the continuation fact; verified
                    // quantities appear only in lanes, from engine events.
                    HStack(spacing: 8) {
                        Label("Seen \(ins.mounts)× before — continuing into its existing card folder",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Semantics.source.opacity(Semantics.chip), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Semantics.source.opacity(0.35)))
                    .foregroundStyle(Semantics.sourceText)
                } else {
                    Label("New card", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let retry = model.stagedRetryLabel {
                VStack(alignment: .leading, spacing: 6) {
                Label("Retry staged from \(retry). Press Start when ready.",
                      systemImage: "arrow.clockwise.circle")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Semantics.warning.opacity(Semantics.wash), in: .rect(cornerRadius: 8))
                Toggle("Use current verification and report settings", isOn: $model.retryUsesCurrentSettings)
                Text(model.retryUsesCurrentSettings ? "Current settings apply. Original destination folders are retained." : "Saved job settings override Settings for this retry.")
                    .font(.caption)
                Text(model.retrySettingsSummary).font(Typo.safety)
                }
            }
            HStack(spacing: 8) {
                // LabeledContent sacrifices its label first under pressure;
                // at the supported 940pt window it made the visible "Card
                // name" disappear. Keep the safety-bearing continuation key
                // explicitly laid out and let only the field flex.
                Text("Card name")
                    .font(.callout)
                    .fixedSize()
                // Writes go through operatorEditedLabel so a card read that
                // lands after typing keeps the typed name (Joshua, 2026-09-28).
                TextField("CARD_A", text: Binding(
                    get: { model.label },
                    set: { model.operatorEditedLabel($0) }))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(minWidth: 130, idealWidth: 220, maxWidth: 220)
                Text("← continuation key")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
            }
            PlannedLaneGroup()
            if let reason = model.startBlockedReason {
                startBlockedFooter(reason)
            }
        }
        .padding(14)
    }

    /// Ordinary next steps ("Add at least one destination" right after a
    /// card lands, "Reading card…") read as instructions, not alarms; only a
    /// real problem keeps the warning color (Joshua, 2026-09-28).
    @ViewBuilder
    private func startBlockedFooter(_ reason: String) -> some View {
        if AppModel.isNextStepReason(reason) {
            Label(reason, systemImage: "info.circle")
                .font(Typo.safety)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                if reason == AppModel.sourceChangedReason {
                    // Same assignment path as staging the card again: a new
                    // session, a fresh read, and the typed name kept.
                    Button("Re-read Card") { model.rereadStagedSource() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Read the card again so Start can run on what is on it now")
                }
            }
        }
    }

}

/// The staged plan as dashed, unfilled lanes — one per destination, each
/// terminating in the rendered card-folder path and its free space. Dashed =
/// nothing has moved yet; solid lanes belong to real jobs. Bench lanes track
/// the LIVE staged destinations; job lanes track the frozen LaunchPlan —
/// they look different on purpose.
struct PlannedLaneGroup: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.destinationPaths.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.destinationPaths, id: \.self) { path in
                    let rendered = model.effectiveDestinations([path], forSource: model.sourcePath).first ?? path
                    let cardFolder = model.label.isEmpty ? rendered
                        : (rendered as NSString).appendingPathComponent(model.label)
                    // model.volumes is the 30s-refreshed snapshot — no
                    // statfs in body (Ox review, F3: a wedged mount would
                    // block the MAIN thread mid-render).
                    let cap: (free: Int64, total: Int64)? = model.volumes
                        .first(where: { pathIsAtOrInside(path, root: $0.path) })
                        .flatMap { v in
                            guard let f = v.freeBytes, let t = v.totalBytes else { return nil }
                            return (free: f, total: t)
                        }
                    HStack(spacing: 8) {
                        Image(systemName: "sdcard.fill")
                            .imageScale(.small)
                            .foregroundStyle(Semantics.sourceText)
                        LaneTrack(fraction: 0, state: .planned)
                            .frame(height: 5)
                        VStack(alignment: .trailing, spacing: 0) {
                            // Middle, not head: head truncation ate the
                            // volume name ("…LE_2/Raws/A001"), which is the
                            // one part that tells two shuttles apart.
                            Text(volumeRelativePath(cardFolder))
                                .font(Typo.evidenceQuiet.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            if let cap {
                                Text("\(bytesString(cap.free)) free")
                                    .font(shortfall(cap)
                                          ? Typo.safety.monospacedDigit()
                                          : Typo.evidenceQuiet.monospacedDigit())
                                    .foregroundStyle(shortfall(cap)
                                        ? AnyShapeStyle(Semantics.warningText)
                                        : AnyShapeStyle(.tertiary))
                            }
                        }
                        .frame(width: 190, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func shortfall(_ cap: (free: Int64, total: Int64)) -> Bool {
        guard let bytes = model.inspection?.bytes, bytes > 0 else { return false }
        return cap.free < bytes
    }
}

// MARK: - Job cards

struct JobCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: Job
    @State private var evidenceSheetShown = false
    @State private var quickLookURL: URL?

    /// ONE voice per verdict (2026-08-26 facelift — the settled-card rule
    /// extended to failures after the Victor + Kimi K3 design reviews): the
    /// filled VerdictBadge owns the verdict, the 4pt left rail echoes it,
    /// and the border stays neutral so the card never states one fact three
    /// times. A failure remains unmissable — filled danger badge, danger
    /// rail, danger error line, red failed lanes — it just speaks once.
    private var cardStroke: AnyShapeStyle {
        switch job.verdict {
        case .running:
            // Verdict-keyed chrome stays indigo for the whole run: the frame
            // renders from Job.verdict, so it must never wear brand amber
            // (amber sits a hue-step from the warning palette — facelift
            // review). The copy/verify distinction lives in the PHASE-scoped
            // progress bars instead.
            return AnyShapeStyle(Semantics.running.opacity(0.28))
        case .failed, .unverified, .safeToWipe, .verifiedKeepCard:
            return AnyShapeStyle(Color(nsColor: .separatorColor))
        }
    }
    private var cardRail: AnyShapeStyle {
        switch job.verdict {
        case .running:                     return AnyShapeStyle(Semantics.running)
        case .failed, .unverified:         return AnyShapeStyle(Semantics.danger)
        case .safeToWipe, .verifiedKeepCard: return AnyShapeStyle(.quaternary)
        }
    }
    private var cardRailWidth: CGFloat {
        switch job.verdict {
        case .safeToWipe, .verifiedKeepCard: return 3
        default:                             return 4
        }
    }

    var body: some View {
        Group {
            if job.isRunning {
                card
            } else {
                card.contextMenu { receiptActions }
            }
        }
        .sheet(isPresented: $evidenceSheetShown) {
            JobEvidenceView(job: job)
        }
        .quickLookPreview($quickLookURL)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            JobHeaderBand(job: job)
            FlowLaneGroup(job: job)
            if job.destinationCheckPending {
                // Work in progress, not a warning: the post-SAFE re-check of
                // the copies normally takes seconds. Amber text beside the
                // green verdict read as a problem (Joshua, 2026-09-28).
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text("Checking copied files. Keep the card until this check finishes.")
                        .font(Typo.safetyBody)
                        .foregroundStyle(Semantics.runningText)
                }
                .accessibilityElement(children: .combine)
            }
            messagesBlock
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cardStroke, lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(cardRail)
                .frame(width: cardRailWidth)
        }
    }

    /// Right-click receipt actions. Handing a card back is a paperwork moment:
    /// the report, its path (for a delivery note), and the card label.
    @ViewBuilder
    private var receiptActions: some View {
        Button {
            evidenceSheetShown = true
        } label: {
            Label("Inspect Evidence & Checksums…", systemImage: "doc.text.magnifyingglass")
        }

        let reports = JobEvidenceParser.validatedReportPaths(for: job) ?? []
        if !reports.isEmpty {
            ForEach(reports, id: \.self) { report in
                let ext = (report as NSString).pathExtension.uppercased()
                let name = ext.isEmpty ? "Report" : "\(ext) Report"
                Button("Open \(name)") {
                    FinderEvidenceActions.openFileOrFolder(report)
                }
                Button("Quick Look \(name)") {
                    quickLookURL = URL(fileURLWithPath: report)
                }
                Button("Reveal \(name) in Finder") {
                    FinderEvidenceActions.revealInFinder(report)
                }
            }
            if let primary = job.reportPath {
                Button("Copy Report Path") { FinderEvidenceActions.copyToPasteboard(primary) }
            }
        }

        let manifests = JobEvidenceParser.validatedManifestPaths(for: job) ?? []
        if !manifests.isEmpty {
            ForEach(manifests, id: \.self) { manifest in
                let filename = (manifest as NSString).lastPathComponent
                Button("Quick Look Manifest (\(filename))") {
                    quickLookURL = URL(fileURLWithPath: manifest)
                }
                Button("Reveal Manifest in Finder (\(filename))") {
                    FinderEvidenceActions.revealInFinder(manifest)
                }
            }
        }

        let dests = job.destinations.isEmpty ? job.laneRoots : job.destinations
        ForEach(dests, id: \.self) { dest in
            let name = (dest as NSString).lastPathComponent
            Button("Reveal '\(name)' in Finder") {
                FinderEvidenceActions.revealInFinder(dest)
            }
            Button("Open '\(name)'") {
                FinderEvidenceActions.openFileOrFolder(dest)
            }
        }

        Divider()
        Button("Copy Card Label") { FinderEvidenceActions.copyToPasteboard(job.label) }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private var messagesBlock: some View {
        JobMessagesView(job: job)
    }

}

private struct JobMessagesView: View {
    @ObservedObject var job: Job
    @State private var page = 0
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        if !job.messages.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Previous messages") { page = max(0, page - 1) }
                            .disabled(page == 0)
                        Text("Page \(page + 1) of \(max(1, (job.messages.count + Job.messagePageSize - 1) / Job.messagePageSize))")
                        Button("Next messages") { page += 1 }
                            .disabled((page + 1) * Job.messagePageSize >= job.messages.count)
                        Spacer()
                        Button(exporting ? "Exporting…" : "Export all messages…", action: exportMessages)
                            .disabled(exporting)
                    }
                    .font(.caption)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(job.messagePage(page)) { message in
                                Label(String(message.text.prefix(4096)) + (message.text.count > 4096 ? "… [full text in export]" : ""),
                                      systemImage: message.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(Typo.evidenceQuiet)
                                    .foregroundStyle(message.severity == .error ? Semantics.dangerText : Semantics.warningText)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(page)
                    .frame(maxHeight: 180)
                    if let exportError { Text(exportError).foregroundStyle(Semantics.dangerText) }
                }
            } label: {
                Text("\(job.errorCount) errors · \(job.warningCount) warnings")
                    .font(Typo.safety.monospacedDigit())
                    .foregroundStyle(job.errorCount > 0 ? Semantics.dangerText : Semantics.warningText)
            }
        }
    }

    private func exportMessages() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dumptruck messages.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            let messages = job.messages
            Task {
                let failure = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        // Stream to a sibling temporary file, then replace atomically.
                        let temp = url.deletingLastPathComponent().appendingPathComponent(".dumptruck-\(UUID().uuidString).txt")
                        defer { try? FileManager.default.removeItem(at: temp) }
                        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        let file = try FileHandle(forWritingTo: temp)
                        defer { try? file.close() }
                        for message in messages {
                            try file.write(contentsOf: Data("[\(message.severity)] \(message.text)\n".utf8))
                        }
                        try file.synchronize()
                        if FileManager.default.fileExists(atPath: url.path) {
                            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                        } else { try FileManager.default.moveItem(at: temp, to: url) }
                        return nil
                    } catch { return "Message export failed: \(error.localizedDescription)" }
                }.value
                exportError = failure
                exporting = false
            }
        }
    }
}

/// The header band: label + single verdict badge, then the phase-honest
/// progress block (copy bar / re-read bar / indeterminate sealing),
/// speedometer + sparkline + windowed ETA, or the done-state summary with
/// its proof line, wipe blockers, elapsed time, report and earned-eject
/// controls. Error/warning counts live in the messagesBlock label on the
/// card face — once, not twice (2026-08-26 facelift).
struct JobHeaderBand: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: Job
    @State private var stopConfirmation = false
    @State private var evidenceSheetShown = false
    @State private var quickLookURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the rolling-digit readouts. nil under Reduce Motion.
    private var digitAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Card labels are names, not identifiers — system face
                // (2026-08-26 facelift: mono is reserved for paths, hashes,
                // and byte counts). No error chip here: the counts stay on
                // the card face via the always-visible messagesBlock label
                // (Kimi K3's visibility requirement holds), and the header
                // stating them twice was half of "busy".
                Text(job.label)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                VerdictBadge(verdict: job.verdict, phaseText: job.phase.rawValue)
                    .layoutPriority(1)
            }
            if job.hasCustodyFailure {
                Label("Custody check failed. Keep the card. " + job.custodyFailures.keys.sorted().joined(separator: ", "),
                      systemImage: "xmark.octagon.fill")
                    .font(Typo.safety).foregroundStyle(Semantics.dangerText)
                Text("The verdict above records the earlier offload.").font(.caption)
            }
            if let drive = job.ejectedDestinationName {
                // A backup drive ejected after SAFE is routine at wrap: the
                // copies are fine as far as anyone knows, they are just no
                // longer watched. Amber and plain, not the red damage line
                // below (Joshua, 2026-09-28). Authority is withdrawn the same.
                let line = "\(drive) was ejected, so \(Job.Verdict.safeToWipe.displayLine) "
                    + "is no longer being watched. Verify again before wiping."
                Label(line, systemImage: "eject.circle.fill")
                    .font(Typo.safety).foregroundStyle(Semantics.warningText)
                    .accessibilityLabel(line)
            } else if let reason = job.destinationAuthorityWithdrawn {
                // The withdrawal sits under the badge it qualifies, always
                // visible: a green SAFE headline with the reason hidden in a
                // collapsed warning list misled the operator (desktop QA
                // round 5, R5-01).
                Label("Wipe permission withdrawn. Keep the card. " + reason,
                      systemImage: "xmark.octagon.fill")
                    .font(Typo.safety).foregroundStyle(Semantics.dangerText)
                    .accessibilityLabel("Wipe permission withdrawn: \(reason)")
                Text("The verdict above is historical; verify the copies again before wiping.")
                    .font(.caption)
            }
            if let later = job.laterVerification {
                // The newest fact about the copy sits right under the verdict
                // it qualifies: a later check that found damage must never be
                // invisible behind an earlier green result.
                Label(later.line, systemImage: later.isClean
                      ? "checkmark.seal" : "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(later.isClean ? Semantics.successText : Semantics.dangerText)
                    .accessibilityLabel(later.line)
            }
            if job.isRunning {
                runningBody
            } else {
                finishedBody
            }
        }
        // Phase swaps (queued -> copying -> re-read -> sealing -> verdict)
        // cross-fade instead of snapping. Verdict weight is unaffected: the
        // badge carries its own settle rules (alarms still snap).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: job.phase)
        .sheet(isPresented: $evidenceSheetShown) {
            JobEvidenceView(job: job)
        }
        .quickLookPreview($quickLookURL)
    }

    @ViewBuilder
    private var runningBody: some View {
        if job.phase == .copying {
            // No milestone ticks here: this bar measures SOURCE bytes read
            // into the pipeline, and lit milestones would imply verified
            // completion the lanes have not shown (agy audit, MEDIUM 7).
            // Amber = copying; the verify re-read below keeps indigo — the
            // phase distinction the chrome carries (2026-08-26 facelift).
            ProgressView(value: job.fraction)
                .tint(Brand.amber)
            HStack(spacing: 10) {
                Text("\(job.filesCopied + job.filesSkipped) / \(job.filesTotal) files")
                    .contentTransition(.numericText())
                    .animation(digitAnimation, value: job.filesCopied + job.filesSkipped)
                Text("·")
                // No rolling digits on the copy counter: the engine reports
                // per 4 MiB chunk, hundreds of updates/sec on fast media —
                // a 250ms roll would never complete (codex review). The
                // once-per-second re-read counter below does roll.
                Text("\(bytesString(job.displayedBytesDone)) of \(bytesString(job.bytesTotal))")
                Spacer()
                if let secs = copyETASeconds {
                    ETAReadout(secondsRemaining: secs)
                        .id(job.phase)
                }
                Text("\(Int(job.fraction * 100))%")
                    .contentTransition(.numericText(value: job.fraction))
                    .animation(digitAnimation, value: Int(job.fraction * 100))
            }
            .font(Typo.evidenceQuiet.monospacedDigit()).foregroundStyle(.secondary)
            speedometerRow
        } else if job.phase == .sourceVerify, job.rereadTotal > 0 {
            let frac = Double(job.rereadDone) / Double(job.rereadTotal)
            ProgressView(value: frac)
                .tint(Semantics.running)
                .overlay {
                    MilestoneTicksOverlay(fraction: frac)
                }
            HStack(spacing: 10) {
                Text("re-reading the card to prove the copy")
                Text("·")
                Text("\(bytesString(job.rereadDone)) of \(bytesString(job.rereadTotal))")
                    .contentTransition(.numericText())
                    .animation(digitAnimation, value: job.rereadDone)
                Spacer()
                if let secs = rereadETASeconds {
                    ETAReadout(secondsRemaining: secs)
                        .id(job.phase)
                }
                Text("\(Int(frac * 100))%")
                    .contentTransition(.numericText(value: frac))
                    .animation(digitAnimation, value: Int(frac * 100))
            }
            .font(Typo.evidenceQuiet.monospacedDigit()).foregroundStyle(.secondary)
            speedometerRow
        } else if job.phase == .reports {
            // Manifest/report sealing is genuinely indeterminate — the bar
            // must never sit pinned at 100% while safety work is underway.
            ProgressView().progressViewStyle(.linear)
                .tint(Semantics.running)
            sealingChecklist
        } else {
            ProgressView().progressViewStyle(.linear)
                .tint(Semantics.running)
            Text(job.phase.rawValue)
                .font(Typo.evidence).foregroundStyle(.secondary)
        }
        if !job.currentFile.isEmpty {
            HStack(spacing: 8) {
                Text(job.currentFile)
                    .font(Typo.evidenceQuiet.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                // The truck hauls only while bytes are being laid down —
                // bounce, dust and the pour into the bed scale with real
                // throughput, and the heap grows with the job's progress
                // (pure decoration; every number stays in the text). The verify
                // re-read is a safety phase, not a loading animation, so the
                // mascot sits it out (Kimi K3 design review, 2026-08-26).
                if job.phase == .copying {
                    TruckDrivingView(speed: min(1, job.currentSpeed / 400_000_000),
                                     load: job.fraction)
                        .frame(width: 132, height: 42)
                        .accessibilityHidden(true)
                }
            }
        }
        if job.phase == .queued {
            let pos = model.queuePosition(of: job) ?? 1
            let total = model.queuedJobs.count
            let isNext = (pos == 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(
                        isNext
                            ? "Next in queue · Position \(pos) of \(total)"
                            : "Queued · Position \(pos) of \(total)",
                        systemImage: isNext ? "arrowshape.forward.fill" : "clock.arrow.2.circlepath"
                    )
                    .font(Typo.evidence.weight(.medium))
                    .foregroundStyle(isNext ? Semantics.runningText : .secondary)

                    if model.isDispatchPaused {
                        Text("· Dispatch Paused")
                            .font(Typo.evidenceQuiet)
                            .foregroundStyle(Semantics.warningText)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        _ = model.moveQueuedEarlier(job: job)
                    } label: {
                        Label("Move Earlier", systemImage: "arrow.up")
                    }
                    .controlSize(.small)
                    .disabled(!model.canMoveQueuedEarlier(job: job))
                    .help("Move this transfer earlier in the queue")
                    .accessibilityLabel("Move \(job.label) earlier in queue")

                    Button {
                        _ = model.moveQueuedLater(job: job)
                    } label: {
                        Label("Move Later", systemImage: "arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(!model.canMoveQueuedLater(job: job))
                    .help("Move this transfer later in the queue")
                    .accessibilityLabel("Move \(job.label) later in queue")

                    Spacer()

                    // No Stop beside it: a queued card has copied nothing,
                    // and Remove covers it without filing a FAILED record
                    // (Joshua, 2026-09-28).
                    Button("Remove from Queue", role: .destructive) {
                        model.removeQueued(job: job)
                    }
                    .controlSize(.small)
                    .help("Remove this transfer from the queue without starting it")
                    .accessibilityLabel("Remove \(job.label) from queue")
                }
            }
        } else {
            Button(job.stopRequested ? "Stopping…" : "Stop Transfer", role: .destructive) {
                stopConfirmation = true
            }
            .controlSize(.small)
            .disabled(job.stopRequested)
            .confirmationDialog(
                "Stop \(job.label)? The copy will be incomplete and the source must not be wiped.",
                isPresented: $stopConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop Transfer", role: .destructive) {
                    model.stop(job: job)
                }
                Button("Continue Transfer", role: .cancel) {}
            }
        }
        // A quiet, entirely optional nudge: the games exist and now is the
        // one moment they're useful. Caption-weight, dismiss-free, and it
        // never renders on a finished card.
        Button {
            model.arcadeShown = true
        } label: {
            Label("Got a wait? The Dump Yard is open", systemImage: "gamecontroller")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .help("Four mini games while the card hauls — optional, in a sheet, never over your job")
    }

    /// Sealing is the one wait where throughput is legitimately zero, and a
    /// bare spinner reads as a hang. Only two steps exist in the engine's
    /// event stream — manifests being sealed, and the report file landing —
    /// so only two steps are shown. No invented sub-progress.
    private var sealingChecklist: some View {
        let reportWritten = job.reportPath != nil
        let reportsEnabled = UserDefaults.standard.bool(forKey: Pref.makeReports)
        return VStack(alignment: .leading, spacing: 3) {
            sealingStep("Sealing manifests", done: reportWritten, active: !reportWritten)
            // A step for a report the operator disabled would dangle at
            // "not yet" forever — omit it entirely in that case. A report
            // the engine FAILED to write says so plainly (Kimi F4).
            if job.reportFailed {
                Label("Report failed — copy state unaffected", systemImage: "xmark.circle")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.dangerText)
            } else if reportsEnabled {
                sealingStep("Report written", done: reportWritten, active: false)
            }
        }
    }

    private func sealingStep(_ text: String, done: Bool, active: Bool) -> some View {
        Label {
            Text(text)
                .foregroundStyle(done || active ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(.tertiary))
        } icon: {
            ManifestSealView(isSealing: active, isSealed: done, size: 14)
        }
        .font(.caption)
        .accessibilityLabel(done ? "\(text): done" : (active ? "\(text): in progress"
                                                             : "\(text): not yet"))
    }

    @ViewBuilder
    private var speedometerRow: some View {
        if job.currentSpeed > 0 || job.speedHistory.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .imageScale(.small)
                        .foregroundStyle(Semantics.runningText)
                    Group {
                        if job.currentSpeed > 0 {
                            Text(speedString(job.currentSpeed))
                                .foregroundStyle(Semantics.runningText)
                                .contentTransition(.numericText(value: job.currentSpeed))
                                .animation(digitAnimation, value: speedString(job.currentSpeed))
                        } else if job.verifyingCopies {
                            // The engine's verify heartbeat: source reads are
                            // paused while copies are read back. Healthy, and
                            // said plainly so it never reads as a fault.
                            Text("verifying copies…")
                                .foregroundStyle(.secondary)
                        } else if let stallObservation = job.stallObservation {
                            // Still an observation, not a diagnosis: how long
                            // no source-read bytes have arrived. The 120-second
                            // tier names a possibility rather than a finding.
                            Label(stallObservation,
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Semantics.warningText)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            // The pause is real, but a zero source-read sample does
                            // not identify WHICH side of the pipeline is waiting.
                            // Never diagnose healthy back-pressure when the source
                            // device itself could be stalled.
                            Text("waiting for I/O…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(Typo.evidence.monospacedDigit())
                    .frame(minWidth: 74, alignment: .leading)
                    .help(job.verifyingCopies
                          ? "The card is not being read right now because the engine is reading copies back from the destinations to verify them."
                          : "No source-read bytes arrived in the latest sample. This can be normal destination back-pressure, or a slow/stalled source or destination device; the job remains authoritative.")
                    Sparkline(samples: job.speedHistory)
                        .frame(height: 16)
                        .frame(maxWidth: .infinity)
                        .help("Throughput over the last \(job.speedHistory.count)s")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(speedAccessibilityLabel)
                if job.throttleAdvisory {
                    // An observation about this job's own numbers. The cause is
                    // named as a possibility, never as a finding.
                    Label("throughput well below this job's average — possible thermal or bus limit",
                          systemImage: "thermometer.medium")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.warningText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Semantics.warning.opacity(Semantics.chip), in: .capsule)
                        .padding(.leading, 26)
                }
            }
        }
    }

    private var speedAccessibilityLabel: String {
        if job.currentSpeed > 0 { return "Current speed \(speedString(job.currentSpeed))" }
        if job.verifyingCopies { return "Verifying copies" }
        if let stallObservation = job.stallObservation {
            return stallObservation
        }
        return "Waiting for I/O"
    }

    /// ETA from the cumulative mean rates (Kimi K3: the instantaneous 1s
    /// rate whipsaws the number; the sparkline keeps the raw motion). The
    /// model owns the arithmetic so the check suite can drive it with a
    /// clock (round-3 R3-03: bytes alone read "1 second left" for minutes).
    private var copyETASeconds: Int? { job.copyETASeconds() }

    private var rereadETASeconds: Int? {
        guard let rate = job.etaRate, rate > 0, job.rereadDone > 0,
              job.rereadTotal > job.rereadDone else { return nil }
        return Int(Double(job.rereadTotal - job.rereadDone) / rate)
    }

    @ViewBuilder
    private var finishedBody: some View {
        // The verdict carries its proof (or its blockers) inline — the
        // operator should be able to defend the badge without opening the
        // report (Kimi K3 review).
        if job.verdict == .safeToWipe, job.destinationAuthorityWithdrawn != nil {
            // Historical proof, no mascot: the copies it describes are no
            // longer where the verdict left them.
            Label("Historical: \(job.physicalDevices) physical devices · source read twice · flushed to media",
                  systemImage: "clock.arrow.circlepath")
                .font(Typo.safetyBody)
                .foregroundStyle(.secondary)
        } else if job.verdict == .safeToWipe {
            HStack(alignment: .center, spacing: 8) {
                Label("\(job.physicalDevices) physical devices · source read twice · flushed to media",
                      systemImage: "checkmark.circle")
                    .font(Typo.safetyBody)
                    .foregroundStyle(Semantics.successText)
                Spacer()
                TruckDumpView(checkCount: 12)
                    .id(job.id)
                    .frame(width: 120, height: 44)
                    .accessibilityHidden(true)
            }
        } else if job.verdict != .failed, !job.wipeBlockers.isEmpty {
            // No mascot on a failed card (2026-08-26 facelift): a cartoon
            // next to DO NOT WIPE undercuts the one message that must land
            // with full weight — the fun layer never shares a frame with an
            // alarm. (Failed cards also suppress wipe blockers, as before:
            // the filled FAILED badge already forbids the wipe.)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(job.wipeBlockers, id: \.self) { b in
                    Label(b, systemImage: "info.circle")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.warningText)
                }
            }
        }
        // Counts on their own line, actions on theirs: sharing one row
        // wrapped the counts into three lines beside "Eject Sour…" and
        // "Open Re…" at the 685pt center width (2026-09-04 UI audit).
        HStack(spacing: 8) {
            Text("\(job.filesCopied) copied · \(job.filesSkipped) already offloaded"
                 + (job.trustedPrior > 0 ? " (\(job.trustedPrior) trusted, not re-read)" : "")
                 + (job.filesFailed > 0 ? " · \(job.filesFailed) FAILED" : ""))
                .font(job.filesFailed > 0
                      ? Typo.safety.monospacedDigit()
                      : Typo.safetyBody.monospacedDigit())
                .foregroundStyle(job.filesFailed > 0 ? Semantics.dangerText : .secondary)
            if let elapsed = elapsedText {
                Text("·").foregroundStyle(.tertiary)
                Text(elapsed)
                    .font(Typo.evidenceQuiet.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        // Four fixed-size controls want ~458pt; the 440pt center minimum
        // leaves ~384pt after card padding (codex + opus review of the
        // 2026-09-04 audit commit). Fall back to two rows rather than
        // overflow the card or truncate labels again.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer()
                ejectSourceButton
                evidenceButton
                openReportMenu
                stageRetryButton
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Spacer()
                    ejectSourceButton
                    evidenceButton
                }
                HStack(spacing: 8) {
                    Spacer()
                    openReportMenu
                    stageRetryButton
                }
            }
        }
    }

    @ViewBuilder
    private var ejectSourceButton: some View {
        if job.verdict == .safeToWipe,
           model.isCurrentSourceVerdict(job),
           let vol = model.volumes.first(where: { $0.path == job.sourcePath }),
           model.canEject(vol) {
            // The earned-friction gradient: a green card ejects its
            // source in one click, right where the verdict lives.
            Button {
                // Re-validate at CLICK time: a continuation may have
                // started since this button rendered (Ox review, F1 —
                // the notification path already does this).
                guard job.verdict == .safeToWipe,
                      model.isCurrentSourceVerdict(job),
                      model.canEject(vol) else { return }
                model.eject(vol)
            } label: {
                Label("Eject Source", systemImage: "eject.fill")
            }
            .controlSize(.small)
            .fixedSize()
            .tint(Semantics.successText)
            .accessibilityLabel("Eject source \(job.label)")
        }
    }

    private var evidenceButton: some View {
        Button {
            evidenceSheetShown = true
        } label: {
            Label("Evidence", systemImage: "doc.text.magnifyingglass")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Inspect recorded checksums, ASC MHL manifests, and emitted reports")
    }

    @ViewBuilder
    private var openReportMenu: some View {
        let safeReports = JobEvidenceParser.validatedReportPaths(for: job) ?? []
        if let report = safeReports.first(where: { $0 == job.reportPath }) ?? safeReports.first {
            Menu {
                Button("Open Report") {
                    FinderEvidenceActions.openFileOrFolder(report)
                }
                Button("Quick Look Report") {
                    quickLookURL = URL(fileURLWithPath: report)
                }
                Button("Reveal in Finder") {
                    FinderEvidenceActions.revealInFinder(report)
                }
                Button("Copy Report Path") {
                    FinderEvidenceActions.copyToPasteboard(report)
                }
            } label: {
                Label("Open Report", systemImage: "doc.text")
            } primaryAction: {
                FinderEvidenceActions.openFileOrFolder(report)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var stageRetryButton: some View {
        if job.launchPlanSnapshot != nil {
            Button {
                _ = model.stageRetry(job)
            } label: {
                Label("Stage Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Restore the original source, destinations, and rendered folder; Start remains manual")
        }
    }

    private var elapsedText: String? {
        // An interrupted restore's finishedDate is the RECOVERY stamp
        // (relaunch time), not a completion — presenting it as "done at"
        // with a duration through the downtime would be a fabricated
        // timeline (codex v0.4.x review, F2). The card's wipe-blocker line
        // already states the interruption.
        guard !job.restoredInterrupted else { return nil }
        guard let start = job.startedDate, let end = job.finishedDate else { return nil }
        let df = DateFormatter(); df.timeStyle = .short; df.dateStyle = .none
        return "done \(df.string(from: end)) · took \(elapsedString(end.timeIntervalSince(start)))"
    }
}

/// Keeps relative and wall-clock ETA text on the same held completion
/// projection. The raw estimator remains on Job and continues updating every
/// sample; only this display layer buckets and suppresses ordinary jitter.
private struct ETAReadout: View {
    let secondsRemaining: Int
    @State private var hold = ETADisplayHold()
    @State private var projection: ETADisplayProjection?

    var body: some View {
        Group {
            if let projection {
                Text("~\(projection.relativeText) left · done \(finishClockString(finishDate: projection.finishDate))")
            }
        }
        .onAppear { updateProjection() }
        .onChange(of: secondsRemaining) { _, _ in updateProjection() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) {
            updateProjection(at: $0)
        }
    }

    private func updateProjection(at now: Date = Date()) {
        var next = hold
        projection = next.project(secondsRemaining: secondsRemaining, now: now)
        hold = next
    }
}

// MARK: - Lanes

/// One lane per destination, running source-side to destination-side. Lanes
/// fill with engine-accounted bytes, while the caption distinguishes newly
/// verified, trusted-prior, and size-only evidence. There is exactly one
/// speedometer per job (a per-lane MB/s would be fabricated; no per-destination
/// byte counter exists in the engine).
struct FlowLaneGroup: View {
    @ObservedObject var job: Job

    var body: some View {
        if job.phase == .queued {
            Text("waiting · ^[\(job.destinations.count) destination](inflect: true) · \(bytesString(job.bytesTotal))")
                .font(Typo.evidenceQuiet)
                .foregroundStyle(.tertiary)
        } else if !job.laneRoots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(job.laneRoots, id: \.self) { root in
                    DestinationLane(job: job, root: root,
                                    isSlowest: slowestRoot == root && job.laneRoots.count > 1
                                               && job.phase == .copying)
                }
            }
        } else {
            // Older stream or pre-job_started: fall back to the frozen plan.
            ForEach(job.destinations, id: \.self) { d in
                Label(volumeRelativePath(d), systemImage: "externaldrive")
                    .font(Typo.evidence.monospaced())
                    .foregroundStyle(.secondary)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: d)])
                        }
                    }
            }
        }
    }

    private var slowestRoot: String? {
        // Only meaningful when the lanes have actually diverged — a tie (or
        // everyone at zero) has no laggard to call out.
        let counts = job.laneRoots.map { (job.destProgress[$0]?.completionBytes ?? 0, $0) }
        guard let minPair = counts.min(by: { $0.0 < $1.0 }),
              let maxPair = counts.max(by: { $0.0 < $1.0 }),
              minPair.0 < maxPair.0 else { return nil }
        return minPair.1
    }
}

struct DestinationLane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: Job
    let root: String
    let isSlowest: Bool
    @State private var evidenceSheetShown = false
    @State private var quickLookURL: URL?

    private var progress: DestProgress { job.destProgress[root] ?? DestProgress() }
    private var custodyFailed: Bool { job.custodyFailure(for: root) != nil }
    /// The lane whose copy went away or changed after the verdict.
    private var authorityWithdrawnHere: Bool {
        guard let withdrawnRoot = job.destinationAuthorityWithdrawnRoot else { return false }
        return pathIsAtOrInsideLexically(withdrawnRoot, root: root)
            || pathIsAtOrInsideLexically(root, root: withdrawnRoot)
    }
    /// That lane's drive was ejected rather than its copy changed.
    private var ejectedHere: Bool {
        authorityWithdrawnHere && job.destinationAuthorityWithdrawnByEjection
    }

    private var fraction: Double {
        // A finished, fully verified job's lanes render complete: trusted
        // prior files are chain-verified and emit no events, so byte math
        // alone can't reach 1.0 on a continuation.
        if !job.isRunning, job.fullyVerified, progress.filesFailed == 0 { return 1 }
        guard job.bytesTotal > 0 else { return 0 }
        return min(1, Double(progress.completionBytes) / Double(job.bytesTotal))
    }

    private var state: LaneTrack.LaneState {
        if custodyFailed { return .failed }
        if ejectedHere { return .detached }
        if authorityWithdrawnHere { return .failed }
        if progress.filesFailed > 0 { return .failed }
        if !job.isRunning {
            return job.fullyVerified ? .complete : .failed
        }
        if job.phase == .reports { return .sealing }
        return .running
    }

    private var caption: String {
        if custodyFailed { return "custody check failed, keep the card" }
        if ejectedHere { return "ejected after verification, no longer watched" }
        if authorityWithdrawnHere { return "changed or missing after verification, keep the card" }
        var parts: [String]
        if job.phase == .reports && job.isRunning {
            parts = ["sealing manifests"]
        } else {
            // Do not prepend a fabricated-looking "verified Zero KB · 0
            // files" stratum to trusted-only continuations or Fast-mode
            // size checks.  Each caption names only evidence the engine
            // actually emitted for this lane.
            parts = []
            if progress.filesVerified > 0 || progress.bytesVerified > 0 {
                parts.append("verified \(bytesString(progress.bytesVerified)) · \(progress.filesVerified) files")
            }
            if progress.filesTrusted > 0 {
                parts.append("\(progress.filesTrusted) trusted, not re-read")
            }
            if progress.sizeOnly > 0 { parts.append("\(progress.sizeOnly) size checked only — not verified") }
            if progress.filesFailed > 0 { parts.append("\(progress.filesFailed) FAILED") }
            if parts.isEmpty {
                parts.append(job.isRunning ? "waiting for engine evidence" : "no engine evidence")
            }
            // Capacity outranks relative-speed commentary (agy audit 9).
            if let warning = lowSpaceWarning { parts.append(warning) }
            if isSlowest { parts.append("slowest destination") }
        } 
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard.fill")
                    .imageScale(.small)
                    .foregroundStyle(Semantics.sourceText)
                LaneTrack(fraction: fraction, state: state)
                    .frame(height: 6)
                Text(laneDisplayName)
                    .font(Typo.evidence.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 120, alignment: .leading)
                Image(systemName: terminusSymbol)
                    .imageScale(.small)
                    .foregroundStyle(terminusColor)
            }
            Text(caption)
                .font(laneCaptionIsDefect
                      ? Typo.safety.monospacedDigit()
                      : Typo.safetyBody.monospacedDigit())
                .foregroundStyle(captionColor)
                .padding(.leading, 26)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(laneDisplayName): \(caption)")
        .contextMenu {
            Button("Reveal Destination in Finder") {
                FinderEvidenceActions.revealInFinder(root)
            }
            Button("Open Destination in Finder") {
                FinderEvidenceActions.openFileOrFolder(root)
            }
            let safeManifests = JobEvidenceParser.validatedManifestPaths(for: job) ?? []
            let matchingManifests = safeManifests.filter { pathIsAtOrInside($0, root: root) }
            ForEach(matchingManifests, id: \.self) { m in
                let name = (m as NSString).lastPathComponent
                Button("Quick Look Manifest (\(name))") {
                    quickLookURL = URL(fileURLWithPath: m)
                }
                Button("Reveal Manifest in Finder (\(name))") {
                    FinderEvidenceActions.revealInFinder(m)
                }
            }
            let safeReports = JobEvidenceParser.validatedReportPaths(for: job) ?? []
            let matchingReports = safeReports.filter { pathIsAtOrInside($0, root: root) }
            ForEach(matchingReports, id: \.self) { r in
                let name = (r as NSString).lastPathComponent
                Button("Open Report (\(name))") {
                    FinderEvidenceActions.openFileOrFolder(r)
                }
                Button("Quick Look Report (\(name))") {
                    quickLookURL = URL(fileURLWithPath: r)
                }
                Button("Reveal Report in Finder (\(name))") {
                    FinderEvidenceActions.revealInFinder(r)
                }
            }
            Divider()
            Button {
                evidenceSheetShown = true
            } label: {
                Label("Inspect Checksums & Evidence…", systemImage: "doc.text.magnifyingglass")
            }
            Button("Copy Destination Path") {
                FinderEvidenceActions.copyToPasteboard(root)
            }
        }
        .sheet(isPresented: $evidenceSheetShown) {
            JobEvidenceView(job: job)
        }
        .quickLookPreview($quickLookURL)
    }

    private var laneDisplayName: String {
        if root.hasPrefix("/Volumes/") {
            guard let volume = model.volumes.first(where: {
                pathIsAtOrInside(root, root: $0.path)
            }) else { return endpointName(root) }
            let rootsOnVolume = job.laneRoots.filter {
                pathIsAtOrInside($0, root: volume.path)
            }
            guard rootsOnVolume.count > 1 else { return volume.name }
            // Two folder endpoints on one physical drive otherwise render as
            // indistinguishable duplicate lanes. Find the first component
            // that differs among the collocated roots (not merely the first
            // component below the volume: several endpoints may share a
            // project parent) and show that operator-chosen branch.
            let prefix = volume.path + "/"
            func components(_ path: String) -> [Substring] {
                guard path.hasPrefix(prefix) else { return [] }
                return path.dropFirst(prefix.count).split(separator: "/")
            }
            let mine = components(root)
            let peers = rootsOnVolume.map(components)
            guard !mine.isEmpty else {
                return volume.name
            }
            let differingIndex = mine.indices.first { index in
                Set(peers.map { index < $0.count ? String($0[index]) : "" }).count > 1
            }
            let branch = mine[differingIndex ?? (mine.count - 1)]
            return "\(volume.name)/\(branch)"
        }
        return ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    private var terminusSymbol: String {
        switch state {
        case .failed: return "xmark.octagon.fill"
        case .complete: return "checkmark.circle.fill"
        case .detached: return "eject.circle.fill"
        default: return "externaldrive.fill"
        }
    }
    private var terminusColor: Color {
        switch state {
        case .failed: return Semantics.dangerText
        case .complete: return Semantics.successText
        case .sealing, .detached: return Semantics.warningText
        default: return Semantics.destinationText
        }
    }
    private var captionColor: Color {
        if custodyFailed { return Semantics.dangerText }
        if ejectedHere { return Semantics.warningText }
        if progress.filesFailed > 0 { return Semantics.dangerText }
        if lowSpaceWarning != nil { return Semantics.warningText }
        if progress.sizeOnly > 0 { return Semantics.warningText }
        // "slowest destination" is relative trivia, not a defect — it never
        // takes the warning color; LOW SPACE owns amber alone (Kimi F16).
        return .secondary
    }

    /// A lane caption naming a FAILED file or size-only evidence is a defect
    /// report, not supporting prose — it takes the heavier safety tier.
    private var laneCaptionIsDefect: Bool {
        progress.filesFailed > 0 || progress.sizeOnly > 0 || lowSpaceWarning != nil
    }

    private var lowSpaceWarning: String? {
        // Copying phase only (re-read and sealing write nothing new), and the
        // model's 30s-refreshed volumes, not a per-render statfs (Kimi F18).
        guard job.phase == .copying,
              let vol = model.volumes.first(where: { pathIsAtOrInside(root, root: $0.path) }),
              let free = vol.freeBytes else { return nil }
        let remaining = max(0, job.bytesTotal - progress.completionBytes)
        guard free < remaining else { return nil }
        return "LOW SPACE: \(bytesString(free)) free, \(bytesString(remaining)) still to write"
    }
}

/// The lane's visual: a quiet track with a directional fill. Dashed outline
/// for planned (bench) lanes — nothing has moved yet.
struct LaneTrack: View {
    /// `detached`: the lane's drive was ejected after the verdict. Not a
    /// failure; the copy is simply no longer watched.
    enum LaneState { case planned, running, sealing, complete, failed, detached }
    let fraction: Double
    let state: LaneState

    private var fillColor: Color {
        switch state {
        case .planned: return .clear
        case .running: return Semantics.running
        case .sealing, .detached: return Semantics.warning
        case .complete: return Semantics.success
        case .failed: return Semantics.danger
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if state == .planned {
                    Capsule()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.tertiary)
                } else {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.linear(duration: 0.4), value: fraction)
                    MilestoneTicksOverlay(fraction: fraction)
                }
            }
        }
    }
}

/// Global queue dispatch status and operator controls. Shows whether
/// automatic dispatch of queued transfers is running or paused, and provides
/// accessible pause/resume controls.
struct QueueControlBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let count = model.queuedJobs.count
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isDispatchPaused ? "Queue Dispatch: Paused" : "Queue Dispatch: Active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.isDispatchPaused ? Semantics.warningText : Semantics.runningText)
                    Text(model.isDispatchPaused
                         ? "^[\(count) transfer](inflect: true) waiting · automatic dispatch is paused"
                         : (count > 0
                            ? "^[\(count) transfer](inflect: true) in queue · transfers start automatically"
                            : "Queue is ready · automatic dispatch is active"))
                        .font(Typo.evidenceQuiet)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: model.isDispatchPaused ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(model.isDispatchPaused ? Semantics.warningText : Semantics.runningText)
            }
            Spacer()
            Button {
                model.toggleDispatchPause()
            } label: {
                Label(model.isDispatchPaused ? "Resume Dispatch" : "Pause Dispatch",
                      systemImage: model.isDispatchPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(model.isDispatchPaused ? Semantics.warningText : Semantics.runningText)
            .help(model.isDispatchPaused
                  ? "Resume automatic dispatch of queued transfers"
                  : "Pause automatic dispatch — running transfers continue uninterrupted")
            .accessibilityLabel(model.isDispatchPaused ? "Resume queue dispatch" : "Pause queue dispatch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(model.isDispatchPaused
                    ? Semantics.warning.opacity(Semantics.wash)
                    : Semantics.running.opacity(Semantics.wash),
                    in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(model.isDispatchPaused
                          ? Semantics.warning.opacity(0.3)
                          : Semantics.running.opacity(0.2)))
    }
}
