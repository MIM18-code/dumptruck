import SwiftUI

/// One-click eject for verified-safe volumes; anything less routes to the
/// warning sheet. Semantics unchanged from the sidebar era.
struct EjectControl: View {
    @EnvironmentObject var model: AppModel
    let volume: Volume
    @Binding var forceEjectTarget: Volume?

    var body: some View {
        if model.offersEject(volume) {
            if model.canEject(volume) {
                Button {
                    // Re-check on the click: a source-tree event can retire a
                    // verdict between SwiftUI rendering this branch and the
                    // operator pressing the control.
                    if model.canEject(volume) {
                        model.eject(volume)
                    } else {
                        forceEjectTarget = volume
                    }
                } label: { Image(systemName: "eject") }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .help(oneClickHelp)
                    .accessibilityLabel("Eject \(volume.name)")
            } else {
                let reason = model.ejectHold(volume)?.summary ?? "Eject asks first"
                Button { forceEjectTarget = volume } label: {
                    Image(systemName: "eject")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .help(reason)
                .accessibilityLabel("Eject \(volume.name) — \(reason)")
            }
        }
    }

    /// Ejecting a backup drive is ordinary at wrap, but it ends the live
    /// watch that keeps a card's SAFE TO WIPE current. Say so before the
    /// click, not after (Joshua, 2026-09-28).
    private var oneClickHelp: String {
        let labels = model.safeWatchesEndedByEjecting(volume)
        guard let first = labels.first else { return "Eject" }
        let more = labels.count > 1 ? " and \(labels.count - 1) more" : ""
        return "Eject — ends the SAFE watch on \(first)\(more)"
    }
}

/// The warning sheet. It names the real reason one-click eject was withheld
/// (AppModel.ejectHold), the job behind it, and what ejecting now means.
/// It used to demand the volume's name typed back (Joshua, 2026-09-21:
/// "a warning, not homework"). When ejecting would risk a copy, Force Eject
/// owns no key, so the destructive choice is always a deliberate click
/// (Opus GUI audit 2026-08-19, finding b). When the copy is already proven
/// and only the wipe is on hold, ejecting is ordinary and Return takes it.
/// A card never offloaded ejects with a plain click and no key, and so does
/// a card whose SAFE verdict is stale or still being re-checked: ejecting a
/// card never damages a copy, the risk is only in wiping it later.
/// Return stays off those so the keep-the-card line gets read.
struct ForceEjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let volume: Volume

    var body: some View {
        // Read once per render: ejectHold walks every job and resolves paths.
        let hold = model.ejectHold(volume)
        let risky = Self.ejectIsRisky(hold)
        VStack(alignment: .leading, spacing: 14) {
            Label(title(hold), systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(risky ? Semantics.dangerText : Semantics.warningText)
            Text(message(hold))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if case .verifiedNotSafe(let job, false) = hold, !job.wipeBlockers.isEmpty {
                // Every blocker: "the reasons below" must not hide one.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(job.wipeBlockers, id: \.self) { blocker in
                        Text("• " + blocker)
                    }
                }
                .font(Typo.evidence)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let job = hold?.job {
                Label(infoLine(hold, job: job), systemImage: "info.circle")
                    .font(Typo.evidence)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if risky {
                    Button("Force Eject", role: .destructive) { ejectNow() }
                        .buttonStyle(.borderedProminent)
                        .tint(Semantics.dangerProminent)
                } else if case .verifiedNotSafe = hold {
                    Button("Eject") { ejectNow() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Eject") { ejectNow() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    /// Ejecting a card whose copy is proven, one never offloaded, or one
    /// whose SAFE verdict is stale or still being re-checked cannot damage
    /// any copy: the card is only read. Everything else can.
    private static func ejectIsRisky(_ hold: AppModel.EjectHold?) -> Bool {
        switch hold {
        case .verifiedNotSafe, .notOffloaded, .verdictNotCurrent,
             .destinationCheckPending, .none: return false
        default: return true
        }
    }

    private func infoLine(_ hold: AppModel.EjectHold?, job: Job) -> String {
        let state: String
        if job.isRunning {
            state = job.phase.rawValue
        } else if case .verdictNotCurrent = hold {
            // Its SAFE line is history here, not the card's current state.
            state = "marked \(job.verdict.displayLine) earlier, no longer current"
        } else if case .destinationCheckPending = hold {
            // A bare "SAFE TO WIPE" here would contradict "don't wipe yet".
            state = "copies still being re-checked"
        } else {
            state = job.verdict.displayLine
        }
        return "\(job.label): \(state)"
            + (job.filesFailed > 0 ? " · \(job.filesFailed) failed file(s)" : "")
    }

    private func title(_ hold: AppModel.EjectHold?) -> String {
        switch hold {
        case .transferRunning(_, let asSource):
            return asSource ? "Eject a card mid-transfer?" : "Eject a destination mid-job?"
        case .copiesUnverified(_, let asSource):
            return asSource ? "Eject an UNVERIFIED card?" : "Eject a drive holding unverified copies?"
        case .custodyDamaged:
            return "A copy of this card was found damaged"
        case .verifiedNotSafe(_, let singleDrive):
            return singleDrive ? "Backed up to one drive only" : "Verified, but not safe to wipe"
        case .verdictNotCurrent:
            return "Verdict no longer covers this card"
        case .destinationCheckPending:
            return "Still re-checking the copies"
        case .notOffloaded:
            return "Eject a card that hasn't been offloaded?"
        case .journalUnavailable:
            return "Eject without a durable verdict?"
        case .none:
            return "Eject \(volume.name)?"
        }
    }

    private func message(_ hold: AppModel.EjectHold?) -> AttributedString {
        let name = "**\(Self.escaped(volume.name))**"
        let text: String
        switch hold {
        case .transferRunning(_, true):
            text = "\(name) is being copied right now. Ejecting stops the read and the job will fail. Nothing on the card is changed."
        case .transferRunning(_, false):
            text = "A transfer is still writing or verifying copies on \(name). Ejecting now can corrupt the copy in progress and the job will fail. The source card itself is untouched."
        case .copiesUnverified(_, true):
            text = "Verification has not completed for \(name). Ejecting now means the copy is **not proven**. If you wipe this card, footage may be unrecoverable."
        case .copiesUnverified(let job, false):
            text = "No transfer is running. **\(Self.escaped(job.label))** ended \(job.verdict.displayLine) with copies on \(name), so those copies are not proven. The source card itself is untouched."
        case .custodyDamaged:
            text = "A later Verify Existing Custody run found damage in a copy of \(name). This card may now be the only good copy. **Keep it and don't format it** until the copy is replaced and verified."
        case .verifiedNotSafe(_, true):
            text = "\(name) is verified, but its footage is on only one drive. That copy is good; one copy is not a backup. Eject if you like, but **keep this card and don't format it** until a second drive holds a verified copy."
        case .verifiedNotSafe(_, false):
            text = "\(name) is verified, but the engine withheld SAFE TO WIPE for the reasons below. Eject if you like, but **keep this card and don't format it** until they are resolved."
        case .verdictNotCurrent(let job):
            let why = job.destinationAuthorityWithdrawn.map { " (\(Self.escaped($0)))" } ?? ""
            text = "**\(Self.escaped(job.label))** was marked \(Job.Verdict.safeToWipe.displayLine), but that verdict no longer covers the card mounted now: it was re-staged, changed, or a copy moved since\(why). Treat it as unverified and keep the card."
        case .destinationCheckPending:
            text = "Dumptruck is still re-checking the copies. Ejecting the card is fine; **don't wipe it** until the check finishes."
        case .notOffloaded:
            text = "\(name) is staged as a source, but nothing has been copied from it yet. Ejecting takes it off the job; nothing on the card changes."
        case .journalUnavailable:
            text = "The job journal could not be written, so no verdict about \(name) is durable. Treat its copies as unverified and keep the card."
        case .none:
            text = "\(name) is not in use by any transfer."
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// Card names and labels are operator text: an underscore or asterisk in
    /// "A_CAM_001" must not turn into emphasis inside the markdown above, and
    /// edge spaces would stop `**…**` from rendering bold at all.
    private static func escaped(_ raw: String) -> String {
        var out = ""
        for ch in raw.trimmingCharacters(in: .whitespaces) {
            if "\\`*_[]<>#!~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private func ejectNow() {
        model.eject(volume)
        dismiss()
    }
}
