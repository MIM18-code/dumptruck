import Foundation
import Security

// MARK: - Configuration & Constants

enum WebhookConfig {
    static let maxURLLength = 2048
    static let maxLabelLength = 128
    static let maxSecretLength = 1024
    static let maxPayloadBytes = 65536
    static let maxResponseBodyBytes = 1024
    static let maxErrorMessageLength = 200
    static let maxWarningLength = 512
    static let requestTimeout: TimeInterval = 10
    static let resourceTimeout: TimeInterval = 15
    static let keychainService = "tv.mindinmotion.dumptruck.webhook"
    static let keychainAccount = "bearerSecret"
}

// MARK: - Validation Errors

enum WebhookValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyURL
    case oversizedURL(Int)
    case invalidURL
    case schemeNotHTTPS
    case containsCredentials
    case containsFragment
    case missingHost

    var description: String {
        switch self {
        case .emptyURL:
            return "Webhook URL is empty"
        case .oversizedURL(let count):
            return "Webhook URL length (\(count)) exceeds maximum allowed (\(WebhookConfig.maxURLLength))"
        case .invalidURL:
            return "Webhook URL is not a valid URL"
        case .schemeNotHTTPS:
            return "Webhook URL must use the HTTPS scheme"
        case .containsCredentials:
            return "Webhook URL must not contain embedded username or password credentials"
        case .containsFragment:
            return "Webhook URL must not contain a URL fragment (#)"
        case .missingHost:
            return "Webhook URL must include a valid host"
        }
    }
}

// MARK: - Endpoint Validator

enum WebhookEndpointValidator {
    static func validate(urlString: String) -> Result<URL, WebhookValidationError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyURL)
        }
        guard trimmed.count <= WebhookConfig.maxURLLength else {
            return .failure(.oversizedURL(trimmed.count))
        }
        guard let components = URLComponents(string: trimmed),
              let url = components.url else {
            return .failure(.invalidURL)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else {
            return .failure(.schemeNotHTTPS)
        }
        guard components.user == nil,
              components.password == nil,
              url.user == nil,
              url.password == nil else {
            return .failure(.containsCredentials)
        }
        guard components.fragment == nil else {
            return .failure(.containsFragment)
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }
        return .success(url)
    }
}

// MARK: - Secret Store (Keychain & In-Memory)

protocol WebhookSecretStore: Sendable {
    func loadSecret() -> String?
    func saveSecret(_ secret: String?) throws
    func deleteSecret() throws
}

enum WebhookKeychainError: Error, Equatable, CustomStringConvertible, Sendable {
    case keychainStatus(OSStatus)
    case secretOversized
    case secretContainsControlCharacters

    var description: String {
        switch self {
        case .keychainStatus(let status):
            return "Keychain error (status \(status))"
        case .secretOversized:
            return "Bearer secret exceeds maximum length of \(WebhookConfig.maxSecretLength) characters"
        case .secretContainsControlCharacters:
            return "Bearer secret contains unsupported control characters"
        }
    }
}

private enum WebhookSecretValidation {
    static func normalized(_ secret: String?) -> Result<String?, WebhookKeychainError> {
        guard let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .success(nil)
        }
        guard trimmed.count <= WebhookConfig.maxSecretLength else {
            return .failure(.secretOversized)
        }
        guard !trimmed.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }) else {
            return .failure(.secretContainsControlCharacters)
        }
        return .success(trimmed)
    }
}

final class KeychainWebhookSecretStore: WebhookSecretStore, @unchecked Sendable {
    static let shared = KeychainWebhookSecretStore()

    let service: String
    let account: String

    init(
        service: String = WebhookConfig.keychainService,
        account: String = WebhookConfig.keychainAccount
    ) {
        self.service = service
        self.account = account
    }

    func loadSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveSecret(_ secret: String?) throws {
        let normalized: String?
        switch WebhookSecretValidation.normalized(secret) {
        case .success(let value):
            normalized = value
        case .failure(let error):
            throw error
        }
        guard let secret = normalized else {
            try deleteSecret()
            return
        }
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update in place first. Deleting the old token before an add can
        // leave the user with no usable token when Keychain rejects the new
        // item; preserving the previous value is the fail-closed behavior.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw WebhookKeychainError.keychainStatus(updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WebhookKeychainError.keychainStatus(status)
        }
    }

    func deleteSecret() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebhookKeychainError.keychainStatus(status)
        }
    }
}

final class InMemoryWebhookSecretStore: WebhookSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?

    init(initialSecret: String? = nil) {
        self.secret = initialSecret
    }

    func loadSecret() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secret
    }

    func saveSecret(_ newSecret: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        switch WebhookSecretValidation.normalized(newSecret) {
        case .success(let normalized):
            secret = normalized
        case .failure(let error):
            throw error
        }
    }

    func deleteSecret() throws {
        lock.lock()
        defer { lock.unlock() }
        secret = nil
    }
}

// MARK: - Webhook Payload

struct WebhookPayloadCounts: Codable, Equatable, Sendable {
    let filesTotal: Int
    let filesCopied: Int
    let filesSkipped: Int
    let filesFailed: Int
    let bytesTotal: Int64
    let bytesFinished: Int64
    let bytesReread: Int64
    let errorCount: Int
    let warningCount: Int
    let destinationsCount: Int

    init(
        filesTotal: Int,
        filesCopied: Int,
        filesSkipped: Int,
        filesFailed: Int,
        bytesTotal: Int64,
        bytesFinished: Int64,
        bytesReread: Int64,
        errorCount: Int,
        warningCount: Int,
        destinationsCount: Int
    ) {
        self.filesTotal = filesTotal
        self.filesCopied = filesCopied
        self.filesSkipped = filesSkipped
        self.filesFailed = filesFailed
        self.bytesTotal = bytesTotal
        self.bytesFinished = bytesFinished
        self.bytesReread = bytesReread
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.destinationsCount = destinationsCount
    }

    enum CodingKeys: String, CodingKey {
        case filesTotal = "files_total"
        case filesCopied = "files_copied"
        case filesSkipped = "files_skipped"
        case filesFailed = "files_failed"
        case bytesTotal = "bytes_total"
        case bytesFinished = "bytes_finished"
        case bytesReread = "bytes_reread"
        case errorCount = "error_count"
        case warningCount = "warning_count"
        case destinationsCount = "destinations_count"
    }
}

struct WebhookPayload: Codable, Equatable, Sendable {
    let jobID: String
    let label: String
    let verdict: String
    let phase: String
    let fullyVerified: Bool
    let safeToWipe: Bool
    let startedAt: String?
    let finishedAt: String?
    let counts: WebhookPayloadCounts

    init(
        jobID: String,
        label: String,
        verdict: String,
        phase: String,
        fullyVerified: Bool,
        safeToWipe: Bool,
        startedAt: String?,
        finishedAt: String?,
        counts: WebhookPayloadCounts
    ) {
        self.jobID = jobID
        self.label = label
        self.verdict = verdict
        self.phase = phase
        self.fullyVerified = fullyVerified
        self.safeToWipe = safeToWipe
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case label
        case verdict
        case phase
        case fullyVerified = "fully_verified"
        case safeToWipe = "safe_to_wipe"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case counts
    }

    static func from(
        job: Job,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> WebhookPayload {
        let label = String(job.label.prefix(WebhookConfig.maxLabelLength))
        let started = job.startedDate.map { formatter.string(from: $0) }
        let finished = job.finishedDate.map { formatter.string(from: $0) }
        let counts = WebhookPayloadCounts(
            filesTotal: job.filesTotal,
            filesCopied: job.filesCopied,
            filesSkipped: job.filesSkipped,
            filesFailed: job.filesFailed,
            bytesTotal: job.bytesTotal,
            bytesFinished: job.bytesFinished,
            bytesReread: job.rereadDone,
            errorCount: job.errorCount,
            warningCount: job.warningCount,
            destinationsCount: job.destinations.count
        )
        return WebhookPayload(
            jobID: job.id.uuidString,
            label: label,
            verdict: job.verdict.displayLine,
            phase: job.phase.rawValue,
            fullyVerified: job.fullyVerified,
            safeToWipe: job.safeToWipe,
            startedAt: started,
            finishedAt: finished,
            counts: counts
        )
    }

    func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= WebhookConfig.maxPayloadBytes else {
            throw WebhookPayloadError.payloadOversized(data.count)
        }
        return data
    }
}

enum WebhookPayloadError: Error, Equatable, CustomStringConvertible, Sendable {
    case payloadOversized(Int)

    var description: String {
        switch self {
        case .payloadOversized(let count):
            return "Webhook payload size (\(count) bytes) exceeds limit (\(WebhookConfig.maxPayloadBytes) bytes)"
        }
    }
}

// MARK: - HTTP Request Builder

enum WebhookRequestBuilder {
    static func buildRequest(
        url: URL,
        payloadData: Data,
        bearerSecret: String?
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: WebhookConfig.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Dumptruck-Offloader", forHTTPHeaderField: "User-Agent")
        if case .success(let normalized) = WebhookSecretValidation.normalized(bearerSecret),
           let secret = normalized {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payloadData
        return request
    }
}

// MARK: - URLSession Delegate (Redirect Security)

final class WebhookURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow a redirect. Even an HTTPS redirect can cross hosts and
        // cause URLSession to replay the bearer Authorization header. The
        // endpoint is operator-configured, so refusing redirects is the only
        // simple invariant that keeps the secret bound to the exact URL the
        // operator reviewed.
        completionHandler(nil)
    }
}

// MARK: - HTTP Transport Protocol & Implementations

protocol WebhookHTTPTransport: Sendable {
    func send(request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

final class URLSessionWebhookTransport: WebhookHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: WebhookURLSessionDelegate

    init() {
        let delegate = WebhookURLSessionDelegate()
        self.delegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = WebhookConfig.requestTimeout
        config.timeoutIntervalForResource = WebhookConfig.resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        // URLSession.data(for:) buffers an arbitrary response body. Read only
        // the bounded prefix needed for diagnostics, and cancel the data task
        // as soon as that prefix is complete.
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(WebhookConfig.maxResponseBodyBytes)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= WebhookConfig.maxResponseBodyBytes {
                bytes.task.cancel()
                break
            }
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebhookDeliveryError.invalidResponse
        }
        return (data, httpResponse)
    }
}

// MARK: - Delivery Errors, Result, & Service

enum WebhookDeliveryError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidResponse
    case httpError(statusCode: Int, bodySnippet: String?)
    case transportError(String)
    case cancelled

    var description: String {
        switch self {
        case .invalidResponse:
            return "Server did not return a valid HTTP response"
        case .httpError(let status, _):
            // Response snippets are handled by WebhookWarning, where the
            // configured bearer token is redacted before becoming UI/journal
            // text. Never expose the raw body through an Error description.
            return "Server returned HTTP \(status)"
        case .transportError:
            // Keep arbitrary transport descriptions out of Error strings;
            // URLSession implementations may include request details.
            return "Webhook transport error"
        case .cancelled:
            return "Webhook delivery was cancelled"
        }
    }
}

enum WebhookDeliveryResult: Equatable, Sendable {
    case delivered(statusCode: Int)
    case failed(warning: String)
}

final class WebhookNotificationService: Sendable {
    static let shared = WebhookNotificationService()

    private let transport: WebhookHTTPTransport

    init(transport: WebhookHTTPTransport = URLSessionWebhookTransport()) {
        self.transport = transport
    }

    func deliver(
        payload: WebhookPayload,
        endpointURLString: String,
        bearerSecret: String?
    ) async -> WebhookDeliveryResult {
        let normalizedSecret: String?
        switch WebhookSecretValidation.normalized(bearerSecret) {
        case .success(let normalized):
            normalizedSecret = normalized
        case .failure(let error):
            return .failed(warning: "Remote webhook bearer secret invalid: \(error.description)")
        }

        // 1. Validate endpoint
        let targetURL: URL
        switch WebhookEndpointValidator.validate(urlString: endpointURLString) {
        case .success(let url):
            targetURL = url
        case .failure(let error):
            return .failed(warning: "Remote webhook endpoint invalid: \(error)")
        }

        // 2. Encode payload
        let payloadData: Data
        do {
            payloadData = try payload.encodeJSON()
        } catch {
            return .failed(warning: WebhookWarning.make(
                prefix: "Remote webhook payload encoding failed",
                detail: error.localizedDescription,
                secret: normalizedSecret))
        }

        // 3. Build request
        let request = WebhookRequestBuilder.buildRequest(
            url: targetURL,
            payloadData: payloadData,
            bearerSecret: normalizedSecret
        )

        // 4. Send request with cancellation check
        if Task.isCancelled {
            return .failed(warning: "Remote webhook delivery cancelled")
        }

        do {
            let (data, response) = try await transport.send(request: request)
            try Task.checkCancellation()
            let statusCode = response.statusCode
            guard (200...299).contains(statusCode) else {
                let snippet = WebhookWarning.responseSnippet(data, secret: normalizedSecret)
                var detail = "Server returned HTTP \(statusCode)"
                if let snippet, !snippet.isEmpty {
                    detail += ": \(snippet)"
                }
                return .failed(warning: WebhookWarning.make(
                    prefix: "Remote webhook delivery failed",
                    detail: detail,
                    secret: normalizedSecret))
            }
            return .delivered(statusCode: statusCode)
        } catch is CancellationError {
            return .failed(warning: "Remote webhook delivery cancelled")
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failed(warning: "Remote webhook delivery cancelled")
        } catch {
            return .failed(warning: WebhookWarning.make(
                prefix: "Remote webhook delivery failed",
                detail: error.localizedDescription,
                secret: normalizedSecret))
        }
    }
}

private enum WebhookWarning {
    static func responseSnippet(_ data: Data, secret: String?) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data.prefix(WebhookConfig.maxResponseBodyBytes), as: UTF8.self)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(sanitize(text, secret: secret).prefix(WebhookConfig.maxErrorMessageLength))
    }

    static func make(prefix: String, detail: String?, secret: String?) -> String {
        var message = prefix
        if let detail, !detail.isEmpty {
            message += ": \(detail)"
        }
        return String(sanitize(message, secret: secret).prefix(WebhookConfig.maxWarningLength))
    }

    private static func sanitize(_ text: String, secret: String?) -> String {
        var sanitized = text
        if let secret, !secret.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // Keep warning text single-line and free of unprintable control bytes;
        // this prevents a server response from impersonating UI text.
        sanitized = sanitized
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .filter { character in
                character == "\t" || character.unicodeScalars.allSatisfy { $0.value >= 0x20 }
            }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
