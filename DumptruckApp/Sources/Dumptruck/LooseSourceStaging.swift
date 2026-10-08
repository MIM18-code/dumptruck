import Foundation
import Darwin

/// Loose files as a source (Joshua, 2026-09-15): "I should be able to drag
/// a bunch of files to source too." The engine copies one pinned folder and
/// hangs identity, camera history, the second read and the wipe verdict off
/// it, so loose files never reach the engine as files. They are staged as a
/// folder of APFS clones, instant, zero bytes, same volume, and that folder
/// runs through the ordinary card path with `--loose-files`, which turns off
/// card identity, label memory and wipe authorization. Nothing in the copy
/// or verify path changes.
///
/// Rules: flatten (a drop is "these files", not their folders), refuse a
/// name collision rather than rename, refuse anything that is not a plain
/// readable file on the staging volume. A refusal leaves nothing behind.
enum LooseSourceStaging {
    struct Refusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where staged sets live. Checks point this at a temp folder.
    nonisolated(unsafe) static var root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Dumptruck/loose-sources", isDirectory: true)
    }()

    static let folderPrefix = "Loose "

    /// True for a path inside the staging root (the staged set itself or
    /// anything below it). Detection by location, not by a journal flag, so
    /// old journals need no migration and a set is loose wherever it shows up.
    static func isLoosePath(_ path: String, root: URL = root) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let r = root.standardizedFileURL.path
        return std == r || std.hasPrefix(r + "/")
    }

    /// True for the staged set folder itself (a direct child of the root).
    static func isStagedSet(_ path: String, root: URL = root) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        return isLoosePath(std, root: root)
            && (std as NSString).deletingLastPathComponent == root.standardizedFileURL.path
    }

    /// Stage `files` as one set. Returns the set folder's path.
    /// Validation runs to completion before the first clone: a refused drop
    /// creates nothing. Any clone failure removes the half-built set.
    static func stage(files rawFiles: [String], root: URL = root,
                      now: Date = Date()) throws -> String {
        let files = rawFiles.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !files.isEmpty else { throw Refusal(message: "No files were dropped") }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rootStat = stat()
        guard stat(root.path, &rootStat) == 0 else {
            throw Refusal(message: "Cannot reach the staging folder at \(root.path)")
        }

        var seenNames: [String: String] = [:]   // NFC+casefold key -> first path
        var seenPaths = Set<String>()
        var accepted: [String] = []
        for path in files {
            guard seenPaths.insert(path).inserted else { continue }
            var st = stat()
            guard lstat(path, &st) == 0 else {
                throw Refusal(message: "\(display(path)) does not exist")
            }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK {
                throw Refusal(message: "\(display(path)) is a symlink, drop the real file")
            }
            if mode == S_IFDIR {
                throw Refusal(message: "\(display(path)) is a folder, folders stage on their own")
            }
            guard mode == S_IFREG else {
                throw Refusal(message: "\(display(path)) is not a regular file")
            }
            guard access(path, R_OK) == 0 else {
                throw Refusal(message: "\(display(path)) is not readable")
            }
            // An iCloud-evicted file passes every other gate and then
            // clonefile blocks the main thread while iCloud downloads it
            // (Opus review 2026-09-15, finding 4). Say so instead.
            if st.st_flags & UInt32(SF_DATALESS) != 0 {
                throw Refusal(message: "\(display(path)) is not downloaded from iCloud yet, "
                    + "download it first, then drop it again")
            }
            guard st.st_dev == rootStat.st_dev else {
                let volume = volumeName(of: path)
                throw Refusal(message: "\(display(path)) lives on \(volume), not on this Mac's disk, "
                    + "drop the folder it is in instead, so the drive is the source")
            }
            let name = (path as NSString).lastPathComponent
            if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                throw Refusal(message: "\(display(path)) has control characters in its name")
            }
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            if let first = seenNames[key] {
                throw Refusal(message: "Two files are both named \(name) "
                    + "(\(display(first)) and \(display(path))), a flat set can hold only one. "
                    + "Rename one, or drop their folders instead")
            }
            seenNames[key] = path
            accepted.append(path)
        }

        let setURL = try uniqueSetFolder(root: root, now: now)
        do {
            for path in accepted {
                let dest = setURL.appendingPathComponent((path as NSString).lastPathComponent).path
                try clone(path, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: setURL)
            throw error
        }
        return setURL.path
    }

    /// Remove a staged set. Refuses anything that is not a direct child of
    /// the staging root, so a misrouted path can never delete real footage.
    @discardableResult
    static func remove(_ path: String, root: URL = root) -> Bool {
        guard isStagedSet(path, root: root) else { return false }
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        var st = stat()
        guard lstat(std, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        return (try? FileManager.default.removeItem(atPath: std)) != nil
    }

    /// Launch-time sweep: sets nothing live refers to, older than `olderThan`.
    /// Returns the paths removed.
    @discardableResult
    static func sweep(root: URL = root, keeping: Set<String>,
                      olderThan: TimeInterval, now: Date = Date()) -> [String] {
        let keep = Set(keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var removed: [String] = []
        for name in names where name.hasPrefix(folderPrefix) {
            let path = root.appendingPathComponent(name).standardizedFileURL.path
            if keep.contains(path) { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory,
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > olderThan else { continue }
            if remove(path, root: root) { removed.append(path) }
        }
        return removed
    }

    // MARK: - internals

    private static func uniqueSetFolder(root: URL, now: Date) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"   // no colons: Finder shows them as slashes
        let base = folderPrefix + f.string(from: now)
        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base) (\(attempt + 1))"
            let url = root.appendingPathComponent(name, isDirectory: true)
            // O_EXCL semantics: mkdir fails if the name exists, so two drops
            // in the same second cannot share a folder.
            if mkdir(url.path, 0o755) == 0 { return url }
            if errno != EEXIST {
                throw Refusal(message: "Cannot create the staging folder: \(String(cString: strerror(errno)))")
            }
        }
        throw Refusal(message: "Cannot find a free staging folder name")
    }

    /// APFS clone: same bytes, zero copy, a new file. Falls back to a plain
    /// copy only where cloning is unsupported (same volume already proven).
    private static func clone(_ src: String, to dest: String) throws {
        if clonefile(src, dest, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let err = errno
        if err == ENOTSUP || err == EXDEV {
            try FileManager.default.copyItem(atPath: src, toPath: dest)
            return
        }
        if err == EDEADLK {
            // The dataless probe above missed it (evicted between the two
            // calls): the kernel refuses to materialize under this policy.
            throw Refusal(message: "\(display(src)) is not downloaded from iCloud yet, "
                + "download it first, then drop it again")
        }
        throw Refusal(message: "Cannot stage \(display(src)): \(String(cString: strerror(err)))")
    }

    private static func display(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func volumeName(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName {
            return name
        }
        return "another volume"
    }
}
