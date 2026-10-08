import SwiftUI

/// Small modal used by the destination-rail preset menu.  A preset name is a
/// deliberate operator action; there is no generated default that could
/// silently overwrite a workflow.
struct SaveIngestPresetSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var localError: String?
    @State private var confirmOverwrite = false
    @FocusState private var nameFocused: Bool

    private var templatePreflight: TemplateRenderer.PreflightReport {
        let d = UserDefaults.standard
        let template = d.string(forKey: Pref.folderTemplate) ?? ""
        let project = d.string(forKey: Pref.projectName) ?? ""
        let volumeName = model.sourcePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "CARD_VOLUME"
        let context = TemplateContext(
            project: project,
            volumeName: volumeName,
            cardLabel: model.label.isEmpty ? "CARD_LABEL" : model.label,
            date: Date(),
            cameraFormat: (model.inspection?.formatName == "?" ? "" : (model.inspection?.formatName ?? "")).replacingOccurrences(of: "/", with: "-"),
            reel: model.inspection?.reelName ?? "",
            jobID: "PRESET_JOB"
        )
        return TemplateRenderer.preflight(template, context: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save ingest preset")
                .font(.title3.weight(.semibold))
            Text("This saves the current destination anchors, mirrored folder, organization template, verification, report, and queue settings. It never saves a card identity or starts a transfer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let preflight = templatePreflight
            if !preflight.template.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization template:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(preflight.template)
                        .font(Typo.evidence.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    presetPreflightStatus(preflight)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
            }

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { save() }
                .accessibilityLabel("Ingest preset name")
            HStack {
                Text("\(name.count)/\(IngestPresetStore.maxNameLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.safety)
                    .foregroundStyle(Semantics.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { nameFocused = true }
        .confirmationDialog("Replace existing preset?",
                            isPresented: $confirmOverwrite,
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                save(confirmOverwrite: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A preset with this name already exists. Replacing it updates its destinations and ingest settings.")
        }
    }

    @ViewBuilder
    private func presetPreflightStatus(_ report: TemplateRenderer.PreflightReport) -> some View {
        if report.hasMalformed {
            Label(report.summaryDescription, systemImage: "exclamationmark.octagon.fill")
                .font(Typo.safety)
                .foregroundStyle(Semantics.warningText)
                .accessibilityLabel("Preset template malformed: \(report.accessibilitySummary)")
        } else if report.hasUnavailable {
            Label {
                Text(report.summaryDescription + " (will resolve when card is present)")
                    .font(Typo.safety)
            } icon: {
                Image(systemName: "info.circle")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Preset template tokens pending live card: \(report.accessibilitySummary)")
        } else if report.hasOmitted {
            Label {
                Text(report.summaryDescription)
                    .font(Typo.safety)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Semantics.warningText)
            .accessibilityLabel("Preset template note: \(report.accessibilitySummary)")
        } else if report.hasFallback {
            Label {
                Text(report.summaryDescription)
                    .font(Typo.safety)
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Preset template fallback inputs: \(report.accessibilitySummary)")
        } else if !report.tokens.isEmpty {
            Label {
                Text("All \(report.tokens.count) template tokens resolved")
                    .font(Typo.safety)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Preset template tokens resolved: \(report.accessibilitySummary)")
        }
    }

    private func save(confirmOverwrite: Bool = false) {
        let preflight = templatePreflight
        if preflight.hasMalformed {
            localError = "Preset folder template is invalid: " + preflight.summaryDescription
            return
        }
        guard let error = model.saveCurrentIngestPreset(
            named: name, confirmOverwrite: confirmOverwrite) else {
            dismiss()
            return
        }
        if !confirmOverwrite && IngestPresetStore.shared.hasPreset(named: name) {
            localError = nil
            self.confirmOverwrite = true
            return
        }
        localError = error
    }
}
