import SwiftUI
import UniformTypeIdentifiers

/// Right rail: where bytes go TO. Staged destinations carry the capacity
/// gauge, shortfall flag, rendered template path, lock, and eject — a row of
/// their own on a surface that isn't also holding cards.
struct DestinationsRail: View {
    @EnvironmentObject var model: AppModel
    @Binding var forceEjectTarget: Volume?
    @AppStorage("focusJobs") private var focusJobs = false
    @ObservedObject private var presetStore = IngestPresetStore.shared
    @State private var dropTargeted = false
    @State private var savePresetShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if focusJobs {
                RailSpine(role: .destination, forceEjectTarget: $forceEjectTarget)
            } else {
                railHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        stagedSection
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Divider()
                railFooter
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Semantics.destination,
                              style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .dropDestination(for: ShelfDragPayload.self) { items, _ in
            let paths = items.flatMap(\.paths)
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
            let landed = RailMotion.run(reduceMotion: reduceMotion) {
                model.assignDroppedDestinations(paths)
            }
            if landed { Haptics.alignment() } else { Haptics.level() }
            return landed
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.14)) { dropTargeted = targeted }
        }
        .sheet(isPresented: $savePresetShown) {
            SaveIngestPresetSheet()
                .environmentObject(model)
        }
    }

    // One quiet header; the two-separate-drives badge lives on it so the
    // count survives the removal of the section scaffolding (2026-08-26
    // facelift — the badge is a safety affordance and must never vanish).
    private var railHeader: some View {
        // Green only when the count is 2+ AND no staged endpoints share a
        // volume — two folders on one drive are ONE copy, and this badge must
        // never pre-grant the two-copy condition the engine hasn't attested
        // (Kimi K3 workbench audit finding 1).
        let twoSeparate = model.destinationPaths.count >= 2 && sameDriveGroups.isEmpty
        return VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 8) {
                Spacer()
                if !model.destinationPaths.isEmpty {
                    Label {
                        Text("\(model.destinationPaths.count)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: twoSeparate
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .font(Typo.safety)
                    .foregroundStyle(twoSeparate
                                     ? AnyShapeStyle(Semantics.successText)
                                     : AnyShapeStyle(Semantics.warningText))
                    .help("Two destinations on separate physical devices are required before a card can be called safe to wipe. The engine resolves physical devices at Start; its attestation is what decides \(Job.Verdict.safeToWipe.displayLine).")
                }
                Text("Destinations")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Semantics.destinationText)
            }
            if !model.destinationFolderRelativePath.isEmpty {
                Text("mirror …/\(model.destinationFolderRelativePath)")
                    .font(Typo.evidenceQuiet.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                    .help("This relative folder is created on every destination when the job starts")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var stagedSection: some View {
        if model.destinationPaths.isEmpty {
            // Empty means invitation — and the safety sentence stays: it is
            // the one line a first-time operator must read.
            RailDropSlot(title: "Add two drives",
                         subtitle: "A card needs two separate drives before it can be called safe to wipe.",
                         tint: Semantics.destination)
        } else {
            let sameDrive = sameDriveGroups
            ForEach(model.destinationPaths, id: \.self) { path in
                DestinationCard(path: path,
                                sharesDriveWithAnother: sameDrive.contains(path),
                                forceEjectTarget: $forceEjectTarget)
                    .transition(.scale.combined(with: .opacity))
            }
            if !sameDrive.isEmpty {
                Label("Endpoints on the same volume are ONE copy — the engine's attestation decides.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }
        }
    }

    /// Two destination endpoints resolving to the same volume are one copy —
    /// cheap and honest (volume UUID only; physical-disk resolution stays the
    /// engine's job at Start).
    private var sameDriveGroups: Set<String> {
        var byUUID: [String: [String]] = [:]
        for p in model.destinationPaths {
            if let uuid = try? URL(fileURLWithPath: p)
                .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
                byUUID[uuid, default: []].append(p)
            }
        }
        return Set(byUUID.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    private var railFooter: some View {
        HStack {
            if !model.destinationFolderRelativePath.isEmpty {
                Button("Clear Mirrored Folder") {
                    model.clearMirroredDestinationFolder()
                }
                .font(.caption)
                .buttonStyle(HoverHighlightButtonStyle())
            }
            Spacer()
            presetMenu
            Button {
                model.chooseFolder(as: "dest")
            } label: {
                Label("Choose Mirrored Folder…", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .help("Copy TO an existing folder instead of a drive root — the "
                  + "card folder is created inside it")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var presetMenu: some View {
        Menu {
            Button {
                savePresetShown = true
            } label: {
                Label("Save Current as Preset…", systemImage: "bookmark")
            }

            Menu {
                if presetStore.presets.isEmpty {
                    Text("No saved presets")
                } else {
                    ForEach(presetStore.presets) { preset in
                        Button {
                            _ = model.applyIngestPreset(preset)
                        } label: {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Label("Apply Preset", systemImage: "arrow.down.doc")
            }

            Button {
                _ = model.applyLastIngestDestinations()
            } label: {
                Label("Use Last Destinations", systemImage: "clock.arrow.circlepath")
            }

            if !presetStore.presets.isEmpty {
                Divider()
                Menu {
                    ForEach(presetStore.presets) { preset in
                        Button(role: .destructive) {
                            if let error = presetStore.delete(id: preset.id) {
                                model.lastSetupError = error
                            }
                        } label: {
                            Text(preset.name)
                        }
                    }
                } label: {
                    Label("Delete Preset", systemImage: "trash")
                }
            }

            if let notice = presetStore.storageNotice {
                Divider()
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Semantics.warningText)
            }
        } label: {
            Label("Presets", systemImage: presetStore.storageNotice == nil
                  ? "bookmark"
                  : "bookmark.slash")
                .font(.caption)
        }
        .menuStyle(.borderlessButton).hoverHighlight()
        .help("Save, apply, delete, or restore destination presets")
        .accessibilityLabel("Destination presets")
    }
}

/// A staged destination: identity, lock, eject, capacity gauge with the
/// shortfall flag, and the rendered template path — everything the operator
/// checks before trusting a drive with footage.
struct DestinationCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let path: String
    let sharesDriveWithAnother: Bool
    @Binding var forceEjectTarget: Volume?

    private var volume: Volume? {
        model.volumes.first { pathIsAtOrInside(path, root: $0.path) }
    }

    private var templatePreflight: TemplateRenderer.PreflightReport {
        let d = UserDefaults.standard
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""
        let volName = model.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let context = TemplateContext(
            project: project,
            volumeName: volName,
            cardLabel: model.label,
            date: Date(),
            cameraFormat: (model.inspection?.formatName == "?" ? "" : (model.inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: model.inspection?.reelName ?? "",
            jobID: "PREVIEW"
        )
        return TemplateRenderer.preflight(template, context: context)
    }

    @ViewBuilder
    private func preflightBadge(_ report: TemplateRenderer.PreflightReport) -> some View {
        if !report.template.isEmpty {
            if report.hasMalformed {
                Label {
                    Text(report.summaryDescription)
                        .font(Typo.safety)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .foregroundStyle(Semantics.warningText)
                .help(report.summaryDescription)
                .accessibilityLabel("Destination template malformed: \(report.accessibilitySummary)")
            } else if report.hasUnavailable {
                Label {
                    Text(report.summaryDescription)
                        .font(Typo.safety)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(Semantics.warningText)
                .help(report.summaryDescription)
                .accessibilityLabel("Destination template tokens unavailable: \(report.accessibilitySummary)")
            } else if report.hasOmitted {
                // An unset project name is a note on the card, not a reason
                // to refuse it: the rendered path below shows where the
                // footage lands (Joshua, 2026-10-05).
                Label {
                    Text(report.summaryDescription)
                        .font(Typo.safety)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(Semantics.warningText)
                .help(report.summaryDescription)
                .accessibilityLabel("Destination template note: \(report.accessibilitySummary)")
            } else if report.hasFallback {
                Label {
                    Text(report.summaryDescription)
                        .font(Typo.safety)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .foregroundStyle(.secondary)
                .help("Placeholder values will resolve when live inputs are confirmed at start")
                .accessibilityLabel("Destination template fallback inputs: \(report.accessibilitySummary)")
            } else if !report.tokens.isEmpty {
                // "Tokens resolved (1)" was template-engine vocabulary on
                // an operator's card (Joshua, 2026-09-04). The rendered
                // path above already shows the result; this line only
                // needs to say the folder is settled, and the tooltip
                // keeps the placeholder-to-value detail for anyone curious.
                Label {
                    Text("Folder path ready")
                        .font(Typo.safety)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .foregroundStyle(.secondary)
                .help("Every placeholder in the folder template has a value:\n"
                      + report.tokens.map { "\($0.token): \($0.value ?? "")" }.joined(separator: "\n"))
                .accessibilityLabel("Destination folder path ready: \(report.accessibilitySummary)")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: volume == nil ? "folder.fill" : "externaldrive.fill")
                    .foregroundStyle(Semantics.destinationText)
                // Names in the system face; mono stays reserved for paths.
                Text(model.endpointDisplayName(path))
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let vol = volume, !model.canEject(vol) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Semantics.warningText)
                        .help("Participating in a transfer — do not remove")
                }
                if let vol = volume {
                    Button {
                        model.chooseDestinationFolder(on: vol.path)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .foregroundStyle(Semantics.destinationText)
                    .help("Choose a mirrored folder on \(vol.name). The same relative folder "
                          + "is created on every destination. Shortcut: ⇧⌘O")
                    .accessibilityLabel("Choose mirrored folder on \(vol.name)")
                    EjectControl(volume: vol, forceEjectTarget: $forceEjectTarget)
                }
                Button {
                    RailMotion.run(reduceMotion: reduceMotion) {
                        model.unassignDestination(path)
                    }
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .foregroundStyle(.tertiary)
                    .help("Remove from this job")
                    .accessibilityLabel("Remove destination from this job")
            }
            if let cap = Volume.capacity(ofPath: path) {
                CapacityGauge(free: cap.free, total: cap.total,
                              needed: (model.inspection?.bytes).flatMap { $0 > 0 ? $0 : nil })
            }
            if let rendered = model.effectiveDestinations([path], forSource: model.sourcePath).first,
               rendered != path {
                Text("…/" + volumeRelativePath(rendered).split(separator: "/")
                        .dropFirst().joined(separator: "/"))
                    .font(Typo.evidence.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                    .help("Mirrored destination folder + Organize template — the engine adds the card-name folder")
            }
            if !templatePreflight.template.isEmpty {
                preflightBadge(templatePreflight)
            }
            if sharesDriveWithAnother {
                Label("same drive as another destination", systemImage: "link")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
            }
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Semantics.destination.opacity(0.35)))
        .ejectGlide(isEjecting: volume.map {
            model.ejectingVolumePaths.contains($0.path)
        } ?? false)
        .contextMenu {
            if let vol = volume {
                Button("Choose Mirrored Folder Inside \(vol.name)…") {
                    model.chooseDestinationFolder(on: vol.path)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .draggable(URL(fileURLWithPath: path))
    }
}
