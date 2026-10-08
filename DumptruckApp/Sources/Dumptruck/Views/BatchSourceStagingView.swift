import SwiftUI
import AppKit

public struct BatchSourceStagingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var stagingModel: BatchSourceStagingModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.queueMode) private var queueMode = "off"
    // Read only to re-check the cards when Settings › Organize changes: the
    // lanes and the {Project} refusal depend on both.
    @AppStorage(Pref.folderTemplate) private var folderTemplate = "{Project}/Raws"
    @AppStorage(Pref.projectName) private var projectName = ""
    @State private var dropTargeted = false
    @State private var confirmClear = false

    init(stagingModel: BatchSourceStagingModel) {
        self.stagingModel = stagingModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let generalErr = stagingModel.generalError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Semantics.dangerText)
                    Text(generalErr)
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.dangerText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Semantics.danger.opacity(Semantics.wash))
                Divider()
            }

            if model.destinationPaths.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Semantics.warningText)
                    Text("No destination drives yet. Add them in the main window; the cards here wait and are checked as soon as you do.")
                        .font(Typo.safety)
                        .foregroundStyle(Semantics.warningText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Semantics.warning.opacity(Semantics.wash))
                Divider()
            }

            summaryBar
            Divider()

            candidateList

            Divider()
            footerActions
        }
        .frame(minWidth: 680, minHeight: 480)
        // This is a window, so the rail behind it keeps taking drops. The
        // whole list is a drop target too, for the same reason the whole
        // rail is: plug in a stack, drag them over one after another.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Semantics.source,
                              style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .dropDestination(for: URL.self) { urls, _ in
            // Same split as the rail: files become one staged set, folders
            // pass through. A refused set is reported here and adds nothing,
            // so the rows already inspected are left alone.
            do {
                let split = try AppModel.splitDroppedPaths(urls.map(\.path))
                guard !split.ordered.isEmpty else { return false }
                stagingModel.addCandidates(paths: split.ordered, appModel: model)
                Haptics.alignment()
                return true
            } catch {
                stagingModel.generalError = error.localizedDescription
                Haptics.level()
                return false
            }
        } isTargeted: { hovering in
            withAnimation(.snappy) { dropTargeted = hovering }
        }
        .onAppear {
            model.batchStagingShown = true
            stagingModel.revalidateAll(appModel: model)
            if stagingModel.candidates.contains(where: {
                $0.status == .pending || $0.status == .awaitingDestinations
            }) {
                stagingModel.startSerialInspection(appModel: model)
            }
        }
        // Closing the window with the red button keeps the candidates: they
        // stay listed on the sources rail, which reopens this window.
        .onDisappear { model.batchStagingShown = false }
        // A destination change re-runs the full preflight from AppModel's
        // destinationPaths observer, window open or not (cards held for
        // "no destinations" need it; Codex review 2026-09-21, P2).
        .onChange(of: model.destinationFolderRelativePath) { _, _ in
            stagingModel.revalidateAll(appModel: model)
        }
        // Setting the project name in Settings clears a {Project} refusal
        // here without a round trip through a label edit.
        .onChange(of: folderTemplate) { _, _ in
            stagingModel.revalidateAll(appModel: model)
        }
        .onChange(of: projectName) { _, _ in
            stagingModel.revalidateAll(appModel: model)
        }
        .confirmationDialog("Clear this batch?", isPresented: $confirmClear) {
            Button("Clear Batch", role: .destructive) { clearBatch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(Semantics.sourceText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch Sources")
                    .font(.headline.weight(.semibold))
                Text("Every card is inspected before anything starts. Keep dropping cards here or on the rail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if stagingModel.isInspecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting sources…")
                        .font(Typo.evidence)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var summaryBar: some View {
        HStack(spacing: 20) {
            Label("\(stagingModel.readyCount) of \(stagingModel.candidates.count) Ready",
                  systemImage: stagingModel.canQueueBatch ? "checkmark.circle.fill" : "clock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(stagingModel.canQueueBatch ? Semantics.successText : .secondary)

            // One slow or unreadable card used to refuse the pile with no way
            // back short of removing and re-adding cards (Joshua, 2026-09-28).
            // Re-check runs the whole preflight again, labels kept.
            if stagingModel.hasRefusedCard {
                Button {
                    stagingModel.startSerialInspection(appModel: model)
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(stagingModel.isInspecting)
                .help("Inspect every card again against the current destinations")
            }

            if stagingModel.totalCandidateBytes > 0 {
                Text("Total: \(bytesString(stagingModel.totalCandidateBytes)) (\(stagingModel.totalCandidateFiles) files)")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Destinations: \(model.destinationPaths.count)")
                .font(Typo.evidence)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background.secondary)
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if stagingModel.candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No Sources Staged")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Drop cards or folders here, or click 'Add Folders…' below.")
                            .font(Typo.safetyBody)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    ForEach(stagingModel.candidates) { candidate in
                        BatchCandidateRow(candidate: candidate, stagingModel: stagingModel)
                    }
                }
            }
            .padding(14)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button("Add Folders…") {
                openSourcePanel()
            }
            .buttonStyle(.bordered)

            // The Queueing preference, shown where it decides something: a
            // batch honors it (it used to run serially no matter what).
            Picker("Run", selection: $queueMode) {
                Text("All at once").tag("off")
                Text("One at a time").tag("single")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Same setting as Settings › Transfers › Queueing. One at a time keeps a spinning drive from thrashing between write streams.")

            Spacer()

            // Destructive, so it asks first and owns no key. Esc used to be
            // bound here and threw away a whole pile of labeled cards with
            // no prompt, while the red close button kept them (Joshua,
            // 2026-09-28).
            Button("Clear Batch…", role: .destructive) {
                confirmClear = true
            }
            .disabled(stagingModel.candidates.isEmpty)

            // Esc closes the window the way the red button does: the pile
            // stays on the sources rail, which reopens this window.
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Close this window. The cards stay staged on the sources rail.")

            // ⌘Return, not Return: the label fields are editable, and Return
            // there commits the label.
            Button(startTitle) {
                switch stagingModel.queueBatch(appModel: model) {
                case .success:
                    dismiss()
                case .failure:
                    break
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!stagingModel.cardsReadyToQueue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// The button says what it would do. "Start Batch (2)" on a disabled
    /// button read as "starts 2" while three more cards were still pending
    /// (Joshua, 2026-09-28).
    private var startTitle: String {
        let total = stagingModel.candidates.count
        guard total > 0 else { return "Start" }
        if stagingModel.cardsReadyToQueue {
            return total == 1 ? "Start 1 Card" : "Start \(total) Cards"
        }
        let waiting = max(stagingModel.notReadyCount, 1)
        return waiting == 1 ? "Waiting on 1 card…" : "Waiting on \(waiting) cards…"
    }

    private var clearMessage: String {
        let count = stagingModel.candidates.count
        return "Removes \(count == 1 ? "the staged card" : "all \(count) staged cards") and their labels "
            + "from the batch. Nothing on the cards or drives is touched."
    }

    /// A cleared batch leaves nothing staged: loose sets that only this
    /// batch referred to are scratch and go now.
    private func clearBatch() {
        let abandoned = stagingModel.candidates.map(\.path)
        stagingModel.cancelStaging()
        for path in abandoned { model.releaseLooseSourceIfUnused(path) }
        dismiss()
    }

    private func openSourcePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Sources"
        if panel.runModal() == .OK {
            let paths = panel.urls.map(\.path)
            stagingModel.addCandidates(paths: paths, appModel: model)
        }
    }
}

struct BatchCandidateRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var candidate: BatchSourceCandidate
    @ObservedObject var stagingModel: BatchSourceStagingModel
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: candidate.path.hasPrefix("/Volumes/") ? "sdcard.fill" : "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Semantics.sourceText)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(candidate.volumeName)
                            .font(.callout.weight(.semibold))
                        Text(candidate.path)
                            .font(Typo.evidence.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        statusBadge
                    }

                    if let ins = candidate.inspection {
                        HStack(spacing: 12) {
                            Text(ins.formatName)
                                .font(Typo.evidence.weight(.medium))
                            if !ins.reelName.isEmpty {
                                Text("Reel: \(ins.reelName)")
                                    .font(Typo.evidence)
                            }
                            Text("\(ins.files) files")
                                .font(Typo.evidence)
                            Text(bytesString(ins.bytes))
                                .font(Typo.evidence)
                        }
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("Card Label:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Label", text: $candidate.customLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .frame(maxWidth: 240)
                            .focused($labelFocused)
                            // Checked once typing pauses, and at once on
                            // Return or when the field loses focus.
                            .onChange(of: candidate.customLabel) { _, _ in
                                stagingModel.scheduleLabelRevalidation(appModel: model)
                            }
                            .onSubmit {
                                stagingModel.updateLabel(id: candidate.id, newLabel: candidate.customLabel,
                                                         appModel: model)
                            }
                            .onChange(of: labelFocused) { _, focused in
                                guard !focused else { return }
                                stagingModel.updateLabel(id: candidate.id, newLabel: candidate.customLabel,
                                                         appModel: model)
                            }
                        Spacer()
                    }

                    // Same-model cards mount with one default name; the batch
                    // numbers them. Say so next to the field, so the DIT knows
                    // which card became "NO NAME_2" before anything starts
                    // (Joshua, 2026-09-28). Informational, not a fault.
                    if let note = candidate.renameNote, candidate.status == .ready {
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .foregroundStyle(.secondary)
                            Text(note)
                                .font(Typo.evidence)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if case .refused(let reason) = candidate.status {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(Semantics.dangerText)
                            Text(reason)
                                .font(Typo.safety)
                                .foregroundStyle(Semantics.dangerText)
                        }
                        .padding(.vertical, 2)
                    }

                    if !candidate.projectedLanes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Target Lanes:")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                            ForEach(candidate.projectedLanes, id: \.self) { lane in
                                Text(volumeRelativePath(lane))
                                    .font(Typo.evidence.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Button {
                    let removedPath = candidate.path
                    stagingModel.removeCandidate(id: candidate.id, appModel: model)
                    model.releaseLooseSourceIfUnused(removedPath)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .help("Remove candidate from batch")
                .accessibilityLabel("Remove source candidate")
            }
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(strokeColor, lineWidth: 1)
        )
    }

    private var strokeColor: Color {
        switch candidate.status {
        case .ready: return Semantics.success.opacity(0.4)
        case .refused: return Semantics.danger.opacity(0.4)
        case .inspecting: return Semantics.running.opacity(0.4)
        case .awaitingDestinations: return Semantics.warning.opacity(0.35)
        case .pending: return Color.secondary.opacity(0.2)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch candidate.status {
        case .pending:
            Text("Pending")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: .capsule)
                .foregroundStyle(.secondary)
        case .awaitingDestinations:
            // A step still to take, not a fault: amber, never the red
            // Refused chip.
            Label("Waiting for destinations", systemImage: "hourglass")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Semantics.warning.opacity(Semantics.chip), in: .capsule)
                .foregroundStyle(Semantics.warningText)
        case .inspecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Inspecting…")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Semantics.running.opacity(Semantics.chip), in: .capsule)
            .foregroundStyle(Semantics.runningText)
        case .ready:
            Label("Ready", systemImage: "checkmark")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Semantics.success.opacity(Semantics.chip), in: .capsule)
                .foregroundStyle(Semantics.successText)
        case .refused:
            Label("Refused", systemImage: "xmark")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Semantics.danger.opacity(Semantics.chip), in: .capsule)
                .foregroundStyle(Semantics.dangerText)
        }
    }
}
