import Foundation

enum ExistingVerificationCheck {

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

static func requireThrows(_ body: () throws -> Void, _ message: String) {
    do {
        try body()
        fatalError(message)
    } catch {
        // Expected.
    }
}

static func run() throws {
let cleanLine = """
{"event":"verify_done","passed":3,"failed":[],"missing":[],"new":[],"unverifiable":[],"chain_problems":[],"seconds":1.25,"protocol":3,"f_nocache":true,"report_paths":["/Volumes/DEST/Reports/report.html"],"custody_paths":["/Volumes/DEST/ascmhl/CARD.mhl"]}
"""
let cleanJSON = Data(cleanLine.utf8)

let clean = try ExistingVerificationProtocolParser.parseLine(cleanJSON)
require(clean.passed == 3, "clean summary lost passed count")
require(clean.isClean, "clean summary was not clean")
require(clean.protocolVersion == 3, "clean summary protocol was not exact v3")
require(clean.fNocache, "clean summary lost F_NOCACHE status")
require(clean.reportPaths == ["/Volumes/DEST/Reports/report.html"],
        "emitted report path was not retained")
require(clean.custodyPaths == ["/Volumes/DEST/ascmhl/CARD.mhl"],
        "emitted custody path was not retained")

// Framing must tolerate pipe chunks splitting the JSON object, but only one
// terminal event is permitted and EOF must land on a complete line.
var stream = ExistingVerificationJSONStream()
for chunk in stride(from: 0, to: cleanLine.count, by: 7) {
    let start = cleanLine.index(cleanLine.startIndex, offsetBy: chunk)
    let end = cleanLine.index(start, offsetBy: min(7, cleanLine.distance(from: start, to: cleanLine.endIndex)))
    try stream.append(Data(cleanLine[start..<end].utf8))
}
try stream.append(Data("\n".utf8))
let reassembled = try stream.finish()
require(reassembled == clean, "fragmented JSON did not reassemble")

requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"job_done\"}".utf8)) },
              "wrong/missing event was accepted")
requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"verify_done\",\"passed\":0,\"failed\":[],\"missing\":[],\"new\":[],\"unverifiable\":[],\"chain_problems\":[],\"seconds\":0,\"surprise\":1}".utf8)) },
              "unknown protocol field was accepted")
requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"verify_done\",\"passed\":0.5,\"failed\":[],\"missing\":[],\"new\":[],\"unverifiable\":[],\"chain_problems\":[],\"seconds\":0}".utf8)) },
              "fractional protocol count was accepted")
requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"verify_done\",\"passed\":0,\"failed\":[],\"missing\":[],\"new\":[],\"unverifiable\":[],\"chain_problems\":[],\"seconds\":0,\"protocol\":99}".utf8)) },
              "protocol mismatch was accepted")
requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"verify_done\",\"passed\":0,\"failed\":[],\"missing\":[],\"new\":[],\"unverifiable\":[],\"chain_problems\":[],\"seconds\":0,\"f_nocache\":false}".utf8)) },
              "missing exact protocol was accepted")
requireThrows({ _ = try ExistingVerificationProtocolParser.parseLine(
    Data("{\"event\":\"verify_done\",\"passed\":0,\"failed\":[],\"missing\":[],\"new\":[],\"unverifiable\":[],\"chain_problems\":[],\"seconds\":0,\"protocol\":3,\"f_nocache\":false,\"report_paths\":[\"/tmp/../etc/passwd\"]}".utf8)) },
              "non-canonical emitted path was accepted")

var truncated = ExistingVerificationJSONStream()
try truncated.append(Data(cleanJSON.prefix(30)))
requireThrows({ _ = try truncated.finish() }, "truncated JSON line was accepted")

var oversizedCompleteLine = ExistingVerificationJSONStream()
do {
    var oversized = Data(repeating: 0x20,
                         count: ExistingVerificationJSONStream.maximumLineBytes + 1)
    oversized.append(0x0A)
    try oversizedCompleteLine.append(oversized)
    fatalError("newline-terminated oversized JSON line was accepted")
} catch let error as ExistingVerificationProtocolError {
    require(error == .lineTooLong,
            "oversized complete line failed for the wrong reason: \(error)")
}

var twoEvents = ExistingVerificationJSONStream()
try twoEvents.append(cleanJSON + Data("\n".utf8))
requireThrows({ try twoEvents.append(cleanJSON + Data("\n".utf8)) },
              "second terminal event was accepted")

let dirty = ExistingVerificationSummary(
    passed: 2, failed: ["A.mov"], missing: [], new: ["new.txt"],
    unverifiable: [], chainProblems: [], seconds: 2)
switch ExistingVerificationEvaluator.settle(exitStatus: 0, cancelled: false,
                                             protocolError: nil,
                                             summary: clean, stderr: "") {
case .verified: break
case .failed: fatalError("clean zero-exit verification was not verified")
}
switch ExistingVerificationEvaluator.settle(exitStatus: 0, cancelled: false,
                                             protocolError: nil,
                                             summary: dirty, stderr: "") {
case .verified: fatalError("dirty summary was upgraded to verified")
case let .failed(reason, _): require(reason.contains("custody problems"), "dirty reason lost")
}
switch ExistingVerificationEvaluator.settle(exitStatus: 0, cancelled: true,
                                             protocolError: nil,
                                             summary: clean, stderr: "") {
case .verified: fatalError("cancelled verification was upgraded to verified")
case let .failed(reason, _): require(reason.contains("cancelled"), "cancel reason lost")
}
switch ExistingVerificationEvaluator.settle(exitStatus: 1, cancelled: false,
                                             protocolError: nil,
                                             summary: clean, stderr: "bad custody") {
case .verified: fatalError("nonzero verification was upgraded to verified")
case let .failed(reason, _): require(reason.contains("status 1"), "exit status was lost")
}

// This secondary engine surface must follow the same standalone-repo bundle
// walk as the main transfer model. A hardcoded former workspace path makes
// Verify Existing Offload silently diverge after the app/repo is relocated.
let engineRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("dumptruck-existing-root-\(UUID().uuidString)")
let engineCLI = engineRoot.appendingPathComponent("dumptruck/cli.py")
let engineBundle = engineRoot.appendingPathComponent("DumptruckApp/build/Dumptruck.app")
try FileManager.default.createDirectory(
    at: engineCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: engineBundle, withIntermediateDirectories: true)
require(FileManager.default.createFile(atPath: engineCLI.path, contents: Data()),
        "setup: could not create relocated engine marker")
let engineSuite = "dumptruck-existing-root-\(UUID().uuidString)"
let engineDefaults = UserDefaults(suiteName: engineSuite)!
require(ExistingVerificationModel.resolvedEngineRoot(
    bundleURL: engineBundle, defaults: engineDefaults) == engineRoot.path,
        "Verify Existing Offload bypassed bundle-walk engine resolution")
engineDefaults.removePersistentDomain(forName: engineSuite)
try FileManager.default.removeItem(at: engineRoot)

print("ExistingVerificationCheck: PASS")
}
}
