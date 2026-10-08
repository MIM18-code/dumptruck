import Foundation

/// The bundled camera helpers must stay off until the operator agrees to the
/// exact terms shown, and copying must never wait on that answer.
enum CameraTermsCheck {

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

static func run() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("camera-terms-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("tools"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("legal"), withIntermediateDirectories: true)
    let suite = "camera-terms-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func status() -> CameraComponentTerms.Status {
        CameraComponentTerms.status(engineRoot: root.path, defaults: defaults, bundleResources: nil)
    }

    require(status() == .notApplicable, "an engine without helpers has nothing to agree to")
    require(CameraComponentTerms.helpersAllowed(status()), "no helpers must not switch anything off")

    let helper = root.appendingPathComponent("tools/r3d-probe")
    try Data("#!/bin/sh\n".utf8).write(to: helper)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    require(status() == .notApplicable, "helpers without a terms file must not prompt")

    let terms = root.appendingPathComponent("legal/CAMERA_COMPONENT_TERMS.txt")
    try Data("Terms v1\n".utf8).write(to: terms)
    guard case .pending(_, let first) = status() else { fatalError("unanswered terms must be pending") }
    require(!CameraComponentTerms.helpersAllowed(status()), "pending terms must keep helpers off")
    require(CameraComponentTerms.shouldAskAtLaunch(status()), "pending terms must ask at launch")
    require(CameraComponentTerms.formatsPresent(engineRoot: root.path) == ["RED"],
            "the sheet must name only the helpers this engine has")

    let off = EngineRootResolver.processEnvironment(root: root.path, base: ["PATH": "/usr/bin"],
                                                   cameraHelpersAllowed: false)
    require(off["DUMPTRUCK_CAMERA_HELPERS"] == "0", "declined terms must reach the engine")
    require(off["PATH"]?.hasPrefix(root.appendingPathComponent(".venv/bin").path) == true,
            "the helper switch must not disturb the engine PATH")
    let on = EngineRootResolver.processEnvironment(root: root.path, base: ["PATH": "/usr/bin"],
                                                  cameraHelpersAllowed: true)
    require(on["DUMPTRUCK_CAMERA_HELPERS"] == nil, "accepted terms must leave helpers on")

    require(CameraComponentTerms.reflowed("One\ntwo\n\nThree\n  four\n") == "One two\n\nThree four",
            "display reflow must join wrapped lines and keep paragraph breaks")

    CameraComponentTerms.record(accepted: true, digest: first, defaults: defaults)
    require(status() == .accepted, "agreement must be remembered")
    require(CameraComponentTerms.helpersAllowed(status()), "accepted terms must allow helpers")

    try Data("Terms v2\n".utf8).write(to: terms)
    guard case .pending(_, let second) = status() else { fatalError("changed terms must ask again") }
    require(second != first, "changed terms must have a new digest")

    CameraComponentTerms.record(accepted: false, digest: second, defaults: defaults)
    require(status() == .declined, "a decline must be remembered")
    require(!CameraComponentTerms.helpersAllowed(status()), "declined terms must keep helpers off")
    require(!CameraComponentTerms.shouldAskAtLaunch(status()), "a decline must not nag every launch")
    require(defaults.string(forKey: CameraComponentTerms.acceptedKey) == nil,
            "a decline must withdraw the earlier agreement")
}
}
