import Foundation
import Darwin

enum OrphanEngineCheck {

final class FakeInspector: OrphanEngineProcessInspecting {
    var processes: [pid_t: OrphanEngineProcess]
    var signals: [Int32] = []
    var failEnumeration = false
    var onSignal: ((Int32, pid_t) -> Void)?

    init(_ process: OrphanEngineProcess) {
        processes = [process.pid: process]
    }

    func allProcesses() throws -> [OrphanEngineProcess] {
        if failEnumeration {
            throw OrphanEngineInspectionError.unavailable("test enumeration failure")
        }
        return Array(processes.values)
    }

    func process(pid: pid_t) throws -> OrphanEngineProcess {
        guard let process = processes[pid] else {
            throw OrphanEngineInspectionError.processGone
        }
        return process
    }

    @discardableResult
    func send(signal: Int32, to pid: pid_t) -> Bool {
        signals.append(signal)
        onSignal?(signal, pid)
        return true
    }
}

static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

/// The real inspector on this Mac: root-owned daemons answer EPERM and must
/// be skipped, not turn into a recovery block (round 7, R7-02).
static func checkSystemInspectorSkipsInaccessibleProcesses() {
    let inspector = SystemOrphanEngineProcessInspector()
    do {
        let processes = try inspector.allProcesses()
        require(processes.contains(where: { $0.pid == getpid() }),
                "the system inspector must list this process")
        require(!processes.contains(where: { $0.pid == 1 }), "launchd is never inspected")
    } catch {
        fatalError("the system inspector must not fail on unreadable system processes: \(error)")
    }
    do {
        _ = try inspector.process(pid: 1)
        // launchd may be inspectable on some configurations; that is fine.
    } catch OrphanEngineInspectionError.inaccessible {
        // expected on a standard Mac
    } catch {
        fatalError("an unreadable process must be reported as inaccessible, got \(error)")
    }
}

/// A real process with more arguments than any engine launch (another
/// tool's `ls` of 1000+ frame paths) must be skipped by the full scan, not
/// fail it; looked up by PID it is reported, never matched.
static func checkSystemInspectorSkipsOversizedArguments() {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 10", "sh"] + (0..<600).map { "arg\($0)" }
    do { try child.run() } catch {
        fatalError("could not start the oversized-argv fixture: \(error)")
    }
    defer { child.terminate(); child.waitUntilExit() }
    let inspector = SystemOrphanEngineProcessInspector()
    do {
        _ = try inspector.process(pid: child.processIdentifier)
        fatalError("a 600-argument process must not be inspectable as an engine")
    } catch OrphanEngineInspectionError.oversizedArguments(let pid) {
        require(pid == child.processIdentifier, "oversized error names the wrong pid")
    } catch {
        fatalError("an oversized argv must be reported as oversizedArguments, got \(error)")
    }
    do {
        let processes = try inspector.allProcesses()
        require(!processes.contains(where: { $0.pid == child.processIdentifier }),
                "the scan must skip the oversized process")
        require(processes.contains(where: { $0.pid == getpid() }),
                "the scan must still list this process")
    } catch {
        fatalError("an oversized argv must not fail the whole scan: \(error)")
    }
}

static func run() {

    checkSystemInspectorSkipsOversizedArguments()
    checkSystemInspectorSkipsInaccessibleProcesses()
let runID = UUID()
let executable = "/tmp/dumptruck-engine/.venv/bin/python"
let cwd = "/tmp/dumptruck-engine"
let baseArguments = ["-m", "dumptruck.cli", "offload", "/Volumes/CARD", "/Volumes/DEST",
                     "--label", "CARD", "--json"]
let identity = OrphanEngineLaunchIdentity(executablePath: executable,
                                           currentDirectory: cwd,
                                           arguments: baseArguments,
                                           runID: runID)
func process(birth: UInt64 = 1, arguments: [String]? = nil) -> OrphanEngineProcess {
    OrphanEngineProcess(pid: 4242, birthSeconds: birth, birthMicroseconds: 7,
                        executablePath: executable,
                        arguments: arguments ?? [executable] + identity.expectedArguments,
                        currentDirectory: cwd)
}

// A stubborn exact match gets bounded TERM, then KILL, and disappears before
// recovery returns. No shell, PID-only lookup, or substring parsing is used.
let termThenKill = FakeInspector(process())
termThenKill.onSignal = { signal, pid in
    if signal == SIGKILL { termThenKill.processes.removeValue(forKey: pid) }
}
let result = OrphanEngineRecovery(inspector: termThenKill,
                                  sleep: { _ in }, now: { Date() },
                                  termGrace: 0, killGrace: 0)
    .recover(identity: identity)
require(result == .terminated, "stubborn orphan was not terminated")
require(termThenKill.signals == [SIGTERM, SIGKILL],
        "recovery did not use bounded TERM then KILL")

// If the PID is recycled after TERM, recovery must withhold KILL and remain
// visibly blocked instead of touching the replacement process.
let reused = FakeInspector(process())
reused.onSignal = { signal, pid in
    if signal == SIGTERM { reused.processes[pid] = process(birth: 99) }
}
let reusedResult = OrphanEngineRecovery(inspector: reused,
                                        sleep: { _ in }, now: { Date() },
                                        termGrace: 0, killGrace: 0)
    .recover(identity: identity)
require({ if case .blocked = reusedResult { return true }; return false }(),
        "PID reuse was not blocked")
require(reused.signals == [SIGTERM], "PID-reused process received KILL")

// A process with the same engine shape but a different run token is not ours;
// it may be a new operator-started transfer and must interlock Start visibly.
let wrongToken = FakeInspector(process(arguments: [executable] + baseArguments
                                       + ["--gui-run-id", UUID().uuidString]))
let wrongResult = OrphanEngineRecovery(inspector: wrongToken,
                                       sleep: { _ in }, now: { Date() },
                                       termGrace: 0, killGrace: 0)
    .recover(identity: identity)
require({ if case .blocked = wrongResult { return true }; return false }(),
        "mismatched run token was treated as gone")
require(wrongToken.signals.isEmpty, "mismatched process was signalled")

let unavailable = FakeInspector(process())
unavailable.failEnumeration = true
let unavailableResult = OrphanEngineRecovery(inspector: unavailable)
    .recover(identity: identity)
require({ if case .blocked = unavailableResult { return true }; return false }(),
        "inspection failure did not block recovery")

print("OrphanEngineCheck: all assertions passed")
}
}
