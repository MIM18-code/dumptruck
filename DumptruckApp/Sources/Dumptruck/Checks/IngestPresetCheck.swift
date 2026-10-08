import Foundation

enum IngestPresetCheck {

@inline(__always)
static func requirePreset(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

    @MainActor
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-preset-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationA = root.appendingPathComponent("DEST_A")
        let destinationB = root.appendingPathComponent("DEST_B")
        let source = root.appendingPathComponent("SOURCE")
        try FileManager.default.createDirectory(at: destinationA,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationB,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source,
                                                withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("Application Support/ingest-presets.json")
        let settings = IngestPresetSettings(
            folderTemplate: "{Project}/Raws",
            projectName: "SHOW_01",
            verifyMode: "full",
            sourceReread: true,
            reverifyExisting: false,
            extraHashes: "sha256,c4",
            makeReports: true,
            thumbnails: true,
            slateFirst: false,
            openReportWhenDone: false,
            queueMode: "single")

        let store = IngestPresetStore(fileURL: storeURL)
        requirePreset(store.presets.isEmpty, "a new preset store was not empty")
        requirePreset(store.upsert(
            name: "Show 01",
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredDestinationFolder: "Productions/Show 01/Media",
            settings: settings) == nil,
            "valid preset was not saved")
        requirePreset(store.presets.count == 1, "valid preset count was wrong")
        requirePreset(FileManager.default.fileExists(atPath: storeURL.path),
                      "preset JSON was not created atomically")

        // Same-name save requires a deliberate confirmation and must not
        // mutate the existing record on the first attempt.
        let originalID = store.presets[0].id
        requirePreset(store.upsert(
            name: "show 01",
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredDestinationFolder: "Productions/Show 01/Media",
            settings: settings) != nil,
            "same-name preset overwrite was not blocked")
        requirePreset(store.presets.count == 1, "same-name save duplicated a preset")
        requirePreset(store.presets[0].id == originalID,
                      "unconfirmed overwrite changed the existing preset")
        requirePreset(store.upsert(
            name: "show 01",
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredDestinationFolder: "Productions/Show 01/Media",
            settings: settings,
            confirmOverwrite: true) == nil,
            "confirmed same-name preset update failed")

        requirePreset(store.rememberDestinations(
            [destinationA.path, destinationB.path],
            mirroredFolder: "Productions/Show 01/Media") == nil,
            "last destination set was not remembered")
        let reloaded = IngestPresetStore(fileURL: storeURL)
        requirePreset(reloaded.presets.count == 1, "preset did not survive reload")
        requirePreset(reloaded.lastDestinations?.destinationAnchors ==
                      [destinationA.path, destinationB.path],
                      "last destinations did not survive reload")

        // Bounded/untrusted values fail without writing a record.
        requirePreset(reloaded.upsert(
            name: String(repeating: "x", count: IngestPresetStore.maxNameLength + 1),
            destinationAnchors: [destinationA.path],
            mirroredDestinationFolder: "",
            settings: settings) != nil,
            "overlong preset name was accepted")
        requirePreset(reloaded.upsert(
            name: "Traversal",
            destinationAnchors: [destinationA.path],
            mirroredDestinationFolder: "../escape",
            settings: settings) != nil,
            "traversal mirrored path was accepted")

        // Endpoint application checks live directories and source overlap;
        // it does not use path text as a substitute for current mount state.
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredFolder: "Productions/Show 01/Media",
            sourcePath: source.path,
            mountedRoots: []) == nil,
            "valid live endpoints were rejected")
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [source.path],
            mirroredFolder: "",
            sourcePath: source.path,
            mountedRoots: []) != nil,
            "source/destination overlap was accepted")
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [destinationA.path, destinationA.path + "/child"],
            mirroredFolder: "",
            sourcePath: nil,
            mountedRoots: []) != nil,
            "overlapping destinations were accepted")
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [root.appendingPathComponent("MISSING").path],
            mirroredFolder: "",
            sourcePath: nil,
            mountedRoots: [])?.contains("missing") == true,
            "missing destination did not produce a visible reason")

        // Existing projected components must be real directories. A regular
        // file obstruction is refused before any peer could be created.
        let fileObstruction = destinationA.appendingPathComponent("Productions")
        try Data("not-a-folder".utf8).write(to: fileObstruction)
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredFolder: "Productions/Show 01/Media",
            sourcePath: source.path,
            mountedRoots: [])?.contains("regular file") == true,
            "regular-file projected obstruction was accepted")
        try FileManager.default.removeItem(at: fileObstruction)

        // A symlink in any existing projected component is refused even when
        // its resolved target happens to be another directory.
        let symlinkComponent = destinationA.appendingPathComponent("LINK")
        try FileManager.default.createSymbolicLink(atPath: symlinkComponent.path,
                                                   withDestinationPath: destinationB.path)
        requirePreset(IngestPresetEndpointValidator.validate(
            destinationAnchors: [destinationA.path, destinationB.path],
            mirroredFolder: "LINK/Media",
            sourcePath: source.path,
            mountedRoots: [])?.contains("symlink") == true,
            "symlink projected obstruction was accepted")
        try FileManager.default.removeItem(at: symlinkComponent)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: storeURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tmp" }
        requirePreset(leftovers.isEmpty, "temporary preset file was left behind")

        // A corrupt file is quarantined rather than silently overwritten.
        let corruptURL = root.appendingPathComponent("corrupt/ingest-presets.json")
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptURL)
        let corruptStore = IngestPresetStore(fileURL: corruptURL)
        requirePreset(corruptStore.presets.isEmpty, "corrupt store exposed records")
        requirePreset(corruptStore.storageNotice != nil,
                      "corruption was not visible")
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: corruptURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt-") }
        requirePreset(!quarantined.isEmpty, "corrupt preset file was not quarantined")

        let id = reloaded.presets[0].id
        requirePreset(reloaded.delete(id: id) == nil, "preset delete failed")
        requirePreset(reloaded.presets.isEmpty, "deleted preset remained in memory")
        print("ingest preset checks passed")
    }
}
