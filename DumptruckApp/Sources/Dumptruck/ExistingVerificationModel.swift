import AppKit
import Darwin
import Foundation
import SwiftUI

enum ExistingVerificationStatus: String, Equatable, Sendable {
    case idle
    case running
    case cancelling
    case verified
    case failed

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .running: return "Checking"
        case .cancelling: return "Cancelling"
        case .verified: return "VERIFIED"
        case .failed: return "FAILED"
        }
    }
}

/// A locked reference to a Process. The process is created and owned by the
/// main actor, but protocol failures and the Cancel button may request
/// termination from different queues. Foundation's Process has no useful
/// Sendable annotation, so this tiny wrapper documents the synchronization
/// boundary rather than leaking Process through Sendable closures.
private final class ExistingVerificationProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()

    init(process: Process) { self.process = process }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }

    func forceKillIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        // Process.terminate() is SIGTERM.  This bounded escalation prevents
        // a wedged verifier/FIFO from surviving a user cancellation forever.
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

private final class ExistingVerificationStreamState: @unchecked Sendable {
    let queue: DispatchQueue
    let readers: DispatchGroup
    let processBox: ExistingVerificationProcessBox
    var parser = ExistingVerificationJSONStream()
    var protocolError: String?
    var stdoutReadError: String?
    var stderrReadError: String?
    var stderrText = ""
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var watchdogArmed = false

    init(runID: UUID, processBox: ExistingVerificationProcessBox,
         readers: DispatchGroup) {
        queue = DispatchQueue(label: "dumptruck.existing-verify.\(runID)")
        self.processBox = processBox
        self.readers = readers
    }

    func recordProtocolError(_ error: Error) {
        guard protocolError == nil else { return }
        protocolError = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        requestTermination()
    }

    func recordReadError(_ error: Error, stdout: Bool) {
        let streamName = stdout ? "stdout" : "stderr"
        let text = "verification \(streamName) read failed: "
            + "\(error.localizedDescription)"
        if stdout {
            stdoutReadError = stdoutReadError ?? text
        } else {
            stderrReadError = stderrReadError ?? text
        }
        // A pipe read failure means the app cannot prove it consumed the
        // complete protocol/diagnostic stream. Even a clean-looking summary
        // must be rejected when that evidence boundary is damaged.
        protocolError = protocolError ?? text
        requestTermination()
    }

    func appendStderr(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return }
        let maxBytes = 1 * 1024 * 1024
        let joined = Data((stderrText + text).utf8)
        let capped = joined.count > maxBytes ? joined.suffix(maxBytes) : joined[...]
        stderrText = String(data: capped, encoding: .utf8) ?? "(non-UTF-8 engine diagnostics)"
    }

    func markCancellationRequested() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
    }

    func requestTermination() {
        processBox.terminate()
        cancellationLock.lock()
        let shouldArm = !watchdogArmed
        watchdogArmed = true
        cancellationLock.unlock()
        guard shouldArm else { return }
        let box = processBox
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            box.forceKillIfRunning()
        }
    }

    var wasCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }
}

/// Runs the read-only custody verifier against a folder selected by the
/// operator. This model deliberately has no connection to AppModel's Job,
/// eject interlock, or SAFE TO WIPE vocabulary: a checksum re-read result
/// is evidence for the selected folder only and never grants source authority.
@MainActor
final class ExistingVerificationModel: ObservableObject {
    @Published private(set) var selectedFolderPath: String?
    @Published private(set) var status: ExistingVerificationStatus = .idle
    @Published private(set) var summary: ExistingVerificationSummary?
    @Published private(set) var failureReason: String?
    @Published private(set) var stderrText = ""
    /// Fired once per settled run that produced a summary, with the folder
    /// it verified. The workbench attaches it to the matching job.
    var onSettled: ((String, ExistingVerificationSummary) -> Void)?

    private var processBox: ExistingVerificationProcessBox?
    private var process: Process?
    private var streamState: ExistingVerificationStreamState?
    private var runID: UUID?

    var isRunning: Bool {
        status == .running || status == .cancelling
    }

    var reportPaths: [String] { summary?.reportPaths ?? [] }
    var custodyPaths: [String] { summary?.custodyPaths ?? [] }

    /// The exact path is frozen at Start; changing defaults while a run is in
    /// flight cannot retarget the child to another checkout.
    nonisolated static func resolvedEngineRoot(
        bundleURL: URL = Bundle.main.bundleURL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> String {
        EngineRootResolver.resolve(bundleURL: bundleURL,
                                   defaults: defaults,
                                   fileManager: fileManager)
    }

    private var engineRoot: String {
        Self.resolvedEngineRoot()
    }

    private var enginePython: String { "\(engineRoot)/.venv/bin/python" }

    func chooseFolder() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Existing Folder to Verify"
        panel.prompt = "Verify Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard Self.isExistingDirectory(path), !Self.isSymlink(path) else {
            selectedFolderPath = path
            summary = nil
            status = .failed
            failureReason = "The selected path is not a stable, readable folder. "
                + "Choose the actual destination folder, not a symlink."
            stderrText = ""
            return
        }
        selectedFolderPath = path
        summary = nil
        status = .idle
        failureReason = nil
        stderrText = ""
    }

    func clearSelection() {
        guard !isRunning else { return }
        selectedFolderPath = nil
        summary = nil
        status = .idle
        failureReason = nil
        stderrText = ""
    }

    func startVerification() {
        guard !isRunning else { return }
        guard let selectedFolderPath else {
            failBeforeLaunch("Choose an existing destination folder first.")
            return
        }
        guard Self.isExistingDirectory(selectedFolderPath),
              !Self.isSymlink(selectedFolderPath) else {
            failBeforeLaunch("The selected folder changed or is no longer a stable directory. "
                             + "Choose it again before verifying.")
            return
        }

        let frozenRoot = engineRoot
        let frozenPython = enginePython
        guard FileManager.default.isExecutableFile(atPath: frozenPython) else {
            failBeforeLaunch("No executable Dumptruck engine was found at \(frozenPython). "
                             + "Check Settings > Engine.")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: frozenPython)
        p.arguments = ["-m", "dumptruck.cli", "verify", selectedFolderPath, "--json"]
        p.currentDirectoryURL = URL(fileURLWithPath: frozenRoot)
        p.environment = EngineRootResolver.processEnvironment(root: frozenRoot)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let id = UUID()
        let box = ExistingVerificationProcessBox(process: p)
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        let state = ExistingVerificationStreamState(runID: id, processBox: box,
                                                     readers: readers)

        processBox = box
        process = p
        streamState = state
        runID = id
        summary = nil
        failureReason = nil
        stderrText = ""
        status = .running

        p.terminationHandler = { [weak self, weak state] proc in
            guard let state else { return }
            // A termination callback can arrive before the last pipe reader
            // reaches EOF. Waiting for both readers on their serial queue
            // guarantees the final JSON frame is parsed and stderr is drained
            // before the main actor settles the result.
            state.readers.notify(queue: state.queue) { [weak self] in
                var parsedSummary: ExistingVerificationSummary?
                if state.protocolError == nil, state.stdoutReadError == nil {
                    do {
                        parsedSummary = try state.parser.finish()
                    } catch {
                        state.recordProtocolError(error)
                    }
                }
                let protocolError = state.protocolError ?? state.stdoutReadError
                let stderr = state.stderrText
                let cancelled = state.wasCancellationRequested
                let exitStatus = proc.terminationStatus
                let outcome = ExistingVerificationEvaluator.settle(
                    exitStatus: exitStatus,
                    cancelled: cancelled,
                    protocolError: protocolError,
                    summary: parsedSummary,
                    stderr: stderr)
                Task { @MainActor [weak self] in
                    self?.settle(outcome: outcome, stderr: stderr, runID: id)
                }
            }
        }

        do {
            try p.run()
            // The parent must close its copies of both write ends or a child
            // that exits cleanly can leave readers waiting forever.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            self.processBox = nil
            self.process = nil
            self.streamState = nil
            self.runID = nil
            failBeforeLaunch("Could not start verification engine: \(error.localizedDescription)")
            return
        }

        // stdout and stderr are drained concurrently. stdout is framed on the
        // state queue; after a malformed frame the reader still drains bytes
        // while termination is requested, preventing a full pipe deadlock.
        DispatchQueue.global(qos: .utility).async { [state, outPipe] in
            let fh = outPipe.fileHandleForReading
            while true {
                do {
                    guard let data = try fh.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                    state.queue.async {
                        guard state.protocolError == nil else { return }
                        do {
                            try state.parser.append(data)
                        } catch {
                            state.recordProtocolError(error)
                        }
                    }
                } catch {
                    state.queue.async { state.recordReadError(error, stdout: true) }
                    break
                }
            }
            state.queue.async { state.readers.leave() }
            try? fh.close()
        }
        DispatchQueue.global(qos: .utility).async { [state, errPipe] in
            let fh = errPipe.fileHandleForReading
            while true {
                do {
                    guard let data = try fh.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                    state.queue.async { state.appendStderr(data) }
                } catch {
                    state.queue.async { state.recordReadError(error, stdout: false) }
                    break
                }
            }
            state.queue.async { state.readers.leave() }
            try? fh.close()
        }
    }

    func cancelVerification() {
        guard isRunning else { return }
        status = .cancelling
        streamState?.markCancellationRequested()
        streamState?.requestTermination()
    }

    func openEmittedPath(_ path: String) {
        guard (reportPaths + custodyPaths).contains(path),
              FinderEvidenceActions.isSafeExistingPath(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealEmittedPath(_ path: String) {
        guard (reportPaths + custodyPaths).contains(path),
              FinderEvidenceActions.isSafeExistingPath(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func settle(outcome: ExistingVerificationOutcome, stderr: String,
                        runID: UUID) {
        guard self.runID == runID else { return }
        defer {
            processBox = nil
            process = nil
            streamState = nil
            self.runID = nil
        }
        self.stderrText = stderr
        switch outcome {
        case let .verified(summary):
            self.summary = summary
            status = .verified
            failureReason = nil
        case let .failed(reason, summary):
            self.summary = summary
            status = .failed
            failureReason = reason
        }
        if let folder = selectedFolderPath, let settled = self.summary {
            onSettled?(folder, settled)
        }
    }

    private func failBeforeLaunch(_ reason: String) {
        summary = nil
        status = .failed
        failureReason = reason
        stderrText = ""
    }

    deinit {
        // Covers application/window teardown paths where SwiftUI does not
        // deliver the sheet's onDisappear callback before releasing the
        // model. A detached verifier must never outlive its owner.
        processBox?.terminate()
        processBox?.forceKillIfRunning()
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
