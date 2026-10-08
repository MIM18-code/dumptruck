import AppKit
import SwiftUI

extension AppModel {
    var hudActiveJobs: [Job] {
        jobs.filter { $0.isRunning && $0.phase != .queued }
    }

    var hudAggregateSpeed: Double {
        hudActiveJobs.reduce(0) { $0 + max(0, $1.currentSpeed) }
    }

    /// Status-bar text: compact and active-only. An idle menu bar shows the
    /// truck icon alone (plus the warning badge when a bad verdict stands).
    var hudTitle: String {
        let count = hudActiveJobs.count
        guard count > 0 else { return "" }
        return "\(count) · \(speedString(hudAggregateSpeed))"
    }

    /// The presence verdict with its referent: a bare "FAILED — DO NOT WIPE"
    /// next to a freshly staged card reads as if it means THAT card. Naming
    /// the job's label keeps the warning honest (round-24 finding).
    var hudPresenceLine: String? {
        if let bad = settledBadVerdictJob {
            return "\(bad.verdict.displayLine) · \(bad.label)"
        }
        if let safe = latestCurrentSafeVerdict { return safe.displayLine }
        return nil
    }
}

struct MenuBarHUDLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label {
            if !model.hudTitle.isEmpty { Text(model.hudTitle) }
        } icon: {
            Image(systemName: model.settledBadVerdict != nil
                  ? "externaldrive.badge.exclamationmark"
                  : "externaldrive.fill")
        }
        .accessibilityLabel(hudAccessibilityLabel)
    }

    private var hudAccessibilityLabel: String {
        var parts = ["Dumptruck"]
        if !model.hudTitle.isEmpty {
            parts.append("\(model.hudActiveJobs.count) active, "
                         + speedString(model.hudAggregateSpeed))
        }
        if let line = model.hudPresenceLine { parts.append(line) }
        return parts.joined(separator: ", ")
    }
}

struct MenuBarHUDView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarHUDPanel(activeJobCount: model.hudActiveJobs.count,
                        aggregateSpeed: model.hudAggregateSpeed,
                        verdict: model.settledPresenceVerdict,
                        verdictLine: model.hudPresenceLine,
                        openAction: openMainWindow)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Parameterized panel keeps the status-item presentation renderable without
/// constructing AppModel, which would inspect mounted volumes at launch.
struct MenuBarHUDPanel: View {
    let activeJobCount: Int
    let aggregateSpeed: Double
    let verdict: Job.Verdict?
    var verdictLine: String?
    let openAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openAction) {
                Label("Open Dumptruck", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HoverHighlightButtonStyle())

            Divider()

            LabeledContent("Active jobs", value: "\(activeJobCount)")
            LabeledContent("Aggregate speed", value: speedString(aggregateSpeed))
            if let verdict {
                Text(verdictLine ?? verdict.displayLine)
                    .font(Typo.safety)
                    .foregroundStyle(verdict == .safeToWipe
                                     ? Semantics.successText : Semantics.dangerText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
