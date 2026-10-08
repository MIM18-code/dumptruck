import AppKit
import SwiftUI
import UserNotifications



/// ⌥⌘J: collapse both rails to 56pt icon spines — the explicit,
/// operator-controlled answer to "the rails cost width on a laptop".
/// Never automatic; the interlock icons stay visible even collapsed.
struct FocusJobsCommand: View {
    @AppStorage("focusJobs") private var focusJobs = false

    var body: some View {
        Toggle("Focus on Jobs", isOn: $focusJobs)
            .keyboardShortcut("j", modifiers: [.option, .command])
    }
}

/// ⇧⌘V: Commands cannot read the environment directly, so the window
/// action lives in a small view, like HelpMenuCommand.
struct VerifyCustodyCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Verify Existing Custody…") { openWindow(id: "verify") }
            .keyboardShortcut("v", modifiers: [.command, .shift])
    }
}

struct DumptruckCoreApplication: App {
    @StateObject private var model = AppModel()
    /// Owned by the app, not a view: the verify window can close and reopen
    /// on the same run, and the result reaches the workbench either way.
    @StateObject private var existingVerificationModel = ExistingVerificationModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Pref.menuBarHUD) private var menuBarHUD = true

    var body: some Scene {
        // A single-instance safety tool: one window, one state, never two
        // Start buttons over one job list.
        Window("Dumptruck", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear {
                    AppDelegate.model = model
                    if CameraComponentTerms.shouldAskAtLaunch(
                        CameraComponentTerms.status(engineRoot: model.engineRoot)) {
                        model.cameraTermsShown = true
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Dumptruck") {
                    CameraComponents.showAboutPanel(engineRoot: model.engineRoot)
                }
                if CameraComponentTerms.status(engineRoot: model.engineRoot) != .notApplicable {
                    Button("Camera Component Terms…") { model.cameraTermsShown = true }
                }
            }
            // The setup actions had no menu items or shortcuts; the only way
            // in was the mouse (Joshua, 2026-09-28). ⌘Return starts from
            // anywhere, including the card-name field, where plain Return
            // only ends the edit. Start explains itself when blocked.
            CommandGroup(replacing: .newItem) {
                Button("Choose Source Folder…") {
                    model.chooseFolder(as: "source")
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Choose Destination Folder…") {
                    model.chooseDestinationFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Batch Sources…") {
                    model.chooseBatchSources()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                VerifyCustodyCommand()
                Divider()
                // ⌘R, not ⌘Return: the Batch Sources window's Start owns
                // ⌘Return, and one chord must never mean two launches.
                Button("Start Offload") {
                    model.startOrExplain()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                FocusJobsCommand()
            }
            CommandGroup(replacing: .importExport) {
                Button("Job History & CSV Export…") {
                    model.historyShown = true
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                HelpMenuCommand()
            }
        }

        // A window, not a sheet on the main window: a re-verify can run for
        // hours, and the sheet held the workbench modal the whole time
        // (Joshua, 2026-09-28). Closing it while a run is in flight asks
        // first (ExistingVerificationView).
        Window("Verify Existing Custody", id: "verify") {
            ExistingVerificationView(model: existingVerificationModel)
                .onAppear {
                    // Every run starts from this window, so wiring here always
                    // precedes the first result.
                    existingVerificationModel.onSettled = { [weak model = model] folder, summary in
                        model?.recordLaterVerification(folder: folder, summary: summary)
                    }
                }
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentMinSize)

        Window("Dumptruck Help", id: "help") {
            HelpGuideView()
        }
        .defaultSize(width: 680, height: 760)
        .windowResizability(.contentSize)

        // A window, not a sheet: the main window stays live underneath, so
        // the sources rail keeps taking drops while the list is up and each
        // card joins it. One instance, like the help window.
        Window("Batch Sources", id: "batch") {
            BatchSourceStagingView(stagingModel: model.batchStagingModel)
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $menuBarHUD) {
            MenuBarHUDView()
                .environmentObject(model)
        } label: {
            MenuBarHUDLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

package enum DumptruckApplication {
    @MainActor
    package static func main() {
        DumptruckCoreApplication.main()
    }
}
