//
//  main.swift
//  BatchSourceStagingCheck
//
//  Focused test suite for BatchSourceStaging core.
//

import Foundation

enum BatchSourceStagingCheck {

// MARK: - Mock Injected FileSystem

final class MockBatchSourceFileSystem: BatchSourceFileSystem, @unchecked Sendable {
    struct Entry {
        var isDirectory: Bool
        var isSymlink: Bool
        var pin: FileIdentityPin
    }

    var entries: [String: Entry] = [:]
    var existingLanes: Set<String> = []

    func normalizePath(_ path: String) throws -> String {
        return StandardPurePathNormalizer.normalize(path)
    }

    func fileExists(atPath path: String) async throws -> Bool {
        return entries[path] != nil
    }

    func isDirectory(atPath path: String) async throws -> Bool {
        guard let entry = entries[path] else { return false }
        return entry.isDirectory
    }

    func isSymlink(atPath path: String) async throws -> Bool {
        guard let entry = entries[path] else { return false }
        return entry.isSymlink
    }

    func fileIdentity(forPath path: String) async throws -> FileIdentityPin {
        guard let entry = entries[path] else {
            throw BatchSourceStagingError.sourceNotFound(path: path)
        }
        return entry.pin
    }

    func destinationLaneExists(atPath path: String) async throws -> Bool {
        return existingLanes.contains(path)
    }

    func registerDirectory(_ path: String, devId: UInt64, fileId: UInt64, volumeUUID: String? = nil) {
        let norm = StandardPurePathNormalizer.normalize(path)
        entries[norm] = Entry(
            isDirectory: true,
            isSymlink: false,
            pin: FileIdentityPin(deviceId: devId, fileId: fileId, volumeUUID: volumeUUID)
        )
    }

    func registerFile(_ path: String, devId: UInt64, fileId: UInt64) {
        let norm = StandardPurePathNormalizer.normalize(path)
        entries[norm] = Entry(
            isDirectory: false,
            isSymlink: false,
            pin: FileIdentityPin(deviceId: devId, fileId: fileId)
        )
    }

    func registerSymlink(_ path: String, devId: UInt64, fileId: UInt64) {
        let norm = StandardPurePathNormalizer.normalize(path)
        entries[norm] = Entry(
            isDirectory: true,
            isSymlink: true,
            pin: FileIdentityPin(deviceId: devId, fileId: fileId)
        )
    }

    func registerExistingLane(_ path: String) {
        let norm = StandardPurePathNormalizer.normalize(path)
        existingLanes.insert(norm)
    }
}

// MARK: - Mock Injected Inspector

final class MockBatchSourceInspector: BatchSourceInspector, @unchecked Sendable {
    var inspectionMap: [String: BatchInspectionResult] = [:]
    var defaultProtocolVersion: Int = 3
    var throwErrorForPath: [String: Error] = [:]
    var delaySeconds: TimeInterval = 0

    func inspect(sourcePath: String, pin: FileIdentityPin) async throws -> BatchInspectionResult {
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }

        if let error = throwErrorForPath[sourcePath] {
            throw error
        }

        if let result = inspectionMap[sourcePath] {
            return result
        }

        // Default mock result
        let lastComp = (sourcePath as NSString).lastPathComponent
        return BatchInspectionResult(
            protocolVersion: defaultProtocolVersion,
            metadata: CardInspectionMetadata(label: lastComp, totalBytes: 1_000_000, fileCount: 42)
        )
    }
}

// MARK: - Test Framework

@MainActor
final class TestRecorder {
    static let shared = TestRecorder()
    var passCount = 0
    var failCount = 0

    func recordPass() {
        passCount += 1
    }

    func recordFail(message: String, line: UInt) {
        failCount += 1
        print("❌ FAIL: \(message) at line \(line)")
    }
}

@MainActor
static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        TestRecorder.shared.recordPass()
    } else {
        TestRecorder.shared.recordFail(message: "\(message) - Expected '\(expected)', got '\(actual)'", line: line)
    }
}

@MainActor
static func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if condition {
        TestRecorder.shared.recordPass()
    } else {
        TestRecorder.shared.recordFail(message: "\(message) - Expected true", line: line)
    }
}

// MARK: - Test Cases

@MainActor
static func testEmptyCandidatesRejection() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: [], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected emptyCandidates error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .emptyCandidates, "Empty candidates rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testCandidateLimitExceededRejection() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()
    let options = BatchSourceStagingOptions(maxCandidates: 64)
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector, options: options)

    var candidates: [String] = []
    for i in 1...65 {
        candidates.append("/Volumes/Card\(i)")
    }

    do {
        _ = try await core.stageBatch(candidateSourcePaths: candidates, destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected candidateLimitExceeded error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .candidateLimitExceeded(count: 65, limit: 64), "Candidate limit exceeded")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testInvalidPathRejection() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    // Non-absolute path
    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["relative/path"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected invalidPath for relative path", line: #line)
    } catch let error as BatchSourceStagingError {
        switch error {
        case .invalidPath:
            TestRecorder.shared.recordPass()
        default:
            TestRecorder.shared.recordFail(message: "Expected invalidPath, got \(error)", line: #line)
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }

    // Whitespace only path
    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["   "], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected invalidPath for whitespace path", line: #line)
    } catch let error as BatchSourceStagingError {
        switch error {
        case .invalidPath:
            TestRecorder.shared.recordPass()
        default:
            TestRecorder.shared.recordFail(message: "Expected invalidPath, got \(error)", line: #line)
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testPathLengthExceededRejection() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()
    let options = BatchSourceStagingOptions(maxPathLength: 30)
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector, options: options)

    let longPath = "/Volumes/ThisIsAVeryLongPathThatExceedsTheLimit"
    do {
        _ = try await core.stageBatch(candidateSourcePaths: [longPath], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected pathLengthExceeded error", line: #line)
    } catch let error as BatchSourceStagingError {
        switch error {
        case let .pathLengthExceeded(path, length, limit):
            assertEqual(path, longPath, "Path length exceeded path match")
            assertEqual(length, longPath.utf8.count, "Path length match")
            assertEqual(limit, 30, "Path length limit match")
        default:
            TestRecorder.shared.recordFail(message: "Expected pathLengthExceeded, got \(error)", line: #line)
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testSourceNotFoundRejection() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/NonExistentCard"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected sourceNotFound error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .sourceNotFound(path: "/Volumes/NonExistentCard"), "Source not found rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testSourceNotDirectoryRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerFile("/Volumes/RegularFile.txt", devId: 1, fileId: 100)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/RegularFile.txt"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected sourceNotDirectory error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .sourceNotDirectory(path: "/Volumes/RegularFile.txt"), "Source not directory rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testSourceIsSymlinkRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerSymlink("/Volumes/SymlinkCard", devId: 1, fileId: 200)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/SymlinkCard"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected sourceIsSymlink error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .sourceIsSymlink(path: "/Volumes/SymlinkCard"), "Source is symlink rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testDuplicateCandidatePathRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 300)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/CardA", "/Volumes/CardA/"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected duplicateCandidatePath error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .duplicateCandidatePath(path: "/Volumes/CardA"), "Duplicate candidate path rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testDuplicateCandidatePinRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/MountPoint1", devId: 99, fileId: 1234, volumeUUID: "UUID-1234")
    fs.registerDirectory("/Volumes/MountPoint2", devId: 99, fileId: 1234, volumeUUID: "UUID-1234")
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/MountPoint1", "/Volumes/MountPoint2"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected duplicateCandidatePin error", line: #line)
    } catch let error as BatchSourceStagingError {
        let expectedPin = FileIdentityPin(deviceId: 99, fileId: 1234, volumeUUID: "UUID-1234")
        assertEqual(
            error,
            .duplicateCandidatePin(pin: expectedPin, firstSource: "/Volumes/MountPoint1", secondSource: "/Volumes/MountPoint2"),
            "Duplicate candidate pin rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testMutualSourceOverlapRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 401)
    fs.registerDirectory("/Volumes/CardA/DCIM", devId: 1, fileId: 402)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA", "/Volumes/CardA/DCIM"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected mutualSourceOverlap error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(
            error,
            .mutualSourceOverlap(source1: "/Volumes/CardA", source2: "/Volumes/CardA/DCIM"),
            "Mutual source overlap rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testSourceDestinationOverlapRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/Backup/CardA", devId: 1, fileId: 501)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    // Source is inside destination root
    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/Backup/CardA"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected sourceDestinationOverlap error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(
            error,
            .sourceDestinationOverlap(source: "/Volumes/Backup/CardA", destination: "/Volumes/Backup"),
            "Source inside destination overlap rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }

    // Source is parent of destination root
    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/Backup"],
            destinationRoots: ["/Volumes/Backup/DestLane"]
        )
        TestRecorder.shared.recordFail(message: "Expected sourceDestinationOverlap error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(
            error,
            .sourceDestinationOverlap(source: "/Volumes/Backup", destination: "/Volumes/Backup/DestLane"),
            "Source is parent of destination overlap rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testActiveSourceOverlapRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA/Subfolder", devId: 1, fileId: 601)
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA/Subfolder"],
            destinationRoots: ["/Volumes/Backup"],
            existingActiveSourcePaths: ["/Volumes/CardA"]
        )
        TestRecorder.shared.recordFail(message: "Expected activeSourceOverlap error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(
            error,
            .activeSourceOverlap(source: "/Volumes/CardA/Subfolder", activeSource: "/Volumes/CardA"),
            "Active source overlap rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testEmptyOrInvalidLabelRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 701)
    let inspector = MockBatchSourceInspector()

    // Inspector returns label with path separator '/'
    inspector.inspectionMap["/Volumes/CardA"] = BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(label: "Bad/Label", totalBytes: 100, fileCount: 1)
    )
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/CardA"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected invalidLabel error for bad character", line: #line)
    } catch let error as BatchSourceStagingError {
        switch error {
        case let .invalidLabel(label, _):
            assertEqual(label, "Bad/Label", "Invalid label error match")
        default:
            TestRecorder.shared.recordFail(message: "Expected invalidLabel, got \(error)", line: #line)
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testLabelLengthExceededRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 702)
    let inspector = MockBatchSourceInspector()
    let longLabel = String(repeating: "X", count: 256)
    inspector.inspectionMap["/Volumes/CardA"] = BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(label: longLabel, totalBytes: 100, fileCount: 1)
    )
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(candidateSourcePaths: ["/Volumes/CardA"], destinationRoots: ["/Volumes/Backup"])
        TestRecorder.shared.recordFail(message: "Expected labelLengthExceeded error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .labelLengthExceeded(label: longLabel, length: 256, limit: 255), "Label length exceeded")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testDuplicateLabelRejection() async {
    // Cards of one camera model mount with one default name. A shared
    // suggestion used to throw and refuse every card in the pile (Joshua,
    // 2026-09-28: "a bunch of Sony A7S3s ... the same default name"). Now
    // the first card keeps the name and the others are numbered, in drag
    // order, every card staged.
    let fs = MockBatchSourceFileSystem()
    let paths = ["/Volumes/NO NAME", "/Volumes/NO NAME 1", "/Volumes/NO NAME 2"]
    let inspector = MockBatchSourceInspector()
    for (offset, path) in paths.enumerated() {
        fs.registerDirectory(path, devId: UInt64(80 + offset), fileId: UInt64(801 + offset))
        inspector.inspectionMap[path] = BatchInspectionResult(
            protocolVersion: 3,
            metadata: CardInspectionMetadata(label: "NO NAME", totalBytes: 100, fileCount: 1)
        )
    }
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: paths,
            destinationRoots: ["/Volumes/Backup"]
        )
        assertEqual(staged.map(\.label), ["NO NAME", "NO NAME_2", "NO NAME_3"],
                    "Same-name cards are numbered in drag order")
        assertEqual(staged.map(\.suggestedLabel), ["NO NAME", "NO NAME", "NO NAME"],
                    "The engine's suggestion is kept for the rename note")
        assertEqual(staged.map(\.renamedBecause),
                    [nil, .sameNameInBatch, .sameNameInBatch],
                    "Only the numbered cards say why they were renamed")
        assertTrue(staged.allSatisfy { $0.refusal == nil }, "No same-name card is refused")
        assertEqual(staged.map { $0.destinationLanes.map(\.lanePath) },
                    [["/Volumes/Backup/NO NAME"], ["/Volumes/Backup/NO NAME_2"], ["/Volumes/Backup/NO NAME_3"]],
                    "Every card gets its own lane")
        assertTrue(staged.allSatisfy { item in item.destinationLanes.allSatisfy { $0.label == item.label } },
                   "Lane labels follow the assigned name")
    } catch {
        TestRecorder.shared.recordFail(message: "Same-name cards must stage, got \(error)", line: #line)
    }
}

@MainActor
static func testLabelKeyIgnoresCaseWhenNumbering() async {
    // 'A001' and 'a001' are one folder on APFS/exFAT, so they are one name.
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 811)
    fs.registerDirectory("/Volumes/CardB", devId: 2, fileId: 812)
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/CardA"] = BatchInspectionResult(
        protocolVersion: 3, metadata: CardInspectionMetadata(label: "Untitled"))
    inspector.inspectionMap["/Volumes/CardB"] = BatchInspectionResult(
        protocolVersion: 3, metadata: CardInspectionMetadata(label: "UNTITLED"))
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)
    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA", "/Volumes/CardB"],
            destinationRoots: ["/Volumes/Backup"])
        assertEqual(staged.map(\.label), ["Untitled", "UNTITLED_2"], "Case-only duplicates are numbered")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testDestinationLaneCollisionRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 901)
    fs.registerDirectory("/Volumes/CardB", devId: 2, fileId: 902)
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/CardA"] = BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(label: "ROLL_A", totalBytes: 100, fileCount: 1)
    )
    inspector.inspectionMap["/Volumes/CardB"] = BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(label: "ROLL_B", totalBytes: 200, fileCount: 2)
    )
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA", "/Volumes/CardB"],
            destinationRoots: ["/Volumes/Backup"]
        )
        assertEqual(staged.count, 2, "Staged 2 distinct candidates")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testConcreteMirroredDestinationLaneProjection() async {
    // Regression for the live DT20 setup: two separate raw roots must project
    // to two separate concrete card lanes. This is pure path math; it does
    // not mount, inspect, create, or touch either volume.
    let roots = [
        "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws",
        "/Volumes/DT20_DEST_B/SHOW/Raws/DUMPTRUCK_TEST/Raws"
    ]
    let label = "DT20_CARD"
    let expected = [
        "/Volumes/DT20_DEST_A/SHOW/Raws/DUMPTRUCK_TEST/Raws/DT20_CARD",
        "/Volumes/DT20_DEST_B/SHOW/Raws/DUMPTRUCK_TEST/Raws/DT20_CARD"
    ]

    let projected = roots.compactMap {
        BatchDestinationLanePath.make(destinationRoot: $0, label: label)
    }
    assertEqual(projected, expected, "Concrete mirrored lane paths")
    assertTrue(
        projected.allSatisfy { !$0.contains("(root)") && !$0.contains("(label)") },
        "Lane projection never emits placeholders"
    )
    assertEqual(
        BatchDestinationLanePath.make(destinationRoot: "(root)", label: "(label)"),
        nil,
        "Placeholder roots/labels are refused instead of projected"
    )

    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/DT20_CARD/DCIM", devId: 20, fileId: 2001)
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/DT20_CARD/DCIM"] = BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(label: label, totalBytes: 12_600_000, fileCount: 2)
    )
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/DT20_CARD/DCIM"],
            destinationRoots: roots
        )
        assertEqual(
            staged[0].destinationLanes.map(\.lanePath),
            expected,
            "Core and UI projection agree for mirrored roots"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected DT20 lane projection error \(error)", line: #line)
    }
}

@MainActor
static func testExistingDestinationLaneConflictRejection() async {
    // Yesterday's "CardA" folder is already on the drive and this is a
    // different card (unknown to the registry). It must not write there;
    // it is numbered past every taken folder instead of refusing the batch.
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 1001)
    fs.registerDirectory("/Volumes/CardB", devId: 2, fileId: 1002)
    fs.registerExistingLane("/Volumes/Backup/CardA")
    fs.registerExistingLane("/Volumes/Backup/CardA_2")
    let inspector = MockBatchSourceInspector()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA", "/Volumes/CardB"],
            destinationRoots: ["/Volumes/Backup"]
        )
        assertEqual(staged.map(\.label), ["CardA_3", "CardB"],
                    "A different card never writes into an existing lane")
        assertEqual(staged[0].renamedBecause, .folderTaken(lanePath: "/Volumes/Backup/CardA"),
                    "The rename names the folder that was in the way")
        assertEqual(staged[0].destinationLanes.map(\.lanePath), ["/Volumes/Backup/CardA_3"],
                    "The numbered lane is the one staged")
        assertEqual(staged[1].renamedBecause, nil, "The other card is untouched")
    } catch {
        TestRecorder.shared.recordFail(message: "Existing lane must not refuse the batch, got \(error)", line: #line)
    }
}

/// A card the engine recognized, with the card folders it wrote before.
private static func knownCard(_ label: String, previous: [String]) -> BatchInspectionResult {
    BatchInspectionResult(
        protocolVersion: 3,
        metadata: CardInspectionMetadata(
            label: label, totalBytes: 100, fileCount: 1,
            customProperties: ["known": "true"],
            previousDestinations: previous))
}

@MainActor
static func testKnownCardContinuesIntoItsOwnLane() async {
    // Re-inserting a card continues into its existing folder, exactly as
    // single-card Start does. An unknown card with the same default name,
    // dragged in FIRST, must not take that name from it.
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/NO NAME", devId: 1, fileId: 1201)
    fs.registerDirectory("/Volumes/NO NAME 1", devId: 2, fileId: 1202)
    fs.registerExistingLane("/Volumes/Backup/NO NAME")
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/NO NAME"] = BatchInspectionResult(
        protocolVersion: 3, metadata: CardInspectionMetadata(label: "NO NAME"))
    // The registry records realpath() spellings and folds case.
    inspector.inspectionMap["/Volumes/NO NAME 1"] = knownCard(
        "NO NAME", previous: ["/Volumes/BACKUP/no name"])
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/NO NAME", "/Volumes/NO NAME 1"],
            destinationRoots: ["/Volumes/Backup"])
        assertEqual(staged.map(\.label), ["NO NAME_2", "NO NAME"],
                    "The known card keeps its name; the new card is numbered")
        assertEqual(staged[1].destinationLanes.map(\.lanePath), ["/Volumes/Backup/NO NAME"],
                    "The known card continues into its own existing lane")
        assertEqual(staged[1].refusal, nil, "Continuation is not refused")
        assertEqual(staged[1].renamedBecause, nil, "A known card is never renamed")
        assertEqual(staged[0].renamedBecause, .sameNameInBatch, "The new card is numbered")
    } catch {
        TestRecorder.shared.recordFail(message: "Continuation must stage, got \(error)", line: #line)
    }
}

@MainActor
static func testKnownCardBlockedByAnotherCardsLaneIsRefusedAlone() async {
    // A known card's name is its continuation key, so it is not renamed
    // behind the operator's back. When its folder on this drive was written
    // by a different card, only that card is refused, inspection kept.
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/A001", devId: 1, fileId: 1301)
    fs.registerDirectory("/Volumes/B001", devId: 2, fileId: 1302)
    fs.registerExistingLane("/Volumes/Backup/A001")
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/A001"] = knownCard("A001", previous: ["/Volumes/Other/A001"])
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/A001", "/Volumes/B001"],
            destinationRoots: ["/Volumes/Backup"])
        assertEqual(staged.count, 2, "Both cards come back inspected")
        assertEqual(staged[0].refusal,
                    BatchLabelAllocator.existingFolderRefusal(label: "A001", lanePath: "/Volumes/Backup/A001"),
                    "The known card is refused with the fix in the message")
        assertTrue(staged[0].destinationLanes.isEmpty, "A refused card has no lanes")
        assertEqual(staged[0].metadata.fileCount, 1, "A refused card keeps its inspection")
        assertEqual(staged[1].refusal, nil, "The other card is unaffected")
        assertEqual(staged[1].label, "B001", "The other card keeps its name")
    } catch {
        TestRecorder.shared.recordFail(message: "A per-card refusal must not throw, got \(error)", line: #line)
    }
}

@MainActor
static func testTwoKnownCardsWithOneNameAreBothRefused() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/Untitled", devId: 1, fileId: 1401)
    fs.registerDirectory("/Volumes/Untitled 1", devId: 2, fileId: 1402)
    fs.registerDirectory("/Volumes/Untitled 2", devId: 3, fileId: 1403)
    let inspector = MockBatchSourceInspector()
    inspector.inspectionMap["/Volumes/Untitled"] = knownCard("Untitled", previous: ["/Volumes/X/Untitled"])
    inspector.inspectionMap["/Volumes/Untitled 1"] = knownCard("Untitled", previous: ["/Volumes/Y/Untitled"])
    inspector.inspectionMap["/Volumes/Untitled 2"] = BatchInspectionResult(
        protocolVersion: 3, metadata: CardInspectionMetadata(label: "Untitled"))
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/Untitled", "/Volumes/Untitled 1", "/Volumes/Untitled 2"],
            destinationRoots: ["/Volumes/Backup"])
        assertEqual(staged[0].refusal,
                    BatchLabelAllocator.sameNameRefusal(label: "Untitled", other: "Untitled 1"),
                    "The first known card names the other")
        assertEqual(staged[1].refusal,
                    BatchLabelAllocator.sameNameRefusal(label: "Untitled", other: "Untitled"),
                    "The second known card names the first")
        assertEqual(staged[2].label, "Untitled_2", "A new card is numbered around both")
        assertEqual(staged[2].refusal, nil, "The new card is Ready")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testLabelAllocatorRules() async {
    typealias A = BatchLabelAllocator
    func run(_ entries: [A.Entry], foreign: Set<String> = []) -> [A.Outcome?] {
        var allocator = A(entries: entries)
        var guardCount = 0
        while let request = allocator.nextRequest() {
            guardCount += 1
            if guardCount > 5000 { break }
            let lane = "/D/" + request.label
            allocator.answer(.lanes([A.LaneProbe(path: lane, foreign: foreign.contains(lane))]))
        }
        return allocator.outcomes
    }
    func label(_ outcome: A.Outcome?) -> String? {
        if case let .assigned(label, _, _, _)? = outcome { return label }
        return nil
    }
    func auto(_ source: String, _ label: String) -> A.Entry {
        A.Entry(source: source, displayName: source, label: label, fixed: false)
    }
    func typed(_ source: String, _ label: String) -> A.Entry {
        A.Entry(source: source, displayName: source, label: label, fixed: true)
    }

    // A numbered name never takes the name another card carries itself.
    let natural = run([auto("a", "NO NAME"), auto("b", "NO NAME"), auto("c", "NO NAME_2")])
    assertEqual(natural.map(label), ["NO NAME", "NO NAME_3", "NO NAME_2"],
                "Numbering skips another card's own name")

    // Two typed duplicates refuse both, with the other card named; an
    // automatic card with the same suggestion steps around them.
    let typedDup = run([typed("a", "CAM_B"), auto("b", "CAM_B"), typed("c", "cam_b")])
    assertEqual(typedDup[0], .refused(A.sameNameRefusal(label: "CAM_B", other: "c")), "First typed duplicate refused")
    assertEqual(typedDup[2], .refused(A.sameNameRefusal(label: "cam_b", other: "a")), "Second typed duplicate refused")
    assertEqual(label(typedDup[1]), "CAM_B_2", "The automatic card avoids the typed name")

    // Editing one of them clears both.
    let fixedDup = run([typed("a", "CAM_B"), auto("b", "CAM_B"), typed("c", "CAM_C")])
    assertEqual(fixedDup.map(label), ["CAM_B", "CAM_B_2", "CAM_C"], "Renaming one duplicate clears both")

    // A typed name is never renamed: a foreign folder refuses it.
    let typedTaken = run([typed("a", "A001")], foreign: ["/D/A001"])
    assertEqual(typedTaken[0], .refused(A.existingFolderRefusal(label: "A001", lanePath: "/D/A001")),
                "A typed name whose folder belongs to another card is refused, not renamed")

    // Every numbered name taken: refused, not looped forever.
    var everything = Set<String>(["/D/X"])
    for n in 2...BatchCardNaming.maxSuffix { everything.insert("/D/X_\(n)") }
    let exhausted = run([auto("a", "X")], foreign: everything)
    assertEqual(exhausted[0], .refused(A.exhaustedRefusal(label: "X")), "Exhausted names refuse the card")

    // The number is kept whole; the base is trimmed to fit the byte limit.
    let long = String(repeating: "é", count: 127)   // 254 bytes
    let numbered = BatchCardNaming.numbered(long, 12, maxLength: 255)
    assertTrue(numbered.hasSuffix("_12") && numbered.utf8.count <= 255, "Numbered names fit 255 bytes")
    assertEqual(BatchCardNaming.numbered("NO NAME", 1), "NO NAME", "The first card keeps its name")

    // Rename notes.
    assertEqual(A.renameNote(from: "NO NAME", reason: .sameNameInBatch),
                "Renamed from \"NO NAME\": another card in this batch has the same name.",
                "Same-name note")
}

@MainActor
static func testLaneOwnershipMatchesEngineSpelling() async {
    let identity: (String) -> String = { $0 }
    assertTrue(BatchCardNaming.laneBelongsToCard(
        "/Volumes/Backup/A001", known: true,
        previousDestinations: ["/Volumes/backup/a001/"], resolve: identity),
        "Case and trailing slash do not matter")
    assertTrue(BatchCardNaming.laneBelongsToCard(
        "/var/folders/x/A001", known: true,
        previousDestinations: ["/private/var/folders/x/A001"], resolve: identity),
        "realpath's /private spelling matches")
    assertTrue(!BatchCardNaming.laneBelongsToCard(
        "/Volumes/Backup/A001", known: false,
        previousDestinations: ["/Volumes/Backup/A001"], resolve: identity),
        "An unknown card owns nothing")
    assertTrue(!BatchCardNaming.laneBelongsToCard(
        "/Volumes/Backup/A001", known: true,
        previousDestinations: ["/Volumes/Other/A001"], resolve: identity),
        "Same name on another drive is not this lane")
    assertTrue(BatchCardNaming.laneBelongsToCard(
        "/Volumes/Link/A001", known: true,
        previousDestinations: ["/Volumes/Real/A001"],
        resolve: { $0.replacingOccurrences(of: "/Link/", with: "/Real/") }),
        "Symlinks resolve before comparing")

    // The live parser carries the recorded folders through.
    let payload: [String: Any] = [
        "protocol": 3, "version": "0.3.0", "format": "sony_xavc_s",
        "format_name": "Sony XAVC S", "reel_name": NSNull(),
        "suggested_label": "NO NAME_2", "known": true, "ambiguous": false,
        "mounts": 2, "last_offload": NSNull(),
        "previous_destinations": ["/Volumes/Backup/NO NAME_2"],
        "files": 1, "bytes": 1, "warnings": NSNull()
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let parsed = try StandardBatchSourceInspector.parseInspectionData(data, sourcePath: "/Volumes/NO NAME")
        assertEqual(parsed.metadata.previousDestinations, ["/Volumes/Backup/NO NAME_2"],
                    "previous_destinations reaches the batch")
        assertTrue(parsed.metadata.isKnownCard, "known reaches the batch")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected parse error \(error)", line: #line)
    }
}

@MainActor
static func testProtocolMismatchRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 1101)
    let inspector = MockBatchSourceInspector()
    inspector.defaultProtocolVersion = 2
    let core = BatchSourceStagingCore(
        fileSystem: fs,
        inspector: inspector,
        options: BatchSourceStagingOptions(expectedProtocolVersion: 3)
    )

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected protocolMismatch error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(
            error,
            .protocolMismatch(expected: 3, actual: 2, path: "/Volumes/CardA"),
            "Protocol mismatch rejection"
        )
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testInspectionFailureRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 1201)
    let inspector = MockBatchSourceInspector()
    struct CustomError: LocalizedError {
        var errorDescription: String? { "I/O Hardware Error" }
    }
    inspector.throwErrorForPath["/Volumes/CardA"] = CustomError()
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected inspectionFailed error", line: #line)
    } catch let error as BatchSourceStagingError {
        switch error {
        case let .inspectionFailed(path, message):
            assertEqual(path, "/Volumes/CardA", "Inspection failed path")
            assertTrue(message.contains("I/O Hardware Error"), "Inspection failed message")
        default:
            TestRecorder.shared.recordFail(message: "Expected inspectionFailed, got \(error)", line: #line)
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testGenericSourceAcceptsNullableInspectionMetadata() async {
    // This is the exact shape emitted by `dumptruck inspect` for a fresh
    // generic/DCIM source: camera-embedded reel identity and prior-offload
    // history are legitimately null.  Keep this regression on JSON parsing,
    // then feed the parsed result through the real batch staging core.
    let payload: [String: Any] = [
        "protocol": 3,
        "version": "0.3.0",
        "format": "dcim",
        "format_name": "Generic camera (DCIM)",
        "reel_name": NSNull(),
        "suggested_label": "DT20_CARD",
        "known": false,
        "ambiguous": false,
        "mounts": 0,
        "last_offload": NSNull(),
        "previous_destinations": NSNull(),
        "files": 2,
        "bytes": 10_485_760,
        "warnings": NSNull()
    ]

    do {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let parsed = try StandardBatchSourceInspector.parseInspectionData(
            data,
            sourcePath: "/Volumes/DT20_CARD"
        )
        assertEqual(parsed.protocolVersion, 3, "Nullable metadata protocol")
        assertEqual(parsed.metadata.label, "DT20_CARD", "Generic source label")
        assertEqual(parsed.metadata.totalBytes, 10_485_760, "Generic source bytes")
        assertEqual(parsed.metadata.fileCount, 2, "Generic source files")
        assertEqual(parsed.metadata.customProperties["reel_name"], "", "Null reel is absent")
        assertEqual(parsed.metadata.customProperties["known"], "false", "Known identity")

        let fs = MockBatchSourceFileSystem()
        fs.registerDirectory("/Volumes/DT20_CARD", devId: 7, fileId: 701)
        let inspector = MockBatchSourceInspector()
        inspector.inspectionMap["/Volumes/DT20_CARD"] = parsed
        let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/DT20_CARD"],
            destinationRoots: ["/Volumes/DT20_DEST_A"]
        )
        assertEqual(staged.count, 1, "Generic source stages as one candidate")
        assertEqual(staged[0].label, "DT20_CARD", "Generic source lane label")

        // Null is allowed only on nullable metadata.  A required field must
        // still refuse a truncated/malformed inspection rather than decay to
        // a placeholder that can be queued.
        var missingRequired = payload
        missingRequired["suggested_label"] = NSNull()
        let malformed = try JSONSerialization.data(withJSONObject: missingRequired)
        do {
            _ = try StandardBatchSourceInspector.parseInspectionData(
                malformed,
                sourcePath: "/Volumes/DT20_CARD"
            )
            TestRecorder.shared.recordFail(
                message: "Expected null required suggested_label to be rejected",
                line: #line
            )
        } catch let error as BatchSourceStagingError {
            switch error {
            case let .inspectionFailed(path, message):
                assertEqual(path, "/Volumes/DT20_CARD", "Required field rejection path")
                assertTrue(message.contains("suggested_label"), "Required field rejection reason")
            default:
                TestRecorder.shared.recordFail(
                    message: "Expected inspectionFailed, got \(error)",
                    line: #line
                )
            }
        }
    } catch {
        TestRecorder.shared.recordFail(
            message: "Unexpected nullable generic inspection failure: \(error)",
            line: #line
        )
    }
}

@MainActor
static func testTimeoutRejection() async {
    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/CardA", devId: 1, fileId: 1301)
    let inspector = MockBatchSourceInspector()
    inspector.delaySeconds = 0.5
    // No per-card allowance here: this pins the deadline itself.
    let options = BatchSourceStagingOptions(timeoutSeconds: 0.1, perCandidateTimeoutSeconds: 0)
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector, options: options)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/CardA"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected timeout error", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .timeout(seconds: 0.1), "Timeout rejection")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

/// The deadline grows with the pile: every card is inspected serially, so a
/// flat budget refused a whole batch when one card was slow (Joshua,
/// 2026-09-28). Three cards at 0.3 s each finish in ~0.9 s, past the 0.2 s
/// base, and must still pass with a 0.4 s-per-card allowance.
@MainActor
static func testTimeoutScalesWithCandidateCount() async {
    let defaults = BatchSourceStagingOptions()
    assertEqual(defaults.timeoutBudget(candidateCount: 1), 30.0, "Default budget for one card")
    assertEqual(defaults.timeoutBudget(candidateCount: 4), 75.0, "Default budget for four cards")

    let fs = MockBatchSourceFileSystem()
    fs.registerDirectory("/Volumes/SlowA", devId: 1, fileId: 1401)
    fs.registerDirectory("/Volumes/SlowB", devId: 1, fileId: 1402)
    fs.registerDirectory("/Volumes/SlowC", devId: 1, fileId: 1403)
    let inspector = MockBatchSourceInspector()
    inspector.delaySeconds = 0.3
    let options = BatchSourceStagingOptions(timeoutSeconds: 0.2, perCandidateTimeoutSeconds: 0.4)
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector, options: options)

    do {
        let staged = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/SlowA", "/Volumes/SlowB", "/Volumes/SlowC"],
            destinationRoots: ["/Volumes/Backup"]
        )
        assertEqual(staged.count, 3, "Slow-but-healthy pile stages every card")
    } catch {
        TestRecorder.shared.recordFail(message: "Scaled budget still timed out: \(error)", line: #line)
    }
}

@MainActor
static func testPreservesInputOrderAndMultipleDestinationsSuccess() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()

    let candidatePaths = [
        "/Volumes/Card_Gamma",
        "/Volumes/Card_Alpha",
        "/Volumes/Card_Beta",
        "/Volumes/Card_Delta"
    ]

    for (index, path) in candidatePaths.enumerated() {
        fs.registerDirectory(path, devId: 10, fileId: UInt64(2000 + index), volumeUUID: "VOL-\(index)")
        let label = (path as NSString).lastPathComponent
        inspector.inspectionMap[path] = BatchInspectionResult(
            protocolVersion: 3,
            metadata: CardInspectionMetadata(
                label: label,
                totalBytes: Int64((index + 1) * 1_000_000_000),
                fileCount: (index + 1) * 10,
                customProperties: ["cam": "CAM_\(index)"]
            )
        )
    }

    let destRoots = ["/Volumes/PrimaryBackup", "/Volumes/OffsiteMirror"]
    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        let stagedItems = try await core.stageBatch(
            candidateSourcePaths: candidatePaths,
            destinationRoots: destRoots
        )

        // Verify count
        assertEqual(stagedItems.count, 4, "Staged items count")

        // Verify preservation of exact input order
        for (index, item) in stagedItems.enumerated() {
            let expectedOrig = candidatePaths[index]
            let expectedNorm = StandardPurePathNormalizer.normalize(expectedOrig)
            let expectedLabel = (expectedOrig as NSString).lastPathComponent

            assertEqual(item.originalPath, expectedOrig, "Order preserved originalPath at \(index)")
            assertEqual(item.normalizedSourcePath, expectedNorm, "Order preserved normalizedPath at \(index)")
            assertEqual(item.label, expectedLabel, "Order preserved label at \(index)")
            assertEqual(item.identityPin.deviceId, 10, "Identity pin devId at \(index)")
            assertEqual(item.identityPin.fileId, UInt64(2000 + index), "Identity pin fileId at \(index)")
            assertEqual(item.identityPin.volumeUUID, "VOL-\(index)", "Identity pin volumeUUID at \(index)")
            assertEqual(item.metadata.fileCount, (index + 1) * 10, "Metadata file count at \(index)")

            // Verify destination lanes deterministic mapping
            assertEqual(item.destinationLanes.count, 2, "Destination lanes count")
            assertEqual(item.destinationLanes[0].destinationRoot, "/Volumes/PrimaryBackup", "Dest root 0")
            assertEqual(item.destinationLanes[0].lanePath, "/Volumes/PrimaryBackup/\(expectedLabel)", "Lane path 0")
            assertEqual(item.destinationLanes[1].destinationRoot, "/Volumes/OffsiteMirror", "Dest root 1")
            assertEqual(item.destinationLanes[1].lanePath, "/Volumes/OffsiteMirror/\(expectedLabel)", "Lane path 1")
        }
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

@MainActor
static func testAllOrNothingGuarantee() async {
    let fs = MockBatchSourceFileSystem()
    let inspector = MockBatchSourceInspector()

    // 3 cards, 3rd card does not exist in fs
    fs.registerDirectory("/Volumes/Card1", devId: 1, fileId: 3001)
    fs.registerDirectory("/Volumes/Card2", devId: 1, fileId: 3002)
    // Card3 is missing!

    let core = BatchSourceStagingCore(fileSystem: fs, inspector: inspector)

    do {
        _ = try await core.stageBatch(
            candidateSourcePaths: ["/Volumes/Card1", "/Volumes/Card2", "/Volumes/Card3"],
            destinationRoots: ["/Volumes/Backup"]
        )
        TestRecorder.shared.recordFail(message: "Expected sourceNotFound all-or-nothing failure", line: #line)
    } catch let error as BatchSourceStagingError {
        assertEqual(error, .sourceNotFound(path: "/Volumes/Card3"), "All-or-nothing failure when one candidate fails")
    } catch {
        TestRecorder.shared.recordFail(message: "Unexpected error \(error)", line: #line)
    }
}

// MARK: - Main Runner

    @MainActor
    static func run() async {
        print("🚀 Running BatchSourceStagingCheck suite...")

        await testEmptyCandidatesRejection()
        await testCandidateLimitExceededRejection()
        await testInvalidPathRejection()
        await testPathLengthExceededRejection()
        await testSourceNotFoundRejection()
        await testSourceNotDirectoryRejection()
        await testSourceIsSymlinkRejection()
        await testDuplicateCandidatePathRejection()
        await testDuplicateCandidatePinRejection()
        await testMutualSourceOverlapRejection()
        await testSourceDestinationOverlapRejection()
        await testActiveSourceOverlapRejection()
        await testEmptyOrInvalidLabelRejection()
        await testLabelLengthExceededRejection()
        await testDuplicateLabelRejection()
        await testDestinationLaneCollisionRejection()
        await testConcreteMirroredDestinationLaneProjection()
        await testExistingDestinationLaneConflictRejection()
        await testLabelKeyIgnoresCaseWhenNumbering()
        await testKnownCardContinuesIntoItsOwnLane()
        await testKnownCardBlockedByAnotherCardsLaneIsRefusedAlone()
        await testTwoKnownCardsWithOneNameAreBothRefused()
        await testLabelAllocatorRules()
        await testLaneOwnershipMatchesEngineSpelling()
        await testProtocolMismatchRejection()
        await testInspectionFailureRejection()
        await testGenericSourceAcceptsNullableInspectionMetadata()
        await testTimeoutRejection()
        await testTimeoutScalesWithCandidateCount()
        await testPreservesInputOrderAndMultipleDestinationsSuccess()
        await testAllOrNothingGuarantee()

        let passed = TestRecorder.shared.passCount
        let failed = TestRecorder.shared.failCount

        print("\n📊 BatchSourceStagingCheck Summary:")
        print("   Passed: \(passed)")
        print("   Failed: \(failed)")

        if failed > 0 {
            fatalError("❌ SUITE FAILED")
        } else {
            print("✅ ALL TESTS PASSED")
        }
    }
}
