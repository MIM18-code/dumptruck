import Foundation

/// The `verify --json` command emits one terminal object. Keep this contract
/// separate from the transfer protocol's hello frame, but require the exact
/// protocol epoch in the terminal itself so a skewed verifier cannot look
/// authoritative to the GUI.
struct ExistingVerificationSummary: Codable, Equatable, Sendable {
    let passed: Int
    let failed: [String]
    let missing: [String]
    let new: [String]
    let unverifiable: [String]
    let chainProblems: [String]
    let seconds: Double
    let protocolVersion: Int
    let fNocache: Bool
    let reportPaths: [String]
    let custodyPaths: [String]

    var isClean: Bool {
        failed.isEmpty && missing.isEmpty && new.isEmpty
            && unverifiable.isEmpty && chainProblems.isEmpty
    }

    var issueCount: Int {
        failed.count + missing.count + new.count
            + unverifiable.count + chainProblems.count
    }

    private enum CodingKeys: String, CodingKey {
        case event, passed, failed, missing, new, unverifiable
        case chainProblems = "chain_problems"
        case seconds
        case protocolVersion = "protocol"
        case fNocache = "f_nocache"
        case reportPaths = "report_paths"
        case custodyPaths = "custody_paths"
    }

    init(passed: Int, failed: [String], missing: [String], new: [String],
         unverifiable: [String], chainProblems: [String], seconds: Double,
         protocolVersion: Int = ExistingVerificationProtocolParser.supportedProtocolVersion,
         fNocache: Bool = false, reportPaths: [String] = [],
         custodyPaths: [String] = []) {
        self.passed = passed
        self.failed = failed
        self.missing = missing
        self.new = new
        self.unverifiable = unverifiable
        self.chainProblems = chainProblems
        self.seconds = seconds
        self.protocolVersion = protocolVersion
        self.fNocache = fNocache
        self.reportPaths = reportPaths
        self.custodyPaths = custodyPaths
    }

    /// Codable is used only after the strict key-set check in the parser.
    /// The event name is deliberately not part of the public evidence model.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decode(String.self, forKey: .event)
        passed = try c.decode(Int.self, forKey: .passed)
        failed = try c.decode([String].self, forKey: .failed)
        missing = try c.decode([String].self, forKey: .missing)
        new = try c.decode([String].self, forKey: .new)
        unverifiable = try c.decode([String].self, forKey: .unverifiable)
        chainProblems = try c.decode([String].self, forKey: .chainProblems)
        seconds = try c.decode(Double.self, forKey: .seconds)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        fNocache = try c.decode(Bool.self, forKey: .fNocache)
        reportPaths = try c.decodeIfPresent([String].self, forKey: .reportPaths) ?? []
        custodyPaths = try c.decodeIfPresent([String].self, forKey: .custodyPaths) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("verify_done", forKey: .event)
        try c.encode(passed, forKey: .passed)
        try c.encode(failed, forKey: .failed)
        try c.encode(missing, forKey: .missing)
        try c.encode(new, forKey: .new)
        try c.encode(unverifiable, forKey: .unverifiable)
        try c.encode(chainProblems, forKey: .chainProblems)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(fNocache, forKey: .fNocache)
        if !reportPaths.isEmpty { try c.encode(reportPaths, forKey: .reportPaths) }
        if !custodyPaths.isEmpty { try c.encode(custodyPaths, forKey: .custodyPaths) }
    }
}

enum ExistingVerificationProtocolError: Error, Equatable, Sendable,
                                          LocalizedError {
    case invalidJSON
    case wrongEvent(String)
    case missingFields([String])
    case unknownFields([String])
    case invalidValue(String)
    case protocolMismatch(Int)
    case lineTooLong
    case outputTooLarge
    case emptyLine
    case multipleEvents
    case truncatedLine
    case missingEvent

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "verification engine emitted invalid JSON"
        case let .wrongEvent(event):
            return "verification engine emitted unexpected event \(event)"
        case let .missingFields(fields):
            return "verification event omitted required fields: \(fields.joined(separator: ", "))"
        case let .unknownFields(fields):
            return "verification event contained unknown fields: \(fields.joined(separator: ", "))"
        case let .invalidValue(value):
            return "verification event contained an invalid value: \(value)"
        case let .protocolMismatch(version):
            return "verification event protocol \(version) is not supported"
        case .lineTooLong:
            return "verification engine emitted an oversized JSON line"
        case .outputTooLarge:
            return "verification engine emitted more JSON than the safety limit"
        case .emptyLine:
            return "verification engine emitted an empty protocol line"
        case .multipleEvents:
            return "verification engine emitted more than one terminal event"
        case .truncatedLine:
            return "verification engine ended with a truncated JSON line"
        case .missingEvent:
            return "verification engine ended without verify_done"
        }
    }
}

enum ExistingVerificationProtocolParser {
    /// This mirrors the app's transfer protocol major. Verify terminals must
    /// carry this field; an omitted or mismatched epoch is a hard failure.
    static let supportedProtocolVersion = 3
    private static let maximumListItems = 1_000_000
    private static let maximumItemBytes = 16 * 1024
    private static let maximumPathBytes = 4 * 1024

    private static let requiredKeys: Set<String> = [
        "event", "passed", "failed", "missing", "new", "unverifiable",
        "chain_problems", "seconds", "protocol", "f_nocache"
    ]
    private static let optionalKeys: Set<String> = [
        "report_paths", "custody_paths"
    ]

    private struct Wire: Decodable {
        let event: String
        let passed: Int
        let failed: [String]
        let missing: [String]
        let new: [String]
        let unverifiable: [String]
        let chainProblems: [String]
        let seconds: Double
        let protocolVersion: Int
        let fNocache: Bool
        let reportPaths: [String]?
        let custodyPaths: [String]?

        private enum CodingKeys: String, CodingKey {
            case event, passed, failed, missing, new, unverifiable
            case chainProblems = "chain_problems"
            case seconds
            case protocolVersion = "protocol"
            case fNocache = "f_nocache"
            case reportPaths = "report_paths"
            case custodyPaths = "custody_paths"
        }
    }

    static func parseLine(_ data: Data) throws -> ExistingVerificationSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ExistingVerificationProtocolError.invalidJSON
        }

        let keys = Set(dictionary.keys)
        let missing = requiredKeys.subtracting(keys).sorted()
        guard missing.isEmpty else {
            throw ExistingVerificationProtocolError.missingFields(missing)
        }
        let unknown = keys.subtracting(requiredKeys.union(optionalKeys)).sorted()
        guard unknown.isEmpty else {
            throw ExistingVerificationProtocolError.unknownFields(unknown)
        }

        guard let event = dictionary["event"] as? String else {
            throw ExistingVerificationProtocolError.invalidValue("event")
        }
        guard event == "verify_done" else {
            throw ExistingVerificationProtocolError.wrongEvent(event)
        }

        let wire: Wire
        do {
            // JSONDecoder rejects fractional values for Int and rejects
            // mistyped arrays; JSONSerialization above supplied the strict
            // allow-list so unknown fields cannot silently disappear.
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw ExistingVerificationProtocolError.invalidValue("field types")
        }

        guard wire.event == "verify_done" else {
            throw ExistingVerificationProtocolError.wrongEvent(wire.event)
        }
        guard wire.protocolVersion == supportedProtocolVersion else {
            throw ExistingVerificationProtocolError.protocolMismatch(wire.protocolVersion)
        }
        guard wire.passed >= 0 else {
            throw ExistingVerificationProtocolError.invalidValue("passed must be non-negative")
        }
        guard wire.seconds.isFinite, wire.seconds >= 0 else {
            throw ExistingVerificationProtocolError.invalidValue("seconds must be finite")
        }

        try validateList(wire.failed, name: "failed", absolutePaths: false)
        try validateList(wire.missing, name: "missing", absolutePaths: false)
        try validateList(wire.new, name: "new", absolutePaths: false)
        try validateList(wire.unverifiable, name: "unverifiable", absolutePaths: false)
        try validateList(wire.chainProblems, name: "chain_problems", absolutePaths: false)
        let reportPaths = try validatedEmittedPaths(wire.reportPaths ?? [], name: "report_paths")
        let custodyPaths = try validatedEmittedPaths(wire.custodyPaths ?? [], name: "custody_paths")

        return ExistingVerificationSummary(
            passed: wire.passed,
            failed: wire.failed,
            missing: wire.missing,
            new: wire.new,
            unverifiable: wire.unverifiable,
            chainProblems: wire.chainProblems,
            seconds: wire.seconds,
            protocolVersion: wire.protocolVersion,
            fNocache: wire.fNocache,
            reportPaths: reportPaths,
            custodyPaths: custodyPaths)
    }

    private static func validateList(_ values: [String], name: String,
                                     absolutePaths: Bool) throws {
        guard values.count <= maximumListItems else {
            throw ExistingVerificationProtocolError.invalidValue(
                "\(name) exceeds the \(maximumListItems)-item safety limit")
        }
        for value in values {
            guard value.utf8.count <= (absolutePaths ? maximumPathBytes : maximumItemBytes) else {
                throw ExistingVerificationProtocolError.invalidValue(
                    "\(name) contains an oversized string")
            }
            guard !value.isEmpty,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                throw ExistingVerificationProtocolError.invalidValue("\(name) contains an empty/control string")
            }
            if absolutePaths && !value.hasPrefix("/") {
                throw ExistingVerificationProtocolError.invalidValue("\(name) contains a non-absolute path")
            }
            if absolutePaths {
                let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
                guard standardized == value, !value.contains("\\") else {
                    throw ExistingVerificationProtocolError.invalidValue(
                        "\(name) contains a non-canonical path")
                }
            }
        }
    }

    private static func validatedEmittedPaths(_ values: [String], name: String) throws -> [String] {
        try validateList(values, name: name, absolutePaths: true)
        return values
    }
}

/// Incremental framing for the one-line JSON protocol. It is deliberately
/// value-type state so the process runner can keep the only mutable instance
/// behind its serial pipe queue.
struct ExistingVerificationJSONStream: Sendable {
    static let maximumLineBytes = 1 * 1024 * 1024
    static let maximumOutputBytes = 16 * 1024 * 1024

    private var buffer = Data()
    private var outputBytes = 0
    private var eventCount = 0
    private var summary: ExistingVerificationSummary?

    mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let (nextTotal, overflow) = outputBytes.addingReportingOverflow(data.count)
        guard !overflow, nextTotal <= Self.maximumOutputBytes else {
            throw ExistingVerificationProtocolError.outputTooLarge
        }
        outputBytes = nextTotal
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { throw ExistingVerificationProtocolError.emptyLine }
            // A complete newline-terminated line must obey the same bound as
            // an unfinished residual buffer.  Checking only `buffer` after
            // removal allowed a multi-megabyte single line to skip the 1 MiB
            // frame limit and reach JSON decoding.
            guard line.count <= Self.maximumLineBytes else {
                throw ExistingVerificationProtocolError.lineTooLong
            }
            guard eventCount == 0 else { throw ExistingVerificationProtocolError.multipleEvents }
            summary = try ExistingVerificationProtocolParser.parseLine(line)
            eventCount = 1
        }
        guard buffer.count <= Self.maximumLineBytes else {
            throw ExistingVerificationProtocolError.lineTooLong
        }
    }

    mutating func finish() throws -> ExistingVerificationSummary {
        guard buffer.isEmpty else { throw ExistingVerificationProtocolError.truncatedLine }
        guard eventCount == 1, let summary else {
            throw ExistingVerificationProtocolError.missingEvent
        }
        return summary
    }
}

enum ExistingVerificationOutcome: Equatable, Sendable {
    case verified(ExistingVerificationSummary)
    case failed(reason: String, summary: ExistingVerificationSummary?)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

enum ExistingVerificationEvaluator {
    static func settle(exitStatus: Int32, cancelled: Bool,
                       protocolError: String?,
                       summary: ExistingVerificationSummary?,
                       stderr: String) -> ExistingVerificationOutcome {
        if cancelled {
            return .failed(reason: "Verification cancelled — no custody authority was granted.",
                           summary: summary)
        }
        if let protocolError {
            return .failed(reason: "Verification protocol error: \(protocolError). "
                           + "The result is not trusted.", summary: summary)
        }
        guard let summary else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return .failed(reason: "Verification produced no complete custody summary. "
                           + "The result is not trusted.\(suffix)", summary: nil)
        }
        guard exitStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return .failed(reason: "Verification exited with status \(exitStatus). "
                           + "The result is not trusted.\(suffix)", summary: summary)
        }
        guard summary.isClean else {
            return .failed(reason: "Verification reported custody problems. "
                           + "The result is not trusted.", summary: summary)
        }
        return .verified(summary)
    }
}
