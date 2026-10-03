import Foundation

public protocol GitHubClock: Sendable {
    func now() async -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemGitHubClock: GitHubClock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000))
    }
}

public struct GitHubHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
}

public protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse
}

/// Credentials must never follow a redirect to a different host or enter an HTTP cache.
private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class URLSessionGitHubTransport: GitHubTransport, @unchecked Sendable {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw GitHubAPIError.invalidResponse }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let key = entry.key as? String { result[key] = String(describing: entry.value) }
            }
            return GitHubHTTPResponse(data: data, status: response.statusCode, headers: headers)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? GitHubAPIError { throw error }
            // Do not surface URLSession diagnostics, which may contain request URLs or credentials.
            throw GitHubAPIError.network
        }
    }
}

public enum GitHubAPIError: Error, Equatable, LocalizedError {
    case invalidResponse, network, unauthorized, permissionDenied, forbiddenUnknown, notFoundOrInaccessible
    case rateLimited, queueFull, unsupportedURL, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid GitHub response."
        case .network: return "GitHub network request failed."
        case .unauthorized: return "GitHub authentication required."
        case .permissionDenied: return "GitHub App permissions are insufficient."
        case .forbiddenUnknown: return "GitHub denied access; the cause is unknown."
        case .notFoundOrInaccessible: return "GitHub resource does not exist or is inaccessible."
        case .rateLimited: return "GitHub rate limit reached."
        case .queueFull: return "GitHub request queue is full."
        case .unsupportedURL: return "Unsupported GitHub URL."
        case .http(let status): return "GitHub HTTP error \(status)."
        }
    }
}

/// One serial queue per GitHub host. Cancellation removes queued callers and cancels active I/O.
public actor GitHubHTTPClient {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private let transport: any GitHubTransport
    private let clock: any GitHubClock
    private var busy: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(transport: any GitHubTransport = URLSessionGitHubTransport(), clock: any GitHubClock = SystemGitHubClock()) {
        self.transport = transport
        self.clock = clock
    }

    public func send(_ request: URLRequest, retryRead: Bool = false, deadline: Date? = nil) async throws -> GitHubHTTPResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              ["github.com", "api.github.com"].contains(host), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw GitHubAPIError.unsupportedURL }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await acquire(host: host, id: id)
        } onCancel: {
            Task { await self.cancelWaiter(host: host, id: id) }
        }
        defer { release(host: host) }
        let retryable = retryRead && request.httpMethod == "GET" // POST retries must be explicitly safe elsewhere.
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let until = blockedUntil[host] {
                let target = deadline.map { min($0, until) } ?? until
                while target > (await clock.now()) {
                    try await clock.sleep(seconds: target.timeIntervalSince(await clock.now()))
                }
            }
            if let deadline, (await clock.now()) >= deadline { throw GitHubAuthError.expired }
            var outbound = request
            if let deadline {
                let remaining = deadline.timeIntervalSince(await clock.now())
                guard remaining > 0 else { throw GitHubAuthError.expired }
                outbound.timeoutInterval = min(request.timeoutInterval, remaining)
            }
            let response: GitHubHTTPResponse
            do { response = try await transport.send(outbound) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if let apiError = error as? GitHubAPIError, apiError != .network { throw apiError }
                if retryable && attempt < 2 {
                    try await clock.sleep(seconds: pow(2, Double(attempt)))
                    continue
                }
                throw GitHubAPIError.network
            }
            try Task.checkCancellation()
            let now = await clock.now()
            let delay = Self.rateLimitDelay(response, now: now, attempt: attempt)
            if let delay { blockedUntil[host] = now.addingTimeInterval(delay) }
            if delay != nil && [403, 429].contains(response.status) {
                if retryable && attempt < 2 { continue }
                throw GitHubAPIError.rateLimited
            }
            if retryable && (500...599).contains(response.status) && attempt < 2 {
                try await clock.sleep(seconds: pow(2, Double(attempt)))
                continue
            }
            return response
        }
        throw GitHubAPIError.rateLimited
    }

    private func acquire(host: String, id: UUID) async throws {
        try Task.checkCancellation()
        if !busy.contains(host) { busy.insert(host); return }
        guard (waiters[host]?.count ?? 0) < 64 else { throw GitHubAPIError.queueFull }
        try await withCheckedThrowingContinuation { continuation in
            waiters[host, default: []].append(Waiter(id: id, continuation: continuation))
        }
    }
    private func cancelWaiter(host: String, id: UUID) {
        guard let index = waiters[host]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[host]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release(host: String) {
        if let next = waiters[host]?.first {
            waiters[host]?.removeFirst()
            next.continuation.resume()
        } else { busy.remove(host) }
    }

    static func rateLimitDelay(_ response: GitHubHTTPResponse, now: Date, attempt: Int) -> TimeInterval? {
        let headers = response.headers
        var delay: TimeInterval?
        if let value = headers["retry-after"] {
            if let seconds = Double(value), seconds.isFinite { delay = max(0, seconds) }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: value) { delay = max(0, date.timeIntervalSince(now)) }
            }
        }
        if headers["x-ratelimit-remaining"] == "0", let reset = headers["x-ratelimit-reset"].flatMap(Double.init), reset.isFinite {
            delay = max(delay ?? 0, max(0, reset - now.timeIntervalSince1970))
        }
        if response.status == 429 { delay = delay ?? 60 * pow(2, Double(attempt)) }
        if response.status == 403, let message = try? JSONDecoder().decode(Message.self, from: response.data),
           message.message.lowercased().contains("rate limit") {
            delay = delay ?? 60 * pow(2, Double(attempt))
        }
        return delay
    }
    private struct Message: Decodable { let message: String }

    public static func validate(_ response: GitHubHTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 401: throw GitHubAPIError.unauthorized
        case 403:
            let message = (try? JSONDecoder().decode(Message.self, from: response.data).message.lowercased()) ?? ""
            if message.contains("resource not accessible by") || message.contains("insufficient permission") {
                throw GitHubAPIError.permissionDenied
            }
            throw GitHubAPIError.forbiddenUnknown
        case 404: throw GitHubAPIError.notFoundOrInaccessible
        case 429: throw GitHubAPIError.rateLimited
        default: throw GitHubAPIError.http(response.status)
        }
    }
}
