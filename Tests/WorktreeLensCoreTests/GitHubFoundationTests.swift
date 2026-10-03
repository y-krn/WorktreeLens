import XCTest
import Foundation
@testable import WorktreeLensCore

private actor TestGitHubClock: GitHubClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var sleeps: [TimeInterval] = []
    func now() -> Date { date }
    func sleep(seconds: TimeInterval) throws {
        try Task.checkCancellation()
        sleeps.append(seconds)
        date.addTimeInterval(seconds)
    }
}

private final class MemoryGitHubStore: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GitHubCredentials?
    init(_ value: GitHubCredentials? = nil) { self.value = value }
    func load() -> GitHubCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ credentials: GitHubCredentials) { lock.lock(); defer { lock.unlock() }; value = credentials }
    func delete() { lock.lock(); defer { lock.unlock() }; value = nil }
}

private actor ScriptGitHubTransport: GitHubTransport {
    var responses: [GitHubHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [GitHubHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> GitHubHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else { throw GitHubAPIError.network }
        return responses.removeFirst()
    }
}

private struct AccountDelayGitHubTransport: GitHubTransport {
    let clock: TestGitHubClock
    let base: ScriptGitHubTransport
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        if request.url?.host == "api.github.com" { try await clock.sleep(seconds: 100) }
        return try await base.send(request)
    }
}

private actor BarrierGitHubClock: GitHubClock {
    private var remaining: Int
    private var waiting: [CheckedContinuation<Date, Never>] = []
    init(callers: Int) { remaining = callers }
    func now() async -> Date {
        let date = Date(timeIntervalSince1970: 1_000)
        guard remaining > 0 else { return date }
        remaining -= 1
        if remaining == 0 {
            for waiter in waiting { waiter.resume(returning: date) }
            waiting.removeAll()
            return date
        }
        return await withCheckedContinuation { waiting.append($0) }
    }
    func sleep(seconds: TimeInterval) throws { try Task.checkCancellation() }
}

private actor ConcurrencyGitHubTransport: GitHubTransport {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var requestCount = 0
    func send(_ request: URLRequest) async -> GitHubHTTPResponse {
        active += 1
        requestCount += 1
        maximumActive = max(maximumActive, active)
        await Task.yield()
        active -= 1
        return GitHubHTTPResponse(data: Data("{}".utf8), status: 200)
    }
}

private actor BlockingGitHubTransport: GitHubTransport {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<GitHubHTTPResponse, Error>?
    private var wasCancelled = false
    init(started: XCTestExpectation, cancelled: XCTestExpectation) { self.started = started; self.cancelled = cancelled }
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                if wasCancelled { $0.resume(throwing: CancellationError()) }
                else { continuation = $0; started.fulfill() }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        cancelled.fulfill()
    }
}

private final class CancellationURLProtocol: URLProtocol, @unchecked Sendable {
    static var started: XCTestExpectation?
    static var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?.fulfill() }
    override func stopLoading() { Self.stopped?.fulfill() }
}

final class GitHubFoundationTests: XCTestCase {
    private func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> GitHubHTTPResponse {
        GitHubHTTPResponse(data: Data(json.utf8), status: status, headers: headers)
    }
    private var device: GitHubHTTPResponse {
        response(#"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
    }
    private var token: GitHubHTTPResponse {
        response(#"{"access_token":"access-secret","refresh_token":"refresh-secret","expires_in":28800,"refresh_token_expires_in":15897600}"#)
    }
    private var user: GitHubHTTPResponse { response(#"{"id":42,"login":"tester"}"#) }
    private func credentials(expired: Bool = false) -> GitHubCredentials {
        GitHubCredentials(accessToken: "old-secret", refreshToken: "old-refresh-secret",
                          expiresAt: Date(timeIntervalSince1970: expired ? 900 : 50_000),
                          refreshExpiresAt: Date(timeIntervalSince1970: 90_000), account: GitHubAccount(id: 42, login: "tester"))
    }
    private func provider(transport: any GitHubTransport, clock: any GitHubClock, store: MemoryGitHubStore) -> GitHubDeviceFlowProvider {
        GitHubDeviceFlowProvider(clientID: "test-client", http: GitHubHTTPClient(transport: transport, clock: clock), clock: clock, store: store)
    }

    func testDeviceFlowPendingSlowDownSuccessAndAuthenticatedRead() async throws {
        let transport = ScriptGitHubTransport([device, response(#"{"error":"authorization_pending"}"#),
                                               response(#"{"error":"slow_down"}"#), token, user, user])
        let clock = TestGitHubClock(), store = MemoryGitHubStore()
        let auth = provider(transport: transport, clock: clock, store: store)
        let initial = try await auth.state()
        let prompts = expectation(description: "Browser prompt")
        let account = try await auth.authenticate { prompt in
            XCTAssertEqual(prompt.userCode, "ABCD-EFGH")
            XCTAssertEqual(prompt.verificationURL.absoluteString, "https://github.com/login/device")
            prompts.fulfill()
        }
        await fulfillment(of: [prompts], timeout: 2)
        XCTAssertEqual(account.identifier, "github.com:42")
        let state = try await auth.state()
        XCTAssertNotEqual(initial.revision, state.revision)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [5, 5, 10])
        XCTAssertEqual(store.load()?.accessToken, "access-secret")
        let client = GitHubAPIClient(authentication: auth, http: GitHubHTTPClient(transport: transport, clock: clock))
        let read = try await client.currentUser()
        XCTAssertEqual(read, account)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-secret")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertFalse(requests.contains { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("client_secret") == true })
        XCTAssertFalse(String(describing: store.load()!).contains("access-secret"))
        let authorization = try await auth.authorization()
        XCTAssertFalse(String(reflecting: authorization).contains("access-secret"))
    }

    func testDeviceDenialExpirationAndUnknownOAuthRemainDistinct() async throws {
        for (name, expected) in [("access_denied", GitHubAuthError.denied), ("expired_token", .expired), ("unknown-secret", .oauthUnknown)] {
            let auth = provider(transport: ScriptGitHubTransport([device, response("{\"error\":\"\(name)\"}")]),
                                clock: TestGitHubClock(), store: MemoryGitHubStore())
            do { _ = try await auth.authenticate { _ in }; XCTFail("Expected OAuth error") }
            catch { XCTAssertEqual(error as? GitHubAuthError, expected); XCTAssertFalse(error.localizedDescription.contains("unknown-secret")) }
        }
    }

    func testPollingStopsAtDeadlineWithoutExtraRequest() async throws {
        let shortDevice = response(#"{"device_code":"secret","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":11,"interval":5}"#)
        let transport = ScriptGitHubTransport([shortDevice, response(#"{"error":"authorization_pending"}"#), response(#"{"error":"authorization_pending"}"#)])
        let auth = provider(transport: transport, clock: TestGitHubClock(), store: MemoryGitHubStore())
        do { _ = try await auth.authenticate { _ in }; XCTFail("Expected expiry") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .expired) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testTwentyConcurrentRefreshesUseOneRotatingRefreshToken() async throws {
        let clock = BarrierGitHubClock(callers: 20)
        let transport = ScriptGitHubTransport([token])
        let store = MemoryGitHubStore(credentials(expired: true))
        let auth = provider(transport: transport, clock: clock, store: store)
        let authorizations = try await withThrowingTaskGroup(of: GitHubAuthorization.self) { group in
            for _ in 0..<20 { group.addTask { try await auth.authorization() } }
            var result: [GitHubAuthorization] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(authorizations.count, 20)
        XCTAssertTrue(authorizations.allSatisfy { $0.token == "access-secret" })
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let body = String(data: requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertEqual(store.load()?.refreshToken, "refresh-secret")
    }

    func testRevokedRefreshRequiresReauthenticationAndDeletesSecrets() async throws {
        let store = MemoryGitHubStore(credentials(expired: true))
        let auth = provider(transport: ScriptGitHubTransport([response(#"{"error":"bad_refresh_token"}"#)]), clock: TestGitHubClock(), store: store)
        do { _ = try await auth.authorization(); XCTFail("Expected reauthentication") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .reauthenticationRequired) }
        XCTAssertNil(store.load())
        let state = try await auth.state()
        XCTAssertNil(state.account)
    }

    func testLogoutCancelsActiveAuthenticationAndPreventsPersistence() async throws {
        let started = expectation(description: "Request started"), cancelled = expectation(description: "Request cancelled")
        let transport = BlockingGitHubTransport(started: started, cancelled: cancelled)
        let store = MemoryGitHubStore(credentials())
        let auth = provider(transport: transport, clock: TestGitHubClock(), store: store)
        let before = try await auth.state()
        let task = Task { try await auth.authenticate { _ in } }
        await fulfillment(of: [started], timeout: 2)
        try await auth.logout()
        await fulfillment(of: [cancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.load())
        let after = try await auth.state()
        XCTAssertNil(after.account)
        XCTAssertNotEqual(before.revision, after.revision)
    }

    func testCallerCancellationReachesRealURLSessionTask() async throws {
        let started = expectation(description: "URLSession started"), stopped = expectation(description: "URLSession stopped")
        CancellationURLProtocol.started = started; CancellationURLProtocol.stopped = stopped
        defer { CancellationURLProtocol.started = nil; CancellationURLProtocol.stopped = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationURLProtocol.self]
        let http = GitHubHTTPClient(transport: URLSessionGitHubTransport(configuration: configuration))
        let task = Task { try await http.send(URLRequest(url: URL(string: "https://api.github.com/user")!)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLastRefreshWaiterCancellationCancelsTransport() async throws {
        let started = expectation(description: "Refresh started"), cancelled = expectation(description: "Refresh cancelled")
        let transport = BlockingGitHubTransport(started: started, cancelled: cancelled)
        let auth = provider(transport: transport, clock: TestGitHubClock(), store: MemoryGitHubStore(credentials(expired: true)))
        let task = Task { try await auth.authorization() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRateLimitQueueWaitsAndBoundsRetries() async throws {
        let clock = TestGitHubClock()
        let transport = ScriptGitHubTransport([
            response("{}", status: 403, headers: ["Retry-After": "7", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1012"]), user
        ])
        let http = GitHubHTTPClient(transport: transport, clock: clock)
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        let result = try await http.send(request, retryRead: true)
        XCTAssertEqual(result.status, 200)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [12])
        let exhausted = ScriptGitHubTransport(Array(repeating: response("{}", status: 429), count: 4))
        let bounded = GitHubHTTPClient(transport: exhausted, clock: TestGitHubClock())
        do { _ = try await bounded.send(request, retryRead: true); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? GitHubAPIError, .rateLimited) }
        let count = await exhausted.requests.count
        XCTAssertEqual(count, 3)
    }

    func testHTTPAccessErrorsAndNetworkAreNotEmptyResults() async throws {
        for (response, expected) in [
            (response("{}", status: 401), GitHubAPIError.unauthorized),
            (response(#"{"message":"Resource not accessible by integration"}"#, status: 403), .permissionDenied),
            (response("{}", status: 403), .forbiddenUnknown),
            (response("{}", status: 404), .notFoundOrInaccessible)
        ] {
            XCTAssertThrowsError(try GitHubHTTPClient.validate(response)) { XCTAssertEqual($0 as? GitHubAPIError, expected) }
        }
        let http = GitHubHTTPClient(transport: ScriptGitHubTransport([]), clock: TestGitHubClock())
        do { _ = try await http.send(URLRequest(url: URL(string: "https://api.github.com/user")!)); XCTFail("Expected network error") }
        catch { XCTAssertEqual(error as? GitHubAPIError, .network) }
    }

    func test401InvalidatesAuthenticationAndNotifiesObservers() async throws {
        let store = MemoryGitHubStore(credentials()), clock = TestGitHubClock()
        let transport = ScriptGitHubTransport([response("{}", status: 401)])
        let auth = provider(transport: transport, clock: clock, store: store)
        var iterator = try await auth.changes().makeAsyncIterator()
        let before = await iterator.next()
        let client = GitHubAPIClient(authentication: auth, http: GitHubHTTPClient(transport: transport, clock: clock))
        do { _ = try await client.currentUser(); XCTFail("Expected unauthorized") }
        catch { XCTAssertEqual(error as? GitHubAPIError, .unauthorized) }
        let after = await iterator.next()
        XCTAssertNil(after?.account)
        XCTAssertNotEqual(before?.revision, after?.revision)
        XCTAssertNil(store.load())
    }

    func testGraphQLHTTP200PreservesPartialDataAndErrors() async throws {
        struct Value: Decodable, Sendable { let viewer: GitHubAccount? }
        let transport = ScriptGitHubTransport([
            response(#"{"data":{"viewer":{"id":42,"login":"tester"}},"errors":[{"message":"query-secret","type":"FORBIDDEN"}]}"#),
            response(#"{"data":null,"errors":[{"message":"query-secret"}]}"#)
        ])
        let clock = TestGitHubClock(), store = MemoryGitHubStore(credentials())
        let auth = provider(transport: transport, clock: clock, store: store)
        let client = GitHubAPIClient(authentication: auth, http: GitHubHTTPClient(transport: transport, clock: clock))
        let partial: GitHubGraphQLResult<Value> = try await client.graphQL(query: "query { viewer { id login } }", variables: [String: String]())
        XCTAssertEqual(partial.data?.viewer?.id, 42)
        XCTAssertTrue(partial.hasErrors)
        XCTAssertFalse(String(reflecting: partial.errors!).contains("query-secret"))
        let failure: GitHubGraphQLResult<Value> = try await client.graphQL(query: "query { viewer { id } }", variables: [String: String]())
        XCTAssertNil(failure.data)
        XCTAssertTrue(failure.hasErrors)
    }
    func testDevicePollingDeadlineAppliesToHostRateLimitWait() async throws {
        let clock = TestGitHubClock()
        let shortDevice = response(#"{"device_code":"secret","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":10,"interval":5}"#, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1020"])
        let transport = ScriptGitHubTransport([shortDevice, token])
        let auth = provider(transport: transport, clock: clock, store: MemoryGitHubStore())
        do { _ = try await auth.authenticate { _ in }; XCTFail("Expected expiry") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .expired) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [5, 5])
    }

    func testMissingClientIDAndUntrustedBrowserURLNeverAuthenticate() async throws {
        let transport = ScriptGitHubTransport([device])
        let auth = GitHubDeviceFlowProvider(clientID: " ", http: GitHubHTTPClient(transport: transport), store: MemoryGitHubStore())
        do { _ = try await auth.authenticate { _ in XCTFail("Unexpected prompt") }; XCTFail("Expected configuration error") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .missingClientID) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        let malicious = response(#"{"device_code":"secret","user_code":"CODE","verification_uri":"https://example.com/login/device","expires_in":900,"interval":5}"#)
        let bad = provider(transport: ScriptGitHubTransport([malicious]), clock: TestGitHubClock(), store: MemoryGitHubStore())
        do { _ = try await bad.authenticate { _ in XCTFail("Unexpected prompt") }; XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .invalidResponse) }
    }

    func testExpiredRefreshAndStaleUnauthorizedCannotInvalidateNewSession() async throws {
        let expired = GitHubCredentials(accessToken: "secret", refreshToken: "expired-refresh", expiresAt: Date(timeIntervalSince1970: 900),
                                        refreshExpiresAt: Date(timeIntervalSince1970: 999), account: GitHubAccount(id: 42, login: "tester"))
        let store = MemoryGitHubStore(expired)
        let transport = ScriptGitHubTransport([])
        let auth = provider(transport: transport, clock: TestGitHubClock(), store: store)
        do { _ = try await auth.authorization(); XCTFail("Expected reauthentication") }
        catch { XCTAssertEqual(error as? GitHubAuthError, .reauthenticationRequired) }
        XCTAssertNil(store.load())
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)

        let validStore = MemoryGitHubStore(credentials())
        let current = provider(transport: ScriptGitHubTransport([device, token, user]), clock: TestGitHubClock(), store: validStore)
        let old = try await current.authorization()
        _ = try await current.authenticate { _ in }
        try await current.invalidate(old)
        let state = try await current.state()
        XCTAssertEqual(state.account?.id, 42)
        XCTAssertEqual(validStore.load()?.accessToken, "access-secret")
    }

    func testRetryAfterHTTPDateAndUnknown403DoNotInventPermissions() async throws {
        let clock = TestGitHubClock()
        let transport = ScriptGitHubTransport([response("{}", status: 429, headers: ["Retry-After": "Thu, 01 Jan 1970 00:16:47 GMT"]), user])
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        _ = try await GitHubHTTPClient(transport: transport, clock: clock).send(request, retryRead: true)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [7])
        let forbidden = ScriptGitHubTransport([response("{}", status: 403)])
        let result = try await GitHubHTTPClient(transport: forbidden, clock: clock).send(request, retryRead: true)
        XCTAssertThrowsError(try GitHubHTTPClient.validate(result)) { XCTAssertEqual($0 as? GitHubAPIError, .forbiddenUnknown) }
        let count = await forbidden.requests.count
        XCTAssertEqual(count, 1)
    }

    func testConcurrentRequestsUseOneActiveTransportPerHost() async throws {
        let transport = ConcurrencyGitHubTransport()
        let http = GitHubHTTPClient(transport: transport, clock: TestGitHubClock())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = try await http.send(URLRequest(url: URL(string: "https://api.github.com/user")!))
                }
            }
            try await group.waitForAll()
        }
        let maximum = await transport.maximumActive
        let count = await transport.requestCount
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(count, 32)
    }

    func testOAuthPostDoesNotReplayRefreshOnNetworkOrRateLimit() async throws {
        for responses in [[], [response("{}", status: 429, headers: ["Retry-After": "7"])]] {
            let transport = ScriptGitHubTransport(responses)
            let auth = provider(transport: transport, clock: TestGitHubClock(), store: MemoryGitHubStore(credentials(expired: true)))
            do { _ = try await auth.authorization(); XCTFail("Expected failure") }
            catch { XCTAssertTrue([GitHubAPIError.network, .rateLimited].contains(error as? GitHubAPIError ?? .invalidResponse)) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testTokenLifetimeStartsBeforeSlowAccountVerification() async throws {
        let clock = TestGitHubClock(), store = MemoryGitHubStore()
        let transport = AccountDelayGitHubTransport(clock: clock, base: ScriptGitHubTransport([device, token, user]))
        let auth = provider(transport: transport, clock: clock, store: store)
        _ = try await auth.authenticate { _ in }
        XCTAssertEqual(store.load()?.expiresAt, Date(timeIntervalSince1970: 1_005 + 28_800))
        XCTAssertEqual(store.load()?.refreshExpiresAt, Date(timeIntervalSince1970: 1_005 + 15_897_600))
    }

}
