import CryptoKit
import Foundation
import SwiftUI

/// RED's SDK agreement (sections 1.4 and 2) lets Dumptruck ship RED's
/// runtime only under an end-user license the operator actually agrees to.
/// A terms file sitting next to the app in the DMG binds nobody, so the app
/// asks once, before the bundled camera helpers ever run.
///
/// Agreement is recorded against a hash of the terms text: changed terms
/// ask again. Until the operator agrees, every engine process gets
/// DUMPTRUCK_CAMERA_HELPERS=0, which switches off only the bundled RED,
/// Blackmagic and ARRI helpers. Copying, verification, reports, REDline and
/// the ARRI Reference Tool never depend on this answer.
enum CameraComponentTerms {
    static let acceptedKey = "cameraTermsAcceptedSHA256"
    static let declinedKey = "cameraTermsDeclinedSHA256"
    static let helperNames = ["r3d-probe", "braw-probe", "arri-probe"]
    static let fileName = "CAMERA_COMPONENT_TERMS.txt"

    enum Status: Equatable {
        /// No bundled helpers, or no terms text to show (a private checkout
        /// or Homebrew engine). Nothing to agree to.
        case notApplicable
        case accepted
        case declined
        case pending(text: String, digest: String)
    }

    /// The camera formats the bundled helpers read, for the sheet's wording.
    static func formatsPresent(engineRoot: String,
                               fileManager: FileManager = .default) -> [String] {
        [("r3d-probe", "RED"), ("braw-probe", "Blackmagic RAW"), ("arri-probe", "ARRI")]
            .filter { fileManager.isExecutableFile(atPath: "\(engineRoot)/tools/\($0.0)") }
            .map(\.1)
    }

    static func helpersPresent(engineRoot: String,
                               fileManager: FileManager = .default) -> Bool {
        helperNames.contains { name in
            fileManager.isExecutableFile(atPath: "\(engineRoot)/tools/\(name)")
        }
    }

    /// The app bundle's copy wins; an engine checkout keeps its own in legal/.
    static func termsText(engineRoot: String,
                          bundleResources: URL? = Bundle.main.resourceURL) -> String? {
        var candidates: [URL] = []
        if let bundleResources {
            candidates.append(bundleResources.appendingPathComponent("legal/cameras/\(fileName)"))
        }
        candidates.append(URL(fileURLWithPath: engineRoot).appendingPathComponent("legal/\(fileName)"))
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// The terms file is hard-wrapped at 80 columns; a narrower sheet broke
    /// those lines raggedly. Join each paragraph into one line for display.
    /// The digest always covers the file exactly as shipped.
    static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func status(engineRoot: String,
                       defaults: UserDefaults = .standard,
                       bundleResources: URL? = Bundle.main.resourceURL,
                       fileManager: FileManager = .default) -> Status {
        guard helpersPresent(engineRoot: engineRoot, fileManager: fileManager),
              let text = termsText(engineRoot: engineRoot, bundleResources: bundleResources)
        else { return .notApplicable }
        let current = digest(text)
        if defaults.string(forKey: acceptedKey) == current { return .accepted }
        if defaults.string(forKey: declinedKey) == current { return .declined }
        return .pending(text: text, digest: current)
    }

    static func helpersAllowed(_ status: Status) -> Bool {
        status == .notApplicable || status == .accepted
    }

    /// Ask at launch only when the current terms have no answer yet. A
    /// decline is remembered, so the sheet does not nag every launch; the
    /// app menu reopens it.
    static func shouldAskAtLaunch(_ status: Status) -> Bool {
        if case .pending = status { return true }
        return false
    }

    static func record(accepted: Bool, digest: String, defaults: UserDefaults = .standard) {
        if accepted {
            defaults.set(digest, forKey: acceptedKey)
            defaults.removeObject(forKey: declinedKey)
        } else {
            defaults.set(digest, forKey: declinedKey)
            defaults.removeObject(forKey: acceptedKey)
        }
    }
}

struct CameraComponentTermsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let status = CameraComponentTerms.status(engineRoot: model.engineRoot)
        let text: String? = {
            if case .pending(let text, _) = status { return text }
            return CameraComponentTerms.termsText(engineRoot: model.engineRoot)
        }()
        let formats = CameraComponentTerms.formatsPresent(engineRoot: model.engineRoot)
        let formatList = ListFormatter.localizedString(byJoining: formats.isEmpty ? ["camera"] : formats)
        VStack(alignment: .leading, spacing: 14) {
            Text("Camera component terms")
                .font(.title2.weight(.semibold))
            Text("This copy of Dumptruck includes helpers that read metadata and thumbnails from \(formatList) clips. They come under separate terms from the rest of the app.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Copying and verification work whether or not you agree. If you don't, those clips still copy and verify, and their reports get metadata and thumbnails only from REDline or the ARRI Reference Tool, if you have them installed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text.map(CameraComponentTerms.reflowed) ?? "The terms file is missing from this copy of Dumptruck.")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 260)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if status == .accepted {
                Text("You agreed to these terms. Camera helpers are on.")
                    .foregroundStyle(.secondary)
            } else if status == .declined {
                Text("You declined these terms. Camera helpers are off.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if let text {
                    let digest = CameraComponentTerms.digest(text)
                    Button("Don't Use Camera Helpers") {
                        CameraComponentTerms.record(accepted: false, digest: digest)
                        dismiss()
                    }
                    Button("Agree") {
                        CameraComponentTerms.record(accepted: true, digest: digest)
                        dismiss()
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(text != nil && CameraComponentTerms.shouldAskAtLaunch(status))
    }
}
