import Foundation

/// "0 KB", never "Zero KB": the running card reads "0 KB of 37.7 MB" for
/// its first second, and the spelled-out word breaks the numeric column.
/// A fresh formatter per call, not a shared global: Foundation formatters
/// are not thread-safe, every caller is on the main actor today, and
/// nothing in Swift 5 language mode would catch a future background
/// caller (opus review). Construction is cheap next to a SwiftUI body.
func bytesString(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: n)
}

func speedString(_ bytesPerSec: Double) -> String {
    "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .file))/s"
}

func etaString(_ seconds: Int) -> String {
    if seconds > 90 { return "\(Int((Double(seconds) / 60).rounded())) min" }
    return "\(max(seconds, 1))s"
}

/// A display projection of the raw ETA. The estimator remains untouched;
/// this value only controls what the operator sees.
struct ETADisplayProjection: Equatable {
    let secondsRemaining: Int
    let finishDate: Date

    var relativeText: String { etaString(secondsRemaining) }
}

/// Holds the projected completion time through ordinary estimator jitter.
/// Estimates above 90 seconds move only when their projected finish changes
/// by more than two minutes. Once the raw estimate reaches 90 seconds, the
/// display returns to raw second-by-second values.
struct ETADisplayHold {
    private(set) var heldFinishDate: Date?

    mutating func project(secondsRemaining rawSeconds: Int?, now: Date = Date())
        -> ETADisplayProjection? {
        guard let rawSeconds else {
            heldFinishDate = nil
            return nil
        }
        let safeSeconds = max(1, rawSeconds)
        if safeSeconds <= 90 {
            heldFinishDate = nil
            return ETADisplayProjection(
                secondsRemaining: safeSeconds,
                finishDate: now.addingTimeInterval(TimeInterval(safeSeconds)))
        }

        let proposedFinish = now.addingTimeInterval(TimeInterval(safeSeconds))
        if let heldFinishDate {
            if heldFinishDate <= now || abs(proposedFinish.timeIntervalSince(heldFinishDate)) > 120 {
                self.heldFinishDate = proposedFinish
            }
        } else {
            heldFinishDate = proposedFinish
        }
        guard let heldFinishDate else { return nil }
        let heldSeconds = max(1, Int(heldFinishDate.timeIntervalSince(now).rounded()))
        return ETADisplayProjection(
            secondsRemaining: heldSeconds,
            finishDate: heldFinishDate)
    }
}

/// Wall-clock projection of an ETA: "4:18 PM". The AD asking when camera gets
/// the mag back wants a time, not an interval — this is the same estimate the
/// relative ETA carries, rendered in the operator's locale clock.
private let finishClockFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .none
    df.timeStyle = .short
    return df
}()

func finishClockString(secondsRemaining: Int) -> String {
    finishClockString(
        finishDate: Date().addingTimeInterval(TimeInterval(max(0, secondsRemaining))))
}

func finishClockString(finishDate: Date) -> String {
    finishClockFormatter.string(from: finishDate)
}

func elapsedString(_ interval: TimeInterval) -> String {
    let s = Int(interval)
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 90 { return "\(s / 60)m \(s % 60)s" }
    return "\(s)s"
}

/// "/Volumes/Extreme SSD/DUMPTRUCK_TEST/Raws" -> "Extreme SSD/DUMPTRUCK_TEST/Raws"
/// The operator must see WHERE footage goes, not just the deepest folder name.
func volumeRelativePath(_ p: String) -> String {
    p.hasPrefix("/Volumes/") ? String(p.dropFirst("/Volumes/".count)) : p
}

/// Display name for a lane terminus / rail row: the volume name for mounted
/// volumes, the last path component for folder endpoints.
func endpointName(_ path: String) -> String {
    if path.hasPrefix("/Volumes/") {
        let rel = path.dropFirst("/Volumes/".count)
        if let first = rel.split(separator: "/").first { return String(first) }
    }
    return (path as NSString).lastPathComponent
}

/// Component-boundary containment for rail participant math. Raw hasPrefix
/// makes `/Volumes/DEST2` look like a child of `/Volumes/DEST`, while exact-only
/// comparisons lose chosen subfolders on mounted volumes.
/// LEXICAL containment on component boundaries — zero filesystem access, so
/// it is the ONLY containment helper render paths and body-read gates may
/// use (codex v0.4.x verify F2: `pathIsAtOrInside` resolves symlinks, and a
/// wedged mount froze rendering through it). Inputs are the model's own
/// already-standardized paths; symlink-resolving containment stays below for
/// click, assignment, eject, and launch validation.
func pathIsAtOrInsideLexically(_ path: String, root: String) -> Bool {
    let p = lexicallyCleanedPath(path)
    let r = lexicallyCleanedPath(root)
    return p == r || p.hasPrefix(r + "/")
}

/// Pure-string defensive cleanup for the lexical helper's operands: collapse
/// repeated slashes, drop "." segments, strip the trailing slash. Assignment
/// standardizes at ingress; this keeps a stray non-canonical string (codex
/// verify round 3, NEW 3) from miscomparing. ".." is deliberately NOT
/// resolved — that cannot be done honestly without the filesystem.
func lexicallyCleanedPath(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "/./", with: "/")
    while out.contains("//") {
        out = out.replacingOccurrences(of: "//", with: "/")
    }
    if out.hasSuffix("/.") { out.removeLast(2) }
    while out.hasSuffix("/"), out.count > 1 { out.removeLast() }
    return out.isEmpty ? "/" : out
}

func pathIsAtOrInside(_ path: String, root: String) -> Bool {
    let p = (URL(fileURLWithPath: path).standardizedFileURL.path as NSString)
        .resolvingSymlinksInPath
    let r = (URL(fileURLWithPath: root).standardizedFileURL.path as NSString)
        .resolvingSymlinksInPath
    return p == r || p.hasPrefix(r + "/")
}
