import Foundation

/// Workflow convenience APIs for named ingest presets.  These methods are
/// intentionally separate from the transfer engine and verdict logic: a
/// preset can only rebuild the staging bench and UserDefaults settings; it
/// cannot create a job, grant eject authority, or manufacture a verdict.
@MainActor
extension AppModel {
    private var ingestPresetStore: IngestPresetStore { .shared }

    private var currentIngestPresetSettings: IngestPresetSettings {
        let defaults = UserDefaults.standard
        return IngestPresetSettings(
            folderTemplate: defaults.string(forKey: Pref.folderTemplate) ?? "",
            projectName: defaults.string(forKey: Pref.projectName) ?? "",
            verifyMode: defaults.string(forKey: Pref.verifyMode) ?? "full",
            sourceReread: defaults.object(forKey: Pref.sourceReread) == nil
                || defaults.bool(forKey: Pref.sourceReread),
            reverifyExisting: defaults.bool(forKey: Pref.reverifyExisting),
            extraHashes: defaults.string(forKey: Pref.extraHashes) ?? "",
            makeReports: defaults.object(forKey: Pref.makeReports) == nil
                || defaults.bool(forKey: Pref.makeReports),
            thumbnails: defaults.object(forKey: Pref.thumbnails) == nil
                || defaults.bool(forKey: Pref.thumbnails),
            slateFirst: defaults.bool(forKey: Pref.slateFirst),
            openReportWhenDone: defaults.bool(forKey: Pref.openReportWhenDone),
            queueMode: defaults.string(forKey: Pref.queueMode) ?? "off")
    }

    /// Save the current destination set and ingest settings.  Saving performs
    /// the same live endpoint checks as applying; a missing drive is an
    /// explicit refusal rather than a stale path silently entering a preset.
    @discardableResult
    func saveCurrentIngestPreset(named name: String,
                                 confirmOverwrite: Bool = false) -> String? {
        refreshVolumes()
        guard !destinationPaths.isEmpty else {
            let message = "Add at least one destination before saving an ingest preset."
            lastSetupError = message
            return message
        }
        if let error = validatePresetEndpoints(destinationAnchors: destinationPaths,
                                               mirroredFolder: destinationFolderRelativePath) {
            lastSetupError = error
            return error
        }
        let settings = currentIngestPresetSettings
        let volumeName = sourcePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "CARD_VOLUME"
        let context = TemplateContext(
            project: settings.projectName,
            volumeName: volumeName,
            cardLabel: label.isEmpty ? "CARD_LABEL" : label,
            date: Date(),
            cameraFormat: (inspection?.formatName == "?" ? "" : (inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: inspection?.reelName ?? "",
            jobID: "PRESET_JOB"
        )
        if let templateError = TemplateRenderer.validate(
            settings.folderTemplate,
            context: context) {
            lastSetupError = templateError
            return templateError
        }
        if let error = ingestPresetStore.upsert(
            name: name,
            destinationAnchors: destinationPaths,
            mirroredDestinationFolder: destinationFolderRelativePath,
            settings: settings,
            confirmOverwrite: confirmOverwrite) {
            lastSetupError = error
            return error
        }
        rememberCurrentIngestDestinations()
        lastSetupError = nil
        return nil
    }

    /// Apply a complete preset after validating all live destination paths.
    /// No destination folder is created here and no transfer is started.
    @discardableResult
    func applyIngestPreset(_ preset: IngestPreset) -> String? {
        refreshVolumes()
        guard IngestPresetStore.validatePresets([preset]) == nil else {
            let message = "Preset \(preset.name) contains unsupported or unsafe values."
            lastSetupError = message
            return message
        }
        let settings = preset.settings
        let volumeName = sourcePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "CARD_VOLUME"
        let context = TemplateContext(
            project: settings.projectName,
            volumeName: volumeName,
            cardLabel: label.isEmpty ? "CARD_LABEL" : label,
            date: Date(),
            cameraFormat: (inspection?.formatName == "?" ? "" : (inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: inspection?.reelName ?? "",
            jobID: "PRESET_JOB"
        )
        if let templateError = TemplateRenderer.validate(
            settings.folderTemplate,
            context: context) {
            lastSetupError = templateError
            return templateError
        }
        if let endpointError = validatePresetEndpoints(
            destinationAnchors: preset.destinationAnchors,
            mirroredFolder: preset.mirroredDestinationFolder) {
            lastSetupError = endpointError
            return endpointError
        }
        for anchor in preset.destinationAnchors
            where !preset.mirroredDestinationFolder.isEmpty {
            let projected = DestinationFolderProjection.project(
                root: anchor,
                mirroredFolder: preset.mirroredDestinationFolder,
                organizationFolder: "")
            if FileManager.default.fileExists(atPath: projected),
               (projected as NSString).resolvingSymlinksInPath != projected {
                let error = "Mirrored destination folder \(projected) is a symlink — choose the real folder before applying this preset."
                lastSetupError = error
                return error
            }
        }

        // A preset supersedes an operator-staged historical retry. Clear the
        // retry context before installing the new settings so Start cannot
        // silently keep the old raw roots/organization path/verification
        // arguments while the UI displays this preset.
        clearMirroredDestinationFolder()

        // This is the only staging mutation. The helper deliberately stores
        // the anchor roots, not projected folders, so queued-job identity pins
        // and launch-time folder creation stay correct.
        installPresetDestinationSelection(
            anchors: preset.destinationAnchors,
            mirroredFolder: preset.mirroredDestinationFolder)
        for anchor in preset.destinationAnchors
            where !volumes.contains(where: { $0.path == anchor })
                && !folderEndpoints.contains(where: { $0.path == anchor }) {
            folderEndpoints.append(Endpoint(path: anchor, kind: .folder))
        }
        applyIngestPresetSettings(settings)
        rememberCurrentIngestDestinations()
        lastSetupError = nil
        objectWillChange.send()
        return nil
    }

    @discardableResult
    func applyIngestPreset(id: UUID) -> String? {
        guard let preset = ingestPresetStore.preset(id: id) else {
            let error = "That ingest preset no longer exists."
            lastSetupError = error
            return error
        }
        return applyIngestPreset(preset)
    }

    /// Restore only the last destination set.  Current verification,
    /// organization, and queue settings remain untouched.
    @discardableResult
    func applyLastIngestDestinations() -> String? {
        refreshVolumes()
        guard let remembered = ingestPresetStore.lastDestinations else {
            let error = "There is no remembered destination set yet."
            lastSetupError = error
            return error
        }
        if let error = validatePresetEndpoints(
            destinationAnchors: remembered.destinationAnchors,
            mirroredFolder: remembered.mirroredDestinationFolder) {
            lastSetupError = error
            return error
        }
        // Restoring destinations is also a new staging choice. It must not
        // leave a historical retry armed behind the scenes.
        clearMirroredDestinationFolder()
        installPresetDestinationSelection(
            anchors: remembered.destinationAnchors,
            mirroredFolder: remembered.mirroredDestinationFolder)
        for anchor in remembered.destinationAnchors
            where !volumes.contains(where: { $0.path == anchor })
                && !folderEndpoints.contains(where: { $0.path == anchor }) {
            folderEndpoints.append(Endpoint(path: anchor, kind: .folder))
        }
        rememberCurrentIngestDestinations()
        lastSetupError = nil
        objectWillChange.send()
        return nil
    }

    /// Called by the destination rail whenever its selection changes.  The
    /// store retains the last non-empty set, including stale paths, so the
    /// next restore can explain which drive needs to be reinserted.
    func rememberCurrentIngestDestinations() {
        guard !destinationPaths.isEmpty else { return }
        _ = ingestPresetStore.rememberDestinations(
            destinationPaths,
            mirroredFolder: destinationFolderRelativePath)
    }

    private func validatePresetEndpoints(destinationAnchors: [String],
                                         mirroredFolder: String) -> String? {
        let source = sourcePath
        let mountedRoots = volumes.map(\.path)
        if let error = IngestPresetEndpointValidator.validate(
            destinationAnchors: destinationAnchors,
            mirroredFolder: mirroredFolder,
            sourcePath: source,
            mountedRoots: mountedRoots) {
            return error
        }
        for job in jobs where job.isRunning {
            let occupied = [job.sourcePath] + job.destinations
            if destinationAnchors.contains(where: { candidate in
                occupied.contains { IngestPresetEndpointValidator.overlaps(candidate, $0) }
            }) {
                return "A preset destination overlaps the running transfer \(job.label) — wait for it to finish before changing destinations."
            }
        }
        return nil
    }

    private func applyIngestPresetSettings(_ settings: IngestPresetSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.folderTemplate, forKey: Pref.folderTemplate)
        defaults.set(settings.projectName, forKey: Pref.projectName)
        defaults.set(settings.verifyMode, forKey: Pref.verifyMode)
        defaults.set(settings.sourceReread, forKey: Pref.sourceReread)
        defaults.set(settings.reverifyExisting, forKey: Pref.reverifyExisting)
        defaults.set(settings.extraHashes, forKey: Pref.extraHashes)
        defaults.set(settings.makeReports, forKey: Pref.makeReports)
        defaults.set(settings.thumbnails, forKey: Pref.thumbnails)
        defaults.set(settings.slateFirst, forKey: Pref.slateFirst)
        defaults.set(settings.openReportWhenDone, forKey: Pref.openReportWhenDone)
        defaults.set(settings.queueMode, forKey: Pref.queueMode)
        // AppModel already observes UserDefaults.didChangeNotification, but
        // send a local invalidation as well so Start's gate updates before a
        // sheet/menu animation completes.
        objectWillChange.send()
    }

}
