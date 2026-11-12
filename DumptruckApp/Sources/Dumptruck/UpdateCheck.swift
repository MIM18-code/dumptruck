import AppKit
import Foundation

/// A release on the public repository that is newer than this build.
struct AvailableUpdate: Equatable {
    /// Dotted numbers only: "0.6.1".
    let version: String
    /// The release's own title: "Dumptruck 0.6.1 beta".
    let name: String
    let pageURL: URL
    let downloadURL: URL?
}

/// Whether a newer Dumptruck is out. The app only tells the operator and
/// opens the download; it never fetches or installs a build by itself, so
/// what runs on the Mac is always something the operator chose to open.
/// The one request goes to GitHub's public API and carries nothing about
/// the Mac, its drives or its jobs.
enum UpdateCheck {
    static let releasesURL = URL(string: "https://api.github.com/repos/MIM18-code/dumptruck/releases?per_page=10")!
    /// At most one automatic check a day.
    static let interval: TimeInterval = 24 * 60 * 60
    private static let releasePathPrefix = "/MIM18-code/dumptruck/"

    /// "v0.6.1-beta" and "0.6.1 beta" are both [0, 6, 1]. Nil for anything
    /// that does not start with dotted numbers.
    static func numbers(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = numbers(candidate), let b = numbers(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The highest-numbered published release newer than `current`, from
    /// the API's JSON. Drafts are skipped; betas count, since every release
    /// so far is one. Links are kept only when they point at this project's
    /// own pages on github.com.
    static func newest(in data: Data, newerThan current: String) -> AvailableUpdate? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: AvailableUpdate?
        for release in list {
            if release["draft"] as? Bool == true { continue }
            guard let tag = release["tag_name"] as? String,
                  let parts = numbers(tag),
                  isNewer(tag, than: best?.version ?? current),
                  let page = ownLink(release["html_url"]) else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let dmg = assets.lazy.compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(".dmg") else { return nil }
                return ownLink(asset["browser_download_url"])
            }.first
            let title = (release["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            best = AvailableUpdate(
                version: parts.map(String.init).joined(separator: "."),
                name: (title?.isEmpty == false ? title : nil) ?? "Dumptruck \(tag)",
                pageURL: page, downloadURL: dmg)
        }
        return best
    }

    private static func ownLink(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix(releasePathPrefix),
              // A browser resolves dot segments, encoded or not, and
              // "/MIM18-code/dumptruck/../../other" lands elsewhere.
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { return nil }
        return url
    }
}

extension AppModel {
    /// The running app's version. Nil outside an app bundle (the check
    /// suite), where nothing is ever compared or fetched.
    static var runningVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The automatic check: once a day at most, and only when the operator
    /// has left it on. Called when the main window appears and from the
    /// model's 30-second timer, so an app left open keeps checking daily.
    /// It needs a bundle version, so a model built by the checks, which has
    /// none, makes no request.
    func checkForUpdatesIfDue(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Pref.checkForUpdates) else { return }
        let last = defaults.double(forKey: Pref.lastUpdateCheck)
        guard now.timeIntervalSince1970 - last >= UpdateCheck.interval,
              Self.runningVersion != nil else { return }
        // The attempt is recorded before the request, not after its answer:
        // a failed or slow check must not be repeated at every launch, and
        // a window that appears twice must not start two (Sol review).
        defaults.set(now.timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
        checkForUpdates(userAsked: false)
    }

    /// Ask GitHub for the release list. A check the operator asked for
    /// always answers, including "you have the newest" and "couldn't reach
    /// GitHub"; the automatic one stays silent unless there is news.
    func checkForUpdates(userAsked: Bool) {
        guard let current = Self.runningVersion else {
            if userAsked { updateNotice = "This build has no version number to compare." }
            return
        }
        var request = URLRequest(url: UpdateCheck.releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task { @MainActor [weak self] in
            // Ephemeral: no cookies, no cache on disk.
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            var body: Data?
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                body = data
            }
            guard let self else { return }
            guard let body else {
                if userAsked { self.updateNotice = "Couldn't reach GitHub to check for a newer version." }
                return
            }
            self.applyUpdateCheck(UpdateCheck.newest(in: body, newerThan: current),
                                  current: current, userAsked: userAsked)
        }
    }

    /// What a finished check shows. A version the operator hid stays hidden
    /// from the automatic check until a newer one is out; asking by hand
    /// shows it again.
    func applyUpdateCheck(_ update: AvailableUpdate?, current: String, userAsked: Bool) {
        if let update {
            let hidden = UserDefaults.standard.string(forKey: Pref.skippedUpdateVersion)
            if userAsked || hidden != update.version { availableUpdate = update }
            updateNotice = nil
        } else {
            availableUpdate = nil
            updateNotice = userAsked ? "Dumptruck \(current) is the newest version." : nil
        }
    }

    /// Hide this version's notice. The next version shows again.
    func hideAvailableUpdate() {
        if let update = availableUpdate {
            UserDefaults.standard.set(update.version, forKey: Pref.skippedUpdateVersion)
        }
        availableUpdate = nil
    }

    /// Open the disk image download in the browser, or the release page
    /// when the release carries no disk image.
    func openUpdateDownload() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL ?? update.pageURL)
    }
}
