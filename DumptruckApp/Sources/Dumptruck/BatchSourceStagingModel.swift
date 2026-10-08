import Foundation
import SwiftUI

/// Exact state vocabulary used by the batch sheet. A refused candidate never
/// silently becomes queueable after another candidate succeeds: the whole
/// batch must pass preflight together.
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
    let assignmentID: UUID

    @Published var status: BatchCandidateStatus = .pending
    @Published var inspection: CardInspection?
    @Published var customLabel: String
    @Published var projectedLanes: [String] = []
    /// Set when the batch picked a different name than the engine
    /// suggested, and says why ("Renamed from "NO NAME": …"), so the DIT
    /// sees the rename before Start (Joshua, 2026-09-28).
    @Published var renameNote: String?
    var identityPin: FileIdentityPin?
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

    init(path: String, originalPath: String? = nil, assignmentID: UUID = UUID()) {
        self.id = UUID()
        self.originalPath = originalPath ?? path
        self.path = path
        self.volumeName = URL(fileURLWithPath: path).lastPathComponent
        self.assignmentID = assignmentID
        self.customLabel = ""
    }

    /// Before inspection the field is empty and the suggestion stands in.
    /// Preflight seeds the field with the suggestion; from then on the field
    /// is what the operator sees, so a field they cleared is an empty label
    /// and gets the empty-label error, never a silent fallback (Codex
    /// desktop QA round 2, 2026-09-15, R2-02).
    var effectiveLabel: String {
        let edited = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if inspection != nil { return edited }
        if !edited.isEmpty { return edited }
        return ""
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
        case .notReady: return "Every staged source must finish preflight before queueing."
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
                label: result.metadata.label,
                totalBytes: result.metadata.totalBytes,
                fileCount: result.metadata.fileCount,
                customProperties: properties,
                previousDestinations: []))
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
        for original in paths {
            let normalized = StandardPurePathNormalizer.normalize(
                original.trimmingCharacters(in: .whitespacesAndNewlines))
            guard normalized.hasPrefix("/"), !normalized.isEmpty, !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            candidates.append(BatchSourceCandidate(path: normalized, originalPath: original))
        }
        generalError = nil
        if !candidates.isEmpty { startSerialInspection(appModel: appModel) }
    }

    func removeCandidate(id: UUID, appModel: AppModel) {
        inspectionTask?.cancel()
        inspectionTask = nil
        candidates.removeAll { $0.id == id }
        generalError = nil
        if !candidates.isEmpty {
            startSerialInspection(appModel: appModel)
        } else {
            isInspecting = false
        }
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
    }

    /// Re-check cheap, non-mutating facts after the sheet appears or a label
    /// is edited. Full protocol inspection remains serial and is only started
    /// for pending candidates; this method never writes destination folders.
    ///
    /// Card names are settled here, per card, every time. A shared or taken
    /// name used to refuse the whole pile from the preflight, and a label
    /// edit never re-ran that check, so the operator could not rename their
    /// way out (Joshua, 2026-09-28). Now an automatic name is numbered past
    /// the clash, and a clash on a name someone typed (or a known card's
    /// continuation key) refuses only the cards involved and clears on the
    /// next edit, because every edit comes back through here.
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
                : candidate.effectiveLabel
            if let reason = validateLabel(label) {
                candidate.status = .refused(reason)
                candidate.renameNote = nil
                firstError = firstError ?? reason
                continue
            }
            named.append(candidate)
            entries.append(BatchLabelAllocator.Entry(
                source: candidate.path, displayName: candidate.volumeName,
                label: label, fixed: !automatic || inspection.known))
        }

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
            for root in roots {
                guard let lane = projectedLane(root: root, label: request.label,
                                               candidate: candidate, appModel: appModel) else {
                    rootInvalid = true
                    break
                }
                // An existing folder is only fine when this same card wrote
                // it: a known card continuing, as single-card Start allows.
                let foreign = FileManager.default.fileExists(atPath: lane)
                    && !laneBelongsToCard(lane, candidate: candidate)
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
                    candidate.renameNote = renamedFrom.map {
                        BatchLabelAllocator.renameNote(from: $0, reason: reason)
                    }
                } else {
                    candidate.renameNote = nil
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

    /// True when this card wrote `lane` on an earlier offload (engine
    /// registry), which makes writing there again a continuation.
    private func laneBelongsToCard(_ lane: String, candidate: BatchSourceCandidate) -> Bool {
        guard let inspection = candidate.inspection else { return false }
        return BatchCardNaming.laneBelongsToCard(
            lane, known: inspection.known,
            previousDestinations: inspection.previousDestinations,
            resolve: { ($0 as NSString).resolvingSymlinksInPath })
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

    /// One all-or-nothing protocol-3 preflight for the complete candidate set.
    /// The inspector is a detached value and the result is applied only if
    /// this run's generation is still current, so stale cards cannot leak into
    /// a later batch.
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

    func startSerialInspection(appModel: AppModel) {
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
        candidates.forEach { $0.status = .inspecting }

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
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""
        let laneBase: BatchSourceStagingCore.LaneBase = { root, label, inspection, sourcePath in
            Self.laneBase(
                root: root, label: label,
                volumeName: URL(fileURLWithPath: sourcePath).lastPathComponent,
                cameraFormat: inspection.metadata.customProperties["format_name"] ?? "",
                reel: inspection.metadata.customProperties["reel_name"] ?? "",
                mirroredFolder: mirrored, template: template, project: project)
        }
        inspectionTask = Task { [weak self] in
            do {
                let staged = try await core.stageBatch(
                    candidateSourcePaths: paths,
                    destinationRoots: roots,
                    existingActiveSourcePaths: activeSources,
                    laneBase: laneBase
                )
                guard !Task.isCancelled, let self, self.generation == runGeneration else { return }
                self.applySuccessfulPreflight(staged, appModel: appModel)
            } catch {
                guard !Task.isCancelled, let self, self.generation == runGeneration else { return }
                self.isInspecting = false
                let message = (error as? BatchSourceStagingError)?.description
                    ?? "Batch source preflight failed."
                self.generalError = message
                self.candidates.forEach {
                    $0.status = .refused(message)
                    $0.projectedLanes = []
                }
                self.objectWillChange.send()
            }
        }
    }

    @discardableResult
    func queueBatch(appModel: AppModel) -> Result<[Job], BatchQueueError> {
        // Start is gated on the cards, not the banner. A message from an
        // earlier failed attempt (journal write, plan refusal) is stale once
        // the operator tries again; the checks below re-derive every current
        // refusal before anything is queued.
        labelRevalidation?.cancel()
        labelRevalidation = nil
        generalError = nil
        guard canQueueBatch else {
            let error = BatchQueueError.notReady
            generalError = error.description
            return .failure(error)
        }
        guard !appModel.destinationPaths.isEmpty else {
            let error = BatchQueueError.preflightFailed("Select at least one destination before queueing the batch.")
            generalError = error.description
            return .failure(error)
        }

        // Re-check identity and labels at the exact queue edge. A card can be
        // removed/reinserted after inspection; no stale metadata may become a
        // persisted job merely because the UI still says Ready.
        let namesShown = candidates.map(\.effectiveLabel)
        revalidateAll(appModel: appModel)
        guard canQueueBatch else {
            let error = BatchQueueError.preflightFailed(
                generalError ?? "Batch preflight changed; re-inspect before queueing."
            )
            return .failure(error)
        }
        // The re-check can renumber an automatic name (a folder appeared on
        // the destination meanwhile). Never queue a folder name the operator
        // did not see; show the new one and let them press Start again.
        guard candidates.map(\.effectiveLabel) == namesShown else {
            let error = BatchQueueError.preflightFailed(
                "A card name changed because the destination changed. Check the names and press Start again.")
            generalError = error.description
            return .failure(error)
        }

        let now = Date()
        let defaults = UserDefaults.standard
        let project = defaults.string(forKey: Pref.projectName) ?? ""
        var planPairs: [(candidate: BatchSourceCandidate, plan: AppModel.LaunchPlan)] = []
        for candidate in candidates {
            guard let inspection = candidate.inspection else {
                let error = BatchQueueError.notReady
                generalError = error.description
                return .failure(error)
            }
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
                let batchError = BatchQueueError.planFailed(error.message)
                generalError = batchError.description
                return .failure(batchError)
            case .success(let plan):
                planPairs.append((candidate: candidate, plan: plan))
            }
        }

        let result = appModel.queueBatch(plans: planPairs)
        if case .success = result {
            candidates.removeAll()
            generalError = nil
        } else if case .failure(let error) = result {
            generalError = error.description
        }
        return result
    }

    private func applySuccessfulPreflight(_ staged: [BatchStagedSourceItem], appModel: AppModel) {
        let byPath = Dictionary(uniqueKeysWithValues: staged.map { ($0.normalizedSourcePath, $0) })
        for candidate in candidates {
            guard let item = byPath[candidate.path] else {
                candidate.status = .refused("source was not returned by preflight")
                continue
            }
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
    static func laneBase(root: String, label: String, volumeName: String,
                         cameraFormat: String, reel: String,
                         mirroredFolder: String, template: String, project: String,
                         date: Date = Date()) -> String {
        let context = TemplateContext(
            project: project, volumeName: volumeName, cardLabel: label, date: date,
            cameraFormat: (cameraFormat == "?" ? "" : cameraFormat).replacingOccurrences(of: "/", with: "-"),
            reel: reel, jobID: "PREVIEW")
        let organization = TemplateRenderer.render(template, context: context)
        return DestinationFolderProjection.project(
            root: root, mirroredFolder: mirroredFolder, organizationFolder: organization)
    }

    private func projectedLane(root: String, label: String,
                               candidate: BatchSourceCandidate, appModel: AppModel) -> String? {
        let d = UserDefaults.standard
        let base = Self.laneBase(
            root: root, label: label, volumeName: candidate.volumeName,
            cameraFormat: candidate.inspection?.formatName ?? "",
            reel: candidate.inspection?.reelName ?? "",
            mirroredFolder: appModel.destinationFolderRelativePath,
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
