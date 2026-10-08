import CoreServices
import Foundation

/// The C stream owns this callback box independently of the Swift monitor.
/// A callback already executing while `stop()` tears down the stream can still
/// finish safely without dereferencing a deallocated SourceMutationMonitor.
final class SourceMutationCallbackBox: @unchecked Sendable {
    let handler: @Sendable () -> Void
    let settled: @Sendable () -> Void
    let filter: MutationEventFilter?
    let judge: DestinationChangeJudge?
    private let lock = NSLock()
    private var mutationSeen = false

    init(filter: MutationEventFilter?, judge: DestinationChangeJudge?,
         settled: @escaping @Sendable () -> Void,
         handler: @escaping @Sendable () -> Void) {
        self.filter = filter
        self.judge = judge
        self.handler = handler
        self.settled = settled
        judge?.onCaptureFailed = { [weak self] in self?.fire() }
    }

    /// `forced` carries the FSEvents flags that mean the change set is
    /// unknown (dropped events, a scan-subdirs hint, root or mount changes):
    /// those bypass the filter and the judge, because an unknown change
    /// set must fail closed.
    /// `eventMetadataOnly[i]` is true when event i only touched metadata
    /// (xattrs, inode fields): a filter that `ignoresMetadataOnly` drops a
    /// burst whose remaining relevant events are all like that.
    func receiveEvent(paths: [String], forced: Bool, metadataOnly: Bool = false,
                      eventMetadataOnly: [Bool] = []) {
        judge?.beginChecking()
        settled()
        defer { judge?.endChecking(); settled() }
        if forced {
            fire()
            return
        }
        // A filtered stream drops a burst that touched only ignorable
        // names. An empty path list (or no filter) is always a mutation.
        var relevant = paths
        if let filter, judge == nil, !paths.isEmpty {
            let kept = paths.indices.filter { !filter.isIgnorable(paths[$0]) }
            if kept.isEmpty { return }
            // Judged per remaining event, never over the whole burst: a
            // Finder visit writes .DS_Store (dropped above) in the same
            // burst that tags a clip's last-opened date.
            if filter.ignoresMetadataOnly, eventMetadataOnly.count == paths.count,
               kept.allSatisfy({ eventMetadataOnly[$0] }) {
                return
            }
            relevant = kept.map { paths[$0] }
        }
        // Delayed pre-arm events are harmless only when the current bytes
        // still match verified evidence. A timestamp match is insufficient.
        if let judge, !relevant.isEmpty, !relevant.contains(where: { judge.provesChange($0, metadataOnly: metadataOnly) }) {
            return
        }
        fire()
    }

    private func fire() {
        lock.lock()
        let first = !mutationSeen
        mutationSeen = true
        lock.unlock()
        if first || judge == nil { handler() }
    }

    var hasSeenMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutationSeen
    }
}

/// Recursive, event-driven observation of the staged source tree. Directory
/// vnode sources only see direct-child changes; FSEvents with file events sees
/// nested creates, deletes, renames, metadata changes, and same-size rewrites.
/// Source watchers filter only what cannot change the offload's evidence:
/// the engine's own junk names and metadata-only events (see
/// MutationEventFilter.sourceJunk). Any content write, create, delete,
/// rename, or unknown change set under the card still retires authority.
final class SourceMutationMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dumptruck.source-mutation", qos: .utility)
    private let callbackBox: SourceMutationCallbackBox
    private let judge: DestinationChangeJudge?
    private var stream: FSEventStreamRef?

    /// `filter` is a struct, not a closure, so the trailing-closure call
    /// sites keep binding to `handler`. A source watcher passes
    /// `MutationEventFilter.sourceJunk(root:)`: Finder litter and tags on the
    /// card are not changes to what was copied. A destination watcher
    /// passes `MutationEventFilter.destinationJunk` so a Finder visit to the
    /// verified lane (Reveal in Finder writes .DS_Store) is not mistaken
    /// for a damaged copy.
    init?(path: String, filter: MutationEventFilter? = nil,
          judge: DestinationChangeJudge? = nil,
          settled: @escaping @Sendable () -> Void = {},
          handler: @escaping @Sendable () -> Void) {
        let callbackBox = SourceMutationCallbackBox(filter: filter, judge: judge,
                                                    settled: settled, handler: handler)
        self.callbackBox = callbackBox
        self.judge = judge

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<SourceMutationCallbackBox>
                    .fromOpaque(info)
                    .retain()
                    .toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<SourceMutationCallbackBox>
                    .fromOpaque(info)
                    .release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                // UseCFTypes: eventPaths is a CFArray of CFString.
                let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                let unknownChangeSet = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagRootChanged
                        | kFSEventStreamEventFlagMount
                        | kFSEventStreamEventFlagUnmount)
                let forced = (0..<count).contains { eventFlags[$0] & unknownChangeSet != 0 }
                let metadataFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod
                    | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir)
                let eventMetadataOnly = (0..<count).map {
                    eventFlags[$0] != 0 && eventFlags[$0] & ~metadataFlags == 0
                }
                let metadataOnly = count > 0 && eventMetadataOnly.allSatisfy { $0 }
                Unmanaged<SourceMutationCallbackBox>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .receiveEvent(paths: paths, forced: forced, metadataOnly: metadataOnly,
                                  eventMetadataOnly: eventMetadataOnly)
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.20,
            flags
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        // Queue the baseline before FSEvents can queue a callback, but do not
        // let the walk start until the stream is live. This covers mutations
        // during capture without judging a stale event against no baseline.
        queue.suspend()
        if let judge { queue.async { judge.capture(); settled() } }
        guard FSEventStreamStart(stream) else {
            judge?.cancel()
            queue.resume()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
        queue.resume()
    }

    var isReady: Bool { (judge?.isReady ?? true) && !callbackBox.hasSeenMutation }

    /// Flush before teardown so a file change already committed by the kernel
    /// cannot hide in the stream's latency window while a terminal verdict is
    /// being published. The callback box records the event synchronously even
    /// if its main-actor UI task has not run yet.
    @discardableResult
    func stop() -> Bool {
        guard let stream else { return callbackBox.hasSeenMutation }
        if let judge {
            judge.cancel()
            self.stream = nil
            // No authority survives removal from AppModel. Do not block the
            // main actor waiting for a background destination read to finish.
            queue.async {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            return callbackBox.hasSeenMutation
        }
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        return callbackBox.hasSeenMutation
    }

    deinit {
        stop()
    }
}

/// A destination baseline is checked against the hashes carried by file_done.
/// Metadata alone cannot prove unchanged content. Capture and event checks run
/// on the stream queue, with current wipe authority suspended until they finish.
final class DestinationChangeJudge: @unchecked Sendable {
    struct Entry: Equatable {
        let size: Int64
        let mtimeNs: Int64
        let dev: UInt64
        let ino: UInt64
        let mode: UInt16
        var digest: UInt64?
        var isDir: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    }

    let root: String
    private let expected: [String: UInt64]
    private let resolvedRoot: String
    private let rootIdentity: Entry?
    private let lock = NSLock()
    private var snapshot: [String: Entry]?
    private var captureFailed = false
    private var checking = false
    private var cancelled = false
    var onCaptureFailed: (@Sendable () -> Void)?

    init(root: String, expectedHashes: [String: UInt64]) {
        self.root = root
        expected = expectedHashes
        if let real = realpath(root, nil) {
            resolvedRoot = String(cString: real)
            free(real)
        } else { resolvedRoot = root }
        rootIdentity = Self.entry(at: root)
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot != nil && !captureFailed && !checking && !cancelled
    }

    func beginChecking() { lock.lock(); checking = true; lock.unlock() }
    func endChecking() { lock.lock(); checking = false; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private static func entry(at path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Entry(size: Int64(st.st_size),
                     mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                         + Int64(st.st_mtimespec.tv_nsec),
                     dev: UInt64(st.st_dev), ino: UInt64(st.st_ino), mode: st.st_mode)
    }

    private func digest(_ path: String, matching entry: Entry) -> UInt64? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              UInt64(st.st_dev) == entry.dev, UInt64(st.st_ino) == entry.ino else { return nil }
        let before = st
        var hash = DestinationXXH64()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while !isCancelled {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 {
                guard fstat(fd, &st) == 0,
                      st.st_size == before.st_size,
                      st.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                      st.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                      st.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                      st.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                      Self.entry(at: path) == entry else { return nil }
                return hash.value
            }
            hash.update(buffer.prefix(n))
        }
        return nil
    }

    func capture() {
        guard !isCancelled else { return }
        var entries: [String: Entry] = [:]
        var failed = expected.isEmpty || rootIdentity?.isDir != true
        var found = Set<String>()
        let rootURL = URL(fileURLWithPath: resolvedRoot)
        let walker = FileManager.default.enumerator(at: rootURL,
            includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
                failed = true
                return false
            })
        if let walker {
            while !failed, !isCancelled, let url = walker.nextObject() as? URL {
                let rel = String(url.path.dropFirst(resolvedRoot.count + 1))
                if MutationEventFilter.destinationJunk.isIgnorable(rel) {
                    walker.skipDescendants()
                    continue
                }
                guard var e = Self.entry(at: url.path) else { failed = true; break }
                if !e.isDir {
                    guard let hash = digest(url.path, matching: e) else { failed = true; break }
                    e.digest = hash
                    if let proof = expected[rel] {
                        guard hash == proof else { failed = true; break }
                        found.insert(rel)
                    }
                }
                entries[rel] = e
            }
        } else { failed = true }
        failed = failed || found.count != expected.count || !rootIsUnchanged()
        lock.lock()
        snapshot = failed || cancelled ? nil : entries
        captureFailed = failed
        lock.unlock()
        if failed { onCaptureFailed?() }
    }

    private func rootIsUnchanged() -> Bool {
        guard let now = Self.entry(at: root), let then = rootIdentity else { return false }
        return now.isDir && now.dev == then.dev && now.ino == then.ino
    }

    func provesChange(_ path: String, metadataOnly: Bool = false) -> Bool {
        lock.lock()
        let baseline = snapshot
        let failed = captureFailed || cancelled
        lock.unlock()
        guard !failed, let baseline, rootIsUnchanged() else { return true }
        let resolved = path
        // FSEvents reports resolved paths. Resolve only the root alias, never
        // a changed leaf symlink that could redirect this read elsewhere.
        let canonical = resolved.hasPrefix(root + "/")
            ? resolvedRoot + resolved.dropFirst(root.count) : resolved
        if canonical == resolvedRoot || canonical == root { return false }
        guard canonical.hasPrefix(resolvedRoot + "/") else { return true }
        let rel = String(canonical.dropFirst(resolvedRoot.count + 1))
        if MutationEventFilter.destinationJunk.isIgnorable(rel) { return false }
        let now = Self.entry(at: canonical)
        let then = baseline[rel]
        switch (then, now) {
        case (nil, nil): return false // a vanished pre-arm staging file
        case (nil, _), (_, nil): return true
        case (var a?, let b?):
            let expectedDigest = a.digest
            a.digest = nil
            if a.isDir && b.isDir { return a.dev != b.dev || a.ino != b.ino }
            guard a == b else { return true }
            if metadataOnly { return false }
            guard let hash = digest(canonical, matching: b) else { return true }
            return hash != expectedDigest
        }
    }
}

/// Streaming xxHash64, seed zero, matching the engine's file_done checksum.
/// The buffer retains at most 31 bytes between reads.
struct DestinationXXH64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261
    private var v1 = p1 &+ p2
    private var v2 = p2
    private var v3: UInt64 = 0
    private var v4: UInt64 = 0 &- p1
    private var total: UInt64 = 0
    private var tail: [UInt8] = []
    private static func rotate(_ x: UInt64, _ n: UInt64) -> UInt64 { (x << n) | (x >> (64 - n)) }
    private static func word(_ bytes: [UInt8], _ i: Int, _ count: Int = 8) -> UInt64 {
        var value: UInt64 = 0
        for j in 0..<count { value |= UInt64(bytes[i + j]) << (8 * j) }
        return value
    }
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotate(acc &+ input &* p2, 31) &* p1
    }
    mutating func update(_ bytes: ArraySlice<UInt8>) {
        total &+= UInt64(bytes.count)
        let data = tail + bytes
        var i = 0
        while i + 32 <= data.count {
            v1 = Self.round(v1, Self.word(data, i))
            v2 = Self.round(v2, Self.word(data, i + 8))
            v3 = Self.round(v3, Self.word(data, i + 16))
            v4 = Self.round(v4, Self.word(data, i + 24))
            i += 32
        }
        tail = Array(data[i...])
    }
    var value: UInt64 {
        var h = Self.p5
        if total >= 32 {
            h = Self.rotate(v1, 1) &+ Self.rotate(v2, 7) &+ Self.rotate(v3, 12) &+ Self.rotate(v4, 18)
            for v in [v1, v2, v3, v4] { h = (h ^ Self.round(0, v)) &* Self.p1 &+ Self.p4 }
        }
        h &+= total
        var i = 0
        while i + 8 <= tail.count {
            h ^= Self.round(0, Self.word(tail, i))
            h = Self.rotate(h, 27) &* Self.p1 &+ Self.p4
            i += 8
        }
        if i + 4 <= tail.count {
            h ^= Self.word(tail, i, 4) &* Self.p1
            h = Self.rotate(h, 23) &* Self.p2 &+ Self.p3
            i += 4
        }
        while i < tail.count {
            h ^= UInt64(tail[i]) &* Self.p5
            h = Self.rotate(h, 11) &* Self.p1
            i += 1
        }
        h ^= h >> 33; h &*= Self.p2
        h ^= h >> 29; h &*= Self.p3
        return h ^ (h >> 32)
    }
}

/// Which event paths a watcher may disregard. Deliberately narrow: only
/// names macOS itself writes into any folder it displays or indexes.
struct MutationEventFilter: Sendable {
    let isIgnorable: @Sendable (String) -> Bool
    /// Also drop events that only changed metadata (xattrs, inode fields)
    /// on the paths that remain. Source watchers only: see `sourceJunk`.
    var ignoresMetadataOnly = false

    /// Exactly what the engine never copies (dumptruck/ignore.py
    /// IGNORE_NAMES + IGNORE_PATTERNS; keep the two lists in step), matched
    /// on any path component below the watched card, because the engine
    /// skips a junk directory whole.
    static let engineJunkNames: Set<String> = [
        ".DS_Store", ".Trashes", ".TemporaryItems", ".Spotlight-V100", ".fseventsd",
        ".metadata_never_index", ".com.apple.timemachine.donotpresent",
        ".DocumentRevisions-V100", ".MobileBackups", ".PKInstallSandboxManager",
        "System Volume Information", "$RECYCLE.BIN", "Thumbs.db", "desktop.ini",
    ]
    static func isEngineJunk(_ name: String) -> Bool {
        if engineJunkNames.contains(name) { return true }
        return name.hasPrefix("._") || name.hasPrefix(".dumptruck-")
            || name.contains(".dumptruck-partial-")
            || name.hasPrefix(".DocumentRevisions-V100") || name.hasPrefix(".Spotlight-V100")
            || name.hasPrefix(".MobileBackups")
    }

    /// Browsing a card in Finder must not cost the offload (Joshua,
    /// 2026-09-28: "in Offshoot I can open stuff in Finder all the time").
    /// A Finder visit writes .DS_Store, AppleDouble "._" sidecars (exFAT
    /// cards), and last-opened tags. None of it is copied, and none of it
    /// can change what the engine attests: its checks are size, mtime and
    /// a full byte re-read, and a tag moves none of those. So a source
    /// watcher ignores exactly the engine's junk plus metadata-only events;
    /// any content write, create, delete or rename still fires, as does an
    /// unknown change set (forced). Paths outside `root` never match, so
    /// the filter fails closed on anything it cannot place.
    static func sourceJunk(root: String) -> MutationEventFilter {
        let roots = Set([root, (root as NSString).resolvingSymlinksInPath].map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        })
        var filter = MutationEventFilter { path in
            guard let base = roots.first(where: { path.hasPrefix($0 + "/") }) else {
                return false
            }
            let rel = String(path.dropFirst(base.count + 1))
            return (rel as NSString).pathComponents.contains {
                MutationEventFilter.isEngineJunk($0)
            }
        }
        filter.ignoresMetadataOnly = true
        return filter
    }

    static let destinationJunk = MutationEventFilter { path in
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name.hasPrefix("._") { return true }
        // Volume-root litter (indexing, trash, event log) lives at the top
        // of the drive, but a lane root is never the volume root, so any
        // of these names under a lane are a component of the path itself.
        let components = (path as NSString).pathComponents
        return components.contains { $0 == ".Spotlight-V100" || $0 == ".fseventsd"
                                     || $0 == ".Trashes" || $0 == ".TemporaryItems" }
    }
}
