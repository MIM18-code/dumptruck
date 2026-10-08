import AppKit
import SwiftUI
import UserNotifications

/// The About panel names the camera components the engine bundles, with the
/// versions the vendors want shown. ARRI's Partner Program asks for the
/// exact line "ARRI Image SDK Version X / ARRI MXF Library Version Y"; the
/// helper prints it from the headers it was built against, so the panel can
/// never drift from the runtime.
enum CameraComponents {
    /// Runs `<engineRoot>/tools/arri-probe --version` once and caches it.
    /// Absent helper (public build before ARRI approval) means no line.
    nonisolated(unsafe) private static var cachedArriLine: String??

    static func arriLine(engineRoot: String) -> String? {
        if let cached = cachedArriLine { return cached }
        let helper = "\(engineRoot)/tools/arri-probe"
        var result: String? = nil
        if FileManager.default.isExecutableFile(atPath: helper) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: helper)
            p.arguments = ["--version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            if (try? p.run()) != nil {
                try? pipe.fileHandleForWriting.close()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, line.hasPrefix("ARRI Image SDK Version") { result = line }
            }
        }
        cachedArriLine = .some(result)
        return result
    }

    static func creditsText(engineRoot: String) -> NSAttributedString {
        var lines: [String] = [
            "Camera media copy and verification for production.",
            "",
            "Camera components:",
        ]
        if let arri = arriLine(engineRoot: engineRoot) {
            lines.append(arri)
            lines.append("ARRI and ALEXA are trademarks of Arnold & Richter Cine Technik GmbH & Co. Betriebs KG. Uses JPEG XS licensed by Fraunhofer IIS.")
        } else {
            lines.append("ARRIRAW via a separately installed ARRI Reference Tool")
        }
        // Name only what this engine actually bundles. RED's SDK agreement
        // (section 2) forbids implying certification or a performance
        // guarantee, so the panel says so outright.
        let bundled = CameraComponentTerms.formatsPresent(engineRoot: engineRoot)
            .filter { $0 != "ARRI" }
        if !bundled.isEmpty {
            lines.append("\(ListFormatter.localizedString(byJoining: bundled)) runtimes, under the Dumptruck camera component terms.")
        }
        lines.append("No camera maker certifies Dumptruck or guarantees its performance.")
        lines.append("")
        lines.append("Third-party notices ship in the app's legal folder.")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
        ])
    }

    @MainActor
    static func showAboutPanel(engineRoot: String) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: creditsText(engineRoot: engineRoot),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Quitting mid-transfer must be a decision, not an accident: an abandoned
/// engine child keeps writing with no owner, no eject interlock, and no
/// sleep assertion — and the job never seals manifests.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate,
                         @preconcurrency UNUserNotificationCenterDelegate {
    static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let jobID = userInfo[CompletionNotification.jobIDKey] as? String
        let reportPath = userInfo[CompletionNotification.reportPathKey] as? String
        Task { @MainActor in
            Self.model?.handleNotificationAction(
                action, jobID: jobID, reportPath: reportPath)
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Same one-sound rule as AppModel.notify: the truck clip already
        // played when effects are on, so the banner stays silent; with them
        // off, the system sound is the completion's only audible cue
        // (Joshua, 2026-09-28).
        var options: UNNotificationPresentationOptions = [.banner]
        if !UserDefaults.standard.bool(forKey: Pref.soundEffects) {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model,
              model.jobs.contains(where: { $0.isRunning }) else { return .terminateNow }
        // Queued cards have no engine and nothing copied: quitting costs a
        // re-queue, not a copy. The critical "mid-copy" alert over a queue
        // that never started cried wolf (Joshua, 2026-09-28).
        if !model.jobs.contains(where: { $0.isRunning && $0.phase != .queued }) {
            let queued = model.jobs.filter { $0.phase == .queued }.count
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = queued == 1
                ? "1 card is queued and hasn't started. Quit anyway?"
                : "\(queued) cards are queued and haven't started. Quit anyway?"
            alert.informativeText = "Nothing has been copied from them yet. When Dumptruck "
                + "reopens they are listed as never started; queue them again to offload."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            model.terminateAllEngines()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "A transfer is still running"
        alert.informativeText = "Quitting stops the engine mid-copy. Nothing already "
            + "verified is lost, but this run will NOT finish or seal manifests — "
            + "the result is \(Job.Verdict.unverified.displayLine) until a full run completes."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model.terminateAllEngines()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Also covers a harmless in-flight inspection when no transfer was
        // running (applicationShouldTerminate returns immediately in that case).
        Self.model?.terminateAllEngines()
    }
}
