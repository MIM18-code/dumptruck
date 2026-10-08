import Combine
import Darwin
import Foundation

/// The settings that belong to an ingest workflow rather than to the
/// application itself.  A preset deliberately does not contain a source
/// path, a volume UUID, a verdict, or any job history.  It is a convenience
/// for rebuilding a staging bench after the operator has verified that the
/// current drives are the intended ones.
struct IngestPresetSettings: Codable, Equatable {
    var folderTemplate: String
    var projectName: String
    var verifyMode: String
    var sourceReread: Bool
    var reverifyExisting: Bool
    var extraHashes: String
    var makeReports: Bool
    var thumbnails: Bool
    var slateFirst: Bool
    var openReportWhenDone: Bool
    var queueMode: String
}

struct IngestPreset: Codable, Identifiable, Equatable {
    static let schemaVersion = 1

    let id: UUID
    var name: String
    /// These are the folders that were selected as destination anchors. They
    /// are never identity authority: applying a preset revalidates the live
    /// mount, directory, symlink, and source-overlap state first.
    var destinationAnchors: [String]
    /// A component-safe path projected below every destination anchor. Missing
    /// peer folders are still only a launch-time concern; saving/applying a
    /// preset never creates them.
    var mirroredDestinationFolder: String
    var settings: IngestPresetSettings
    var createdAt: Date
    var updatedAt: Date
}

struct RememberedDestinations: Codable, Equatable {
    var destinationAnchors: [String]
    var mirroredDestinationFolder: String
    var updatedAt: Date
}

/// Disk-backed, versioned storage for named ingest workflows.  The store is
/// intentionally small and synchronous: every mutation happens on the main
/// actor, and the JSON file is replaced atomically before the new state is
/// exposed to SwiftUI.
@MainActor
final class IngestPresetStore: ObservableObject {
    nonisolated static let maxPresetCount = 64
    nonisolated static let maxNameLength = 80
    nonisolated static let maxPathLength = 4_096
    nonisolated static let maxMirroredFolderLength = 1_024
    nonisolated static let maxTemplateLength = 512
    nonisolated static let maxProjectLength = 256
    nonisolated static let maxHashesLength = 128
    nonisolated static let maxDiskBytes = 4 * 1024 * 1024

    static let shared = IngestPresetStore(fileURL: defaultFileURL)

    static var defaultFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory,
                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Dumptruck", isDirectory: true)
            .appendingPathComponent("ingest-presets.json", isDirectory: false)
    }

    @Published private(set) var presets: [IngestPreset] = []
    @Published private(set) var lastDestinations: RememberedDestinations?
    /// A non-nil notice is deliberately surfaced in the destination preset
    /// menu and Settings.  Corruption is quarantined, never silently erased.
    @Published private(set) var storageNotice: String?

    let fileURL: URL
    private let fileManager: FileManager

    private struct DiskPayload: Codable {
        var schemaVersion: Int
        var presets: [IngestPreset]
        var lastDestinations: RememberedDestinations?
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        load()
    }

    var storageLocationDescription: String {
        fileURL.path
    }

    // MARK: public mutations

    /// Save a new named preset. Replacing a preset with the same name is an
    /// explicit second action: callers must pass `confirmOverwrite: true`.
    /// The returned string is an operator-facing reason, not a log-only
    /// failure.
    @discardableResult
    func upsert(name rawName: String,
                destinationAnchors rawAnchors: [String],
                mirroredDestinationFolder rawMirrored: String,
                settings: IngestPresetSettings,
                confirmOverwrite: Bool = false) -> String? {
        guard let name = Self.normalizedName(rawName) else {
            return "Preset names must be 1–\(Self.maxNameLength) characters and cannot contain a slash or control character."
        }
        guard let anchors = Self.normalizedAnchors(rawAnchors) else {
            return "A preset needs existing destination folders with valid absolute paths."
        }
        guard let mirrored = Self.normalizedRelativeFolder(rawMirrored) else {
            return "The mirrored destination folder must be a safe relative folder path."
        }
        guard let error = Self.validateSettings(settings) else {
            let now = Date()
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: .current)
            var next = presets
            let existingIndex = next.firstIndex {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: .current) == folded
            }
            let preset: IngestPreset
            if let existingIndex {
                guard confirmOverwrite else {
                    return "A preset named \"\(name)\" already exists — confirm replacement before saving over it."
                }
                let old = next[existingIndex]
                preset = IngestPreset(id: old.id, name: name,
                                      destinationAnchors: anchors,
                                      mirroredDestinationFolder: mirrored,
                                      settings: settings,
                                      createdAt: old.createdAt,
                                      updatedAt: now)
                next.remove(at: existingIndex)
            } else {
                guard next.count < Self.maxPresetCount else {
                    return "You have reached the \(Self.maxPresetCount)-preset limit. Delete an old preset first."
                }
                preset = IngestPreset(id: UUID(), name: name,
                                      destinationAnchors: anchors,
                                      mirroredDestinationFolder: mirrored,
                                      settings: settings,
                                      createdAt: now,
                                      updatedAt: now)
            }
            next.insert(preset, at: 0)
            guard Self.validatePresets(next) == nil else {
                return "That preset contains unsupported or unsafe values."
            }
            let oldPresets = presets
            presets = next
            if let error = persist() {
                presets = oldPresets
                return error
            }
            return nil
        }
        return error
    }

    @discardableResult
    func delete(id: UUID) -> String? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            return "That preset no longer exists."
        }
        let old = presets
        presets.remove(at: index)
        if let error = persist() {
            presets = old
            return error
        }
        return nil
    }

    func preset(id: UUID) -> IngestPreset? {
        presets.first { $0.id == id }
    }

    func hasPreset(named rawName: String) -> Bool {
        guard let name = Self.normalizedName(rawName) else { return false }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: .current)
        return presets.contains {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                            locale: .current) == folded
        }
    }

    /// Remember the last non-empty destination set.  Stale paths are retained
    /// on purpose so Use Last Destinations can explain which drive is missing;
    /// they are never used without live validation in AppModel.
    @discardableResult
    func rememberDestinations(_ anchors: [String], mirroredFolder: String) -> String? {
        guard let normalizedAnchors = Self.normalizedAnchors(anchors),
              !normalizedAnchors.isEmpty,
              let normalizedMirrored = Self.normalizedRelativeFolder(mirroredFolder) else {
            return "The current destinations could not be remembered because their paths are invalid."
        }
        let next = RememberedDestinations(destinationAnchors: normalizedAnchors,
                                          mirroredDestinationFolder: normalizedMirrored,
                                          updatedAt: Date())
        if lastDestinations?.destinationAnchors == next.destinationAnchors,
           lastDestinations?.mirroredDestinationFolder == next.mirroredDestinationFolder {
            return nil
        }
        let old = lastDestinations
        lastDestinations = next
        if let error = persist() {
            lastDestinations = old
            return error
        }
        return nil
    }

    // MARK: validation shared by load/tests

    nonisolated static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength,
              !name.contains("/"), !name.contains("\\"),
              !containsControlCharacter(name) else { return nil }
        return name
    }

    nonisolated static func normalizedAnchors(_ raw: [String]) -> [String]? {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        var output: [String] = []
        for path in raw {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maxPathLength,
                  trimmed.hasPrefix("/"), !containsControlCharacter(trimmed) else {
                return nil
            }
            let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            guard normalized == trimmed,
                  normalized != "/", normalized != "/Volumes" else { return nil }
            guard !output.contains(normalized) else { return nil }
            output.append(normalized)
        }
        return output
    }

    /// Empty is the valid representation for “mirror the destination root”.
    nonisolated static func normalizedRelativeFolder(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.count <= maxMirroredFolderLength,
              !containsControlCharacter(path),
              !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\") else { return nil }
        if path.isEmpty { return "" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    nonisolated static func validateSettings(_ settings: IngestPresetSettings) -> String? {
        guard settings.folderTemplate.count <= maxTemplateLength,
              settings.projectName.count <= maxProjectLength,
              settings.extraHashes.count <= maxHashesLength,
              !containsControlCharacter(settings.folderTemplate),
              !containsControlCharacter(settings.projectName),
              !containsControlCharacter(settings.extraHashes) else {
            return "Preset settings exceed their safety limits."
        }
        guard settings.verifyMode == "full" || settings.verifyMode == "fast" else {
            return "Preset verification mode is not supported."
        }
        guard settings.queueMode == "off" || settings.queueMode == "single" else {
            return "Preset queue mode is not supported."
        }
        let allowed = Set(["md5", "sha1", "sha256", "c4"])
        let hashes = settings.extraHashes.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard Set(hashes).isSubset(of: allowed) else {
            return "Preset contains an unsupported extra checksum."
        }
        if let error = TemplateRenderer.validate(
            settings.folderTemplate,
            context: .preview(project: settings.projectName)) {
            return "Preset folder template is invalid: \(error)"
        }
        return nil
    }

    nonisolated static func validatePresets(_ values: [IngestPreset]) -> String? {
        guard values.count <= maxPresetCount else { return "too many presets" }
        var ids = Set<UUID>()
        var names = Set<String>()
        for preset in values {
            guard ids.insert(preset.id).inserted else { return "duplicate preset id" }
            guard let name = normalizedName(preset.name) else { return "invalid preset name" }
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: .current)
            guard names.insert(folded).inserted else { return "duplicate preset name" }
            guard normalizedAnchors(preset.destinationAnchors) != nil,
                  normalizedRelativeFolder(preset.mirroredDestinationFolder) != nil,
                  validateSettings(preset.settings) == nil else {
                return "invalid preset values"
            }
        }
        return nil
    }

    nonisolated static func validateRemembered(_ value: RememberedDestinations?) -> String? {
        guard let value else { return nil }
        guard normalizedAnchors(value.destinationAnchors) != nil,
              normalizedRelativeFolder(value.mirroredDestinationFolder) != nil else {
            return "invalid remembered destinations"
        }
        return nil
    }

    // MARK: disk I/O

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maxDiskBytes else {
                throw StorageError.invalid("file exceeds \(Self.maxDiskBytes) bytes")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(DiskPayload.self, from: data)
            guard payload.schemaVersion == IngestPreset.schemaVersion else {
                throw StorageError.invalid("unsupported schema version")
            }
            guard Self.validatePresets(payload.presets) == nil,
                  Self.validateRemembered(payload.lastDestinations) == nil else {
                throw StorageError.invalid("unsafe values")
            }
            presets = payload.presets
            lastDestinations = payload.lastDestinations
        } catch {
            quarantine(reason: "\(error.localizedDescription)")
        }
    }

    private enum StorageError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let text): return text
            }
        }
    }

    private func quarantine(reason: String) {
        let base = fileURL.deletingPathExtension()
        let stamp = Int(Date().timeIntervalSince1970)
        var target = base.appendingPathExtension("corrupt-\(stamp).json")
        var suffix = 1
        while fileManager.fileExists(atPath: target.path) {
            target = base.appendingPathExtension("corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }
        let moved = (try? fileManager.moveItem(at: fileURL, to: target)) != nil
        let detail = moved
            ? "moved to \(target.lastPathComponent)"
            : "could not be moved; it remains in place"
        storageNotice = "Preset storage was corrupt (\(reason)); \(detail). Presets were reset."
        presets = []
        lastDestinations = nil
    }

    private func persist() -> String? {
        guard Self.validatePresets(presets) == nil,
              Self.validateRemembered(lastDestinations) == nil else {
            let message = "Preset storage refused an unsafe value."
            storageNotice = message
            return message
        }
        let payload = DiskPayload(schemaVersion: IngestPreset.schemaVersion,
                                  presets: presets,
                                  lastDestinations: lastDestinations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            guard data.count <= Self.maxDiskBytes else {
                throw StorageError.invalid("file exceeds \(Self.maxDiskBytes) bytes")
            }
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
            try atomicWrite(data, in: directory)
            return nil
        } catch {
            let message = "Could not save ingest presets: \(error.localizedDescription)"
            storageNotice = message
            return message
        }
    }

    /// Write a unique temporary file, force its bytes to stable storage,
    /// atomically replace the destination, then force the parent directory.
    /// The final directory fsync is important on APFS: a successful rename
    /// alone does not make the new directory entry durable across power loss.
    private func atomicWrite(_ data: Data, in directory: URL) throws {
        let temp = directory.appendingPathComponent(
            ".ingest-presets-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var closed = false
        defer {
            if !closed { _ = close(fd) }
            try? fileManager.removeItem(at: temp)
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard close(fd) == 0 else {
            closed = true
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        closed = true

        // `rename` is an atomic replacement when source and destination are
        // in the same directory/filesystem, including when the destination
        // already exists.
        guard Darwin.rename(temp.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(directoryFD) }
        guard fsync(directoryFD) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated private static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

/// Live endpoint checks for applying a preset.  Keeping this pure and
/// deterministic makes it testable without constructing an AppModel or
/// touching the engine.  The caller supplies currently mounted roots; paths
/// under `/Volumes` that are not below one of those roots are rejected even if
/// a stale directory happens to remain there.
enum IngestPresetEndpointValidator {
    static func overlaps(_ a: String, _ b: String) -> Bool {
        pathsOverlap(a, b)
    }

    static func validate(destinationAnchors: [String],
                         mirroredFolder: String,
                         sourcePath: String?,
                         mountedRoots: [String],
                         fileManager: FileManager = .default) -> String? {
        guard !destinationAnchors.isEmpty else {
            return "This preset has no destination folders."
        }
        guard IngestPresetStore.normalizedRelativeFolder(mirroredFolder) != nil else {
            return "This preset's mirrored folder is not a safe relative path."
        }
        var normalized: [String] = []
        for anchor in destinationAnchors {
            let path = URL(fileURLWithPath: anchor).standardizedFileURL.path
            guard path == anchor else {
                return "Preset destination \(anchor) is not a normalized directory path."
            }
            if let error = validateExistingDirectory(path,
                                                      description: "Destination",
                                                      fileManager: fileManager) {
                return error
            }
            if path.hasPrefix("/Volumes/") {
                guard mountedRoots.contains(where: { isContained(path, in: $0) }) else {
                    return "Destination \(path) is not on a currently mounted drive — reinsert it and apply the preset again."
                }
            }
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard resolved == path else {
                return "Destination \(path) is a symlink; choose the real mounted folder before applying a preset."
            }
            if let sourcePath, fileManager.fileExists(atPath: sourcePath),
               pathsOverlap(path, sourcePath) {
                return "Preset destination \(path) overlaps the current source — choose another preset or source."
            }
            guard !normalized.contains(where: { pathsOverlap($0, path) }) else {
                return "Preset destinations overlap each other at \(path) — choose separate folders or drives."
            }
            if let error = validateProjectedComponents(root: path,
                                                       mirroredFolder: mirroredFolder,
                                                       fileManager: fileManager) {
                return error
            }
            normalized.append(path)
        }
        return nil
    }

    /// Returns nil when the path is an existing, non-symlink directory.
    /// Missing paths are an error for anchors, but are allowed for projected
    /// mirror components because launch is the only operation allowed to
    /// create those peers.
    private static func validateExistingDirectory(_ path: String,
                                                   description: String,
                                                   fileManager: FileManager) -> String? {
        var info = Darwin.stat()
        guard Darwin.lstat(path, &info) == 0 else {
            return missingReason(for: path)
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK {
            return "\(description) \(path) is a symlink; choose the real mounted folder before applying this preset."
        }
        guard type == S_IFDIR else {
            return "\(description) \(path) is a regular file, not an existing directory."
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return missingReason(for: path)
        }
        return nil
    }

    /// Validate every component that already exists below a destination
    /// anchor. A missing component ends the walk and is safe to create only at
    /// launch; a symlink or regular-file obstruction is refused before any
    /// preset mutation, across all anchors.
    private static func validateProjectedComponents(root: String,
                                                    mirroredFolder: String,
                                                    fileManager: FileManager) -> String? {
        guard !mirroredFolder.isEmpty else { return nil }
        var current = root
        for component in mirroredFolder.split(separator: "/", omittingEmptySubsequences: true) {
            current = (current as NSString).appendingPathComponent(String(component))
            var info = Darwin.stat()
            guard Darwin.lstat(current, &info) == 0 else {
                if errno == ENOENT { return nil }
                return "Could not inspect projected destination \(current) — preset application refused."
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                return "Projected destination \(current) is a symlink — choose a real folder before applying this preset."
            }
            guard type == S_IFDIR else {
                return "Projected destination \(current) is a regular file, not a directory — remove the obstruction before applying this preset."
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "Projected destination \(current) is not an existing directory — preset application refused."
            }
        }
        return nil
    }

    private static func missingReason(for path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            return "Destination \(path) is missing or its drive is not mounted — reinsert it and apply the preset again."
        }
        return "Destination \(path) is missing or is not an existing directory."
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        let p = (URL(fileURLWithPath: path).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        let r = (URL(fileURLWithPath: root).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        return p == r || p.hasPrefix(r + "/")
    }

    private static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let ra = (URL(fileURLWithPath: a).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        let rb = (URL(fileURLWithPath: b).standardizedFileURL.path as NSString)
            .resolvingSymlinksInPath
        return ra == rb || ra.hasPrefix(rb + "/") || rb.hasPrefix(ra + "/")
    }
}
