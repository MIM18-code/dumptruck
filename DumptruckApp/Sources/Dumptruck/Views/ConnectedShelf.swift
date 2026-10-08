import AppKit
import SwiftUI

func shelfEjectVolume(for endpoint: Endpoint, in volumes: [Volume]) -> Volume? {
    guard endpoint.kind == .volume else { return nil }
    return volumes.first { $0.path == endpoint.path }
}

/// Connected endpoints stay here until staged in a rail or used by a transfer.
struct ConnectedShelf: View {
    @EnvironmentObject var model: AppModel
    @Binding var forceEjectTarget: Volume?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("focusJobs") private var focusJobs = false
    @State private var selection = Set<String>()
    @State private var shelfWidth: CGFloat = 600
    @State private var selectionAnchor: String?
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var dropTargeted = false

    private struct ShelfEntry: Identifiable {
        let endpoint: Endpoint
        let canSource: Bool
        let canDestination: Bool
        var id: String { endpoint.path }
    }

    private var entries: [ShelfEntry] {
        // Same running-job exclusions the rails' AVAILABLE sections used:
        // an exact running source is not offerable as a source; a drive a
        // running job is writing into is not offerable as a destination.
        // Snapshots, not the computed lists: candidate computation resolves
        // symlinks and must stay off the render path (codex review F5). The
        // running-job filters below are pure string work.
        let runningJobs = model.jobs.filter { $0.isRunning }
        let sourceEligible = model.sourceCandidatesSnapshot.filter { c in
            !runningJobs.contains { $0.sourcePath == c.path }
        }
        let destEligible = model.destinationCandidatesSnapshot.filter { c in
            !runningJobs.contains { job in
                // Lexical only: this runs from body (codex verify F2).
                job.destinations.contains { pathIsAtOrInsideLexically($0, root: c.path) }
            }
        }
        let srcPaths = Set(sourceEligible.map(\.path))
        let dstPaths = Set(destEligible.map(\.path))
        var seen = Set<String>()
        var result: [ShelfEntry] = []
        for e in sourceEligible + destEligible {
            guard !seen.contains(e.path) else { continue }
            seen.insert(e.path)
            result.append(ShelfEntry(endpoint: e,
                                     canSource: srcPaths.contains(e.path),
                                     canDestination: dstPaths.contains(e.path)))
        }
        return result
    }

    /// Something is on a rail, so the shelf must exist as the place to
    /// drag it back to.
    private var somethingStaged: Bool {
        model.sourcePath != nil || !model.destinationPaths.isEmpty
            || !model.batchStagingModel.candidates.isEmpty
    }

    /// Focus on Jobs collapses chrome — but at a cold open there is nothing
    /// to focus ON, and the welcome copy points at this shelf; hiding it
    /// then would make step 1 a lie (facelift review).
    private var coldOpen: Bool {
        model.sourcePath == nil && model.destinationPaths.isEmpty
            && !model.jobs.contains { !$0.restoredFromJournal }
    }

    /// Arrival is an event, not a role: dual-eligible hardware pulses brand
    /// amber (chrome — the Brand contract only bars amber from verdict
    /// vocabulary); single-role tiles pulse their one eligible role color.
    private func pulseColor(_ entry: ShelfEntry) -> Color {
        if entry.canSource && entry.canDestination { return Brand.amber }
        return entry.canSource ? Semantics.source : Semantics.destination
    }

    var body: some View {
        let entries = entries
        Group {
            // The shelf stays on screen while anything is staged, even with
            // nothing left on it: it is the only place a card can be dragged
            // back to, and with every connected card on a rail it vanished
            // and "doesnt drag back" (Joshua, 2026-10-05).
            if !entries.isEmpty || somethingStaged, !focusJobs || coldOpen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        RailSectionHeader(title: "Connected")
                        let dumped = model.dumpedCardVolumes
                        if !dumped.isEmpty {
                            // The pile at wrap: every card a settled job
                            // read and one-click eject already allows.
                            Button {
                                model.ejectDumpedCards()
                                Haptics.alignment()
                            } label: {
                                Label(dumped.count == 1
                                      ? "Eject dumped card"
                                      : "Eject \(dumped.count) dumped cards",
                                      systemImage: "eject")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Eject every card whose offload is verified: "
                                  + dumped.map(\.name).joined(separator: ", "))
                            .accessibilityLabel("Eject \(dumped.count) dumped cards")
                        }
                        Spacer()
                        if !selection.isEmpty {
                            Text("\(selection.count) selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !entries.isEmpty {
                            Text("Drag to select · ⌘/⇧ click")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if entries.isEmpty {
                        RailDropSlot(title: "Everything connected is staged",
                                     subtitle: "drop a card here to take it off a rail",
                                     tint: Brand.amber)
                            .frame(maxWidth: .infinity)
                    } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                            ForEach(entries) { entry in
                                ShelfTile(endpoint: entry.endpoint,
                                          canSource: entry.canSource,
                                          canDestination: entry.canDestination,
                                          isSelected: selection.contains(entry.id),
                                          forceEjectTarget: $forceEjectTarget,
                                          stage: { stage(entry.id, as: $0, entries: entries) })
                                    .contentShape(Rectangle())
                                    // Drag first, click second. An exclusive
                                    // tap gesture applied before .draggable
                                    // owned the mouse-down, so a press-and-
                                    // move on a tile never became a drag and
                                    // nothing could be dropped on either
                                    // rail (Joshua, 2026-10-05). A
                                    // simultaneous tap selects on click and
                                    // stays out of the drag's way.
                                    .draggable(ShelfDragPayload(paths: selection.contains(entry.id)
                                        ? entries.map(\.id).filter { selection.contains($0) } : [entry.id]))
                                    .simultaneousGesture(TapGesture().onEnded {
                                        // A click on a tile's Source or
                                        // Destination button ends this tap
                                        // too. Settle the selection one turn
                                        // later so the button stages the
                                        // group the operator had selected,
                                        // whichever handler the system runs
                                        // first.
                                        DispatchQueue.main.async {
                                            select(entry.id, paths: entries.map(\.id))
                                        }
                                    })
                                    .volumeArrivalPulse(trigger: entry.endpoint.id, color: pulseColor(entry))
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: ConnectedShelfFramesKey.self,
                                            value: [entry.id: geometry.frame(in: .named("ConnectedShelfGrid"))])
                                    })
                            }
                        }
                        .padding(8)
                        .coordinateSpace(name: "ConnectedShelfGrid")
                        .background {
                            ConnectedShelfInteraction(paths: entries.map(\.id), frames: tileFrames,
                                                      selection: $selection)
                        }
                        .onPreferenceChange(ConnectedShelfFramesKey.self) { tileFrames = $0 }
                    }
                    .frame(height: shelfHeight(count: entries.count))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ConnectedShelfWidthKey.self, value: geometry.size.width)
                    })
                    .onPreferenceChange(ConnectedShelfWidthKey.self) { shelfWidth = $0 }
                    }

                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .top) { Divider() }
                // The shelf is the unassigned pool, so a card dragged back
                // here leaves whatever rail it was on (Joshua, 2026-10-05:
                // "doesnt let me drag it back").
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Brand.amber,
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(3)
                        .opacity(dropTargeted ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .contentShape(Rectangle())
                .dropDestination(for: ShelfDragPayload.self) { items, _ in
                    let paths = items.flatMap(\.paths)
                    guard !paths.isEmpty else { return false }
                    let released = RailMotion.run(reduceMotion: reduceMotion) {
                        model.releaseStaged(paths)
                    }
                    if released { Haptics.alignment() } else { Haptics.level() }
                    return released
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.14)) { dropTargeted = targeted }
                }
            }
        }
        .onChange(of: entries.map(\.id)) { _, paths in
            selection.formIntersection(paths)
        }
    }

    private func select(_ path: String, paths: [String]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let selectionAnchor,
           let a = paths.firstIndex(of: selectionAnchor), let b = paths.firstIndex(of: path) {
            let range = Set(paths[min(a, b)...max(a, b)])
            selection = modifiers.contains(.command) ? selection.union(range) : range
        } else if modifiers.contains(.command) {
            if !selection.insert(path).inserted { selection.remove(path) }
            selectionAnchor = path
        } else {
            selection = [path]
            selectionAnchor = path
        }
    }

    private func shelfHeight(count: Int) -> CGFloat {
        let columns = max(1, Int((max(0, shelfWidth - 16) + 8) / 248))
        let rows = max(1, (count + columns - 1) / columns)
        return min(190, CGFloat(rows) * 84 + 24)
    }

    private func stage(_ path: String, as role: EndpointRole, entries: [ShelfEntry]) {
        let paths = selection.contains(path)
            ? entries.map(\.id).filter { selection.contains($0) } : [path]
        let landed = RailMotion.run(reduceMotion: reduceMotion) {
            if paths.count == 1 { return model.assign(path, as: role) }
            switch role {
            case .source: return model.stageDroppedSources(paths) != nil
            case .destination: return model.assignDroppedDestinations(paths)
            }
        }
        if landed { Haptics.alignment() } else { Haptics.level() }
    }
}

private struct ConnectedShelfWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A drive or folder with staging buttons and a selection outline.
private struct ShelfTile: View {
    @EnvironmentObject var model: AppModel
    let endpoint: Endpoint
    let canSource: Bool
    let canDestination: Bool
    let isSelected: Bool
    @Binding var forceEjectTarget: Volume?
    let stage: (EndpointRole) -> Void

    /// Folder endpoints have no volume of their own.
    private var volume: Volume? {
        shelfEjectVolume(for: endpoint, in: model.volumes)
    }

    private var capacity: (free: Int64, total: Int64)? {
        model.volumes.first { $0.path == endpoint.path }
            .flatMap { v in v.totalBytes.flatMap { t in v.freeBytes.map { ($0, t) } } }
    }

    private var displayName: String {
        endpoint.kind == .folder
            ? volumeRelativePath(endpoint.path)
            : model.endpointDisplayName(endpoint.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: endpoint.kind == .folder ? "folder" : "externaldrive")
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let cap = capacity {
                    Text("\(bytesString(cap.free)) free")
                        .font(Typo.evidenceQuiet.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let vol = volume {
                    EjectControl(volume: vol, forceEjectTarget: $forceEjectTarget)
                }
            }
            HStack(spacing: 6) {
                if canSource {
                    stageButton("Source", role: .source,
                                help: "Copy FROM \(displayName)")
                }
                if canDestination {
                    stageButton("Destination", role: .destination,
                                help: "Copy TO \(displayName)")
                }
                Spacer(minLength: 0)
                // The folder-inside affordance the old AVAILABLE rows kept
                // visible — a context menu alone hides it (facelift review).
                if endpoint.kind == .volume, canSource || canDestination {
                    Menu {
                        folderInsideItems
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .menuStyle(.borderlessButton).hoverHighlight()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Use a folder inside \(displayName) instead of the whole drive")
                    .accessibilityLabel("Choose a folder inside \(displayName)")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            .allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                          lineWidth: isSelected ? 2 : 1))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if endpoint.kind == .volume {
                folderInsideItems
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: endpoint.path)])
            }
        }
    }

    @ViewBuilder
    private var folderInsideItems: some View {
        if canSource {
            Button("Choose Source Folder Inside…") {
                model.chooseFolder(inside: endpoint.path, as: .source)
            }
        }
        if canDestination {
            Button("Choose Mirrored Folder Inside…") {
                model.chooseFolder(inside: endpoint.path, as: .destination)
            }
        }
    }

    private func stageButton(_ title: String, role: EndpointRole,
                             help: String) -> some View {
        Button {
            stage(role)
        } label: {
            Label(title, systemImage: role == .source
                  ? "arrow.up.forward.square" : "arrow.down.forward.square")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .tint(role == .source ? Semantics.source : Semantics.destination)
        .help(help)
        .accessibilityLabel("Stage \(displayName) as \(title.lowercased())")
    }
}
