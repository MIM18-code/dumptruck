import Foundation

enum WebhookNotificationCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAILED: \(message)") }
}

final class MockTransport: WebhookHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var handler: Handler?
    private var requests: [URLRequest] = []

    init(handler: Handler? = nil) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func recordAndReadHandler(for request: URLRequest) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return handler
    }

    func send(request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let currentHandler = recordAndReadHandler(for: request)

        if let currentHandler {
            return try await currentHandler(request)
        }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data("{\"status\":\"ok\"}".utf8), resp)
    }
}

    static func run() async throws {
        print("--- Running WebhookNotificationCheck ---")
        try Self.testURLValidation()
        try Self.testSecretStore()
        try Self.testPayloadConstructionAndPrivacyAudit()
        try Self.testVerdictDisplayLineMappings()
        try Self.testRequestBuilder()
        try Self.testRedirectSecurityDelegate()
        try await Self.testInjectableDeliverySuccess()
        try await Self.testInjectableDeliveryHttpErrors()
        try await Self.testSecretRedactionAndBounds()
        try await Self.testInjectableDeliveryNetworkFailure()
        try await Self.testInjectableDeliveryCancellation()
        try await Self.testJobNonMutationInvariants()
        print("--- All WebhookNotificationCheck tests passed! ---")
    }

    // MARK: - 1. URL Validation Tests

    static func testURLValidation() throws {
        // Valid HTTPS URLs
        let validURLs = [
            "https://example.com/webhook",
            "https://api.dumptruck.tv:8443/v1/notify",
            "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX",
            "https://sub.domain.co.uk/path/to/hook?token=abc&source=dt",
            "https://192.168.1.100:8443/hook",
            "https://example.com"
        ]
        for urlStr in validURLs {
            switch WebhookEndpointValidator.validate(urlString: urlStr) {
            case .success(let url):
                require(url.scheme?.lowercased() == "https", "Scheme was not https for \(urlStr)")
            case .failure(let err):
                fatalError("Valid URL was rejected: \(urlStr), error: \(err)")
            }
        }

        // Leading/trailing whitespace should be trimmed and accepted
        switch WebhookEndpointValidator.validate(urlString: "  https://example.com/hook  \n") {
        case .success(let url):
            require(url.absoluteString == "https://example.com/hook", "Trimming failed")
        case .failure(let err):
            fatalError("Trimmed URL was rejected: \(err)")
        }

        // Empty & whitespace
        require(WebhookEndpointValidator.validate(urlString: "") == .failure(.emptyURL), "Empty URL not rejected")
        require(WebhookEndpointValidator.validate(urlString: "   \t\n  ") == .failure(.emptyURL), "Whitespace URL not rejected")

        // Non-HTTPS schemes
        require(WebhookEndpointValidator.validate(urlString: "http://example.com/hook") == .failure(.schemeNotHTTPS), "HTTP was not rejected")
        require(WebhookEndpointValidator.validate(urlString: "ftp://example.com/hook") == .failure(.schemeNotHTTPS), "FTP was not rejected")
        require(WebhookEndpointValidator.validate(urlString: "file:///tmp/hook") == .failure(.schemeNotHTTPS), "file:// was not rejected")
        require(WebhookEndpointValidator.validate(urlString: "javascript:alert(1)") == .failure(.schemeNotHTTPS), "javascript: was not rejected")
        require(WebhookEndpointValidator.validate(urlString: "ws://example.com/hook") == .failure(.schemeNotHTTPS), "ws:// was not rejected")
        require(WebhookEndpointValidator.validate(urlString: "example.com/hook") == .failure(.schemeNotHTTPS), "schemeless URL was not rejected")

        // Credentials in URL
        require(WebhookEndpointValidator.validate(urlString: "https://user:password@example.com/hook") == .failure(.containsCredentials), "Credentials user:pass not rejected")
        require(WebhookEndpointValidator.validate(urlString: "https://user@example.com/hook") == .failure(.containsCredentials), "Credential user@ not rejected")
        require(WebhookEndpointValidator.validate(urlString: "https://:password@example.com/hook") == .failure(.containsCredentials), "Credential :password@ not rejected")

        // Fragments in URL
        require(WebhookEndpointValidator.validate(urlString: "https://example.com/hook#section1") == .failure(.containsFragment), "Fragment #section not rejected")
        require(WebhookEndpointValidator.validate(urlString: "https://example.com/hook#") == .failure(.containsFragment), "Empty fragment # not rejected")

        // Oversized URL
        let hugePath = String(repeating: "a", count: WebhookConfig.maxURLLength)
        let oversized = "https://example.com/\(hugePath)"
        switch WebhookEndpointValidator.validate(urlString: oversized) {
        case .failure(.oversizedURL(let count)):
            require(count > WebhookConfig.maxURLLength, "Oversized count mismatch")
        default:
            fatalError("Oversized URL was not rejected")
        }

        // Missing host
        require(WebhookEndpointValidator.validate(urlString: "https:///path") == .failure(.missingHost), "Missing host was not rejected")

        // Malformed
        require(WebhookEndpointValidator.validate(urlString: "https://foo bar.com") == .failure(.invalidURL), "Malformed spaces URL not rejected")
    }

    // MARK: - 2. Secret Store Tests

    static func testSecretStore() throws {
        let store = InMemoryWebhookSecretStore()
        require(store.loadSecret() == nil, "Initial secret must be nil")

        try store.saveSecret("super-secret-token-123")
        require(store.loadSecret() == "super-secret-token-123", "Secret was not retrieved")

        // Whitespace trimming
        try store.saveSecret("  trimmed-secret  \n")
        require(store.loadSecret() == "trimmed-secret", "Secret was not trimmed")

        // Saving empty/nil clears secret
        try store.saveSecret("")
        require(store.loadSecret() == nil, "Empty string did not delete secret")

        try store.saveSecret("another-token")
        require(store.loadSecret() == "another-token", "Secret was not updated")
        try store.deleteSecret()
        require(store.loadSecret() == nil, "deleteSecret failed")

        // Oversized secret
        let hugeSecret = String(repeating: "s", count: WebhookConfig.maxSecretLength + 1)
        do {
            try store.saveSecret(hugeSecret)
            fatalError("Oversized secret did not throw")
        } catch WebhookKeychainError.secretOversized {
            // expected
        }

        do {
            try store.saveSecret("token\nforbidden")
            fatalError("Control-character secret did not throw")
        } catch WebhookKeychainError.secretContainsControlCharacters {
            // expected
        }
    }

    // MARK: - 3. Payload Construction & Strict Privacy Audit

    static func testPayloadConstructionAndPrivacyAudit() throws {
        let sourcePath = "/Volumes/RED_CARD_042/DCIM/100MEDIA"
        let dest1 = "/Volumes/RAID_MASTER/Production/ShowA/Raws"
        let dest2 = "/Volumes/SHUTTLE_DRIVE/Production/ShowA/Raws"
        let reportPath = "/Volumes/RAID_MASTER/Production/ShowA/Reports/Offload_042.pdf"
        let fileName = "A042_C001_0821XZ_001.R3D"

        let job = Job(
            label: "CARD_042",
            sourcePath: sourcePath,
            destinations: [dest1, dest2]
        )
        job.reportPath = reportPath
        job.currentFile = fileName
        job.bytesTotal = 1_000_000_000
        job.bytesFinished = 1_000_000_000
        job.filesTotal = 50
        job.filesCopied = 48
        job.filesSkipped = 2
        job.filesFailed = 0
        job.rereadDone = 1_000_000_000
        job.fullyVerified = true
        job.safeToWipe = true
        job.phase = .done
        let t0 = Date(timeIntervalSince1970: 1700000000)
        let t1 = Date(timeIntervalSince1970: 1700000500)
        job.startedDate = t0
        job.finishedDate = t1
        job.warn("Minor non-fatal warning")

        let payload = WebhookPayload.from(job: job)
        require(payload.jobID == job.id.uuidString, "Job ID mismatch")
        require(payload.label == "CARD_042", "Label mismatch")
        require(payload.verdict == "SAFE TO WIPE", "Verdict display line mismatch")
        require(payload.phase == "Done", "Phase mismatch")
        require(payload.fullyVerified == true, "fullyVerified mismatch")
        require(payload.safeToWipe == true, "safeToWipe mismatch")
        require(payload.startedAt == ISO8601DateFormatter().string(from: t0), "startedAt mismatch")
        require(payload.finishedAt == ISO8601DateFormatter().string(from: t1), "finishedAt mismatch")
        require(payload.counts.destinationsCount == 2, "destinationsCount mismatch")
        require(payload.counts.filesTotal == 50, "filesTotal mismatch")
        require(payload.counts.filesCopied == 48, "filesCopied mismatch")
        require(payload.counts.filesSkipped == 2, "filesSkipped mismatch")
        require(payload.counts.filesFailed == 0, "filesFailed mismatch")
        require(payload.counts.bytesTotal == 1_000_000_000, "bytesTotal mismatch")
        require(payload.counts.warningCount == 1, "warningCount mismatch")
        require(payload.counts.errorCount == 0, "errorCount mismatch")

        let encodedData = try payload.encodeJSON()
        guard let jsonString = String(data: encodedData, encoding: .utf8) else {
            fatalError("Payload failed to serialize as UTF-8 string")
        }

        // STRICT PRIVACY AUDIT:
        // Assert that NO filesystem path, drive name, file name, or report path is in the payload!
        let forbiddenSubstrings = [
            sourcePath, "/Volumes/RED_CARD_042", "RED_CARD_042", "/DCIM", "100MEDIA",
            dest1, dest2, "/Volumes/RAID_MASTER", "RAID_MASTER", "/Volumes/SHUTTLE_DRIVE", "SHUTTLE_DRIVE",
            reportPath, "Offload_042.pdf",
            fileName, "A042_C001_0821XZ_001", "R3D",
            "/Volumes/", "/Users/", "/tmp/"
        ]
        for forbidden in forbiddenSubstrings {
            require(
                !jsonString.contains(forbidden),
                "PRIVACY LEAK: Payload contains forbidden local path or filename substring '\(forbidden)':\n\(jsonString)"
            )
        }

        // Verify JSON top-level keys
        guard let jsonObject = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any] else {
            fatalError("JSON is not an object dictionary")
        }
        let expectedTopKeys = Set([
            "job_id", "label", "verdict", "phase", "fully_verified", "safe_to_wipe",
            "started_at", "finished_at", "counts"
        ])
        let actualTopKeys = Set(jsonObject.keys)
        require(actualTopKeys == expectedTopKeys, "JSON top keys drifted: \(actualTopKeys)")

        guard let countsObject = jsonObject["counts"] as? [String: Any] else {
            fatalError("counts is not a dictionary")
        }
        let expectedCountKeys = Set([
            "files_total", "files_copied", "files_skipped", "files_failed",
            "bytes_total", "bytes_finished", "bytes_reread", "error_count",
            "warning_count", "destinations_count"
        ])
        let actualCountKeys = Set(countsObject.keys)
        require(actualCountKeys == expectedCountKeys, "counts keys drifted: \(actualCountKeys)")

        // Check label bounding
        let hugeLabelJob = Job(
            label: String(repeating: "X", count: 300),
            sourcePath: "/Volumes/SRC",
            destinations: ["/Volumes/DST"]
        )
        let hugeLabelPayload = WebhookPayload.from(job: hugeLabelJob)
        require(hugeLabelPayload.label.count == WebhookConfig.maxLabelLength, "Label was not truncated to maxLabelLength")
    }

    // MARK: - 4. Verdict Display Line Mappings

    static func testVerdictDisplayLineMappings() throws {
        // Safe to wipe
        let j1 = Job(label: "J1", sourcePath: "/s", destinations: ["/d"])
        j1.phase = .done
        j1.fullyVerified = true
        j1.safeToWipe = true
        let p1 = WebhookPayload.from(job: j1)
        require(p1.verdict == Job.Verdict.safeToWipe.displayLine, "Safe to wipe verdict mismatch")
        require(p1.verdict == "SAFE TO WIPE", "Exact string mismatch")

        // Verified keep card
        let j2 = Job(label: "J2", sourcePath: "/s", destinations: ["/d"])
        j2.phase = .done
        j2.fullyVerified = true
        j2.safeToWipe = false
        let p2 = WebhookPayload.from(job: j2)
        require(p2.verdict == Job.Verdict.verifiedKeepCard.displayLine, "Verified keep card verdict mismatch")
        require(p2.verdict == "VERIFIED · KEEP CARD", "Exact string mismatch")

        // Unverified
        let j3 = Job(label: "J3", sourcePath: "/s", destinations: ["/d"])
        j3.phase = .done
        j3.fullyVerified = false
        let p3 = WebhookPayload.from(job: j3)
        require(p3.verdict == Job.Verdict.unverified.displayLine, "Unverified verdict mismatch")
        require(p3.verdict == "UNVERIFIED — KEEP CARD", "Exact string mismatch")

        // Failed
        let j4 = Job(label: "J4", sourcePath: "/s", destinations: ["/d"])
        j4.phase = .failed
        let p4 = WebhookPayload.from(job: j4)
        require(p4.verdict == Job.Verdict.failed.displayLine, "Failed verdict mismatch")
        require(p4.verdict == "FAILED — DO NOT WIPE", "Exact string mismatch")

        // Refused
        let j5 = Job(label: "J5", sourcePath: "/s", destinations: ["/d"])
        j5.phase = .refused
        let p5 = WebhookPayload.from(job: j5)
        require(p5.verdict == Job.Verdict.failed.displayLine, "Refused verdict mismatch")
        require(p5.verdict == "FAILED — DO NOT WIPE", "Exact string mismatch")
    }

    // MARK: - 5. Request Builder Tests

    static func testRequestBuilder() throws {
        let url = URL(string: "https://example.com/webhook")!
        let payloadData = Data("{\"test\":true}".utf8)

        // With secret
        let reqWithAuth = WebhookRequestBuilder.buildRequest(
            url: url,
            payloadData: payloadData,
            bearerSecret: "my-secret-key"
        )
        require(reqWithAuth.httpMethod == "POST", "Method must be POST")
        require(reqWithAuth.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8", "Content-Type header wrong")
        require(reqWithAuth.value(forHTTPHeaderField: "User-Agent") == "Dumptruck-Offloader", "User-Agent header wrong")
        require(reqWithAuth.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret-key", "Authorization header wrong")
        require(reqWithAuth.httpBody == payloadData, "Body mismatch")
        require(reqWithAuth.timeoutInterval == WebhookConfig.requestTimeout, "Timeout mismatch")

        // Without secret (nil)
        let reqNoAuth = WebhookRequestBuilder.buildRequest(
            url: url,
            payloadData: payloadData,
            bearerSecret: nil
        )
        require(reqNoAuth.value(forHTTPHeaderField: "Authorization") == nil, "Auth header should be absent when secret is nil")

        // With empty secret
        let reqEmptyAuth = WebhookRequestBuilder.buildRequest(
            url: url,
            payloadData: payloadData,
            bearerSecret: "   \t  "
        )
        require(reqEmptyAuth.value(forHTTPHeaderField: "Authorization") == nil, "Auth header should be absent when secret is empty")

        // The builder also fails closed when called directly with malformed
        // input; the service validates and reports these values before send.
        let reqControlAuth = WebhookRequestBuilder.buildRequest(
            url: url,
            payloadData: payloadData,
            bearerSecret: "token\nforbidden"
        )
        require(reqControlAuth.value(forHTTPHeaderField: "Authorization") == nil, "Control-character auth must be absent")
        let reqOversizedAuth = WebhookRequestBuilder.buildRequest(
            url: url,
            payloadData: payloadData,
            bearerSecret: String(repeating: "s", count: WebhookConfig.maxSecretLength + 1)
        )
        require(reqOversizedAuth.value(forHTTPHeaderField: "Authorization") == nil, "Oversized auth must be absent")

        let sensitiveError = WebhookDeliveryError.httpError(
            statusCode: 500,
            bodySnippet: "server echoed top-secret-token"
        )
        require(!sensitiveError.description.contains("top-secret-token"), "Error description leaked response secret")
        require(!WebhookDeliveryError.transportError("contains top-secret-token").description.contains("top-secret-token"),
                "Transport error description leaked request secret")
    }

    // MARK: - 6. Redirect Security Delegate Tests

    static func testRedirectSecurityDelegate() throws {
        let delegate = WebhookURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalRequest = URLRequest(url: URL(string: "https://example.com/api1")!)
        let response = HTTPURLResponse(url: originalRequest.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        let dummyTask = session.dataTask(with: originalRequest)

        // Case A: Redirect to valid HTTPS URL -> REJECTED. The bearer token
        // must never be replayed to a URL the operator did not configure.
        let validHttpsRedirect = URLRequest(url: URL(string: "https://example.com/api2")!)
        var rejectedHttpsRequest: URLRequest? = originalRequest
        let exp1 = DispatchSemaphore(value: 0)
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: response, newRequest: validHttpsRedirect) { req in
            rejectedHttpsRequest = req
            exp1.signal()
        }
        exp1.wait()
        require(rejectedHttpsRequest == nil, "All HTTPS redirects must be rejected")

        // Case B: Redirect to HTTP (non-HTTPS) -> REJECTED (completionHandler(nil))
        let httpRedirect = URLRequest(url: URL(string: "http://example.com/api2")!)
        var rejectedRequest: URLRequest? = originalRequest
        let exp2 = DispatchSemaphore(value: 0)
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: response, newRequest: httpRedirect) { req in
            rejectedRequest = req
            exp2.signal()
        }
        exp2.wait()
        require(rejectedRequest == nil, "HTTP redirect must be rejected")

        // Case C: Redirect to HTTPS with credentials -> REJECTED
        let credRedirect = URLRequest(url: URL(string: "https://user:pass@example.com/api2")!)
        var rejectedCredRequest: URLRequest? = originalRequest
        let exp3 = DispatchSemaphore(value: 0)
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: response, newRequest: credRedirect) { req in
            rejectedCredRequest = req
            exp3.signal()
        }
        exp3.wait()
        require(rejectedCredRequest == nil, "Credential redirect must be rejected")

        // Case D: Redirect with fragment -> REJECTED
        let fragRedirect = URLRequest(url: URL(string: "https://example.com/api2#section")!)
        var rejectedFragRequest: URLRequest? = originalRequest
        let exp4 = DispatchSemaphore(value: 0)
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: response, newRequest: fragRedirect) { req in
            rejectedFragRequest = req
            exp4.signal()
        }
        exp4.wait()
        require(rejectedFragRequest == nil, "Fragment redirect must be rejected")
    }

    // MARK: - 7. Injectable Delivery Tests: Success

    static func testInjectableDeliverySuccess() async throws {
        let job = Job(label: "TEST_JOB", sourcePath: "/Volumes/A", destinations: ["/Volumes/B"])
        job.phase = .done
        job.fullyVerified = true
        job.safeToWipe = true
        let payload = WebhookPayload.from(job: job)

        let mockTransport = MockTransport { request in
            require(request.url?.absoluteString == "https://webhook.site/test-123", "Request URL mismatch")
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-xyz", "Auth header missing")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data("{\"ok\":true}".utf8), response)
        }

        let service = WebhookNotificationService(transport: mockTransport)
        let result = await service.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: "secret-xyz"
        )
        require(result == .delivered(statusCode: 200), "Delivery should succeed with 200")
        require(mockTransport.recordedRequests().count == 1, "Expected 1 request sent")

        // HTTP 204 No Content
        let mock204 = MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }
        let service204 = WebhookNotificationService(transport: mock204)
        let result204 = await service204.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: nil
        )
        require(result204 == .delivered(statusCode: 204), "Delivery should succeed with 204")
    }

    // MARK: - 8. Injectable Delivery Tests: HTTP Errors

    static func testInjectableDeliveryHttpErrors() async throws {
        let job = Job(label: "TEST_JOB", sourcePath: "/Volumes/A", destinations: ["/Volumes/B"])
        job.phase = .done
        let payload = WebhookPayload.from(job: job)

        // 500 Server Error with response body snippet
        let mock500 = MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (Data("Internal database connection failed\nDetails...".utf8), response)
        }
        let service500 = WebhookNotificationService(transport: mock500)
        let result500 = await service500.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: nil
        )
        switch result500 {
        case .failed(let warning):
            require(warning.contains("500"), "Warning should contain 500 status code: \(warning)")
            require(warning.contains("Internal database connection failed"), "Warning should contain response snippet")
        default:
            fatalError("500 should return .failed")
        }

        // 401 Unauthorized
        let mock401 = MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }
        let service401 = WebhookNotificationService(transport: mock401)
        let result401 = await service401.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: nil
        )
        switch result401 {
        case .failed(let warning):
            require(warning.contains("401"), "Warning should contain 401 status code: \(warning)")
        default:
            fatalError("401 should return .failed")
        }
    }

    // MARK: - 9. Secret Redaction & Bounded Diagnostics

    static func testSecretRedactionAndBounds() async throws {
        let job = Job(label: "TEST_JOB", sourcePath: "/Volumes/A", destinations: ["/Volumes/B"])
        let payload = WebhookPayload.from(job: job)
        let bearerSecret = "top-secret-token"
        let hugeBody = String(repeating: "x", count: WebhookConfig.maxResponseBodyBytes * 8)
            + bearerSecret
            + String(repeating: "y", count: 500)
        let mock = MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(hugeBody.utf8), response)
        }
        let service = WebhookNotificationService(transport: mock)
        let result = await service.deliver(
            payload: payload,
            endpointURLString: "https://example.com/hook",
            bearerSecret: bearerSecret
        )
        guard case .failed(let warning) = result else {
            fatalError("Expected bounded HTTP failure warning")
        }
        require(!warning.contains(bearerSecret), "Bearer secret leaked into webhook warning")
        require(warning.count <= WebhookConfig.maxWarningLength, "Webhook warning exceeded bound")
        require(warning.contains("500"), "Bounded warning lost HTTP status")

        let oversizedSecret = String(repeating: "s", count: WebhookConfig.maxSecretLength + 1)
        let oversizedResult = await service.deliver(
            payload: payload,
            endpointURLString: "https://example.com/hook",
            bearerSecret: oversizedSecret
        )
        guard case .failed(let oversizedWarning) = oversizedResult else {
            fatalError("Oversized bearer secret must fail closed")
        }
        require(!oversizedWarning.contains(oversizedSecret), "Oversized secret leaked into warning")
        require(mock.recordedRequests().count == 1, "Invalid secret must not send a request")

        let controlResult = await service.deliver(
            payload: payload,
            endpointURLString: "https://example.com/hook",
            bearerSecret: "token\nforbidden"
        )
        guard case .failed = controlResult else {
            fatalError("Control-character bearer secret must fail closed")
        }
        require(mock.recordedRequests().count == 1, "Control-character secret must not send a request")
    }

    // MARK: - 10. Injectable Delivery Tests: Network Failures

    static func testInjectableDeliveryNetworkFailure() async throws {
        let job = Job(label: "TEST_JOB", sourcePath: "/Volumes/A", destinations: ["/Volumes/B"])
        let payload = WebhookPayload.from(job: job)

        let mockTimeout = MockTransport { _ in
            throw URLError(.timedOut)
        }
        let service = WebhookNotificationService(transport: mockTimeout)
        let result = await service.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: nil
        )
        switch result {
        case .failed(let warning):
            require(!warning.isEmpty, "Warning message must not be empty")
            require(warning.contains("Remote webhook delivery failed:"), "Warning format mismatch: \(warning)")
        default:
            fatalError("Timeout should return .failed")
        }
    }

    // MARK: - 11. Injectable Delivery Tests: Cancellation

    static func testInjectableDeliveryCancellation() async throws {
        let job = Job(label: "TEST_JOB", sourcePath: "/Volumes/A", destinations: ["/Volumes/B"])
        let payload = WebhookPayload.from(job: job)

        let mockCancelled = MockTransport { _ in
            throw CancellationError()
        }
        let service = WebhookNotificationService(transport: mockCancelled)
        let result = await service.deliver(
            payload: payload,
            endpointURLString: "https://webhook.site/test-123",
            bearerSecret: nil
        )
        switch result {
        case .failed(let warning):
            require(warning == "Remote webhook delivery cancelled", "Cancellation warning mismatch: \(warning)")
        default:
            fatalError("Cancellation should return .failed with cancelled message")
        }
    }

    // MARK: - 12. Safety & Non-Mutation Invariants

    @MainActor
    static func testJobNonMutationInvariants() async throws {
        // Create job in terminal safeToWipe state
        let job = Job(
            label: "CARD_SAFETY_TEST",
            sourcePath: "/Volumes/CARD",
            destinations: ["/Volumes/BACKUP_1", "/Volumes/BACKUP_2"]
        )
        job.phase = .done
        job.fullyVerified = true
        job.safeToWipe = true
        job.reportPath = "/Volumes/BACKUP_1/report.pdf"
        job.reportFailed = false
        job.filesFailed = 0

        require(job.verdict == .safeToWipe, "Precondition: initial verdict must be .safeToWipe")
        require(job.safeToWipe == true, "Precondition: initial safeToWipe must be true")
        require(job.fullyVerified == true, "Precondition: initial fullyVerified must be true")
        require(job.phase == .done, "Precondition: initial phase must be .done")
        require(job.messages.isEmpty, "Precondition: no initial messages")

        // Simulate delivery failure and appending warning
        let warningText = "Remote webhook delivery failed: Server returned HTTP 500: Database unavailable"
        job.warn(warningText)

        // VERIFY INVARIANTS:
        // Delivery failure is visible as a warning ONLY, and can NEVER mutate Job.verdict,
        // fullyVerified, safeToWipe, phase, or report outcome!
        require(job.messages.count == 1, "Warning was not added to job messages")
        require(job.messages[0].severity == .warning, "Message severity must be .warning")
        require(job.messages[0].text == warningText, "Message text mismatch")
        require(job.errorCount == 0, "errorCount must remain 0")
        require(job.warningCount == 1, "warningCount must be 1")

        // CRITICAL STATE MUST REMAIN EXACTLY UNCHANGED:
        require(job.verdict == .safeToWipe, "INVARIANT VIOLATION: Job.verdict was mutated! Expected .safeToWipe, got \(job.verdict)")
        require(job.safeToWipe == true, "INVARIANT VIOLATION: job.safeToWipe was mutated!")
        require(job.fullyVerified == true, "INVARIANT VIOLATION: job.fullyVerified was mutated!")
        require(job.phase == .done, "INVARIANT VIOLATION: job.phase was mutated!")
        require(job.filesFailed == 0, "INVARIANT VIOLATION: job.filesFailed was mutated!")
        require(job.reportFailed == false, "INVARIANT VIOLATION: job.reportFailed was mutated!")
        require(job.reportPath == "/Volumes/BACKUP_1/report.pdf", "INVARIANT VIOLATION: job.reportPath was mutated!")
        require(job.destinations.count == 2, "INVARIANT VIOLATION: job.destinations was mutated!")

        // Verify latestSourceRunsAllowEject remains true!
        require(Job.latestSourceRunsAllowEject([job]) == true, "INVARIANT VIOLATION: eject authority was compromised by webhook warning!")
    }
}
