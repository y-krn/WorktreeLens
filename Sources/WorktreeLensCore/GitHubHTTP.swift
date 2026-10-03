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
    public let wasNotModified: Bool
    public let validatedAt: Date?
    public init(data: Data, status: Int, headers: [String: String] = [:], wasNotModified: Bool = false, validatedAt: Date? = nil) {
        self.data = data
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.wasNotModified = wasNotModified; self.validatedAt = validatedAt
    }
}

/// Shared in-memory GitHub response and display state. Local repository view snapshots stay path-scoped elsewhere.
public actor GitHubStateStore {
    public static let shared = GitHubStateStore()

    private struct RequestKey: Hashable {
        let accountIdentifier: String
        let method: String
        let url: String
        let body: Data?
        let accept: String?
        let apiVersion: String?
    }
    private struct Representation {
        let data: Data
        var headers: [String: String]
        let etag: String?
        var validatedAt: Date
    }
    private struct Flight {
        let id: UUID
        let task: Task<GitHubHTTPResponse, Error>
        let accountGeneration: UUID
        let sessionRevision: UUID?
        var waiters: [UUID: CheckedContinuation<GitHubHTTPResponse, Error>]
    }
    private struct RepositoryAlias: Hashable {
        let host: String
        let accountIdentifier: String
        let name: String
    }
    private struct RepositoryScope: Hashable {
        let host: String
        let accountIdentifier: String
        let repositoryID: String
    }
    private struct BranchKey: Hashable {
        let repository: RepositoryScope
        let headRepository: String
        let branch: String
        let sha: String
    }
    private struct PullRequestKey: Hashable {
        let repository: RepositoryScope
        let number: Int
        let nodeID: String
    }
    private struct IssueKey: Hashable {
        let repository: RepositoryScope
        let nodeID: String
    }
    private struct CheckKey: Hashable {
        let repository: RepositoryScope
        let sha: String
        let nodeID: String
    }
    private struct ActionKey: Hashable {
        let repository: RepositoryScope
        let sha: String
        let runID: Int
        let attempt: Int
        let fallbackID: String
    }
    private struct BranchRecord {
        let metadata: GitHubStatus
        let pullRequests: [PullRequestKey]
        let issues: [IssueKey]
        let checks: [CheckKey]
        let actions: [ActionKey]
        let currentActions: Set<ActionKey>
    }

    private let clock: any GitHubClock
    private var representations: [RequestKey: Representation] = [:]
    private var flights: [RequestKey: Flight] = [:]
    private var repositoryIDs: [RepositoryAlias: String] = [:]
    private var branches: [BranchKey: BranchRecord] = [:]
    private var pullRequests: [PullRequestKey: GitHubPullRequest] = [:]
    private var issues: [IssueKey: GitHubIssue] = [:]
    private var checks: [CheckKey: GitHubCheck] = [:]
    private var actions: [ActionKey: GitHubActionRun] = [:]
    private var activeRevisions: [String: UUID] = [:]
    private var accountGenerations: [String: UUID] = [:]

    public init(clock: any GitHubClock = SystemGitHubClock()) { self.clock = clock }

    /// Shares concurrent equivalent requests. REST GET responses use account-scoped ETags;
    /// GraphQL POSTs are only coalesced while in flight and always execute on a later refresh.
    public func send(_ request: URLRequest, accountIdentifier: String,
                     sessionRevision: UUID? = nil,
                     operation: @escaping @Sendable (URLRequest) async throws -> GitHubHTTPResponse) async throws -> GitHubHTTPResponse {
        guard let key = requestKey(request, accountIdentifier: accountIdentifier) else { throw GitHubAPIError.unsupportedURL }
        let accountGeneration = generation(for: accountIdentifier)
        if let sessionRevision {
            if activeRevisions[accountIdentifier] != nil, activeRevisions[accountIdentifier] != sessionRevision {
                cancelFlights(accountIdentifier: accountIdentifier)
            }
            activeRevisions[accountIdentifier] = sessionRevision
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var flight = flights[key] {
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    return
                }
                var outbound = request
                if key.method == "GET", let etag = representations[key]?.etag {
                    outbound.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                let task = Task.detached { try await operation(outbound) }
                let flightID = UUID()
                flights[key] = Flight(id: flightID, task: task, accountGeneration: accountGeneration,
                                      sessionRevision: sessionRevision, waiters: [waiterID: continuation])
                Task.detached { [weak self] in
                    let result = await task.result
                    await self?.finish(key, flightID: flightID, result: result)
                }
            }
        } onCancel: {
            Task { await self.cancel(key, waiterID: waiterID) }
        }
    }

    func activeRequestWaiterCount(_ request: URLRequest, accountIdentifier: String) -> Int {
        guard let key = requestKey(request, accountIdentifier: accountIdentifier) else { return 0 }
        return flights[key]?.waiters.count ?? 0
    }

    private func finish(_ key: RequestKey, flightID: UUID, result: Result<GitHubHTTPResponse, Error>) async {
        guard let initialFlight = flights[key], initialFlight.id == flightID else { return }
        var delivered = result
        if case .success(let response) = result, key.method == "GET" {
            let now = await clock.now()
            guard let currentFlight = flights[key], currentFlight.id == flightID,
                  currentFlight.accountGeneration == accountGenerations[key.accountIdentifier],
                  currentFlight.sessionRevision == nil || activeRevisions[key.accountIdentifier] == currentFlight.sessionRevision else {
                if let staleFlight = flights[key], staleFlight.id == flightID {
                    flights.removeValue(forKey: key)
                    staleFlight.task.cancel()
                    for continuation in staleFlight.waiters.values { continuation.resume(throwing: CancellationError()) }
                }
                return
            }
            if response.status == 304 {
                if var prior = representations[key] {
                    prior.validatedAt = now
                    prior.headers.merge(response.headers, uniquingKeysWith: { _, latest in latest })
                    if let etag = response.headers["etag"] { prior = Representation(data: prior.data, headers: prior.headers, etag: etag, validatedAt: now) }
                    representations[key] = prior
                    delivered = .success(GitHubHTTPResponse(data: prior.data, status: 200, headers: prior.headers,
                                                             wasNotModified: true, validatedAt: now))
                } else {
                    delivered = .failure(GitHubAPIError.invalidResponse)
                }
            } else if (200..<300).contains(response.status) {
                representations[key] = Representation(data: response.data, headers: response.headers,
                                                       etag: response.headers["etag"], validatedAt: now)
                delivered = .success(GitHubHTTPResponse(data: response.data, status: response.status, headers: response.headers,
                                                         wasNotModified: false, validatedAt: now))
            }
        }
        guard let flight = flights.removeValue(forKey: key), flight.id == flightID else { return }
        for continuation in flight.waiters.values { continuation.resume(with: delivered) }
    }

    private func cancel(_ key: RequestKey, waiterID: UUID) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func requestKey(_ request: URLRequest, accountIdentifier: String) -> RequestKey? {
        guard let url = request.url else { return nil }
        return RequestKey(accountIdentifier: accountIdentifier, method: (request.httpMethod ?? "GET").uppercased(),
                          url: url.absoluteString, body: request.httpBody,
                          accept: request.value(forHTTPHeaderField: "Accept"),
                          apiVersion: request.value(forHTTPHeaderField: "X-GitHub-Api-Version"))
    }

    public func cachedStatus(accountIdentifier: String, target: GitHubBranchTarget) -> GitHubStatus? {
        guard let repositoryID = repositoryIDs[alias(accountIdentifier, target.base.fullName)] else { return nil }
        let key = branchKey(accountIdentifier, repositoryID, target)
        guard let record = branches[key] else { return nil }
        return materialize(record)
    }

    /// Saves entity data by GitHub IDs and returns last-known-good fields when this refresh is partial or fails.
    public func recordStatus(accountIdentifier: String, target: GitHubBranchTarget, repositoryID: String? = nil,
                             sessionRevision: UUID? = nil,
                             status incoming: GitHubStatus) -> GitHubStatus {
        if let sessionRevision, activeRevisions[accountIdentifier] != sessionRevision { return incoming }
        let alias = alias(accountIdentifier, target.base.fullName)
        if let repositoryID { repositoryIDs[alias] = repositoryID }
        guard let repositoryID = repositoryID ?? repositoryIDs[alias] else { return incoming }
        let key = branchKey(accountIdentifier, repositoryID, target)
        let previous = branches[key].map(materialize)
        let merged = Self.merge(previous: previous, incoming: incoming)
        let scope = RepositoryScope(host: "github.com", accountIdentifier: accountIdentifier, repositoryID: repositoryID)
        let prKeys = merged.pullRequests.map { PullRequestKey(repository: scope, number: $0.number, nodeID: $0.id) }
        let issueKeys = merged.issues.map { issue in
            let issueScope = RepositoryScope(host: "github.com", accountIdentifier: accountIdentifier,
                                             repositoryID: issue.repositoryID ?? repositoryID)
            return IssueKey(repository: issueScope, nodeID: issue.id)
        }
        let checkKeys = merged.checks.map { CheckKey(repository: scope, sha: $0.sha, nodeID: $0.id) }
        let actionKeys = merged.actions.map { ActionKey(repository: scope, sha: target.sha, runID: $0.runID ?? 0,
                                                        attempt: $0.attempt ?? 0, fallbackID: $0.id) }
        for (key, item) in zip(prKeys, merged.pullRequests) { pullRequests[key] = item }
        for (key, item) in zip(issueKeys, merged.issues) { issues[key] = item }
        for (key, item) in zip(checkKeys, merged.checks) { checks[key] = item }
        for (key, item) in zip(actionKeys, merged.actions) { actions[key] = item }
        let currentActionKeys = Set(zip(actionKeys, merged.actions).compactMap { key, item in item.isCurrent ? key : nil })
        let metadata = GitHubStatus(issues: [], pullRequests: [], actions: [], error: merged.error, isLoaded: merged.isLoaded,
                                    mergeEvidenceLoaded: merged.mergeEvidenceLoaded, checks: [],
                                    pullRequestFetch: merged.pullRequestFetch, issueFetch: merged.issueFetch,
                                    checkFetch: merged.checkFetch, actionFetch: merged.actionFetch, localSHA: merged.localSHA)
        branches[key] = BranchRecord(metadata: metadata, pullRequests: prKeys, issues: issueKeys, checks: checkKeys,
                                     actions: actionKeys, currentActions: currentActionKeys)
        return merged
    }

    public func invalidateRepository(accountIdentifier: String, fullName: String) {
        let alias = alias(accountIdentifier, fullName)
        guard let repositoryID = repositoryIDs.removeValue(forKey: alias) else { return }
        let scopes = Set(branches.keys.filter { $0.repository.accountIdentifier == accountIdentifier && $0.repository.repositoryID == repositoryID }.map(\.repository))
        branches = branches.filter { !scopes.contains($0.key.repository) }
        pullRequests = pullRequests.filter { !scopes.contains($0.key.repository) }
        issues = issues.filter { !scopes.contains($0.key.repository) }
        checks = checks.filter { !scopes.contains($0.key.repository) }
        actions = actions.filter { !scopes.contains($0.key.repository) }
    }

    public func invalidateAccount(accountIdentifier: String) {
        representations = representations.filter { $0.key.accountIdentifier != accountIdentifier }
        accountGenerations[accountIdentifier] = UUID()
        repositoryIDs = repositoryIDs.filter { $0.key.accountIdentifier != accountIdentifier }
        branches = branches.filter { $0.key.repository.accountIdentifier != accountIdentifier }
        pullRequests = pullRequests.filter { $0.key.repository.accountIdentifier != accountIdentifier }
        issues = issues.filter { $0.key.repository.accountIdentifier != accountIdentifier }
        checks = checks.filter { $0.key.repository.accountIdentifier != accountIdentifier }
        actions = actions.filter { $0.key.repository.accountIdentifier != accountIdentifier }
        activeRevisions.removeValue(forKey: accountIdentifier)
        cancelFlights(accountIdentifier: accountIdentifier)
    }

    private func cancelFlights(accountIdentifier: String) {
        let keys = flights.keys.filter { $0.accountIdentifier == accountIdentifier }
        for key in keys {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.task.cancel()
            for continuation in flight.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func alias(_ accountIdentifier: String, _ name: String) -> RepositoryAlias {
        RepositoryAlias(host: "github.com", accountIdentifier: accountIdentifier, name: name.lowercased())
    }
    private func generation(for accountIdentifier: String) -> UUID {
        if let generation = accountGenerations[accountIdentifier] { return generation }
        let generation = UUID()
        accountGenerations[accountIdentifier] = generation
        return generation
    }
    private func branchKey(_ accountIdentifier: String, _ repositoryID: String, _ target: GitHubBranchTarget) -> BranchKey {
        BranchKey(repository: RepositoryScope(host: "github.com", accountIdentifier: accountIdentifier, repositoryID: repositoryID),
                  headRepository: target.head.fullName.lowercased(), branch: target.branch, sha: target.sha)
    }
    private func materialize(_ record: BranchRecord) -> GitHubStatus {
        let metadata = record.metadata
        let materializedActions = record.actions.compactMap { key -> GitHubActionRun? in
            guard let action = actions[key] else { return nil }
            return GitHubActionRun(id: action.id, name: action.name, status: action.status, conclusion: action.conclusion,
                                   url: action.url, headSHA: action.headSHA, event: action.event, runID: action.runID,
                                   attempt: action.attempt, repositoryName: action.repositoryName,
                                   isCurrent: record.currentActions.contains(key))
        }
        return GitHubStatus(issues: record.issues.compactMap { issues[$0] }, pullRequests: record.pullRequests.compactMap { pullRequests[$0] },
                            actions: materializedActions, error: metadata.error, isLoaded: metadata.isLoaded,
                            mergeEvidenceLoaded: metadata.mergeEvidenceLoaded, checks: record.checks.compactMap { checks[$0] },
                            pullRequestFetch: metadata.pullRequestFetch, issueFetch: metadata.issueFetch,
                            checkFetch: metadata.checkFetch, actionFetch: metadata.actionFetch, localSHA: metadata.localSHA)
    }
    private static func merge(previous: GitHubStatus?, incoming: GitHubStatus) -> GitHubStatus {
        guard let previous else { return incoming }
        func mergeItems<Item: Identifiable & Hashable>(_ fresh: [Item], state: GitHubFetchState,
                                                       old: [Item], oldState: GitHubFetchState) -> ([Item], GitHubFetchState) {
            if state.phase == .notRequested { return (old, oldState) }
            if state.phase == .loaded { return (fresh, state) }
            guard oldState.fetchedAt != nil else { return (fresh, state) }
            var values = fresh
            var ids = Set(fresh.map(\.id))
            for item in old where ids.insert(item.id).inserted { values.append(item) }
            return (values, GitHubFetchState(phase: state.phase, fetchedAt: oldState.fetchedAt,
                                             lastAttemptAt: state.lastAttemptAt ?? state.fetchedAt,
                                             stale: true, error: state.error))
        }
        let prs = mergeItems(incoming.pullRequests, state: incoming.pullRequestFetch, old: previous.pullRequests, oldState: previous.pullRequestFetch)
        let linkedIssues = mergeItems(incoming.issues, state: incoming.issueFetch, old: previous.issues, oldState: previous.issueFetch)
        let checks = mergeItems(incoming.checks, state: incoming.checkFetch, old: previous.checks, oldState: previous.checkFetch)
        let actions = mergeItems(incoming.actions, state: incoming.actionFetch, old: previous.actions, oldState: previous.actionFetch)
        return GitHubStatus(issues: linkedIssues.0, pullRequests: prs.0, actions: actions.0, error: incoming.error,
                            isLoaded: incoming.isLoaded, mergeEvidenceLoaded: incoming.mergeEvidenceLoaded, checks: checks.0,
                            pullRequestFetch: prs.1, issueFetch: linkedIssues.1, checkFetch: checks.1,
                            actionFetch: actions.1, localSHA: incoming.localSHA)
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
        try await perform(request, retryRead: retryRead, deadline: deadline, authentication: nil, revision: nil).0
    }

    /// Reacquires credentials after queue/backoff waits and before every transport attempt.
    /// Refresh uses github.com, so holding the api.github.com queue cannot deadlock refresh.
    public func sendAuthenticated(_ request: URLRequest, retryRead: Bool, authentication: any GitHubAuthenticationProviding,
                                  revision: UUID, deadline: Date? = nil) async throws -> (GitHubHTTPResponse, GitHubAuthorization) {
        guard request.url?.host == "api.github.com" else { throw GitHubAPIError.unsupportedURL }
        let (response, authorization) = try await perform(request, retryRead: retryRead, deadline: deadline,
                                                         authentication: authentication, revision: revision)
        guard let authorization else { throw GitHubAPIError.invalidResponse }
        return (response, authorization)
    }

    private func perform(_ request: URLRequest, retryRead: Bool, deadline: Date?,
                         authentication: (any GitHubAuthenticationProviding)?, revision: UUID?) async throws -> (GitHubHTTPResponse, GitHubAuthorization?) {
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
            var authorization: GitHubAuthorization?
            if let authentication {
                let current = try await authentication.authorization()
                guard current.revision == revision else { throw CancellationError() }
                outbound.setValue("Bearer \(current.token)", forHTTPHeaderField: "Authorization")
                authorization = current
            }
            try Task.checkCancellation()
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
            return (response, authorization)
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
