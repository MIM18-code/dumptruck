import Foundation
import Darwin

/// The identity of a process that Dumptruck is allowed to terminate during
/// crash recovery.  A PID is deliberately not part of this value: macOS can
/// recycle a PID between the crash and the next launch.  The engine path,
/// working directory, complete argv, and unique run token are all required.
struct OrphanEngineLaunchIdentity: Equatable {
    let executablePath: String
    let currentDirectory: String
    let arguments: [String]
    let runID: UUID

    var expectedArguments: [String] {
        arguments + ["--gui-run-id", runID.uuidString]
    }

    var runToken: String { runID.uuidString }
}

struct OrphanEngineProcess: Equatable {
    let pid: pid_t
    /// macOS' process birth time.  This is captured before a signal and
    /// compared again immediately before TERM/KILL, so a recycled PID can
    /// never receive a signal intended for the old process.
    let birthSeconds: UInt64
    let birthMicroseconds: UInt64
    let executablePath: String
    let arguments: [String]
    let currentDirectory: String

    var birthIdentity: String { "\(birthSeconds):\(birthMicroseconds)" }
}

enum OrphanEngineInspectionError: Error, CustomStringConvertible {
    case unavailable(String)
    case processGone
    /// A process this user may not inspect (root-owned system daemons
    /// answer EPERM). It cannot be our engine, which runs as this user, so
    /// the scan skips it instead of blocking every recovery on the Mac
    /// (desktop QA round 7, R7-02: MDRemoteServiceSupport blocked Start).
    case inaccessible(pid_t)
    /// An argument list larger than the engine could ever have (an `ls` of
    /// thousands of frames from another tool). It cannot be our engine, so
    /// the scan skips it; a single-PID lookup still reports it as an error
    /// and recovery withholds any signal (2026-09-24: another session's
    /// `ls` of 1000+ paths failed every scan).
    case oversizedArguments(pid_t)

    var description: String {
        switch self {
        case .unavailable(let message): return message
        case .processGone: return "process exited during inspection"
        case .inaccessible(let pid): return "process \(pid) is not inspectable by this user"
        case .oversizedArguments(let pid):
            return "process \(pid) has more arguments than the engine can have"
        }
    }
}

/// The small process-inspection seam makes recovery deterministic in a model
/// test without shelling out to ps.  The production implementation below
/// uses libproc/sysctl, which returns structured process data instead of a
/// lossy command-line substring.
protocol OrphanEngineProcessInspecting {
    func allProcesses() throws -> [OrphanEngineProcess]
    func process(pid: pid_t) throws -> OrphanEngineProcess
    @discardableResult
    func send(signal: Int32, to pid: pid_t) -> Bool
}

struct SystemOrphanEngineProcessInspector: OrphanEngineProcessInspecting {
    private static let maxProcesses = 65_536
    private static let maxArgvBytes = 4 * 1024 * 1024
    private static let maxArguments = 512
    private static let maxArgumentBytes = 256 * 1024

    func allProcesses() throws -> [OrphanEngineProcess] {
        let initialBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard initialBytes > 0 else {
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not enumerate processes (proc_listpids: \(errno))")
        }
        var capacity = min(Self.maxProcesses,
                           max(64, Int(initialBytes) / MemoryLayout<pid_t>.size + 32))
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else {
                throw OrphanEngineInspectionError.unavailable(
                    "macOS could not enumerate processes (proc_listpids: \(errno))")
            }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count >= capacity {
                guard capacity < Self.maxProcesses else {
                    throw OrphanEngineInspectionError.unavailable(
                        "macOS process list exceeded the safe inspection bound")
                }
                capacity = min(Self.maxProcesses, capacity * 2)
                continue
            }
            var result: [OrphanEngineProcess] = []
            result.reserveCapacity(count)
            for pid in pids.prefix(count) where pid > 1 {
                do {
                    result.append(try process(pid: pid))
                } catch OrphanEngineInspectionError.processGone {
                    // A process may exit between proc_listpids and the first
                    // proc_pidinfo call. That is proof it is no longer an
                    // orphan, not a recovery failure.
                    continue
                } catch OrphanEngineInspectionError.inaccessible {
                    continue
                } catch OrphanEngineInspectionError.oversizedArguments {
                    continue
                }
            }
            return result
        }
        throw OrphanEngineInspectionError.unavailable(
            "macOS process list changed too quickly to inspect safely")
    }

    /// EPERM/EACCES: another user's process. ENOENT/EINVAL: a zombie or a
    /// process whose executable is gone. None of these can be the engine
    /// this app launched as this user from a bundle that still exists.
    static func isNotInspectable(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES || code == ENOENT || code == EINVAL
    }

    func process(pid: pid_t) throws -> OrphanEngineProcess {
        var bsd = proc_bsdinfo()
        let bsdBytes = withUnsafeMutablePointer(to: &bsd) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0,
                         Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard bsdBytes == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            if errno == ESRCH { throw OrphanEngineInspectionError.processGone }
            if Self.isNotInspectable(errno) { throw OrphanEngineInspectionError.inaccessible(pid) }
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not inspect process \(pid) (proc_pidinfo: \(errno))")
        }

        var executableBuffer = [CChar](repeating: 0,
                                       count: 4096)
        let pathBytes = executableBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard pathBytes > 0 else {
            if errno == ESRCH { throw OrphanEngineInspectionError.processGone }
            if Self.isNotInspectable(errno) { throw OrphanEngineInspectionError.inaccessible(pid) }
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not read executable path for process \(pid) (proc_pidpath: \(errno))")
        }
        let executable = String(cString: executableBuffer)

        let arguments = try Self.readArguments(pid: pid)
        var vnode = proc_vnodepathinfo()
        let vnodeBytes = withUnsafeMutablePointer(to: &vnode) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0,
                         Int32(MemoryLayout<proc_vnodepathinfo>.size))
        }
        guard vnodeBytes == Int32(MemoryLayout<proc_vnodepathinfo>.size) else {
            if errno == ESRCH { throw OrphanEngineInspectionError.processGone }
            if Self.isNotInspectable(errno) { throw OrphanEngineInspectionError.inaccessible(pid) }
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not read working directory for process \(pid) (proc_pidinfo: \(errno))")
        }
        let pathCapacity = MemoryLayout.size(ofValue: vnode.pvi_cdir.vip_path)
        let currentDirectory = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                String(cString: $0)
            }
        }

        return OrphanEngineProcess(
            pid: pid,
            birthSeconds: bsd.pbi_start_tvsec,
            birthMicroseconds: bsd.pbi_start_tvusec,
            executablePath: executable,
            arguments: arguments,
            currentDirectory: currentDirectory)
    }

    @discardableResult
    func send(signal: Int32, to pid: pid_t) -> Bool {
        Darwin.kill(pid, signal) == 0
    }

    private static func readArguments(pid: pid_t) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            if errno == ESRCH { throw OrphanEngineInspectionError.processGone }
            if Self.isNotInspectable(errno) { throw OrphanEngineInspectionError.inaccessible(pid) }
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not size argv for process \(pid) (sysctl: \(errno))")
        }
        guard size >= MemoryLayout<Int32>.size else {
            throw OrphanEngineInspectionError.unavailable(
                "process \(pid) has an invalid argv")
        }
        guard size <= maxArgvBytes else {
            throw OrphanEngineInspectionError.oversizedArguments(pid)
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else {
            if errno == ESRCH { throw OrphanEngineInspectionError.processGone }
            if Self.isNotInspectable(errno) { throw OrphanEngineInspectionError.inaccessible(pid) }
            throw OrphanEngineInspectionError.unavailable(
                "macOS could not read argv for process \(pid) (sysctl: \(errno))")
        }
        guard size >= 4 else {
            throw OrphanEngineInspectionError.unavailable(
                "process \(pid) returned a truncated argv")
        }
        let argc = Int32(bytes[0])
            | (Int32(bytes[1]) << 8)
            | (Int32(bytes[2]) << 16)
            | (Int32(bytes[3]) << 24)
        guard argc >= 0 else {
            throw OrphanEngineInspectionError.unavailable(
                "process \(pid) returned an invalid argv count")
        }
        guard argc <= Int32(maxArguments) else {
            throw OrphanEngineInspectionError.oversizedArguments(pid)
        }

        // KERN_PROCARGS2 starts with argc, then the executable string and a
        // NUL-separated argv block. Empty strings between those sections are
        // padding, not arguments.
        var cursor = 4
        while cursor < size, bytes[cursor] != 0 { cursor += 1 }
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        result.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            let start = cursor
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            guard cursor - start <= maxArgumentBytes else {
                throw OrphanEngineInspectionError.oversizedArguments(pid)
            }
            result.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        }
        return result
    }
}

enum OrphanEngineRecoveryResult: Equatable {
    case noMatchingProcess
    case terminated
    case blocked(String)
}

/// Finds and terminates exactly one orphan engine. Recovery is synchronous on
/// app launch, before the first Start/queue decision. It never trusts a PID or
/// a substring match: a process must match the executable, cwd, complete
/// tokenized argv, module, and unique GUI run ID. TERM is bounded, then KILL is
/// attempted only after the same PID birth identity is revalidated.
struct OrphanEngineRecovery {
    private let inspector: any OrphanEngineProcessInspecting
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date
    private let termGrace: TimeInterval
    private let killGrace: TimeInterval

    init(inspector: any OrphanEngineProcessInspecting = SystemOrphanEngineProcessInspector(),
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> Date = Date.init,
         termGrace: TimeInterval = 2.0,
         killGrace: TimeInterval = 1.0) {
        self.inspector = inspector
        self.sleep = sleep
        self.now = now
        self.termGrace = max(0, termGrace)
        self.killGrace = max(0, killGrace)
    }

    func recover(identity: OrphanEngineLaunchIdentity) -> OrphanEngineRecoveryResult {
        let processes: [OrphanEngineProcess]
        do {
            processes = try inspector.allProcesses()
        } catch {
            return .blocked("could not inspect running processes: \(error)")
        }

        let exact = processes.filter { Self.matches($0, identity: identity) }
        let engineLike = processes.filter { Self.isEngineLike($0, identity: identity) }
        let sameToken = processes.filter { $0.arguments.contains(identity.runToken) }
        guard exact.count <= 1 else {
            return .blocked("multiple processes matched run \(identity.runToken); no process was signalled")
        }
        guard engineLike.count <= 1 else {
            return .blocked("multiple Dumptruck engine processes were found; no process was signalled")
        }
        guard sameToken.count <= 1 else {
            return .blocked("run token \(identity.runToken) appeared in multiple processes; no process was signalled")
        }
        guard let target = exact.first else {
            if !engineLike.isEmpty || !sameToken.isEmpty {
                return .blocked("a process resembled the interrupted engine but its identity did not match exactly")
            }
            return .noMatchingProcess
        }

        guard send(signal: SIGTERM, to: target, identity: identity) else {
            return .blocked("the interrupted engine changed identity before SIGTERM; no process was signalled")
        }
        if waitUntilGone(pid: target.pid, birth: target.birthIdentity,
                         identity: identity, timeout: termGrace) {
            return .terminated
        }
        guard let stillTarget = sameProcess(target.pid, birth: target.birthIdentity,
                                            identity: identity) else {
            // A different process now owns the PID. Never escalate to KILL.
            do {
                _ = try inspector.process(pid: target.pid)
                return .blocked("the interrupted engine PID was reused or changed; KILL was withheld")
            } catch OrphanEngineInspectionError.processGone {
                return .terminated
            } catch {
                return .blocked("the interrupted engine PID could not be revalidated; KILL was withheld")
            }
        }
        guard send(signal: SIGKILL, to: stillTarget, identity: identity) else {
            return .blocked("the interrupted engine did not accept SIGKILL")
        }
        if waitUntilGone(pid: stillTarget.pid, birth: stillTarget.birthIdentity,
                         identity: identity, timeout: killGrace) {
            return .terminated
        }
        return .blocked("the interrupted engine is still present after bounded TERM/KILL recovery")
    }

    private func send(signal: Int32, to target: OrphanEngineProcess,
                      identity: OrphanEngineLaunchIdentity) -> Bool {
        guard let current = sameProcess(target.pid, birth: target.birthIdentity,
                                        identity: identity),
              current == target else { return false }
        return inspector.send(signal: signal, to: target.pid)
    }

    private func sameProcess(_ pid: pid_t, birth: String,
                             identity: OrphanEngineLaunchIdentity) -> OrphanEngineProcess? {
        guard let current = try? inspector.process(pid: pid),
              current.birthIdentity == birth,
              Self.matches(current, identity: identity) else { return nil }
        return current
    }

    private func waitUntilGone(pid: pid_t, birth: String,
                               identity: OrphanEngineLaunchIdentity,
                               timeout: TimeInterval) -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            do {
                let current = try inspector.process(pid: pid)
                if current.birthIdentity != birth { return false }
                if !Self.matches(current, identity: identity) { return false }
            } catch OrphanEngineInspectionError.processGone {
                return true
            } catch {
                return false
            }
            guard now() < deadline else { return false }
            sleep(min(0.05, max(0, deadline.timeIntervalSince(now()))))
        }
    }

    private static func matches(_ process: OrphanEngineProcess,
                                identity: OrphanEngineLaunchIdentity) -> Bool {
        canonical(process.executablePath) == canonical(identity.executablePath)
            && canonical(process.currentDirectory) == canonical(identity.currentDirectory)
            && process.arguments.count == identity.expectedArguments.count + 1
            && canonicalArgv(process.arguments, identity: identity)
    }

    private static func canonicalArgv(_ argv: [String],
                                      identity: OrphanEngineLaunchIdentity) -> Bool {
        guard let first = argv.first,
              canonical(first) == canonical(identity.executablePath) else { return false }
        return Array(argv.dropFirst()) == identity.expectedArguments
    }

    /// A mismatched process with the same executable/cwd/module is not ours,
    /// but it may be an operator-started transfer. Treating it as "no orphan"
    /// would permit concurrent writes during recovery, so it blocks visibly.
    private static func isEngineLike(_ process: OrphanEngineProcess,
                                     identity: OrphanEngineLaunchIdentity) -> Bool {
        guard canonical(process.executablePath) == canonical(identity.executablePath),
              canonical(process.currentDirectory) == canonical(identity.currentDirectory)
        else { return false }
        let args = process.arguments
        guard let moduleIndex = args.firstIndex(of: "-m"),
              args.indices.contains(moduleIndex + 1),
              args[moduleIndex + 1] == "dumptruck.cli",
              args.contains("offload") else { return false }
        return true
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
