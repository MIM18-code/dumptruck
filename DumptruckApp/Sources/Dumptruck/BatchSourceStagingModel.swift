import Foundation
import SwiftUI

/// Exact state vocabulary used by the batch sheet. A refused candidate never
/// silently becomes queueable after another candidate succeeds. It stays in
/// the list with its reason while the Ready cards start without it: one
/// card's problem never holds back a dump (issue #25, 2026-11-11).
enum BatchCandidateStatus: Equatable {
    case pending
    /// Nothing is wrong with the card: no destination is chosen yet, so
    /// there is nothing to preflight against. Shown as a wait, not a
    /// refusal (Joshua, 2026-09-28: red "Refused" on every card he dragged
    /// in before picking drives). Never queueable, like .pending.
    case awaitingDestinations
    case inspecting
    case ready
    case refused(String)
}

final class BatchSourceCandidate: ObservableObject, Identifiable {
    let id: UUID
    let originalPath: String
    let path: String
    let volumeName: String
    /// What the batch list calls this source: a pick by where it came from.
    var displayName: String { LooseSourceStaging.displayName(for: path) ?? volumeName }
    let assignmentID: UUID

    @Published var status: BatchCandidateStatus = .pending
    @Published var inspection: CardInspection?
    @Published var customLabel: String
    @Published var projectedLanes: [String] = []
    /// Set when the card copies under a numbered name, and says why
    /// ("Copying to "NO NAME_2": …"), so the DIT sees it before Start
    /// (Joshua, 2026-09-28).
    @Published var renameNote: String?
    var identityPin: FileIdentityPin?
    /// Why the last preflight held this card out, or nil when it passed.
    /// Only a new preflight (Re-check, a destination change, a card added)
    /// clears it: a label edit must not turn the card Ready on a read that
    /// failed or went stale.
    var preflightRefusal: String?
    /// The name the batch last wrote into the field itself. While the field
    /// still holds exactly that, the name is the batch's to change; anything
    /// else in the field (typed before the read finished, edited, cleared)
    /// is the operator's and is never renamed.
    private(set) var autoLabel: String?

    var labelIsAutomatic: Bool {
        guard let autoLabel else { return false }
        return customLabel == autoLabel
    }

    /// Write a name the batch chose. The field shows it, and it stays
    /// automatic until someone changes it.
    func seedAutomaticLabel(_ label: String) {
        autoLabel = label
        customLabel = label
    }

    /// The numbered name a typed name was given because it was taken
    /// ("CAM_B_2" for "CAM_B"), and the field text it was given for. The
    /// field keeps what the operator typed, which stays the base for the
    /// next check, so "CAM_B" never grows into "CAM_B_2_2". Any edit to the
    /// field makes it stale (Joshua, 2026-11-09: number a taken name, never
    /// refuse it).
    private var assignedLabel: (label: String, forText: String)?

    /// Record the name the batch gave a typed name, or nil when the card
    /// copies under the typed name itself.
    func assignNumberedLabel(_ label: String?) {
        assignedLabel = label.map { ($0, customLabel) }
    }

    init(path: String, originalPath: String? = nil, assignmentID: UUID = UUID()) {
        self.id = UUID()
        self.originalPath = originalPath ?? path
        self.path = path
        self.volumeName = LooseSourceStaging.templateVolumeName(for: path)
        self.assignmentID = assignmentID
        self.customLabel = ""
    }

    /// Before inspection the field is empty and the suggestion stands in.
    /// Preflight seeds the field with the suggestion; from then on the field
    /// is what the operator sees, so a field they cleared is an empty label
    /// and gets the empty-label error, never a silent fallback (Codex
    /// desktop QA round 2, 2026-09-15, R2-02).
    var typedLabel: String {
        let edited = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if inspection != nil { return edited }
        if !edited.isEmpty { return edited }
        return ""
    }

    /// The name the card is queued under and its folder carries: the
    /// field's text, or the numbered name the batch gave it.
    var effectiveLabel: String {
        if let assignedLabel, assignedLabel.forText == customLabel { return assignedLabel.label }
        return typedLabel
    }

    var statusText: String {
        switch status {
        case .pending: return "Pending"
        case .awaitingDestinations: return "Waiting for destinations"
        case .inspecting: return "Inspecting…"
        case .ready: return "Ready"
        case .refused(let reason): return "Refused — " + reason
        }
    }
}

enum BatchQueueError: Error, Equatable, CustomStringConvertible {
    case emptyBatch
    case notReady
    case preflightFailed(String)
    case planFailed(String)
    case sourceChanged(String)
    case monitorFailed(String)
    case journalPersistenceFailed(String)
    case recoveryBlocked(String)

    var description: String {
        switch self {
        case .emptyBatch: return "No sources are staged."
        case .notReady: return "No staged card is ready to start yet."
        case .preflightFailed(let message): return message
        case .planFailed(let message): return message
        case .sourceChanged(let path): return "Source changed while staging: " + path
        case .monitorFailed(let message): return message
        case .journalPersistenceFailed(let message): return message
        case .recoveryBlocked(let message): return message
        }
    }
}

/// A staged loose-files set runs with --loose-files: no card identity,
/// no continuation (AppModel.inspect clears the same fields). The
/// engine's inspect sees a plain folder and could still match a card's
/// anchors, so the batch must not let it "continue" into that card's
/// folder either.
private struct LooseAwareBatchInspector: BatchSourceInspector {
    let base: StandardBatchSourceInspector

    func inspect(sourcePath: String, pin: FileIdentityPin) async throws -> BatchInspectionResult {
        let result = try await base.inspect(sourcePath: sourcePath, pin: pin)
        guard LooseSourceStaging.isStagedSet(sourcePath) else { return result }
        var properties = result.metadata.customProperties
        properties["known"] = "false"
        properties["mounts"] = "0"
        properties["previous_destinations_count"] = "0"
        return BatchInspectionResult(
            protocolVersion: result.protocolVersion,
            metadata: CardInspectionMetadata(
                label: LooseSourceStaging.suggestedLabel(for: sourcePath) ?? result.metadata.label,
                totalBytes: result.metadata.totalBytes,
                fileCount: result.metadata.fileCount,
                customProperties: properties,
                previousDestinations: [],
                datasetID: nil))
    }
}

/// Main-actor coordinator for the multiple-source sheet. It owns no source
/// bytes and never calls AppModel.setSource/inspect; every candidate is an
/// independent assignment with its own identity pin and template context.
@MainActor
final class BatchSourceStagingModel: ObservableObject {
    @Published var candidates: [BatchSourceCandidate] = []
    @Published var isInspecting = false
    @Published var generalError: String?
    /// Something the operator should know that is not a fault: a card they
    /// picked was left out because it is already copying.
    @Published var notice: String?
    /// The engine's card record, read once per revalidation pass. Checks
    /// replace it so they never read the real one.
    var cardRegistry: () -> [CardFolderClaims.Record] = { CardFolderClaims.loadRegistry() }

    private var inspectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var labelRevalidation: Task<Void, Never>?

    var readyCount: Int {
        candidates.filter { $0.status == .ready }.count
    }

    var totalCandidateBytes: Int64 {
        candidates.compactMap { $0.inspection?.bytes }.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    var totalCandidateFiles: Int {
        candidates.compactMap { $0.inspection?.files }.reduce(0, +)
    }

    /// The card statuses alone: every card preflighted and Ready. This is
    /// what enables Start. A banner left over from an earlier failed queue
    /// attempt must not keep the button disabled after its cause is fixed
    /// (Joshua, 2026-09-28); queueBatch clears it and re-checks before
    /// anything is queued, so the stricter canQueueBatch still guards the edge.
    var cardsReadyToQueue: Bool {
        !candidates.isEmpty && !isInspecting
            && candidates.allSatisfy { $0.status == .ready }
    }

    var canQueueBatch: Bool {
        cardsReadyToQueue && generalError == nil
    }

    /// Start has something to copy: no read in flight and at least one
    /// Ready card. Cards that are not Ready stay staged.
    var canStartReadyCards: Bool {
        !isInspecting && readyCount > 0
    }

    /// The refused cards and why, in list order.
    var refusedCards: [(name: String, reason: String)] {
        candidates.compactMap { candidate in
            if case .refused(let reason) = candidate.status {
                return (candidate.displayName, reason)
            }
            return nil
        }
    }

    /// What the batch window's banner shows: a problem that is not already
    /// written on a card's own row. Every refused card says why on its row,
    /// so a banner repeating one of them said it three times with the chip.
    /// One reason shared by every card is about the batch, and keeps the
    /// banner as its headline.
    var bannerError: String? {
        guard let generalError else { return nil }
        let reasons = refusedCards.map(\.reason)
        guard reasons.contains(where: { generalError.contains($0) }) else { return generalError }
        let batchWide = candidates.count > 1 && reasons.count == candidates.count
            && Set(reasons).count == 1
        return batchWide ? generalError : nil
    }

    /// Cards the last Start left staged because the queue-edge check gave
    /// them a name the operator had not seen yet.
    private var renamedAtLastStart = 0

    /// One line for the cards a Start left in the batch.
    var heldBackLine: String? {
        if renamedAtLastStart > 0 {
            return (renamedAtLastStart == 1
                    ? "1 card got a new name at the last check and stayed in the batch."
                    : "\(renamedAtLastStart) cards got a new name at the last check and stayed in the batch.")
                + " Check the names and press Start again."
        }
        let refused = refusedCards
        guard let first = refused.first else { return nil }
        return refused.count == 1
            ? "\(first.name) stayed in the batch: \(first.reason)"
            : "\(refused.count) cards stayed in the batch. \(first.name): \(first.reason)"
    }

    /// Cards not yet Ready: pending, waiting, inspecting, or refused.
    var notReadyCount: Int {
        candidates.count - readyCount
    }

    var hasRefusedCard: Bool {
        candidates.contains {
            if case .refused = $0.status { return true }
            return false
        }
    }

    func addCandidates(paths: [String], appModel: AppModel) {
        let existing = Set(candidates.map(\.path))
        var seen = existing
        // A card with a queued or running job is not a candidate. The rail
        // drop already refuses it; the folder pickers used to let it in, and
        // the preflight then refused every card in the list (issue #24).
        let copying = Set(appModel.jobs.filter(\.isRunning).map(\.sourcePath))
        var leftOut: [String] = []
        for original in paths {
            let normalized = StandardPurePathNormalizer.normalize(
                original.trimmingCharacters(in: .whitespacesAndNewlines))
            guard normalized.hasPrefix("/"), !normalized.isEmpty, !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            if copying.contains(normalized) {
                leftOut.append(LooseSourceStaging.displayName(for: normalized)
                    ?? LooseSourceStaging.templateVolumeName(for: normalized))
                continue
            }
            candidates.append(BatchSourceCandidate(path: normalized, originalPath: original))
        }
        generalError = nil
        notice = Self.alreadyCopyingNotice(leftOut)
        if !candidates.isEmpty { startSerialInspection(appModel: appModel) }
    }

    /// "A001 is already copying, so it was not added."
    static func alreadyCopyingNotice(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is already copying, so it was not added."
        default:
            let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            return "\(list) are already copying, so they were not added."
        }
    }

    func removeCandidate(id: UUID, appModel: AppModel) {
        inspectionTask?.cancel()
        inspectionTask = nil
        candidates.removeAll { $0.id == id }
        generalError = nil
        notice = nil
        if !candidates.isEmpty {
            startSerialInspection(appModel: appModel)
        } else {
            isInspecting = false
        }
    }

    /// Cards that already have a queued or running job leave the batch.
    /// Queueing one again made a second job for the same folder, which the
    /// engine refused and the job list showed as FAILED (Joshua, 2026-11-10).
    func dropCandidatesAlreadyCopying(appModel: AppModel) {
        let active = Set(appModel.jobs.filter(\.isRunning).map(\.sourcePath))
        let copying = candidates.filter { active.contains($0.path) }
        guard !copying.isEmpty else { return }
        // Removed in place: the other cards keep the preflight they passed,
        // so the same click can still start them.
        candidates.removeAll { active.contains($0.path) }
        if candidates.isEmpty {
            inspectionTask?.cancel()
            inspectionTask = nil
            isInspecting = false
        }
        objectWillChange.send()
    }

    func cancelStaging() {
        inspectionTask?.cancel()
        inspectionTask = nil
        labelRevalidation?.cancel()
        labelRevalidation = nil
        generation = UUID()
        isInspecting = false
        candidates.removeAll()
        generalError = nil
        notice = nil
    }

    /// Re-check cheap, non-mutating facts after the sheet appears or a label
    /// is edited. Full protocol inspection remains serial and is only started
    /// for pending candidates; this method never writes destination folders.
    ///
    /// Card names are settled here, per card, every time. A shared or taken
    /// name used to refuse the whole pile from the preflight, and a label
    /// edit never re-ran that check, so the operator could not rename their
    /// way out (Joshua, 2026-09-28). Now every taken name is numbered past
    /// the clash, typed names and known cards' names included: a naming
    /// question never stops a copy (Joshua, 2026-11-09). A typed name keeps
    /// its text in the field and copies under the numbered name.
    func revalidateAll(appModel: AppModel) {
        guard !isInspecting else { return }
        var firstError: String?
        let d = UserDefaults.standard
        let roots = appModel.destinationPaths
        guard !roots.isEmpty else {
            holdForDestinations()
            return
        }
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""

        // Per-card facts first. A card that fails one never takes part in
        // naming, so it cannot hold a name another card needs.
        var named: [BatchSourceCandidate] = []
        var entries: [BatchLabelAllocator.Entry] = []
        for candidate in candidates {
            // A destination selection or label can change between checks;
            // never leave lanes from the previous context visible while the
            // new one is being validated.
            candidate.projectedLanes = []
            if let reason = candidate.preflightRefusal {
                candidate.status = .refused(reason)
                candidate.renameNote = nil
                firstError = firstError ?? (candidate.displayName + ": " + reason)
                continue
            }
            guard let pin = candidate.identityPin,
                  let inspection = candidate.inspection else {
                if case .ready = candidate.status { candidate.status = .pending }
                continue
            }
            guard identityStillHolds(candidate.path, pin: pin) else {
                let message = "source was removed, replaced, or became a symlink"
                candidate.status = .refused(message)
                candidate.renameNote = nil
                firstError = firstError ?? ("Batch preflight refused: " + candidate.path + " " + message + ".")
                continue
            }
            // An automatic name starts again from the engine's suggestion,
            // so a card renamed only because of another card gets its own
            // name back once that card is renamed or removed.
            let automatic = candidate.labelIsAutomatic
            let label = automatic
                ? inspection.suggestedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                : candidate.typedLabel
            if let reason = validateLabel(label) {
                candidate.status = .refused(reason)
                candidate.renameNote = nil
                firstError = firstError ?? reason
                continue
            }
            named.append(candidate)
            entries.append(BatchLabelAllocator.Entry(
                source: candidate.path, displayName: candidate.displayName,
                label: label, fixed: !automatic || inspection.known))
        }

        // Stale until this pass gives the card a name again.
        candidates.forEach { $0.assignNumberedLabel(nil) }
        let registry = cardRegistry()
        // Folders a queued or running job is already writing. The engine
        // refuses a second writer, so they are taken, the same rule
        // single-card Start applies (AppModel.planUnderFreeName).
        let busy = Set(appModel.jobs.filter(\.isRunning)
            .flatMap(appModel.verdictLaneRoots).map(BatchCardNaming.labelKey))
        var allocator = BatchLabelAllocator(entries: entries)
        while let request = allocator.nextRequest() {
            let candidate = named[request.index]
            // The folder-template check single-card Start runs, with the same
            // inputs and message. Rendering alone turned an unset {Project}
            // into "Raws", so a batch queued into a different folder tree than
            // Start would have refused (Joshua, 2026-09-28).
            if let reason = Self.templateRefusal(
                template: template, project: project,
                volumeName: candidate.volumeName, label: request.label,
                cameraFormat: candidate.inspection?.formatName ?? "",
                reel: candidate.inspection?.reelName ?? "") {
                allocator.answer(.refuse(reason))
                continue
            }
            var probes: [BatchLabelAllocator.LaneProbe] = []
            var rootInvalid = false
            // Picked files have no card record, so nothing on record is theirs.
            let datasetID = LooseSourceStaging.isStagedSet(candidate.path)
                ? nil : candidate.inspection?.datasetID
            for root in roots {
                guard let lane = projectedLane(root: root, label: request.label,
                                               candidate: candidate, appModel: appModel) else {
                    rootInvalid = true
                    break
                }
                // The engine's rule, the one single-card Start uses: a
                // folder is taken only when it holds files another card
                // on record wrote (or, unclaimed, carries its name).
                let foreign = busy.contains(BatchCardNaming.labelKey(lane))
                    || CardFolderClaims.isTaken(
                        lane: lane, label: request.label, datasetID: datasetID, registry: registry)
                probes.append(BatchLabelAllocator.LaneProbe(path: lane, foreign: foreign))
            }
            allocator.answer(rootInvalid
                ? .refuse("destination root is invalid; reselect destinations")
                : .lanes(probes))
        }

        for (index, candidate) in named.enumerated() {
            switch allocator.outcomes[index] {
            case let .assigned(label, lanes, renamedFrom, reason)?:
                if candidate.labelIsAutomatic {
                    if candidate.customLabel != label { candidate.seedAutomaticLabel(label) }
                } else {
                    // The field keeps the typed text; the card copies under
                    // the numbered name.
                    candidate.assignNumberedLabel(label == candidate.typedLabel ? nil : label)
                }
                candidate.renameNote = renamedFrom.map {
                    BatchLabelAllocator.renameNote(from: $0, to: label, reason: reason)
                }
                candidate.projectedLanes = lanes
                candidate.status = .ready
            case let .refused(reason)?:
                candidate.status = .refused(reason)
                candidate.renameNote = nil
                firstError = firstError ?? reason
            case nil:
                // The allocator settles every card; fail closed regardless.
                let reason = "card name could not be checked; press Re-check"
                candidate.status = .refused(reason)
                candidate.renameNote = nil
                firstError = firstError ?? reason
            }
        }
        generalError = firstError
        objectWillChange.send()
    }

    func updateLabel(id: UUID, newLabel: String, appModel: AppModel) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        labelRevalidation?.cancel()
        labelRevalidation = nil
        candidate.customLabel = newLabel
        revalidateAll(appModel: appModel)
    }

    /// Typing in a label field re-checks once the operator pauses, not on
    /// every keystroke: each check touches the disk, and a half-typed or
    /// momentarily empty label flashed a red Refused banner while they were
    /// still typing (Joshua, 2026-09-28). Nothing can queue on the stale
    /// verdict in between: queueBatch re-runs revalidateAll at the edge.
    func scheduleLabelRevalidation(appModel: AppModel, delayNanoseconds: UInt64 = 300_000_000) {
        labelRevalidation?.cancel()
        labelRevalidation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.labelRevalidation = nil
            self.revalidateAll(appModel: appModel)
        }
    }

    /// The same template check AppModel.startBlockedReason runs for a single
    /// card: an empty template needs nothing, and "?" (unknown format) counts
    /// as no format. jobID is a placeholder; it is generated at queue time.
    static func templateRefusal(template: String, project: String, volumeName: String,
                                label: String, cameraFormat: String, reel: String,
                                date: Date = Date()) -> String? {
        guard !template.isEmpty else { return nil }
        let context = TemplateContext(
            project: project, volumeName: volumeName, cardLabel: label, date: date,
            cameraFormat: (cameraFormat == "?" ? "" : cameraFormat).replacingOccurrences(of: "/", with: "-"),
            reel: reel, jobID: "VALIDATION")
        return TemplateRenderer.validate(template, context: context)
    }

    /// Sources the preflight's overlap gate treats as active. The CURRENTLY
    /// STAGED source counts too: a batch candidate inside it could otherwise
    /// queue and run concurrently with the manual job for its parent (codex
    /// v0.4.x review, F4). Except when the staged card IS a candidate: a drop
    /// onto an occupied rail promotes it into this batch, and listing it as
    /// active made it overlap with itself and refuse the whole sheet (Opus
    /// review 2026-09-15, finding 1). A candidate nested inside the staged
    /// card is still caught by the prefix test.
    static func activeSourcePaths(runningSources: [String], staged: String?,
                                  candidates: [String]) -> [String] {
        guard let staged, !candidates.contains(staged) else { return runningSources }
        return runningSources + [staged]
    }

    /// No destinations: park every card as waiting, with no error banner.
    /// The engine preflight needs destination roots, and a missing choice
    /// is a step still to take, not a fault in the card.
    private func holdForDestinations() {
        inspectionTask?.cancel()
        inspectionTask = nil
        generation = UUID()
        isInspecting = false
        generalError = nil
        for candidate in candidates {
            candidate.projectedLanes = []
            candidate.status = .awaitingDestinations
        }
        objectWillChange.send()
    }

    /// The protocol-3 preflight for the staged cards. The core checks one
    /// set of cards all-or-nothing; when it refuses over a single card
    /// (pulled, unreadable, inside a card that is copying), that card is
    /// held out with its reason and the rest are checked again without it.
    /// The inspector is a detached value and the result is applied only if
    /// this run's generation is still current, so stale cards cannot leak
    /// into a later batch.
    func startSerialInspection(appModel: AppModel) {
        // A card that started copying since it was staged is no longer a
        // candidate; left in, it overlaps its own job and is refused.
        dropCandidatesAlreadyCopying(appModel: appModel)
        guard !candidates.isEmpty else { return }
        guard !appModel.destinationPaths.isEmpty else {
            holdForDestinations()
            return
        }
        inspectionTask?.cancel()
        generation = UUID()
        let runGeneration = generation
        isInspecting = true
        generalError = nil
        candidates.forEach {
            $0.status = .inspecting
            $0.preflightRefusal = nil
        }

        let paths = candidates.map(\.path)
        let roots = appModel.destinationPaths
        let activeSources = Self.activeSourcePaths(
            runningSources: appModel.jobs.filter { $0.isRunning }.map(\.sourcePath),
            staged: appModel.sourcePath,
            candidates: paths)
        let inspector = LooseAwareBatchInspector(base: StandardBatchSourceInspector(
            enginePython: appModel.enginePython,
            engineRoot: appModel.engineRoot
        ))
        let core = BatchSourceStagingCore(
            fileSystem: StandardBatchSourceFileSystem(),
            inspector: inspector,
            options: BatchSourceStagingOptions(expectedProtocolVersion: EngineContract.protocolVersion)
        )

        let d = UserDefaults.standard
        let mirrored = appModel.destinationFolderRelativePath
        let exactRoots = appModel.exactDestinationRoots.filter { roots.contains($0) }
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""
        let laneBase: BatchSourceStagingCore.LaneBase = { root, label, inspection, sourcePath in
            Self.laneBase(
                root: root, label: label,
                volumeName: LooseSourceStaging.templateVolumeName(for: sourcePath),
                cameraFormat: inspection.metadata.customProperties["format_name"] ?? "",
                reel: inspection.metadata.customProperties["reel_name"] ?? "",
                mirroredFolder: mirrored, exactRoots: exactRoots,
                template: template, project: project)
        }
        inspectionTask = Task { [weak self] in
            let outcome = await Self.preflightHoldingOutRefusedCards(paths: paths) { remaining in
                try await core.stageBatch(
                    candidateSourcePaths: remaining,
                    destinationRoots: roots,
                    existingActiveSourcePaths: activeSources,
                    laneBase: laneBase
                )
            }
            guard !Task.isCancelled, let self, self.generation == runGeneration else { return }
            switch outcome {
            case let .checked(staged, heldOut):
                self.applyPreflight(staged, heldOut: heldOut, appModel: appModel)
            case .failed(let message):
                self.isInspecting = false
                self.generalError = message
                self.candidates.forEach {
                    $0.preflightRefusal = message
                    $0.status = .refused(message)
                    $0.projectedLanes = []
                }
                self.objectWillChange.send()
            }
        }
    }

    enum PreflightOutcome {
        /// The cards that passed, and the ones held out with their reasons.
        case checked([BatchStagedSourceItem], heldOut: [String: String])
        /// A refusal that is not about one card (timeout, engine mismatch).
        case failed(String)
    }

    /// Runs `stage` on the cards, and again without the offending card each
    /// time it refuses over one. Every pass removes a card, so it ends.
    static func preflightHoldingOutRefusedCards(
        paths: [String],
        stage: ([String]) async throws -> [BatchStagedSourceItem]
    ) async -> PreflightOutcome {
        var remaining = paths
        var heldOut: [String: String] = [:]
        while !remaining.isEmpty {
            do {
                return .checked(try await stage(remaining), heldOut: heldOut)
            } catch {
                let stagingError = error as? BatchSourceStagingError
                guard let stagingError,
                      let refusal = cardRefusal(for: stagingError),
                      remaining.contains(refusal.path) else {
                    return .failed(stagingError?.description ?? "Batch source preflight failed.")
                }
                heldOut[refusal.path] = refusal.reason
                remaining.removeAll { $0 == refusal.path }
            }
        }
        return .checked([], heldOut: heldOut)
    }

    /// The one card a preflight refusal is about, and a short reason for
    /// its row. Nil for refusals about the whole batch.
    nonisolated static func cardRefusal(for error: BatchSourceStagingError) -> (path: String, reason: String)? {
        func name(_ path: String) -> String {
            LooseSourceStaging.displayName(for: path) ?? (path as NSString).lastPathComponent
        }
        switch error {
        case let .sourceNotFound(path):
            return (path, "source is no longer there; reconnect it and press Re-check")
        case let .sourceNotDirectory(path):
            return (path, "source is not a folder")
        case let .sourceIsSymlink(path):
            return (path, "source is a symbolic link, which cannot be copied from")
        case let .sourceIdentityChanged(path):
            return (path, "source was removed or replaced while it was being read")
        case let .inspectionFailed(path, message):
            return (path, "card could not be read: " + message)
        case let .inspectionMetadataOutOfBounds(path):
            return (path, "card details were too large to read")
        case let .invalidPath(path, reason):
            return (path, "path cannot be used: " + reason)
        case let .pathLengthExceeded(path, _, _):
            return (path, "path is too long")
        case let .emptyLabel(path):
            return (path, "no card name could be read; type one and press Re-check")
        case let .duplicateCandidatePin(_, firstSource, secondSource):
            return (secondSource, "is the same folder as " + name(firstSource))
        case let .mutualSourceOverlap(source1, source2):
            return (source2, "overlaps " + name(source1) + ": one is inside the other")
        case let .sourceDestinationOverlap(source, destination):
            return (source, "overlaps the destination " + name(destination))
        case let .activeSourceOverlap(source, activeSource):
            return (source, "overlaps " + name(activeSource) + ", which is staged or copying")
        case .emptyCandidates, .emptyDestinations, .candidateLimitExceeded,
             .labelLengthExceeded, .invalidLabel, .duplicateCandidatePath,
             .duplicateLabel, .destinationLaneCollision, .existingDestinationLaneConflict,
             .protocolMismatch, .timeout, .cancelled:
            return nil
        }
    }

    /// Queue every Ready card. Cards that are not Ready stay staged with
    /// their reason, and `generalError` names the first one. Fails only when
    /// no card can start.
    @discardableResult
    func queueBatch(appModel: AppModel) -> Result<[Job], BatchQueueError> {
        // Start is gated on the cards, not the banner. A message from an
        // earlier failed attempt (journal write, plan refusal) is stale once
        // the operator tries again; the checks below re-derive every current
        // refusal before anything is queued.
        labelRevalidation?.cancel()
        labelRevalidation = nil
        generalError = nil
        notice = nil
        renamedAtLastStart = 0
        dropCandidatesAlreadyCopying(appModel: appModel)
        // Every card was already copying: nothing left to start.
        if candidates.isEmpty { return .success([]) }
        guard !appModel.destinationPaths.isEmpty else {
            let error = BatchQueueError.preflightFailed("Select at least one destination before queueing the batch.")
            generalError = error.description
            return .failure(error)
        }
        guard !isInspecting else {
            let error = BatchQueueError.notReady
            generalError = error.description
            return .failure(error)
        }

        // Re-check identity and labels at the exact queue edge. A card can be
        // removed/reinserted after inspection; no stale metadata may become a
        // persisted job merely because the UI still says Ready. Only a card
        // that was Ready before this check and still is can start: the
        // operator saw its name.
        let namesShown = Dictionary(uniqueKeysWithValues: candidates
            .filter { $0.status == .ready }.map { ($0.id, $0.effectiveLabel) })
        revalidateAll(appModel: appModel)
        let stillReady = candidates.filter { $0.status == .ready && namesShown[$0.id] != nil }
        guard !stillReady.isEmpty else {
            let error = namesShown.isEmpty && generalError == nil
                ? BatchQueueError.notReady
                : BatchQueueError.preflightFailed(
                    generalError ?? "Batch preflight changed; re-inspect before queueing.")
            generalError = error.description
            return .failure(error)
        }
        // The re-check can renumber an automatic name (a folder appeared on
        // the destination meanwhile, or the card holding the plain name was
        // just refused). Never queue a folder name the operator did not see:
        // that card stays staged under its new name for the next Start, and
        // the cards whose names held still go (Sol review, 2026-11-11: one
        // renumbered card used to stop them all).
        let startable = stillReady.filter { namesShown[$0.id] == $0.effectiveLabel }
        renamedAtLastStart = stillReady.count - startable.count
        guard !startable.isEmpty else {
            let error = BatchQueueError.preflightFailed(
                "A card name changed at the last check. Check the names and press Start again.")
            generalError = error.description
            return .failure(error)
        }

        let now = Date()
        let defaults = UserDefaults.standard
        let project = defaults.string(forKey: Pref.projectName) ?? ""
        var planPairs: [(candidate: BatchSourceCandidate, plan: AppModel.LaunchPlan)] = []
        var planRefusals: [(candidate: BatchSourceCandidate, reason: String)] = []
        for candidate in startable {
            // revalidateAll never leaves a card Ready without its inspection.
            guard let inspection = candidate.inspection else { continue }
            let label = candidate.effectiveLabel
            let jobID = String(UUID().uuidString.prefix(8)).uppercased()
            let context = TemplateContext(
                project: project,
                volumeName: candidate.volumeName,
                cardLabel: label,
                date: now,
                cameraFormat: inspection.formatName.replacingOccurrences(of: "/", with: "-"),
                reel: inspection.reelName,
                jobID: jobID
            )
            switch appModel.buildPlan(
                src: candidate.path,
                rawRoots: appModel.destinationPaths,
                cardLabel: label,
                fast: false,
                inspection: inspection,
                context: context
            ) {
            case .failure(let error):
                planRefusals.append((candidate, error.message))
            case .success(let plan):
                planPairs.append((candidate: candidate, plan: plan))
            }
        }
        func markPlanRefusals() {
            for refusal in planRefusals { refusal.candidate.status = .refused(refusal.reason) }
            if let first = planRefusals.first { generalError = generalError ?? first.reason }
        }
        guard !planPairs.isEmpty else {
            markPlanRefusals()
            let error = BatchQueueError.planFailed(
                planRefusals.first?.reason ?? BatchQueueError.notReady.description)
            generalError = error.description
            return .failure(error)
        }

        let result = appModel.queueBatch(plans: planPairs)
        switch result {
        case .success:
            let queued = Set(planPairs.map { $0.candidate.id })
            candidates.removeAll { queued.contains($0.id) }
            generalError = nil
            // The cards left behind are named against the folders the new
            // jobs now hold, and keep their reasons.
            if !candidates.isEmpty { revalidateAll(appModel: appModel) }
            markPlanRefusals()
            if renamedAtLastStart > 0 { generalError = heldBackLine }
        case .failure(let error):
            markPlanRefusals()
            generalError = error.description
        }
        return result
    }

    /// Apply a finished preflight: cards that passed take their inspection,
    /// cards held out take their reason. Package visibility for the checks.
    func applyPreflight(_ staged: [BatchStagedSourceItem], heldOut: [String: String] = [:],
                        appModel: AppModel) {
        let byPath = Dictionary(staged.map { ($0.normalizedSourcePath, $0) },
                                uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            guard let item = byPath[candidate.path] else {
                let reason = heldOut[candidate.path] ?? "source was not returned by preflight"
                candidate.preflightRefusal = reason
                candidate.status = .refused(reason)
                candidate.projectedLanes = []
                continue
            }
            candidate.preflightRefusal = nil
            // suggestedLabel is the engine's own suggestion, not the name the
            // preflight picked: revalidateAll numbers automatic names from
            // it, so a card gets its plain name back when the clash goes.
            // known/previousDestinations tell a card continuing into its own
            // folder from a different card with the same name.
            let inspection = CardInspection(
                format: item.metadata.customProperties["format"] ?? "",
                formatName: item.metadata.customProperties["format_name"] ?? "?",
                reelName: item.metadata.customProperties["reel_name"] ?? "",
                suggestedLabel: item.suggestedLabel,
                known: item.metadata.isKnownCard,
                datasetID: item.metadata.datasetID,
                mounts: Int(item.metadata.customProperties["mounts"] ?? "0") ?? 0,
                files: item.metadata.fileCount,
                bytes: item.metadata.totalBytes,
                previousDestinations: item.metadata.previousDestinations
            )
            candidate.inspection = inspection
            candidate.identityPin = item.identityPin
            // An empty field, or one still holding a name the batch chose,
            // takes this run's name. A typed name stays.
            if candidate.labelIsAutomatic
                || candidate.customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate.seedAutomaticLabel(item.label)
            }
            candidate.status = .ready
        }
        isInspecting = false
        revalidateAll(appModel: appModel)
    }

    private func validateLabel(_ label: String) -> String? {
        CardLabelRules.validate(label)
    }

    /// The lane the launch will actually write: root, then the mirrored
    /// folder, then the rendered folder template, then the label. The
    /// preview used to show root/label and hid the organization folders
    /// (Codex desktop QA round 2, 2026-09-15, R2-03). {Date} renders for
    /// now and {JobID} for a placeholder; queueBatch renders the real ones.
    /// `exactRoots` are extra folders on a drive that is already a
    /// destination: they take neither the mirrored folder nor the Organize
    /// template, exactly as buildPlan projects them, so batch collision
    /// checks look where launch writes.
    static func laneBase(root: String, label: String, volumeName: String,
                         cameraFormat: String, reel: String,
                         mirroredFolder: String, exactRoots: [String] = [],
                         template: String, project: String,
                         date: Date = Date()) -> String {
        let context = TemplateContext(
            project: project, volumeName: volumeName, cardLabel: label, date: date,
            cameraFormat: (cameraFormat == "?" ? "" : cameraFormat).replacingOccurrences(of: "/", with: "-"),
            reel: reel, jobID: "PREVIEW")
        let organization = TemplateRenderer.render(template, context: context)
        return DestinationFolderProjection.project(
            root: root,
            mirroredFolder: DestinationFolderProjection.mirroredFolder(
                mirroredFolder, for: root, exactRoots: exactRoots),
            organizationFolder: DestinationFolderProjection.organizationFolder(
                organization, for: root, exactRoots: exactRoots))
    }

    private func projectedLane(root: String, label: String,
                               candidate: BatchSourceCandidate, appModel: AppModel) -> String? {
        let d = UserDefaults.standard
        let base = Self.laneBase(
            root: root, label: label, volumeName: candidate.volumeName,
            cameraFormat: candidate.inspection?.formatName ?? "",
            reel: candidate.inspection?.reelName ?? "",
            mirroredFolder: appModel.destinationFolderRelativePath,
            exactRoots: appModel.exactDestinationRoots,
            template: d.string(forKey: Pref.folderTemplate) ?? "",
            project: d.string(forKey: Pref.projectName) ?? "")
        return BatchDestinationLanePath.make(destinationRoot: base, label: label)
    }

    private func identityStillHolds(_ path: String, pin: FileIdentityPin) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeDirectory,
              let dev = attrs[.systemNumber] as? NSNumber,
              let ino = attrs[.systemFileNumber] as? NSNumber else { return false }
        let current = FileIdentityPin(
            deviceId: dev.uint64Value,
            fileId: ino.uint64Value,
            volumeUUID: (try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        )
        return current == pin
    }
}
