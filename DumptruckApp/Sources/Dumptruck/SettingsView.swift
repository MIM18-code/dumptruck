import SwiftUI

// Every setting here toggles REAL engine or app behavior — no decoration.
// Keys are read by AppModel.start() and the mount/completion handlers.
enum Pref {
    static let verifyMode = "verifyMode"                 // "full" | "fast"
    static let queueMode = "queueMode"                   // "off" | "single"
    static let sourceReread = "sourceReread"             // Bool, default true
    static let reverifyExisting = "reverifyExisting"     // Bool, default false
    static let extraHashes = "extraHashes"               // comma list: md5,sha1,sha256,c4
    static let makeReports = "makeReports"               // Bool, default true
    static let thumbnails = "thumbnails"                 // Bool, default true
    static let slateFirst = "slateFirst"                 // Bool, default false
    static let openReportWhenDone = "openReportWhenDone" // Bool, default false
    static let autoSourceOnMount = "autoSourceOnMount"   // Bool, default false
    static let autoEjectWhenSafe = "autoEjectWhenSafe"   // Bool, default false
    static let notifyOnCompletion = "notifyOnCompletion" // Bool, default true
    static let webhookEnabled = "webhookEnabled"         // Bool, default false
    static let webhookURL = "webhookURL"                 // String, default ""
    static let soundEffects = "soundEffects"             // Bool, default true — truck SFX
    static let haptics = "haptics"                       // Bool, default true — trackpad taps
    static let menuBarHUD = "menuBarHUD"                 // Bool, default true
    static let folderTemplate = "folderTemplate"         // e.g. {Project}/Raws
    static let projectName = "projectName"
    static let projectRecents = "projectRecents"         // pipe-separated
    static let textScale = "textScale"                   // "standard" | "large" | "extraLarge"

    /// Every preference the model or its gates read. AppModel republishes
    /// only when one of these actually changes value (see
    /// preferencesDidChange), never on the notification alone.
    static let all: [String] = [
        verifyMode, queueMode, sourceReread, reverifyExisting, extraHashes,
        makeReports, thumbnails, slateFirst, openReportWhenDone,
        autoSourceOnMount, autoEjectWhenSafe, notifyOnCompletion,
        webhookEnabled, webhookURL, soundEffects, haptics, menuBarHUD,
        folderTemplate, projectName, projectRecents, textScale, "engineRoot",
    ]
}

/// One grouped-form row: a control with its explanatory caption attached, so
/// the grouped style doesn't split the caption into its own separated row.
@ViewBuilder
private func settingRow<Content: View>(caption: String,
                                       @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        content()
        Text(caption)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    @AppStorage(Pref.textScale) private var textScaleRaw = TextScale.standard.rawValue

    var body: some View {
        TabView {
            TransferSettings()
                .tabItem { Label("Transfers", systemImage: "arrow.left.arrow.right") }
            OrganizeSettings()
                .tabItem { Label("Organize", systemImage: "folder.badge.gearshape") }
            IngestPresetSettingsView()
                .tabItem { Label("Presets", systemImage: "bookmark") }
            ReportSettings()
                .tabItem { Label("Reports", systemImage: "doc.text.image") }
            CardSettings()
                .tabItem { Label("Cards", systemImage: "sdcard") }
            DisplaySettings()
                .tabItem { Label("Display", systemImage: "textformat.size") }
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "gearshape.2") }
        }
        // Grouped forms scroll internally, so the window needs an explicit
        // height — without one each tab's ideal height collapses.
        .frame(width: 620, height: 560)
        .environment(\.dynamicTypeSize, TextScale.current(textScaleRaw).dynamicTypeSize)
    }
}

// MARK: - Presets

private struct IngestPresetSettingsView: View {
    @ObservedObject private var store = IngestPresetStore.shared
    @State private var pendingDelete: IngestPreset?
    @State private var deleteError: String?

    var body: some View {
        Form {
            Text("Named presets save destination anchors and the ingest settings that travel with them. Applying one validates the currently mounted drives first; it never creates folders, starts a transfer, or grants a verdict.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = store.storageNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Preset file") {
                Text(store.fileURL.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // A failed delete keeps the preset (the store rolls back) and says
            // why, as the destinations rail's Presets menu does; it used to be
            // discarded, so the row simply stayed with no explanation.
            if let deleteError {
                Label(deleteError, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.presets.isEmpty {
                Label("No named presets yet", systemImage: "bookmark.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.presets) { preset in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(preset.name)
                                .font(.body.weight(.medium))
                            Spacer()
                            Button(role: .destructive) {
                                pendingDelete = preset
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(HoverHighlightButtonStyle())
                            .help("Delete preset \(preset.name)")
                            .accessibilityLabel("Delete preset \(preset.name)")
                        }
                        Text("\(preset.destinationAnchors.count) destination\(preset.destinationAnchors.count == 1 ? "" : "s") · \(preset.settings.verifyMode == "fast" ? "fast" : "full") verification · \(preset.settings.queueMode == "single" ? "single queue" : "parallel queue")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !preset.mirroredDestinationFolder.isEmpty {
                            Text("mirror …/\(preset.mirroredDestinationFolder)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        // One click on a bare trash icon used to delete a saved setup
        // outright (Joshua, 2026-09-28).
        .confirmationDialog(
            "Delete preset \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { preset in
            Button("Delete Preset", role: .destructive) {
                deleteError = store.delete(id: preset.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Its saved destinations and settings are removed. Drives and folders are not touched.")
        }
    }
}

// MARK: - Transfers

/// The two curated verification bundles plus Custom. Pure data, so the check
/// suite can pin exactly what each level sets — a preset that quietly
/// weakened verification would be a safety bug wearing a convenience label.
enum VerificationLevel: String, CaseIterable {
    case standard, maximum, custom

    struct Values: Equatable {
        var verifyMode: String
        var sourceReread: Bool
        var reverifyExisting: Bool
        var extraHashes: String
    }

    /// The working DIT bar: full byte verification + a second source read.
    static let standardValues = Values(
        verifyMode: "full", sourceReread: true,
        reverifyExisting: false, extraHashes: "")
    /// Every check on: prior offloads re-read instead of trusted, and every
    /// extra checksum recorded alongside xxHash64.
    static let maximumValues = Values(
        verifyMode: "full", sourceReread: true,
        reverifyExisting: true, extraHashes: "c4,md5,sha1,sha256")

    static func classify(_ current: Values) -> VerificationLevel {
        if current == standardValues { return .standard }
        if current == maximumValues { return .maximum }
        return .custom
    }

    /// nil for .custom — selecting Custom changes nothing.
    var values: Values? {
        switch self {
        case .standard: return Self.standardValues
        case .maximum: return Self.maximumValues
        case .custom: return nil
        }
    }
}

private struct TransferSettings: View {
    @AppStorage(Pref.verifyMode) private var verifyMode = "full"
    @AppStorage(Pref.queueMode) private var queueMode = "off"
    @AppStorage(Pref.sourceReread) private var sourceReread = true
    @AppStorage(Pref.reverifyExisting) private var reverifyExisting = false
    @AppStorage(Pref.extraHashes) private var extraHashes = ""
    @AppStorage(Pref.autoEjectWhenSafe) private var autoEjectWhenSafe = false

    private let hashOptions = ["md5", "sha1", "sha256", "c4"]

    var body: some View {
        Form {
            Section {
                settingRow(caption: "One-at-a-time keeps a spinning backup drive from thrashing between two write streams.") {
                    Picker("Queueing", selection: $queueMode) {
                        Text("Off — all transfers run at the same time").tag("off")
                        Text("One transfer at a time — later cards wait their turn").tag("single")
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Section {
                settingRow(caption: levelCaption) {
                    Picker("Verification level", selection: verificationLevel) {
                        Text("Standard").tag(VerificationLevel.standard)
                        Text("Maximum").tag(VerificationLevel.maximum)
                        Text("Custom").tag(VerificationLevel.custom)
                    }
                    .pickerStyle(.segmented)
                    .help("One-click bundles for the individual verification controls below")
                }

                Picker("Verification", selection: $verifyMode) {
                    Text("Full — every destination byte re-read and compared").tag("full")
                    Text("Fast — size check only (NOT verified, nothing sealed)").tag("fast")
                }
                .pickerStyle(.radioGroup)
                if verifyMode == "fast" {
                    Label("Fast copies are never sealed into MHL manifests and never earn "
                          + Job.Verdict.safeToWipe.displayLine
                          + ". A later full offload verifies and seals them.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.warningText)
                }
            }

            Section {
                settingRow(caption: "Skipping this forfeits \(Job.Verdict.safeToWipe.displayLine) for the run.") {
                    Toggle("Re-read the source after copying (catches failing cards and readers)",
                           isOn: $sourceReread)
                }
                settingRow(caption: "Slower on big continuation cards; use when a destination drive is suspect.") {
                    Toggle("Re-verify previously offloaded files instead of trusting sealed history",
                           isOn: $reverifyExisting)
                }
            }

            Section {
                settingRow(caption: "xxHash64 always runs and is what manifests seal. Extras ride along at no extra disk reads and are written to the per-file table in each offload's receipt JSON (Reports folder).") {
                    LabeledContent("Extra checksums") {
                        HStack {
                            ForEach(hashOptions, id: \.self) { h in
                                Toggle(h.uppercased(), isOn: bindingFor(h))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }

            Section {
                settingRow(caption: "Ejects only after full verification on 2+ physical devices. Never ejects on any lesser outcome.") {
                    Toggle("Auto-eject the source once it is "
                           + Job.Verdict.safeToWipe.displayLine, isOn: $autoEjectWhenSafe)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var verificationLevel: Binding<VerificationLevel> {
        Binding(
            get: {
                VerificationLevel.classify(.init(
                    verifyMode: verifyMode, sourceReread: sourceReread,
                    reverifyExisting: reverifyExisting, extraHashes: extraHashes))
            },
            set: { level in
                guard let v = level.values else { return }  // Custom: keep the toggles
                verifyMode = v.verifyMode
                sourceReread = v.sourceReread
                reverifyExisting = v.reverifyExisting
                extraHashes = v.extraHashes
            })
    }

    private var levelCaption: String {
        switch verificationLevel.wrappedValue {
        case .standard:
            return "The working DIT bar: full byte verification plus a second "
                + "source read. Makes fresh cards eligible for "
                + "\(Job.Verdict.safeToWipe.displayLine) — the verdict still "
                + "requires 2+ separate drives and every runtime check."
        case .maximum:
            return "Everything on: prior offloads are re-read instead of trusted, "
                + "and MD5, SHA-1, SHA-256 and C4 ride along with xxHash64 "
                + "(persisted in the receipt while reports are on). Required "
                + "before a continuation card can earn "
                + Job.Verdict.safeToWipe.displayLine + "."
        case .custom:
            return "Your own mix — set the individual controls below."
        }
    }

    private func bindingFor(_ h: String) -> Binding<Bool> {
        Binding(
            get: { extraHashes.split(separator: ",").map(String.init).contains(h) },
            set: { on in
                var set = Set(extraHashes.split(separator: ",").map(String.init))
                if on { set.insert(h) } else { set.remove(h) }
                extraHashes = set.sorted().joined(separator: ",")
            })
    }
}

// MARK: - Organize

private struct OrganizeSettings: View {
    @AppStorage(Pref.folderTemplate) private var folderTemplate = "{Project}/Raws"
    @AppStorage(Pref.projectName) private var projectName = ""
    @AppStorage(Pref.projectRecents) private var projectRecents = ""
    @FocusState private var projectFocused: Bool

    private let tokens = [
        "{Project}", "{VolumeName}", "{CardLabel}", "{CameraFormat}", "{Reel}",
        "{Date}", "{YYYY}", "{MM}", "{DD}", "{JobID}"
    ]
    private var recents: [String] {
        projectRecents.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            LabeledContent("Project") {
                HStack {
                    TextField("", text: $projectName, prompt: Text("PROJECT_NAME"))
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .frame(width: 220)
                        .focused($projectFocused)
                        .onSubmit { rememberProject() }
                        // Tabbing or clicking away saves it too: a name typed
                        // without Return never reached the recents menu.
                        .onChange(of: projectFocused) { _, focused in
                            if !focused { rememberProject() }
                        }
                    if !recents.isEmpty {
                        Menu {
                            ForEach(recents, id: \.self) { r in
                                Button(r) { projectName = r }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton).hoverHighlight()
                        .fixedSize()
                        .help("Recent projects")
                        .accessibilityLabel("Recent projects")
                    }
                }
            }

            LabeledContent("Folder template") {
                TextField("", text: $folderTemplate, prompt: Text("{Project}/Raws"))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(width: 320)
            }
            settingRow(caption: "The card-name folder is always appended last — it is the continuation key. Card folders must keep resolving to the same path for top-ups to work, so avoid date tokens in the standing template.") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(tokens.prefix(5), id: \.self) { t in
                            Button(t) { folderTemplate += folderTemplate.isEmpty ? t : "/" + t }
                                .controlSize(.small)
                                .monospaced()
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(tokens.suffix(5), id: \.self) { t in
                            Button(t) { folderTemplate += folderTemplate.isEmpty ? t : "/" + t }
                                .controlSize(.small)
                                .monospaced()
                        }
                    }
                }
            }

            Section {
                LabeledContent("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(previewError == nil ? Color.secondary : Semantics.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = previewNote {
                            Label(note, systemImage: "exclamationmark.triangle.fill")
                                .font(Typo.safety)
                                .foregroundStyle(Semantics.warningText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        // Same inputs, same validation as an actual Start — the preview must
        // never show a path a real run would refuse or render differently.
        // The project is the saved value, empty included, so a template that
        // names {Project} previews the same path Start writes: without a
        // project name that segment is left out, and the note below says so.
        if let err = previewError {
            return "⚠︎ " + err
        }
        let ctx = TemplateContext.organizePreview(project: projectName)
        let rendered = TemplateRenderer.render(folderTemplate, context: ctx)
        return "<destination>/" + (rendered.isEmpty ? "" : rendered + "/") + "<CardName>/"
    }

    private var previewError: String? {
        TemplateRenderer.validate(folderTemplate,
                                  context: TemplateContext.organizePreview(project: projectName))
    }

    /// A blank project name is allowed; the preview still has to say the
    /// {Project} folder is missing so nobody is surprised at the drive.
    private var previewNote: String? {
        guard previewError == nil,
              TemplateRenderer.omitsProject(folderTemplate, project: projectName) else { return nil }
        return TemplateRenderer.projectOmittedNote
    }

    private func rememberProject() {
        guard !projectName.isEmpty else { return }
        var r = recents.filter { $0 != projectName }
        r.insert(projectName, at: 0)
        projectRecents = r.prefix(8).joined(separator: "|")
    }
}

// MARK: - Reports

private struct ReportSettings: View {
    @AppStorage(Pref.makeReports) private var makeReports = true
    @AppStorage(Pref.thumbnails) private var thumbnails = true
    @AppStorage(Pref.slateFirst) private var slateFirst = false
    @AppStorage(Pref.openReportWhenDone) private var openReportWhenDone = false

    var body: some View {
        Form {
            settingRow(caption: "Written to Reports/ at each destination plus a local library copy — never inside the sealed card folder.") {
                Toggle("Generate an HTML + PDF report after every offload", isOn: $makeReports)
            }

            Toggle("Clip thumbnails (first / middle / last frame)", isOn: $thumbnails)
                .disabled(!makeReports)
            Toggle("First thumbnail from frame 0 (slate logging)", isOn: $slateFirst)
                .disabled(!makeReports || !thumbnails)
            Toggle("Open the report when the offload finishes", isOn: $openReportWhenDone)
                .disabled(!makeReports)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cards

private struct CardSettings: View {
    @AppStorage(Pref.autoSourceOnMount) private var autoSourceOnMount = false
    @AppStorage(Pref.notifyOnCompletion) private var notifyOnCompletion = true
    @AppStorage(Pref.webhookEnabled) private var webhookEnabled = false
    @AppStorage(Pref.webhookURL) private var webhookURL = ""
    @AppStorage(Pref.soundEffects) private var soundEffects = true
    @AppStorage(Pref.haptics) private var haptics = true
    @State private var bearerSecret = ""
    @State private var savedBearerSecret = ""
    @State private var webhookSecretError: String?

    var body: some View {
        Form {
            Section {
                settingRow(caption: "When no source is selected, a freshly inserted card is picked up and inspected automatically. Transfers still require pressing Start.") {
                    Toggle("Auto-select a newly mounted volume as the source", isOn: $autoSourceOnMount)
                }
            }

            Section {
                Toggle("Notify when a transfer finishes", isOn: $notifyOnCompletion)
                Toggle("Truck sound effects (start / done / failed)", isOn: $soundEffects)
                settingRow(caption: "Force Touch trackpads only — a plain mouse or an external trackpad without haptics feels nothing either way.") {
                    Toggle("Trackpad haptics (drops, blocked actions, milestones, verdicts)", isOn: $haptics)
                }
            }

            Section {
                settingRow(caption: "Sends a JSON payload when a transfer finishes. Local paths and file names are never included.") {
                    Toggle("Remote HTTPS webhook notification", isOn: $webhookEnabled)
                }

                if webhookEnabled {
                    LabeledContent("Webhook URL") {
                        TextField("https://example.com/webhook", text: $webhookURL)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .frame(minWidth: 320)
                    }
                    if let err = webhookValidationError {
                        Text("⚠︎ \(err)")
                            .font(.caption)
                            .foregroundStyle(Semantics.warningText)
                    }
                    settingRow(caption: "Saved securely in the macOS Keychain — never stored in settings preferences, journals, or reports.") {
                        LabeledContent("Bearer secret (optional)") {
                            SecureField("Secret token stored in Keychain", text: $bearerSecret)
                                .textFieldStyle(.roundedBorder)
                                .monospaced()
                                .frame(minWidth: 320)
                                .onChange(of: bearerSecret) { _, newValue in
                                    guard newValue != savedBearerSecret else { return }
                                    do {
                                        try KeychainWebhookSecretStore.shared.saveSecret(newValue)
                                        savedBearerSecret = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if savedBearerSecret.isEmpty {
                                            savedBearerSecret = ""
                                        }
                                        bearerSecret = savedBearerSecret
                                        webhookSecretError = nil
                                    } catch {
                                        // Do not leave an unsaved token in the field:
                                        // delivery reads Keychain, so displaying the
                                        // failed edit would falsely imply it is active.
                                        bearerSecret = savedBearerSecret
                                        webhookSecretError = "Could not save the bearer secret to the macOS Keychain. The previous saved secret remains active."
                                    }
                                }
                        }
                    }
                    if let webhookSecretError {
                        Text("⚠︎ \(webhookSecretError)")
                            .font(.caption)
                            .foregroundStyle(Semantics.warningText)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            savedBearerSecret = KeychainWebhookSecretStore.shared.loadSecret() ?? ""
            bearerSecret = savedBearerSecret
            webhookSecretError = nil
        }
    }

    private var webhookValidationError: String? {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch WebhookEndpointValidator.validate(urlString: trimmed) {
        case .success:
            return nil
        case .failure(let err):
            return err.description
        }
    }
}

// MARK: - Display

private struct DisplaySettings: View {
    @AppStorage(Pref.textScale) private var textScaleRaw = TextScale.standard.rawValue
    @AppStorage(Pref.menuBarHUD) private var menuBarHUD = true

    var body: some View {
        Form {
            Section {
                settingRow(caption: "Enlarges every label in the workbench, including verdicts, lane captions and rail echoes. Column widths are unchanged — long names truncate rather than reflow.") {
                    Picker("Text size", selection: $textScaleRaw) {
                        ForEach(TextScale.allCases) { s in Text(s.title).tag(s.rawValue) }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            Section {
                settingRow(caption: "Shows active jobs, their combined speed, and the most urgent outstanding verdict. Clicking it opens Dumptruck.") {
                    Toggle("Show transfer status in the menu bar", isOn: $menuBarHUD)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Engine

private struct EngineSettings: View {
    @AppStorage("engineRoot") private var engineRoot =
        EngineRootResolver.resolve()
    @State private var testResult: String?

    var body: some View {
        Form {
            LabeledContent("Engine folder") {
                HStack {
                    TextField("", text: $engineRoot)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .frame(minWidth: 320)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let path = panel.url?.path {
                            engineRoot = path
                        }
                    }
                }
            }
            LabeledContent("") {
                HStack {
                    Button("Test Engine") { testEngine() }
                    if let r = testResult {
                        Text(r).font(.caption).foregroundStyle(
                            r.hasPrefix("OK") ? Semantics.successText : Semantics.dangerText)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testEngine() {
        let engineRoot = self.engineRoot
        let python = "\(engineRoot)/.venv/bin/python"
        guard FileManager.default.fileExists(atPath: python) else {
            testResult = "No engine at \(python)"
            return
        }
        // Off the main thread: a slow .venv import beachballed the whole app
        // for the child's duration (round-24 finding).
        testResult = "Testing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.engineVersionProbe(engineRoot: engineRoot,
                                                  python: python)
            DispatchQueue.main.async { testResult = outcome }
        }
    }

    private static func engineVersionProbe(engineRoot: String,
                                           python: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "dumptruck.cli", "--version"]
        p.currentDirectoryURL = URL(fileURLWithPath: engineRoot)
        p.environment = EngineRootResolver.processEnvironment(root: engineRoot)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            // Close the PARENT'S copy of the write end, or EOF never arrives
            // and readDataToEndOfFile blocks the main thread forever (Kimi K3
            // PR review F1). Read BEFORE waiting so a chatty child can never
            // deadlock against a full pipe buffer either.
            try? pipe.fileHandleForWriting.close()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            p.waitUntilExit()
            let summary = out.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exact parse of "(protocol N)" — a substring test accepted
            // "protocol 30" as protocol 3 (round-15 PR review finding 6).
            let reported: Int? = summary.range(
                of: #"\(protocol (\d+)\)"#, options: .regularExpression
            ).flatMap { r in
                Int(summary[r].dropFirst("(protocol ".count).dropLast())
            }
            if p.terminationStatus != 0 {
                return "Engine error: \(out.suffix(120))"
            } else if reported != EngineContract.protocolVersion {
                return "Engine mismatch — app requires protocol "
                    + "\(EngineContract.protocolVersion), engine reports "
                    + "\(reported.map(String.init) ?? "none")"
            } else {
                return "OK — \(summary)"
            }
        } catch {
            return "Launch failed: \(error.localizedDescription)"
        }
    }
}
