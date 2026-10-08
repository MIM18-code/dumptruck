import AppKit
import Foundation

enum EvidenceParserCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

    @MainActor
    static func run() throws {
        let refusal = Data("""
        {"protocol":3,"error":"source traversal failed at /CARD/LOCKED_FOOTAGE: Permission denied"}
        """.utf8)
        require(AppModel.inspectionResponse(refusal, exitStatus: 1) == refusal,
                "A nonzero inspect exit must preserve the engine's source error")
        let healthyInspection = Data("""
        {"protocol":3,"suggested_label":"CARD","files":1,"bytes":1024}
        """.utf8)
        require(AppModel.inspectionResponse(healthyInspection, exitStatus: 0) == healthyInspection,
                "Successful inspection data must reach the existing decoder")
        require(AppModel.inspectionResponse(healthyInspection, exitStatus: 1) == nil,
                "A failed process must not publish successful inspection data")
        for invalid in ["not JSON", "[]", "{}",
                        "{\"protocol\":2,\"error\":\"refused\"}",
                        "{\"protocol\":3,\"error\":\" \"}",
                        "{\"protocol\":3,\"error\":false}"] {
            require(AppModel.inspectionResponse(Data(invalid.utf8), exitStatus: 1) == nil,
                    "Malformed or incompatible failure output must be rejected")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dumptruck-evidence-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dest1 = root.appendingPathComponent("DEST1/CARD_A").path
        let dest2 = root.appendingPathComponent("DEST2/CARD_A").path
        try FileManager.default.createDirectory(atPath: dest1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dest2, withIntermediateDirectories: true)

        let reportDir = root.appendingPathComponent("DEST1/Reports/CARD_A").path
        try FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)

        // 1. Valid Receipt JSON Round-trip
        let validReceiptJSON = """
        {
          "job_id": "11111111-2222-3333-4444-555555555555",
          "tool": "Dumptruck 0.3.0",
          "generated": "2026-08-21T18:30:00Z",
          "operator": "joshualand",
          "host": "studio-mac.local",
          "label": "CARD_A",
          "source": "/Volumes/CARD_A",
          "destinations": ["\(dest1)", "\(dest2)"],
          "verdict": "FULLY VERIFIED",
          "attestation": {
            "safe_to_wipe_source": true,
            "safe_to_wipe_blockers": [],
            "source_read_count": 2,
            "source_reread_consistent": true,
            "write_fd_nocache": true,
            "verify_fd_nocache": true,
            "full_flush_before_close": true,
            "independently_verified_destinations": 2,
            "distinct_physical_devices": 2
          },
          "manifests": [
            "\(dest1)/ascmhl/CARD_A_20260821_183000.mhl",
            "\(dest2)/ascmhl/CARD_A_20260821_183000.mhl"
          ],
          "files_total": 3,
          "files_copied": 3,
          "bytes_copied": 3145728,
          "errors": [],
          "files": [
            {
              "path": "CLIPS/A001_C001.mov",
              "size": 1048576,
              "outcome": "verified",
              "hashes": {
                "xxh64": "e3b0c44298fc1c14",
                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
              },
              "status": {
                "\(dest1)": "verified",
                "\(dest2)": "verified"
              }
            },
            {
              "path": "CLIPS/A001_C002.mov",
              "size": 2097152,
              "outcome": "verified",
              "hashes": {
                "xxh64": "0123456789abcdef"
              },
              "status": {
                "\(dest1)": "verified",
                "\(dest2)": "verified"
              }
            },
            {
              "path": "AUDIO/A001_S001.wav",
              "size": 0,
              "outcome": "skipped",
              "hashes": {
                "xxh64": "efcdab8967452301"
              },
              "status": {
                "\(dest1)": "trusted",
                "\(dest2)": "trusted"
              }
            }
          ]
        }
        """

        let receiptURL = URL(fileURLWithPath: reportDir).appendingPathComponent("CARD_A_offload_test.receipt.json")
        try validReceiptJSON.data(using: .utf8)!.write(to: receiptURL)

        let evidence = try JobEvidenceParser.parse(
            data: try Data(contentsOf: receiptURL),
            expectedLabel: "CARD_A",
            expectedDestinations: [dest1, dest2],
            receiptFilePath: receiptURL.path
        )

        require(evidence.label == "CARD_A", "parsed label did not match")
        require(evidence.verdict == "FULLY VERIFIED", "parsed verdict did not match")
        require(evidence.receiptClaimedSafeToWipe == true, "receipt safe_to_wipe claim was not retained as report data")
        require(evidence.files.count == 3, "file count was not 3")
        require(evidence.manifests.count == 2, "manifest count was not 2")
        require(evidence.bytesCopied == 3145728, "bytesCopied mismatch")

        let file0 = evidence.files[0]
        require(file0.path == "CLIPS/A001_C001.mov", "file path mismatch")
        require(file0.size == 1048576, "file size mismatch")
        require(file0.outcome == "verified", "file outcome mismatch")
        require(file0.primaryChecksum?.algorithm == "xxh64", "xxh64 was not chosen as primary")
        require(file0.primaryChecksum?.hex == "e3b0c44298fc1c14", "primary checksum hex mismatch")
        require(file0.formattedSize == "1.0 MB", "formatted size mismatch")

        // 2. Checksum does not imply source wipe safety
        let unsafeAttestationReceipt = """
        {
          "job_id": "22222222-3333-4444-5555-666666666666",
          "label": "CARD_UNSAFE",
          "destinations": ["\(dest1)"],
          "verdict": "OK — NOT FULLY VERIFIED",
          "attestation": {
            "safe_to_wipe_source": false,
            "safe_to_wipe_blockers": ["only one physical device"],
            "independently_verified_destinations": 1,
            "distinct_physical_devices": 1
          },
          "files": [
            {
              "path": "test.mov",
              "size": 100,
              "outcome": "verified",
              "hashes": {"xxh64": "1234567812345678"}
            }
          ]
        }
        """
        let unsafeEvidence = try JobEvidenceParser.parse(
            data: Data(unsafeAttestationReceipt.utf8),
            expectedLabel: "CARD_UNSAFE",
            expectedDestinations: [dest1],
            receiptFilePath: "/tmp/dummy.receipt.json"
        )
        require(!unsafeEvidence.receiptClaimedSafeToWipe, "unsafe receipt claim was marked safe")
        require(unsafeEvidence.receiptClaimedWipeBlockers == ["only one physical device"], "wipe blockers missing")
        require(unsafeEvidence.files[0].primaryChecksum?.hex == "1234567812345678", "valid checksum on destination was lost")

        // 3. Rejection of Path Traversal Escapes
        let traversalReceipt = """
        {
          "label": "CARD_A",
          "destinations": ["\(dest1)"],
          "files": [
            {
              "path": "../../etc/shadow",
              "size": 10,
              "outcome": "verified"
            }
          ]
        }
        """
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(traversalReceipt.utf8),
                expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json"
            )
            fatalError("path traversal in file path was not rejected")
        } catch let err as ReceiptParseError {
            if case .pathTraversalDetected = err {
                // Expected
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // Absolute path in file entry
        let absolutePathReceipt = """
        {
          "label": "CARD_A",
          "destinations": ["\(dest1)"],
          "files": [
            {
              "path": "/System/Library/file.mov",
              "size": 10,
              "outcome": "verified"
            }
          ]
        }
        """
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(absolutePathReceipt.utf8),
                expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json"
            )
            fatalError("absolute file path was not rejected")
        } catch let err as ReceiptParseError {
            if case .pathTraversalDetected = err {
                // Expected
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 4. Rejection of Label Mismatch
        do {
            _ = try JobEvidenceParser.parse(
                data: try Data(contentsOf: receiptURL),
                expectedLabel: "WRONG_LABEL",
                expectedDestinations: [dest1, dest2],
                receiptFilePath: receiptURL.path
            )
            fatalError("label mismatch was not rejected")
        } catch let err as ReceiptParseError {
            if case .labelMismatch(let expected, let found) = err {
                require(expected == "WRONG_LABEL" && found == "CARD_A", "label mismatch details wrong")
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 5. Rejection of Destination Mismatch
        do {
            _ = try JobEvidenceParser.parse(
                data: try Data(contentsOf: receiptURL),
                expectedLabel: "CARD_A",
                expectedDestinations: ["/Volumes/TOTALLY_DIFFERENT_DESTINATION"],
                receiptFilePath: receiptURL.path
            )
            fatalError("destination mismatch was not rejected")
        } catch let err as ReceiptParseError {
            if case .destinationMismatch = err {
                // Expected
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 6. Rejection of Malformed JSON
        do {
            _ = try JobEvidenceParser.parse(
                data: Data("{not valid json".utf8),
                expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json"
            )
            fatalError("malformed JSON was not rejected")
        } catch let err as ReceiptParseError {
            if case .invalidJSON = err {
                // Expected
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 7. Missing Required Field Rejection
        let missingFilesReceipt = """
        {
          "label": "CARD_A",
          "destinations": ["\(dest1)"]
        }
        """
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(missingFilesReceipt.utf8),
                expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json"
            )
            fatalError("missing files field was not rejected")
        } catch let err as ReceiptParseError {
            if case .missingRequiredField(let field) = err {
                require(field == "files", "expected missing field 'files', got '\(field)'")
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 8. Size Cap Rejection
        let bigData = Data(repeating: UInt8(ascii: " "), count: Int(JobEvidenceParser.maxReceiptFileSizeBytes) + 10)
        do {
            _ = try JobEvidenceParser.parse(
                data: bigData,
                expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json"
            )
            fatalError("oversized receipt was not rejected")
        } catch let err as ReceiptParseError {
            if case .fileTooLarge = err {
                // Expected
            } else {
                fatalError("unexpected error: \(err)")
            }
        }

        // 9. Discovery via findReceiptURL
        let job = Job(label: "CARD_A", sourcePath: "/Volumes/CARD_A", destinations: [dest1, dest2])
        job.reportPath = URL(fileURLWithPath: reportDir).appendingPathComponent("CARD_A_offload_test.html").path
        job.reportPaths = [job.reportPath!]
        job.manifestPaths = ["\(dest1)/ascmhl/CARD_A_20260821_183000.mhl"]

        let foundURL = JobEvidenceParser.findReceiptURL(for: job)
        require(foundURL?.path == receiptURL.path, "findReceiptURL did not find sibling receipt")

        // Load evidence via Job
        let loadRes = JobEvidenceParser.loadEvidence(for: job)
        switch loadRes {
        case let .success(loaded):
            require(loaded.label == "CARD_A", "loaded evidence label mismatch")
            require(loaded.files.count == 3, "loaded evidence files count mismatch")
        case let .failure(error):
            fatalError("loadEvidence failed: \(error)")
        }

        // 10. Missing Receipt visible failure
        let missingJob = Job(label: "NON_EXISTENT_CARD", sourcePath: "/source", destinations: ["/Volumes/NON_EXISTENT"])
        let missingRes = JobEvidenceParser.loadEvidence(for: missingJob)
        switch missingRes {
        case .success:
            fatalError("missing receipt unexpectedly succeeded")
        case let .failure(error):
            if case .fileNotFound = error {
                // Expected
            } else {
                fatalError("unexpected error for missing receipt: \(error)")
            }
        }

        // 11. Destination equality is set equality, never a prefix/overlap
        // check. A receipt for one of two destinations is incomplete.
        let subsetDestinations = validReceiptJSON.replacingOccurrences(
            of: "[\"\(dest1)\", \"\(dest2)\"]",
            with: "[\"\(dest1)\"]")
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(subsetDestinations.utf8), expectedLabel: "CARD_A",
                expectedDestinations: [dest1, dest2],
                receiptFilePath: "/tmp/dummy.receipt.json")
            fatalError("destination subset was accepted")
        } catch let err as ReceiptParseError {
            guard case .destinationMismatch = err else {
                fatalError("unexpected subset destination error: \(err)")
            }
        }

        // 12. A source claim is scoped to this job when loading/parsing with
        // an expected source; a same-label receipt for another card is not
        // acceptable evidence.
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(validReceiptJSON.utf8), expectedLabel: "CARD_A",
                expectedDestinations: [dest1, dest2],
                receiptFilePath: "/tmp/dummy.receipt.json",
                expectedSource: "/Volumes/OTHER_CARD")
            fatalError("source mismatch was accepted")
        } catch let err as ReceiptParseError {
            guard case .sourceMismatch = err else {
                fatalError("unexpected source mismatch error: \(err)")
            }
        }

        // 13. Manifest paths must belong to a destination card root, not just
        // contain a matching label.
        let outsideManifestReceipt = """
        {
          "label": "CARD_A",
          "destinations": ["\(dest1)"],
          "source": "/Volumes/CARD_A",
          "manifests": ["\(root.path)/OTHER/CARD_A/ascmhl/bad.mhl"],
          "files": []
        }
        """
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(outsideManifestReceipt.utf8), expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json")
            fatalError("out-of-scope manifest was accepted")
        } catch let err as ReceiptParseError {
            guard case .pathOutsideJobScope = err else {
                fatalError("unexpected manifest scope error: \(err)")
            }
        }

        // 14. Hash algorithms and lengths are bounded; malformed report data
        // cannot become a displayed checksum.
        let malformedHashReceipt = """
        {
          "label": "CARD_A",
          "destinations": ["\(dest1)"],
          "files": [
            {"path": "clip.mov", "outcome": "verified",
             "hashes": {"sha256": "not-a-sha256"}}
          ]
        }
        """
        do {
            _ = try JobEvidenceParser.parse(
                data: Data(malformedHashReceipt.utf8), expectedLabel: "CARD_A",
                expectedDestinations: [dest1],
                receiptFilePath: "/tmp/dummy.receipt.json")
            fatalError("malformed hash was accepted")
        } catch let err as ReceiptParseError {
            guard case .invalidField = err else {
                fatalError("unexpected malformed hash error: \(err)")
            }
        }

        // 15. Discovery is exact-sibling only. A stale same-label receipt in
        // the report directory must not be found by scanning the directory.
        try FileManager.default.removeItem(at: receiptURL)
        let staleReceiptURL = URL(fileURLWithPath: reportDir)
            .appendingPathComponent("CARD_A_stale.receipt.json")
        try Data(validReceiptJSON.utf8).write(to: staleReceiptURL)
        require(JobEvidenceParser.findReceiptURL(for: job) == nil,
                "directory scan found a stale same-label receipt")
        try FileManager.default.removeItem(at: staleReceiptURL)

        // 16. A symlink at the exact derived receipt path is rejected; Finder
        // and Quick Look never follow a receipt redirect.
        let realReceiptURL = receiptURL.appendingPathExtension("real")
        try Data(validReceiptJSON.utf8).write(to: realReceiptURL)
        try FileManager.default.createSymbolicLink(at: receiptURL,
                                                   withDestinationURL: realReceiptURL)
        let symlinkResult = JobEvidenceParser.loadEvidence(for: job)
        switch symlinkResult {
        case .success:
            fatalError("symlink receipt unexpectedly loaded")
        case let .failure(error):
            guard case .invalidReceiptPath = error else {
                fatalError("unexpected symlink receipt error: \(error)")
            }
        }
        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.removeItem(at: realReceiptURL)

        // 17. Exercise the live engine shape: receipt destinations are base
        // roots, while file status keys and manifests are card roots.
        let base1 = root.appendingPathComponent("LIVE_DEST1").path
        let base2 = root.appendingPathComponent("LIVE_DEST2").path
        let cardRoot1 = root.appendingPathComponent("LIVE_DEST1/CARD_LIVE").path
        let cardRoot2 = root.appendingPathComponent("LIVE_DEST2/CARD_LIVE").path
        let liveReportDir = root.appendingPathComponent("LIVE_DEST1/Reports/CARD_LIVE").path
        try FileManager.default.createDirectory(atPath: cardRoot1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cardRoot2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: liveReportDir, withIntermediateDirectories: true)
        let liveReport = URL(fileURLWithPath: liveReportDir)
            .appendingPathComponent("CARD_LIVE_offload_20260821.html")
        let liveReceipt = URL(fileURLWithPath: liveReport.deletingPathExtension().path
            + ".receipt.json")
        let liveJSON = """
        {
          "job_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "label": "CARD_LIVE",
          "source": "/Volumes/CARD_LIVE",
          "destinations": ["\(base1)", "\(base2)"],
          "verdict": "FULLY VERIFIED",
          "manifests": [
            "\(cardRoot1)/ascmhl/0001_CARD_LIVE.mhl",
            "\(cardRoot2)/ascmhl/0001_CARD_LIVE.mhl"
          ],
          "files_total": 1,
          "files_copied": 1,
          "bytes_copied": 10,
          "files": [{
            "path": "CLIPS/A001.mov",
            "size": 10,
            "outcome": "verified",
            "hashes": {"xxh64": "0123456789abcdef"},
            "status": {
              "\(cardRoot1)": "verified",
              "\(cardRoot2)": "verified"
            }
          }]
        }
        """
        try Data("<html></html>".utf8).write(to: liveReport)
        try Data(liveJSON.utf8).write(to: liveReceipt)
        let liveJob = Job(label: "CARD_LIVE", sourcePath: "/Volumes/CARD_LIVE",
                           destinations: [base1, base2])
        liveJob.laneRoots = [cardRoot1, cardRoot2]
        liveJob.reportPaths = [liveReport.path]
        liveJob.reportPath = liveReport.path
        liveJob.manifestPaths = [
            "\(cardRoot1)/ascmhl/0001_CARD_LIVE.mhl",
            "\(cardRoot2)/ascmhl/0001_CARD_LIVE.mhl"
        ]
        switch JobEvidenceParser.loadEvidence(for: liveJob) {
        case let .success(liveEvidence):
            require(liveEvidence.destinations == [base1, base2],
                    "live receipt destination roots were not retained")
            require(liveEvidence.files[0].destinationStatus.count == 2,
                    "live card-root status map was rejected")
        case let .failure(error):
            fatalError("live receipt shape failed: \(error)")
        }

        // 18. Engine path events are rejected before they reach the Job or
        // journal. This prevents a malicious/skewed engine from persisting an
        // arbitrary Finder path under an otherwise valid label.
        let eventJob = Job(label: "CARD_LIVE", sourcePath: "/Volumes/CARD_LIVE",
                           destinations: [base1, base2])
        eventJob.laneRoots = [cardRoot1, cardRoot2]
        require(AppModel.apply(event: [
            "event": "report_written", "paths": [liveReport.path]
        ], to: eventJob), "valid report path event was rejected")
        require(!AppModel.apply(event: [
            "event": "report_written",
            "paths": [root.appendingPathComponent("stale/CARD_LIVE.html").path]
        ], to: eventJob), "out-of-scope report path event was accepted")
        require(eventJob.reportPaths == [liveReport.path],
                "invalid report event changed persisted paths")

        print("EvidenceParserCheck: all assertions passed")
    }
}
