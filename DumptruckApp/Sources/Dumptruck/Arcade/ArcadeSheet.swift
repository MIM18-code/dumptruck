import SwiftUI
import AppKit

/// The Dump Yard: four mini games for the wait while a card hauls. Opened
/// from the toolbar; entirely cosmetic — no game may ever obscure a verdict
/// (it lives in a sheet the operator dismisses).
struct ArcadeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var game = 0
    @State private var windowVisible = true
    /// The sheet's window is key. Opening Settings (⌘,) or Help on top keeps
    /// the app active and the sheet visible, so scenePhase and occlusion both
    /// said "live" while every key went to the other window and the truck
    /// crashed unattended (Joshua, 2026-09-28).
    @State private var windowKey = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("The Dump Yard", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                Picker("", selection: $game) {
                    Text("Gravel Drop").tag(0)
                    Text("Checksum Pairs").tag(1)
                    Text("Convoy").tag(2)
                    Text("Scavenger").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            if let job = statusJob {
                ArcadeJobStatus(job: job)
            }
            // The sheet COVERS the job cards, so a standing failure must not
            // hide behind a calm active/queued row (codex v0.4.x review,
            // F6): any failed/unverified job the main window would show gets
            // its own row here, independent of the status row above.
            if let alarm = alarmJob, alarm.id != statusJob?.id {
                ArcadeJobStatus(job: alarm)
            }
            // Pause means PAUSE: the games stay mounted and their loops gate
            // on `paused`, so an app switch never destroys a run (Opus games
            // review, CRITICAL: swapping the view out of the tree wiped
            // @State — score, lives, board — while the copy promised "keep
            // playing"). The material overlay also blocks game gestures.
            Group {
                let live = scenePhase == .active && windowVisible && windowKey
                ZStack {
                    switch game {
                    case 0: GravelDropView(paused: !live)
                    case 1: ChecksumPairsView(paused: !live)
                    case 2: ConvoyView(paused: !live)
                    default: ScavengerView(paused: !live)
                    }
                    if !live {
                        ContentUnavailableView("Dump Yard paused",
                                               systemImage: "pause.circle",
                                               description: Text(scenePhase == .active && windowVisible
                                                   ? "Click here to keep playing."
                                                   : "Return to Dumptruck to keep playing."))
                            .background(.regularMaterial)
                            // A click on an already-key sheet posts no
                            // become-key notification; re-read here so a
                            // missed one can never leave the game stuck.
                            .onTapGesture { refreshWindowVisibility() }
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 380)
        }
        .padding(16)
        .onChange(of: game) { _, _ in
            // A game left mid-note must not keep ringing under its sibling.
            ArcadeSounds.stopAll()
        }
        .onAppear {
            // Let AppKit finish attaching the sheet before resolving its own
            // window; the parent is legitimately occluded by that sheet.
            DispatchQueue.main.async { refreshWindowVisibility() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ArcadeSounds.stopAll() }
            refreshWindowVisibility()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                refreshWindowVisibility()
            }
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refreshWindowVisibility()
            }
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification)) { _ in
                refreshWindowVisibility()
            }
        .onDisappear { ArcadeSounds.stopAll() }
    }

    /// The status strip mirrors the job the operator is actually waiting on:
    /// an ACTIVE transfer first, then a queued one, then this session's
    /// newest settled job. Never `jobs.first` blind — with the journal
    /// restored into the same array, that could be a days-old record, and a
    /// queued job's calm chip must not stand in for a failing transfer
    /// (Opus games review, CRITICAL: fun layer obscuring safety state).
    private var statusJob: Job? {
        let live = model.jobs.filter { !$0.restoredFromJournal }
        return live.first(where: { $0.isRunning && $0.phase != .queued })
            ?? live.first(where: { $0.isRunning })
            ?? live.first
    }

    /// The newest standing failure the MAIN WINDOW would show — live jobs
    /// always, restored receipts unless the operator cleared THAT receipt
    /// (the shared ID rule in ReceiptVisibility; codex verify F1 replaced
    /// the duplicated timestamp math that could hide a post-clear failure).
    /// Rendered as its own row; the verdict still comes only from
    /// Job.verdict via the shared badge.
    private var alarmJob: Job? {
        let raw = UserDefaults.standard.string(
            forKey: ReceiptVisibility.clearedIDsKey) ?? ""
        return model.jobs.first(where: { job in
            guard !job.isRunning,
                  job.verdict == .failed || job.verdict == .unverified else { return false }
            return !ReceiptVisibility.isCleared(job, raw: raw)
        })
    }

    private func refreshWindowVisibility() {
        // Resolve the ATTACHED SHEET, not its parent: AppKit correctly marks
        // the parent occluded while the sheet is open, which would otherwise
        // pause the game the instant it appeared.
        let key = NSApp.keyWindow
        let window = (key?.sheetParent != nil ? key : key?.attachedSheet)
            ?? NSApp.windows.first { $0.sheetParent != nil && $0.isVisible }
            ?? NSApp.mainWindow
        // An attached sheet can report an empty occlusionState while it is
        // visibly frontmost.  Treat only actual hiding/minimization as hidden;
        // scenePhase separately handles another app taking focus.
        windowVisible = window?.isVisible == true
            && window?.isMiniaturized != true
            && window?.sheetParent?.isMiniaturized != true
        // Key status of that same window. The resign/become pair can arrive
        // in either order when focus moves between two of our windows, so
        // this reads the state rather than trusting which notification fired.
        windowKey = window?.isKeyWindow == true
    }
}

/// A modal game may cover the job card, so repeat the SAME Job.verdict at the
/// top of the sheet. This is a pointer, not a second safety state machine.
private struct ArcadeJobStatus: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: 8) {
            Text(job.label)
                .font(.caption.monospaced())
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            VerdictBadge(verdict: job.verdict, phaseText: job.phase.rawValue)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
