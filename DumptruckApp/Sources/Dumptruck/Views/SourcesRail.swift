import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Left rail: where bytes come FROM. Role is expressed by position — a disk
/// listed here as staged/running IS a source. No toggles. Unassigned
/// hardware waits on the center ConnectedShelf (2026-08-26 facelift,
/// Offshoot-style visibility); staging sends it here, so position still
/// carries the role for everything IN the job.
struct SourcesRail: View {
    @EnvironmentObject var model: AppModel
    @Binding var forceEjectTarget: Volume?
    @AppStorage("focusJobs") private var focusJobs = false
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if focusJobs {
                RailSpine(role: .source, forceEjectTarget: $forceEjectTarget)
            } else {
                railHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        stagedSection
                        runningSection
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Divider()
                railFooter
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Semantics.source,
                              style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .dropDestination(for: ShelfDragPayload.self) { items, _ in
            let paths = items.flatMap(\.paths)
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
            let landed = RailMotion.run(reduceMotion: reduceMotion) {
                model.stageDroppedSources(paths) != nil
            }
            if landed { Haptics.alignment() } else { Haptics.level() }
            return landed
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.14)) { dropTargeted = targeted }
        }
    }

    // One quiet header per rail. Position and the card list carry the rest —
    // the old SOURCES/copy FROM + IN THIS JOB + AVAILABLE stack was six caps
    // labels framing (often) two rows (2026-08-26 facelift, Victor's "busy").
    private var railHeader: some View {
        Text("Sources")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Semantics.sourceText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var stagedSection: some View {
        StagedSources(staging: model.batchStagingModel,
                      forceEjectTarget: $forceEjectTarget)
    }

    @ViewBuilder
    private var runningSection: some View {
        let runningSources = model.jobs
            .filter { $0.isRunning && $0.sourcePath != model.sourcePath }
            .map(\.sourcePath)
        let unique = Array(NSOrderedSet(array: runningSources)) as? [String] ?? []
        if !unique.isEmpty {
            RailSectionHeader(title: "Running")
            ForEach(unique, id: \.self) { path in
                RunningRailRow(path: path, forceEjectTarget: $forceEjectTarget)
            }
        }
    }

    private var railFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    model.chooseFolder(as: "source")
                } label: {
                    Label("Choose Source Folder…", systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .help("Copy FROM any folder — not just a whole card. Useful "
                      + "when a drive holds several shoots and only one needs "
                      + "offloading")
                Spacer()
            }
            HStack {
                Button {
                    model.chooseBatchSources()
                } label: {
                    Label("Batch Sources…", systemImage: "square.stack.3d.up")
                        .font(.caption)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .help("Queue several cards or folders in one pass — one job "
                      + "per card, run back to back against the same drives. "
                      + "Built for end-of-day card piles")
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

/// The rail's staged slot: the single card, or the batch it grew into.
/// Observes the batch model directly, because its candidate list changes
/// without AppModel publishing anything.
private struct StagedSources: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var staging: BatchSourceStagingModel
    @Binding var forceEjectTarget: Volume?

    var body: some View {
        let batchPaths = Set(staging.candidates.map(\.path))
        if let src = model.sourcePath, !batchPaths.contains(src) {
            SourceCard(path: src, forceEjectTarget: $forceEjectTarget)
                .transition(.scale.combined(with: .opacity))
        }
        if !staging.candidates.isEmpty {
            BatchRailSection(staging: staging)
                .transition(.scale.combined(with: .opacity))
        } else if model.sourcePath == nil {
            // Empty means invitation: the slot the card will land in, not a
            // header over an empty list. The whole rail is the drop target.
            RailDropSlot(title: "Insert a card",
                         subtitle: "or drop a folder here",
                         tint: Semantics.source)
        }
    }
}

/// Cards collected for a batch, listed where they were dropped. Rail drops
/// used to front the Batch Sources window, which took focus from the main
/// window so the next drag off the Connected shelf never started (Joshua,
/// 2026-09-28). The pile now builds here, and the window opens on request.
private struct BatchRailSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var staging: BatchSourceStagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Batch · \(staging.candidates.count) cards",
                  systemImage: "square.stack.3d.up.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Semantics.sourceText)
            ForEach(staging.candidates) { candidate in
                BatchRailRow(candidate: candidate) {
                    let removedPath = candidate.path
                    staging.removeCandidate(id: candidate.id, appModel: model)
                    model.releaseLooseSourceIfUnused(removedPath)
                }
            }
            if model.destinationPaths.isEmpty {
                Text("Add destination drives to check these cards.")
                    .font(Typo.evidence)
                    .foregroundStyle(Semantics.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.openBatchWindow()
            } label: {
                Label(staging.canQueueBatch ? "Review & Start Batch…" : "Review Batch…",
                      systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open Batch Sources to check labels and start one job per card")
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Semantics.source.opacity(0.35)))
    }
}

private struct BatchRailRow: View {
    @ObservedObject var candidate: BatchSourceCandidate
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: candidate.path.hasPrefix("/Volumes/") ? "sdcard.fill" : "folder.fill")
                .imageScale(.small)
                .foregroundStyle(Semantics.sourceText)
            Text(candidate.volumeName)
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            statusGlyph
                .help(candidate.statusText)
                .accessibilityLabel(candidate.statusText)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .foregroundStyle(.tertiary)
            .help("Remove from the batch")
            .accessibilityLabel("Remove \(candidate.volumeName) from the batch")
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch candidate.status {
        case .pending, .inspecting:
            ProgressView().controlSize(.mini)
        case .awaitingDestinations:
            Image(systemName: "hourglass")
                .foregroundStyle(Semantics.warningText)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Semantics.successText)
        case .refused:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Semantics.dangerText)
        }
    }
}

/// The staged source: identity + lock + eject + FULLNESS gauge (bytes to
/// move — free space on a camera card is meaningless to a DIT).
struct SourceCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let path: String
    @Binding var forceEjectTarget: Volume?

    private var volume: Volume? {
        model.volumes.first { pathIsAtOrInside(path, root: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: volume == nil ? "folder.fill" : "sdcard.fill")
                    .foregroundStyle(Semantics.sourceText)
                // Volume names are names, not identifiers: system face.
                // Mono stays reserved for paths, hashes, and byte counts.
                Text(model.endpointDisplayName(path))
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let vol = volume, !model.canEject(vol) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Semantics.warningText)
                        .help("Transfer not verified — do not remove this volume")
                }
                if let vol = volume {
                    EjectControl(volume: vol, forceEjectTarget: $forceEjectTarget)
                }
                Button {
                    RailMotion.run(reduceMotion: reduceMotion) { model.clearSource() }
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .foregroundStyle(.tertiary)
                    .help("Remove from this job")
                    .accessibilityLabel("Remove source from this job")
            }
            if let vol = volume, path != vol.path {
                Text(volumeRelativePath(path))
                    .font(Typo.evidence.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let vol = volume, let total = vol.totalBytes, let free = vol.freeBytes {
                FullnessGauge(free: free, total: total)
            }
            if model.inspecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading card…").font(Typo.evidence).foregroundStyle(.secondary)
                }
            } else if let ins = model.inspection {
                Text("\(ins.formatName) · \(ins.files) files · \(bytesString(ins.bytes))")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let job = runningJob {
                // The staged card keeps its slot while its job runs, so the
                // slot has to say so: a lock with no reason read as idle
                // next to a Running list that named every OTHER card
                // (Joshua, 2026-10-05, three cards copying at once).
                HStack(spacing: 6) {
                    if job.phase == .queued {
                        Image(systemName: "clock")
                            .foregroundStyle(Semantics.warningText)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(runningJobLine(job))
                        .font(Typo.evidence)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(runningJobLine(job))
            } else if let echo = sourceEcho {
                // Icon + color, never color alone: the three echo states sit
                // ΔE00 3.37 apart under deuteranopia (2026-08-28 color
                // audit). Same symbols as VerdictBadge so the vocabulary
                // stays one vocabulary.
                Label(echo, systemImage: echoSymbol)
                    .font(Typo.safety)
                    .foregroundStyle(echoColor)
            } else if !model.sourceMutationMonitoringActive {
                Label("live source monitoring unavailable — eject remains locked",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.dangerText)
            } else if model.sourceChangedSinceVerification {
                Label("source changed — verify again before removing",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Semantics.source.opacity(0.35)))
        .ejectGlide(isEjecting: volume.map {
            model.ejectingVolumePaths.contains($0.path)
        } ?? false)
        .contextMenu {
            if let vol = volume {
                Button("Choose Folder Inside \(vol.name)…") {
                    model.chooseFolder(inside: vol.path, as: .source)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .draggable(URL(fileURLWithPath: path))
    }

    /// The job currently moving this card's bytes, if any. jobs is
    /// newest-first, so a card started twice reports its latest run.
    private var runningJob: Job? {
        model.jobs.first { $0.isRunning && $0.sourcePath == path }
    }

    /// Rail echo: lowercase pointer computed from Job.verdict — never a
    /// second verdict vocabulary. A same-path verdict is insufficient: a card
    /// can be ejected, record new footage, and remount at that path. Only the
    /// current source-assignment session may echo its settled verdict. While a
    /// job for that session is running, the echo is suppressed. jobs is
    /// newest-first (insert at 0), so .first is the latest settled verdict.
    private var echoJob: Job? {
        guard let latest = model.runsNewestFirst({ $0.sourcePath == path }).first,
              !latest.isRunning,
              model.isCurrentSourceVerdict(latest) else { return nil }
        return latest
    }
    /// The latest settled job for this staging session whose wipe permission
    /// was withdrawn after the verdict: the rail says so instead of going
    /// silent (desktop QA round 5, R5-01).
    private var withdrawnJob: Job? {
        guard echoJob == nil,
              let latest = model.runsNewestFirst({ $0.sourcePath == path }).first,
              !latest.isRunning,
              latest.destinationAuthorityWithdrawn != nil,
              latest.verdictIsFresh(for: model.sourceAssignmentID) else { return nil }
        return latest
    }
    private var sourceEcho: String? {
        if let echo = echoJob?.currentCustodyEcho { return echo }
        if let withdrawn = withdrawnJob {
            // Ejecting a backup drive is the normal end of a day, not
            // damage: say which drive left, in amber, and keep red for a
            // copy that actually changed (Joshua, 2026-09-28).
            if let drive = withdrawn.ejectedDestinationName {
                return "\(drive) ejected, verify again before wiping"
            }
            return "wipe permission withdrawn, keep the card"
        }
        return nil
    }
    private var withdrawnByEjection: Bool {
        withdrawnJob?.destinationAuthorityWithdrawnByEjection == true
    }
    private var echoColor: Color {
        if withdrawnByEjection, echoJob?.hasCustodyFailure != true { return Semantics.warningText }
        if echoJob?.hasCustodyFailure == true || withdrawnJob != nil { return Semantics.dangerText }
        switch echoJob?.verdict {
        case .safeToWipe: return Semantics.successText
        case .verifiedKeepCard: return Semantics.warningText
        case .unverified, .failed: return Semantics.dangerText
        default: return .secondary
        }
    }
    private var echoSymbol: String {
        if withdrawnByEjection, echoJob?.hasCustodyFailure != true { return "eject.circle" }
        if echoJob?.hasCustodyFailure == true || withdrawnJob != nil { return "xmark.octagon.fill" }
        switch echoJob?.verdict {
        case .safeToWipe: return "checkmark.seal.fill"
        case .verifiedKeepCard: return "externaldrive.badge.exclamationmark"
        case .failed: return "xmark.octagon.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

/// A volume participating in a running job (not the staged source).
struct RunningRailRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    @Binding var forceEjectTarget: Volume?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sdcard.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.endpointDisplayName(path))
                    .font(.caption)
                    .lineLimit(1).truncationMode(.middle)
                if let job = model.jobs.first(where: { $0.isRunning && $0.sourcePath == path }) {
                    Text(runningJobLine(job))
                        .font(Typo.evidence).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: "lock.fill")
                .imageScale(.small)
                .foregroundStyle(Semantics.warningText)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
    }
}

/// One phrase for a card's live job, shared by the staged slot and the
/// Running rows so both rails speak the same way: "queued · A001" while it
/// waits, "in job A001 · copying + verifying" once the engine is up.
func runningJobLine(_ job: Job) -> String {
    job.phase == .queued
        ? "queued · \(job.label)"
        : "in job \(job.label) · \(job.phase.rawValue.lowercased())"
}

/// Empty-rail drop slot: the invitation IS the affordance — a dashed outline
/// where the endpoint will land, instead of a header shouting over an empty
/// list (2026-08-26 facelift). The rail itself remains the drop target;
/// unassigned hardware also waits on the center ConnectedShelf.
struct RailDropSlot: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(Typo.safetyBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(tint.opacity(0.35),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) — \(subtitle)")
    }
}

struct RailSectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.top, 4)
    }
}

/// 56pt icon spine for ⌥⌘J Focus on Jobs: drive glyph + lock + fill ring,
/// hover popover for the full row. The rail never disappears entirely — the
/// interlock stays visible even in focus mode.
struct RailSpine: View {
    @EnvironmentObject var model: AppModel
    let role: EndpointRole
    @Binding var forceEjectTarget: Volume?

    private var participants: [Volume] {
        model.volumes.filter { vol in
            model.jobs.contains { job in
                job.isRunning && (role == .source
                    ? pathIsAtOrInside(job.sourcePath, root: vol.path)
                    : job.destinations.contains { pathIsAtOrInside($0, root: vol.path) })
            } || (role == .source
                  ? model.sourcePath.map { pathIsAtOrInside($0, root: vol.path) } == true
                  : model.destinationPaths.contains { pathIsAtOrInside($0, root: vol.path) })
        }
    }

    private func spineLabel(_ vol: Volume) -> String {
        "\(vol.name), \(role == .source ? "source" : "destination")"
    }

    /// Everything the hover popover carries, for VoiceOver: lock state first
    /// (it is the interlock), then fill.
    private func spineValue(_ vol: Volume) -> String {
        var parts: [String] = []
        parts.append(model.canEject(vol)
            ? "not locked"
            : (role == .source
               ? "Transfer not verified — do not remove this volume"
               : "Participating in a transfer — do not remove"))
        if let total = vol.totalBytes, let free = vol.freeBytes, total > 0 {
            let pct = Int((Double(total - free) / Double(total) * 100).rounded())
            parts.append("\(pct) percent full, \(bytesString(free)) free")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: role == .source ? "arrow.up.forward.square" : "arrow.down.forward.square")
                .foregroundStyle(role == .source ? Semantics.sourceText : Semantics.destinationText)
                .padding(.top, 10)
                .accessibilityLabel(role == .source ? "Sources rail, collapsed"
                                                    : "Destinations rail, collapsed")
            ForEach(participants) { vol in
                VStack(spacing: 2) {
                    Image(systemName: role == .source ? "sdcard.fill" : "externaldrive.fill")
                        .foregroundStyle(.secondary)
                    if !model.canEject(vol) {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(Semantics.warningText)
                    }
                }
                .help("\(spineLabel(vol)) — \(spineValue(vol))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spineLabel(vol))
                .accessibilityValue(spineValue(vol))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A shelf selection shares one payload; Finder URLs import as single items.
struct ShelfDragPayload: Codable, Transferable {
    let paths: [String]
    static let contentType = UTType(exportedAs: "tv.mindinmotion.dumptruck.shelf-paths", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
        ProxyRepresentation(importing: { (url: URL) in
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            return ShelfDragPayload(paths: [url.path])
        })
    }
}
