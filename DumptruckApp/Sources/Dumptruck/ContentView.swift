import SwiftUI

// Semantic state palette: pinned, never the user's system accent (a safety
// vocabulary must not be recolorable from System Settings). Warning is pushed
// redder than .orange so it never reads as the brand's amber.
//
// These are the VIBRANT tokens — shape fills, bars, tracks, progress tints,
// drop-target strokes, decorative role glyphs. Text and small safety glyphs
// take the appearance-resolved `Semantics.*Text` variants in SemanticColors.swift,
// which clear WCAG AA against a white ground.
//
// `running` is indigo, not blue: blue now means source-side only.
enum Semantics {
    static let success = Color.green
    /// #D2450A, hue 38° (2026-08-28 color audit): pushed off the brand amber.
    /// The old #E8730A sat ΔE00 10.29 from Brand.amber under deuteranopia —
    /// on the confusable threshold, with both ambers in adjacent columns on
    /// the default screen. 38° measures ΔE00 19.9 deuteranopia / 29.3
    /// protanopia from brand, and clears the 3:1 non-text bar on white
    /// (4.57:1) so gauge boundaries read.
    static let warning = Color(red: 0.824, green: 0.271, blue: 0.039)
    static let danger = Color.red
    static let running = Color.indigo
    static let source = Color.blue
    static let destination = Color.teal
}

/// The two-sided workbench: SOURCES | FLOW | DESTINATIONS. Role is expressed
/// by position — a disk on the left is a source, a disk on the right is a
/// destination; bytes travel left-to-right, physically, on screen.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var forceEjectTarget: Volume?
    @AppStorage(Pref.textScale) private var textScaleRaw = TextScale.standard.rawValue


    var body: some View {
        WorkbenchLayout {
            SourcesRail(forceEjectTarget: $forceEjectTarget)
        } center: {
            VStack(spacing: 0) {
                errorStrip
                FlowColumn(forceEjectTarget: $forceEjectTarget)
            }
        } destinations: {
            DestinationsRail(forceEjectTarget: $forceEjectTarget)
        }
        .navigationTitle("Dumptruck")
        .toolbar {
            // Declared before Start: items sharing a placement render in
            // declaration order, so the arcade sits just left of the primary
            // button and the leading title region stays clean. Not
            // .secondaryAction — macOS can fold that into an overflow menu and
            // hide the entrance entirely.
            ToolbarItemGroup(placement: .primaryAction) {
                // One GROUP, not four items: macOS 26 draws adjacent toolbar
                // items as a shared capsule and mis-sizes it when the items
                // are declared separately — the capsule's leading edge cut
                // through the first icon (alpha round 29 report).
                Button {
                    model.historyShown = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Job History & CSV Export — search, filter, and export persistent transfer logs")
                .accessibilityLabel("Open Job History and CSV Export")
                // Always present, by Joshua's explicit call (2026-08-26): an
                // earlier facelift pass showed this only while a job ran, and
                // he wants the Dump Yard one click away at all times. Kept as
                // a stable group member so the macOS 26 capsule never
                // re-lays under the cursor.
                Button {
                    model.arcadeShown = true
                } label: { Image(systemName: "gamecontroller") }
                    .help("The Dump Yard — kill time while it hauls")
                    .accessibilityLabel("Open the Dump Yard arcade")
                Button {
                    openWindow(id: "verify")
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .help("Verify an existing destination folder against its sealed custody (\u{21E7}\u{2318}V)")
                .accessibilityLabel("Verify an existing destination folder")
                Button {
                    openWindow(id: "help")
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Open the Dumptruck guide (also in the Help menu, \u{2318}?)")
                .accessibilityLabel("Open the Dumptruck guide")
            }
            ToolbarItem(placement: .primaryAction) {
                // Always clickable: SwiftUI toolbar items cache .disabled past
                // invalidation, silently eating clicks. Blocked clicks explain
                // themselves via startOrExplain instead.
                // Read the gate BEFORE starting: once start() runs, canStart
                // is answering about the job that just launched, not the click.
                Button("Start Offload") {
                    if model.canStart { Haptics.alignment() } else { Haptics.level() }
                    model.startOrExplain()
                }
                    // Brand amber, not the system accent: the one loud thing
                    // in the chrome (2026-08-26 facelift).
                    .buttonStyle(BrandProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help(model.startBlockedReason ?? "Begin copy + verify")
            }
        }
        .sheet(item: $forceEjectTarget) { ForceEjectSheet(volume: $0) }
        .sheet(isPresented: $model.arcadeShown) { ArcadeSheet() }
        .sheet(isPresented: $model.historyShown) { JobHistoryView() }
        .sheet(isPresented: $model.cameraTermsShown) { CameraComponentTermsSheet() }
        // Verify Existing Custody is its own window (DumptruckCoreApplication),
        // not a sheet: a re-read can take hours, and as a sheet it held this
        // whole window modal, with no drops, eject or Start the entire time
        // (Joshua, 2026-09-28). The app owns its model and result wiring.
        // The batch list is its own window (DumptruckCoreApplication): as a
        // sheet it made this window modal, and the third card dragged to
        // the rail, where the first two went, bounced off (Joshua,
        // 2026-09-21). Each drop or pick that lands in the list fronts the
        // window so the card is seen arriving.
        .onChange(of: model.batchStagingOpenRequests) { _, _ in
            openWindow(id: "batch")
        }
        // Last modifier on the body so the toolbar, the force-eject sheet and
        // the arcade sheet all inherit the operator's Text Size choice.
        .environment(\.dynamicTypeSize, TextScale.current(textScaleRaw).dynamicTypeSize)
    }

    /// Setup/eject problems surface over the center, where the eye already
    /// is — the rails stay clean for state.
    @ViewBuilder
    private var errorStrip: some View {
        if let err = model.engineConfigurationError,
           model.lastSetupError != err {
            Label(err, systemImage: "gearshape.2.fill")
                .font(Typo.safety)
                .foregroundStyle(Semantics.dangerText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Semantics.danger.opacity(Semantics.wash))
        }
        if let notice = model.engineResolutionNotice {
            Label(notice, systemImage: "shippingbox.fill")
                .font(Typo.safety)
                .foregroundStyle(Semantics.warningText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Semantics.warning.opacity(Semantics.wash))
        }
        if let err = model.lastSetupError {
            // Dismissable: a setup refusal is a message about one click, and
            // it stayed on screen long after its cause was fixed (Joshua,
            // 2026-09-28). The Start gate itself still re-checks everything.
            HStack(spacing: 8) {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.lastSetupError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .foregroundStyle(.secondary)
                .help("Dismiss this message")
                .accessibilityLabel("Dismiss setup message")
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Semantics.warning.opacity(Semantics.wash))
        }
        if let err = model.lastEjectError {
            Label(err, systemImage: "eject.circle")
                .font(Typo.safety)
                .foregroundStyle(Semantics.dangerText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Semantics.danger.opacity(Semantics.wash))
        }
    }
}
