import AppKit
import QuickLook
import SwiftUI

/// Read-only custody verification window. It deliberately uses VERIFIED/FAILED
/// evidence language and never renders SAFE TO WIPE, eject controls, or a Job
/// verdict: re-verifying a destination cannot prove that a source card is safe
/// to remove.
struct ExistingVerificationView: View {
    @ObservedObject var model: ExistingVerificationModel
    @Environment(\.dismiss) private var dismiss
    @State private var quickLookURL: URL?
    @State private var confirmStop = false
    @State private var closeOnceStopped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            folderSelection
            statusPanel
            if let summary = model.summary {
                evidencePanel(summary)
            }
            Spacer(minLength: 0)
            actionBar
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
        .quickLookPreview($quickLookURL)
        // While a run is live the title-bar close button is off (⌘W then
        // beeps), so the only way out is Close, which asks first. Closing
        // used to cancel an hours-long re-read without a word (Joshua,
        // 2026-09-28).
        .background(CloseButtonLock(locked: model.isRunning))
        .confirmationDialog("Stop verification?", isPresented: $confirmStop,
                            titleVisibility: .visible) {
            Button("Stop and Close", role: .destructive) {
                // Close once the verifier has actually stopped: the window
                // stays up saying "Cancelling…" until then, and the close
                // button is unlocked again by the time it closes.
                closeOnceStopped = true
                model.cancelVerification()
            }
            Button("Keep Verifying", role: .cancel) {}
        } message: {
            Text("The checksum re-read is still running. Stopping it leaves this folder unverified; you can run it again later.")
        }
        .onChange(of: model.isRunning) { _, running in
            guard !running, closeOnceStopped else { return }
            closeOnceStopped = false
            // After this update pass, so the lock has lifted first.
            Task { @MainActor in dismiss() }
        }
        .onDisappear {
            // Closing the window is a live cancellation, never an abandoned
            // child process that keeps reading a removable drive.
            if model.isRunning { model.cancelVerification() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Verify Existing Custody", systemImage: "checkmark.shield")
                .font(.title2.weight(.semibold))
            Text("Re-read destination checksums against its sealed ASC MHL history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("This verifies the selected destination only. It never authorizes wiping a source card.")
                .font(Typo.safety)
                .foregroundStyle(Semantics.warningText)
        }
    }

    private var folderSelection: some View {
        GroupBox("Existing destination folder") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Semantics.destinationText)
                        .accessibilityHidden(true)
                    if let path = model.selectedFolderPath {
                        Text(path)
                            .font(Typo.evidence.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Selected folder path \(path)")
                    } else {
                        Text("No folder selected")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No existing destination folder selected")
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Choose Folder…") { model.chooseFolder() }
                        .accessibilityLabel("Choose an existing destination folder")
                        .disabled(model.isRunning)
                    if model.selectedFolderPath != nil {
                        Button("Clear") { model.clearSelection() }
                            .buttonStyle(HoverHighlightButtonStyle())
                            .accessibilityLabel("Clear selected destination folder")
                            .disabled(model.isRunning)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        GroupBox("Verification") {
            VStack(alignment: .leading, spacing: 9) {
                switch model.status {
                case .idle:
                    Label("Ready to verify", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                    Text("The engine emits only a terminal summary for this command; per-file progress and current-file names are not available.")
                        .font(Typo.evidenceQuiet)
                        .foregroundStyle(.secondary)
                case .running, .cancelling:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.status == .cancelling
                             ? "Cancelling verification…"
                             : "Checking sealed custody…")
                            .font(Typo.safety)
                    }
                    Text("No per-file progress is emitted by the verify command.")
                        .font(Typo.evidenceQuiet)
                        .foregroundStyle(.secondary)
                case .verified:
                    Label("VERIFIED", systemImage: "checkmark.seal.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Semantics.successText)
                    if let summary = model.summary {
                        Text("\(summary.passed) sealed file\(summary.passed == 1 ? "" : "s") matched on a checksum re-read in \(formatSeconds(summary.seconds)).")
                            .font(Typo.evidence)
                        Text("F_NOCACHE: \(summary.fNocache ? "established" : "not established on every read")")
                            .font(Typo.evidenceQuiet)
                            .foregroundStyle(summary.fNocache ? Semantics.successText : Semantics.warningText)
                    }
                case .failed:
                    Label("FAILED", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Semantics.dangerText)
                    if let reason = model.failureReason {
                        Text(reason)
                            .font(Typo.safetyBody)
                            .foregroundStyle(Semantics.dangerText)
                            .textSelection(.enabled)
                    }
                    if !model.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("Engine diagnostics") {
                            Text(model.stderrText)
                                .font(Typo.evidence.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Verification status \(model.status.label)")
        }
    }

    private func evidencePanel(_ summary: ExistingVerificationSummary) -> some View {
        GroupBox("Custody evidence") {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 14) {
                        evidenceMetric("Passed", value: summary.passed,
                                       color: summary.failed.isEmpty
                                       ? Semantics.successText : Semantics.warningText)
                        evidenceMetric("Failed", value: summary.failed.count,
                                       color: summary.failed.isEmpty
                                       ? .secondary : Semantics.dangerText)
                        evidenceMetric("Missing", value: summary.missing.count,
                                       color: summary.missing.isEmpty
                                       ? .secondary : Semantics.dangerText)
                        evidenceMetric("New", value: summary.new.count,
                                       color: summary.new.isEmpty
                                       ? .secondary : Semantics.warningText)
                        evidenceMetric("Unverifiable", value: summary.unverifiable.count,
                                       color: summary.unverifiable.isEmpty
                                       ? .secondary : Semantics.dangerText)
                    }

                    evidenceList(title: "Checksum failures", values: summary.failed)
                    evidenceList(title: "Missing sealed files", values: summary.missing)
                    evidenceList(title: "Unmanifested new files", values: summary.new)
                    evidenceList(title: "Unverifiable files", values: summary.unverifiable)
                    evidenceList(title: "MHL chain problems", values: summary.chainProblems)
                    emittedPaths(title: "Reports emitted by the engine",
                                 values: summary.reportPaths)
                    emittedPaths(title: "Custody paths emitted by the engine",
                                 values: summary.custodyPaths)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
        }
    }

    private func evidenceMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(Typo.evidenceQuiet)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    @ViewBuilder
    private func evidenceList(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.safety)
                ForEach(Array(values.prefix(100)), id: \.self) { value in
                    Text(value)
                        .font(Typo.evidence.monospaced())
                        .textSelection(.enabled)
                }
                if values.count > 100 {
                    Text("… and \(values.count - 100) more")
                        .font(Typo.evidenceQuiet)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Semantics.dangerText)
        }
    }

    @ViewBuilder
    private func emittedPaths(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Typo.safety)
                ForEach(values, id: \.self) { path in
                    HStack(spacing: 8) {
                        Text(path)
                            .font(Typo.evidence.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Open") { model.openEmittedPath(path) }
                            .buttonStyle(HoverHighlightButtonStyle())
                            .accessibilityLabel("Open emitted path \(path)")
                            .disabled(!FinderEvidenceActions.isSafeExistingPath(path))
                        Button("Quick Look") { quickLookURL = URL(fileURLWithPath: path) }
                            .buttonStyle(HoverHighlightButtonStyle())
                            .accessibilityLabel("Quick Look emitted path \(path)")
                            .disabled(!FinderEvidenceActions.isSafeExistingPath(path))
                        Button("Reveal") { model.revealEmittedPath(path) }
                            .buttonStyle(HoverHighlightButtonStyle())
                            .accessibilityLabel("Reveal emitted path \(path) in Finder")
                            .disabled(!FinderEvidenceActions.isSafeExistingPath(path))
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Close") {
                if model.status == .running { confirmStop = true } else { dismiss() }
            }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close existing custody verification")
            Spacer()
            if model.isRunning {
                Button("Cancel Verification") { model.cancelVerification() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel the running custody verification")
            } else {
                Button("Verify Folder") { model.startVerification() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedFolderPath == nil)
                    .accessibilityLabel("Verify selected folder against its sealed ASC MHL custody")
            }
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        if seconds < 1 { return "less than 1 second" }
        return String(format: "%.1f seconds", seconds)
    }
}

/// Turns the hosting window's title-bar close button off while `locked`.
/// A disabled close button also refuses ⌘W (performClose beeps), and it
/// leaves SwiftUI's own window delegate alone, which replacing it would not.
private struct CloseButtonLock: NSViewRepresentable {
    let locked: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
        // On the first pass the view may not be in its window yet.
        Task { @MainActor in apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        view.window?.standardWindowButton(.closeButton)?.isEnabled = !locked
    }
}
