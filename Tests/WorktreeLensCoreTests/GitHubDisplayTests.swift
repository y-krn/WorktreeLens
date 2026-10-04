import XCTest
@testable import WorktreeLensCore

struct DisplayTestAuthentication: GitHubAuthenticationProviding {
    let revision: UUID
    let accountIdentifier: String?
    init(accountIdentifier: String? = nil) { self.revision = UUID(); self.accountIdentifier = accountIdentifier }
    func authorization() async throws -> GitHubAuthorization {
        GitHubAuthorization(token: "fixture", revision: revision, accountIdentifier: accountIdentifier)
    }
    func isCurrent(_ authorization: GitHubAuthorization) async -> Bool { authorization.revision == revision }
    func invalidate(_ authorization: GitHubAuthorization) async throws {}
}
struct DisplayConfigRunner: ProcessRunning {
    let config: String
    func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
        XCTAssertEqual(executable, "/usr/bin/git")
        XCTAssertEqual(Array(arguments.suffix(2)), ["config", "--list"])
        return ProcessResult(status: 0, stdout: config)
    }
}
actor DisplayScriptTransport: GitHubTransport {
    private(set) var requests: [URLRequest] = []
    let respond: @Sendable (URLRequest, Int) throws -> GitHubHTTPResponse
    init(_ respond: @escaping @Sendable (URLRequest, Int) throws -> GitHubHTTPResponse) { self.respond = respond }
    func send(_ request: URLRequest) throws -> GitHubHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        return try respond(request, requests.count)
    }
}
func displayResponse(_ data: [String: Any], errors: [[String: Any]] = []) throws -> GitHubHTTPResponse {
    try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["data": data.merging(["rateLimit": ["cost": 1]], uniquingKeysWith: { old, _ in old }), "errors": errors]), status: 200)
}
func displayQuery(_ request: URLRequest) throws -> String {
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    return try XCTUnwrap(payload["query"] as? String)
}
func displayRepo(_ fields: [String: Any], fork: Bool = false) -> [String: Any] {
    ["id": "BASE", "nameWithOwner": "example/repo", "isFork": fork].merging(fields, uniquingKeysWith: { _, new in new })
}
func displayPage(_ nodes: [[String: Any]], next: String? = nil) -> [String: Any] {
    ["nodes": nodes, "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]]
}
func displayPR(number: Int = 201, branch: String = "feature", sha: String = "local-sha", head: String = "example/repo", baseID: String = "BASE", base: String = "main", mergeCommit: String? = nil) -> [String: Any] {
    ["id": "PR-\(number)", "number": number, "title": "Feature", "state": "MERGED", "isDraft": false,
     "baseRefName": base, "headRefName": branch, "headRefOid": sha, "mergedAt": "2026-01-01T00:00:00Z",
     "mergeCommit": mergeCommit.map { ["oid": $0] as Any } ?? NSNull(),
     "url": "https://github.com/example/repo/pull/\(number)", "baseRepository": ["id": baseID, "nameWithOwner": "example/repo"],
     "headRepository": ["id": head == "example/repo" ? "BASE" : "FORK", "nameWithOwner": head]]
}
func displayBranch(_ name: String = "feature", sha: String = "local-sha", upstream: String? = nil) -> BranchInfo {
    BranchInfo(id: name, name: name, sha: sha, upstream: upstream, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
}
func displayAPI(_ transport: any GitHubTransport, clock: any GitHubClock = SystemGitHubClock(),
                stateStore: GitHubStateStore = .shared, accountIdentifier: String? = nil) -> GitHubAPIClient {
    GitHubAPIClient(authentication: DisplayTestAuthentication(accountIdentifier: accountIdentifier),
                     http: GitHubHTTPClient(transport: transport, clock: clock), stateStore: stateStore)
}
func displayTarget(_ name: String = "feature", sha: String = "local-sha", known: [Int] = []) -> GitHubBranchTarget {
    GitHubBranchTarget(branchID: name, branch: name, sha: sha, base: GitHubRepositoryIdentity(fullName: "example/repo")!,
                       head: GitHubRepositoryIdentity(fullName: "example/repo")!, knownNumbers: known)
}

/// Targeted API fixture used by scanner and cleanup safety tests.
func scannerDisplayFixture(pr: Data, cleanupNodes: [Any]? = nil,
                           beforeCleanupRequest: (@Sendable () throws -> Void)? = nil) -> (GitHubService, DisplayScriptTransport) {
    let transport = DisplayScriptTransport { request, _ in
        XCTAssertEqual(request.url?.path, "/graphql")
        let query = try displayQuery(request)
        let prs = try XCTUnwrap(JSONSerialization.jsonObject(with: pr) as? [[String: Any]])
        var data: [String: Any] = [:]
        if query.contains("base: repository(") {
            try beforeCleanupRequest?()
            let knownPattern = try NSRegularExpression(pattern: #"pullRequest\(number: ([0-9]+)\)"#)
            let knownMatch = knownPattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query))
            let requestedNumber = knownMatch.flatMap { Int(query[Range($0.range(at: 1), in: query)!]) }
            let branchPattern = try NSRegularExpression(pattern: #"headRefName: ("(?:\\.|[^"\\])*")"#)
            let branchMatch = branchPattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query))
            let requestedBranch = try branchMatch.map { match -> String in
                let text = String(query[Range(match.range(at: 1), in: query)!])
                return try JSONDecoder().decode(String.self, from: Data(text.utf8))
            }
            let candidates = prs.filter { raw in
                (requestedNumber == nil || raw["number"] as? Int == requestedNumber) &&
                (requestedBranch == nil || raw["headRefName"] as? String == requestedBranch)
            }
            let selected = candidates.first
            var base = displayRepo(["isFork": false, "defaultBranchRef": ["name": "main"]])
            if requestedNumber != nil { base["pullRequest"] = selected as Any? ?? NSNull() }
            else { base["pullRequests"] = displayPage(candidates) }
            if requestedNumber == nil, let cleanupNodes,
               var page = base["pullRequests"] as? [String: Any] {
                page["nodes"] = cleanupNodes
                base["pullRequests"] = page
            }
            let headRepository = selected?["headRepository"] as? [String: Any]
            data["base"] = base
            data["head"] = ["id": headRepository?["id"] as? String ?? "BASE",
                            "nameWithOwner": headRepository?["nameWithOwner"] as? String ?? "example/repo"]
            return try displayResponse(data)
        }
        XCTAssertFalse(query.contains("closingIssuesReferences")); XCTAssertFalse(query.contains("statusCheckRollup"))
        let regex = try NSRegularExpression(pattern: #"(?s)b([0-9]+): repository.*?headRefName: ("(?:\\.|[^"\\])*")"#)
        for match in regex.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            let alias = "b" + String(query[Range(match.range(at: 1), in: query)!])
            let text = String(query[Range(match.range(at: 2), in: query)!])
            let branch = try JSONDecoder().decode(String.self, from: Data(text.utf8))
            let nodes = prs.filter { $0["headRefName"] as? String == branch }.map { raw in
                raw.merging(["id": "PR-\(raw["number"]!)", "baseRepository": ["id": "BASE", "nameWithOwner": "example/repo"],
                             "headRepository": ["id": "BASE", "nameWithOwner": "example/repo"]], uniquingKeysWith: { _, new in new })
            }
            data[alias] = displayRepo(["pullRequests": displayPage(nodes)])
        }
        return try displayResponse(data)
    }
    let github = GitHubService(api: displayAPI(transport), resolver: GitHubRepositoryResolver(runner: DisplayConfigRunner(config: "remote.origin.url=https://github.com/example/repo.git")))
    return (github, transport)
}

private actor DisplayManualClock: GitHubClock {
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { date }
    func advance() { date = date.addingTimeInterval(1) }
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
}
private struct DisplayAdvancingTransport: GitHubTransport {
    let clock: DisplayManualClock
    let base: DisplayScriptTransport
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        await clock.advance()
        return result
    }
}
private actor DisplayCancellationTransport: GitHubTransport {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<GitHubHTTPResponse, Error>?
    private var didCancel = false
    init(started: XCTestExpectation, cancelled: XCTestExpectation) { self.started = started; self.cancelled = cancelled }
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        try await withTaskCancellationHandler {
            try await park()
        } onCancel: { Task { await self.cancel() } }
    }
    private func park() async throws -> GitHubHTTPResponse {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { pending in
            if didCancel { pending.resume(throwing: CancellationError()); return }
            continuation = pending
            started.fulfill()
        }
    }
    private func cancel() {
        guard !didCancel else { return }
        didCancel = true; continuation?.resume(throwing: CancellationError()); continuation = nil
        cancelled.fulfill()
    }
}

private struct DisplayValuePayload: Decodable, Equatable, Sendable { let value: Int }

private actor DisplaySharedRequestTransport: GitHubTransport {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<GitHubHTTPResponse, Error>?
    private var didCancel = false
    private(set) var requestCount = 0
    init(started: XCTestExpectation) { self.started = started }
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        requestCount += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                started.fulfill()
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func release() {
        continuation?.resume(returning: GitHubHTTPResponse(data: Data(#"{"value":7}"#.utf8), status: 200))
        continuation = nil
    }
    func wasCancelled() -> Bool { didCancel }
    private func cancel() {
        didCancel = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

final class GitHubDisplayTests: XCTestCase {
    func testRefreshMetricsAttributeRequestsAndLatencyPerTarget() async throws {
        let clock = DisplayManualClock()
        let base = DisplayScriptTransport { request, index in
            if index == 1 {
                return try displayResponse([
                    "b0": displayRepo(["pullRequests": displayPage([])]),
                    "b1": displayRepo(["pullRequests": displayPage([])])
                ])
            }
            if request.url?.path == "/graphql" {
                return try displayResponse(["ci": displayRepo(["object": [
                    "oid": "local-sha", "statusCheckRollup": ["contexts": displayPage([])]
                ]])])
            }
            return try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["total_count": 0, "workflow_runs": []]), status: 200)
        }
        let metrics = GitHubRefreshMetrics()
        let service = GitHubDisplayService(api: displayAPI(DisplayAdvancingTransport(clock: clock, base: base), clock: clock),
                                           clock: clock, metrics: metrics)
        let firstTarget = displayTarget()
        let secondTarget = displayTarget("other")
        let summaries = await service.summaries(targets: [firstTarget, secondTarget])
        let summary = try XCTUnwrap(summaries[firstTarget.branchID])
        _ = await service.details(target: firstTarget, summary: summary)

        let recorded = metrics.snapshot()
        let first = try XCTUnwrap(recorded.first { $0.branchID == firstTarget.branchID })
        let second = try XCTUnwrap(recorded.first { $0.branchID == secondTarget.branchID })
        XCTAssertEqual(first.refreshCount, 2)
        XCTAssertEqual(first.apiRequestCount, 3)
        XCTAssertEqual(first.lastAPIRequestCount, 2)
        XCTAssertEqual(first.lastLatency, 2, accuracy: 0.001)
        XCTAssertEqual(first.totalLatency, 3, accuracy: 0.001)
        XCTAssertEqual(second.refreshCount, 1)
        XCTAssertEqual(second.apiRequestCount, 1)
        XCTAssertEqual(second.lastAPIRequestCount, 1)
        XCTAssertEqual(second.lastLatency, 1, accuracy: 0.001)
        XCTAssertEqual(second.totalLatency, 1, accuracy: 0.001)
        let requests = await base.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testRESTETagIsScopedByAccountAnd304KeepsRepresentation() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 {
                return GitHubHTTPResponse(data: Data(#"{"value":7}"#.utf8), status: 200, headers: ["ETag": "\"v1\""])
            }
            if index == 2 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
                return GitHubHTTPResponse(data: Data(), status: 304)
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            let value = index == 3 ? 9 : index == 4 ? 10 : 11
            return GitHubHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["value": value]), status: 200)
        }
        let store = GitHubStateStore()
        let first = GitHubAPIClient(authentication: DisplayTestAuthentication(accountIdentifier: "github.com:42"),
                                    http: GitHubHTTPClient(transport: transport), stateStore: store)
        let second = GitHubAPIClient(authentication: DisplayTestAuthentication(accountIdentifier: "github.com:43"),
                                     http: GitHubHTTPClient(transport: transport), stateStore: store)
        let firstValue: DisplayValuePayload = try await first.get(path: "/repos/example/repo/actions/runs")
        let notModifiedValue: DisplayValuePayload = try await first.get(path: "/repos/example/repo/actions/runs")
        let otherAccountValue: DisplayValuePayload = try await second.get(path: "/repos/example/repo/actions/runs")
        let otherRepositoryValue: DisplayValuePayload = try await first.get(path: "/repos/other/repo/actions/runs")
        await store.invalidateAccount(accountIdentifier: "github.com:42")
        let afterLogoutValue: DisplayValuePayload = try await first.get(path: "/repos/example/repo/actions/runs")
        XCTAssertEqual(firstValue, DisplayValuePayload(value: 7))
        XCTAssertEqual(notModifiedValue, DisplayValuePayload(value: 7))
        XCTAssertEqual(otherAccountValue, DisplayValuePayload(value: 9))
        XCTAssertEqual(otherRepositoryValue, DisplayValuePayload(value: 10))
        XCTAssertEqual(afterLogoutValue, DisplayValuePayload(value: 11))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[3].url?.path, "/repos/other/repo/actions/runs")
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(requests[4].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testSharedRequestSurvivesOneSubscriberCancellation() async throws {
        let started = expectation(description: "shared request started")
        let transport = DisplaySharedRequestTransport(started: started)
        let store = GitHubStateStore()
        let request = URLRequest(url: URL(string: "https://api.github.com/repos/example/repo/actions/runs")!)
        let send: @Sendable () async throws -> GitHubHTTPResponse = {
            try await store.send(request, accountIdentifier: "github.com:42") { outbound in
                try await transport.send(outbound)
            }
        }
        let first = Task { try await send() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await send() }
        var waiters = 0
        for _ in 0..<1_000 {
            waiters = await store.activeRequestWaiterCount(request, accountIdentifier: "github.com:42")
            if waiters == 2 { break }
            await Task.yield()
        }
        guard waiters == 2 else {
            first.cancel(); second.cancel(); await transport.release()
            XCTFail("Second subscriber did not join the in-flight request")
            return
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled subscriber should not receive a response") }
        catch { XCTAssertTrue(error is CancellationError) }
        let wasCancelled = await transport.wasCancelled()
        XCTAssertFalse(wasCancelled)
        await transport.release()
        let sharedResponse = try await second.value
        XCTAssertEqual(sharedResponse.status, 200)
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testAccountInvalidationFencesLateResponseAndStatusWrite() async throws {
        let started = expectation(description: "account request started")
        let transport = DisplaySharedRequestTransport(started: started)
        let store = GitHubStateStore()
        let request = URLRequest(url: URL(string: "https://api.github.com/repos/example/repo/actions/runs")!)
        let revision = UUID()
        let task = Task {
            try await store.send(request, accountIdentifier: "github.com:42", sessionRevision: revision) { outbound in
                try await transport.send(outbound)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await store.invalidateAccount(accountIdentifier: "github.com:42")
        do { _ = try await task.value; XCTFail("Invalidated request must not complete") }
        catch { XCTAssertTrue(error is CancellationError) }

        let good = GitHubStatus(issues: [], pullRequests: [GitHubPullRequest(id: "PR-201", number: 201, title: "Feature",
            state: "OPEN", isDraft: false, baseRefName: "main", headRefName: "feature", headRefOid: "local-sha",
            mergedAt: nil, url: nil)], actions: [], error: nil, localSHA: "local-sha")
        _ = await store.recordStatus(accountIdentifier: "github.com:42", target: displayTarget(), repositoryID: "BASE",
                                     sessionRevision: revision, status: good)
        let cached = await store.cachedStatus(accountIdentifier: "github.com:42", target: displayTarget())
        XCTAssertNil(cached)
    }

    func testFailedRefreshKeepsLastGoodDataButSeparatesSHAAndAccount() async throws {
        let store = GitHubStateStore()
        let success = DisplayScriptTransport { _, _ in
            try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])])
        }
        let first = GitHubDisplayService(api: displayAPI(success, stateStore: store, accountIdentifier: "github.com:42"))
        let initialStatuses = await first.summaries(targets: [displayTarget()])
        let initial = try XCTUnwrap(initialStatuses["feature"])
        XCTAssertEqual(initial.pullRequests.map(\.number), [201])

        let failed = DisplayScriptTransport { _, _ in throw GitHubAPIError.network }
        let second = GitHubDisplayService(api: displayAPI(failed, stateStore: store, accountIdentifier: "github.com:42"))
        let refreshedStatuses = await second.summaries(targets: [displayTarget()])
        let refreshed = try XCTUnwrap(refreshedStatuses["feature"])
        XCTAssertEqual(refreshed.pullRequests.map(\.number), [201])
        XCTAssertEqual(refreshed.pullRequestFetch.phase, .failed)
        XCTAssertTrue(refreshed.pullRequestFetch.stale)
        XCTAssertFalse(refreshed.mergeEvidenceLoaded)
        XCTAssertNotNil(refreshed.error)

        let changedSHAStatuses = await second.summaries(targets: [displayTarget(sha: "new-sha")])
        let changedSHA = try XCTUnwrap(changedSHAStatuses["feature"])
        XCTAssertTrue(changedSHA.pullRequests.isEmpty)
        XCTAssertFalse(changedSHA.pullRequestFetch.stale)

        let target = displayTarget()
        let differentHead = GitHubBranchTarget(branchID: target.branchID, branch: target.branch, sha: target.sha,
            base: target.base, head: GitHubRepositoryIdentity(fullName: "fork/repo")!)
        let differentRepository = GitHubBranchTarget(branchID: target.branchID, branch: target.branch, sha: target.sha,
            base: GitHubRepositoryIdentity(fullName: "other/repo")!, head: target.head)
        let differentHeadStatus = await store.cachedStatus(accountIdentifier: "github.com:42", target: differentHead)
        let differentRepositoryStatus = await store.cachedStatus(accountIdentifier: "github.com:42", target: differentRepository)
        XCTAssertNil(differentHeadStatus)
        XCTAssertNil(differentRepositoryStatus)

        let replacement = GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil,
            pullRequestFetch: GitHubFetchState(phase: .loaded, fetchedAt: Date()))
        let replaced = await store.recordStatus(accountIdentifier: "github.com:42", target: target,
            repositoryID: "REPLACED-BASE", status: replacement)
        XCTAssertTrue(replaced.pullRequests.isEmpty)
        let remappedStatus = await store.cachedStatus(accountIdentifier: "github.com:42", target: target)
        XCTAssertTrue(remappedStatus?.pullRequests.isEmpty == true)

        let otherAccount = GitHubDisplayService(api: displayAPI(failed, stateStore: store, accountIdentifier: "github.com:43"))
        let isolatedStatuses = await otherAccount.summaries(targets: [displayTarget()])
        let isolated = try XCTUnwrap(isolatedStatuses["feature"])
        XCTAssertTrue(isolated.pullRequests.isEmpty)
        XCTAssertFalse(isolated.pullRequestFetch.stale)
    }

    func testRefreshFailureRetainsEachLastGoodEntityAndFreshness() async throws {
        let store = GitHubStateStore()
        let target = displayTarget()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let good = GitHubStatus(issues: [GitHubIssue(id: "ISSUE-7", number: 7, title: "Linked", state: "OPEN", url: nil,
                                                      repositoryID: "ISSUE-REPO")],
                                pullRequests: [GitHubPullRequest(id: "PR-201", number: 201, title: "Feature", state: "OPEN",
                                    isDraft: false, baseRefName: "main", headRefName: "feature", headRefOid: "local-sha",
                                    mergedAt: nil, url: nil)],
                                actions: [GitHubActionRun(id: "example/repo:55:2", name: "Build", status: "completed", conclusion: "success",
                                                          url: nil, headSHA: "local-sha", event: "push", runID: 55, attempt: 2,
                                                          repositoryName: "example/repo")],
                                error: nil, isLoaded: true, mergeEvidenceLoaded: true,
                                checks: [GitHubCheck(id: "CHECK-1", name: "Build", kind: "CheckRun", result: "SUCCESS", sha: "local-sha")],
                                pullRequestFetch: GitHubFetchState(phase: .loaded, fetchedAt: now),
                                issueFetch: GitHubFetchState(phase: .loaded, fetchedAt: now),
                                checkFetch: GitHubFetchState(phase: .loaded, fetchedAt: now),
                                actionFetch: GitHubFetchState(phase: .loaded, fetchedAt: now), localSHA: "local-sha")
        _ = await store.recordStatus(accountIdentifier: "github.com:42", target: target, repositoryID: "BASE", status: good)
        let attempt = Date(timeIntervalSince1970: 1_700_000_100)
        let failed = GitHubStatus(issues: [], pullRequests: [], actions: [], error: "PR request failed", isLoaded: true,
                                  mergeEvidenceLoaded: false,
                                  pullRequestFetch: GitHubFetchState(phase: .failed, lastAttemptAt: attempt, error: "PR request failed"),
                                  issueFetch: GitHubFetchState(phase: .failed, lastAttemptAt: attempt, error: "Issues failed"),
                                  checkFetch: GitHubFetchState(phase: .failed, lastAttemptAt: attempt, error: "Checks failed"),
                                  actionFetch: GitHubFetchState(phase: .failed, lastAttemptAt: attempt, error: "Actions failed"),
                                  localSHA: "local-sha")
        let retained = await store.recordStatus(accountIdentifier: "github.com:42", target: target, status: failed)
        XCTAssertEqual(retained.pullRequests.map(\.id), ["PR-201"])
        XCTAssertEqual(retained.issues.map(\.repositoryID), ["ISSUE-REPO"])
        XCTAssertEqual(retained.checks.map(\.id), ["CHECK-1"])
        XCTAssertEqual(retained.actions.map(\.runID), [55])
        for state in [retained.pullRequestFetch, retained.issueFetch, retained.checkFetch, retained.actionFetch] {
            XCTAssertTrue(state.stale)
            XCTAssertEqual(state.fetchedAt, now)
            XCTAssertEqual(state.lastAttemptAt, attempt)
            XCTAssertNotNil(state.error)
        }
    }
    func testResolverUsesUpstreamBaseAndTrackingRemoteHeadAndExplicitSelection() throws {
        let config = "remote.origin.url=git@github.com:fork/repo.git\nremote.upstream.url=ssh://git@github.com/example/repo.git\nbranch.feature.remote=origin"
        let target = try XCTUnwrap(GitHubRepositoryResolver(runner: DisplayConfigRunner(config: config)).targets(path: "/fixture", branches: [displayBranch()]).first)
        XCTAssertEqual(target.base.fullName, "example/repo"); XCTAssertEqual(target.head.fullName, "fork/repo")
        XCTAssertTrue(target.explicitBase)
        let ambiguous = "remote.origin.url=https://github.com/fork/repo.git\nremote.other.url=https://github.com/example/repo.git\nbranch.feature.remote=origin"
        XCTAssertTrue(try GitHubRepositoryResolver(runner: DisplayConfigRunner(config: ambiguous)).targets(path: "/fixture", branches: [displayBranch()]).isEmpty)
        let explicit = try XCTUnwrap(GitHubRepositoryResolver(runner: DisplayConfigRunner(config: ambiguous + "\nworktreelens.githubrepository=example/repo")).targets(path: "/fixture", branches: [displayBranch()]).first)
        XCTAssertEqual(explicit.base.fullName, "example/repo"); XCTAssertEqual(explicit.head.fullName, "fork/repo")
        XCTAssertNil(GitHubRepositoryIdentity.remote("https://example.com/example/repo.git"))
        XCTAssertNil(GitHubRepositoryIdentity.remote("https://github.com/example/repo.git?token=secret"))
    }

    func testKnownPRDirectFetchAndOldMergedConnectionPagination() async throws {
        let known = DisplayScriptTransport { request, _ in
            let query = try displayQuery(request)
            XCTAssertTrue(query.contains("pullRequest(number: 201)")); XCTAssertFalse(query.contains("pullRequests("))
            return try displayResponse(["k0": displayRepo(["pullRequest": displayPR()])])
        }
        let direct = await GitHubDisplayService(api: displayAPI(known)).summaries(targets: [displayTarget(known: [201])])
        XCTAssertTrue(try XCTUnwrap(direct["feature"]).mergeEvidenceLoaded)
        let pages = DisplayScriptTransport { request, index in
            let query = try displayQuery(request)
            XCTAssertTrue(query.contains("headRefName: \"feature\""))
            if index == 1 { return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR(number: 202, sha: "reused")], next: "old")])]) }
            XCTAssertTrue(query.contains("after: \"old\""))
            return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])])
        }
        let statuses = await GitHubDisplayService(api: displayAPI(pages)).summaries(targets: [displayTarget()])
        let status = try XCTUnwrap(statuses["feature"])
        XCTAssertEqual(status.pullRequests.count, 2)
        XCTAssertEqual(status.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "local-sha")?.number, 201)
        let requests = await pages.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testPaginationBudgetFailsClosedAndPreservesFoundPR() async throws {
        var limits = GitHubDisplayLimits(); limits.maxRequests = 1
        let transport = DisplayScriptTransport { _, _ in
            try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()], next: "more")])])
        }
        let result = await GitHubDisplayService(api: displayAPI(transport), limits: limits).summaries(targets: [displayTarget()])
        let status = try XCTUnwrap(result["feature"])
        XCTAssertEqual(status.pullRequests.count, 1); XCTAssertEqual(status.pullRequestFetch.phase, .incomplete)
        XCTAssertFalse(status.mergeEvidenceLoaded)
        XCTAssertNil(status.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "local-sha"))
    }

    func testPartialErrorsDoNotInvalidateSuccessfulBranchAndRejectWrongIdentity() async throws {
        let transport = DisplayScriptTransport { _, _ in
            try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR(), displayPR(number: 202, head: "fork/repo"), displayPR(number: 203, baseID: "WRONG")])]), "b1": NSNull()],
                                errors: [["type": "FORBIDDEN", "path": ["b1", "pullRequests"]]])
        }
        let result = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget(), displayTarget("other")])
        let good = try XCTUnwrap(result["feature"]); let failed = try XCTUnwrap(result["other"])
        XCTAssertEqual(good.pullRequests.map(\.number), [201]); XCTAssertTrue(good.mergeEvidenceLoaded)
        XCTAssertFalse(failed.mergeEvidenceLoaded); XCTAssertEqual(failed.pullRequestFetch.phase, .failed)
        XCTAssertNil(good.verifiedMergedPullRequest(defaultBranch: "wrong", branchName: "feature", localSHA: "local-sha"))
        XCTAssertNil(good.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "new-sha"))
    }

    func testForkBaseRequiresExplicitChoice() async throws {
        let transport = DisplayScriptTransport { _, _ in try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])], fork: true)]) }
        let result = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget()])
        XCTAssertFalse(try XCTUnwrap(result["feature"]).mergeEvidenceLoaded)
    }

    func testClosingIssueObjectConnectionsCrossRepositoryIdentityAndBothCheckTypes() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 { return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])]) }
            if request.url?.path == "/graphql" {
                let query = try displayQuery(request)
                XCTAssertTrue(query.contains("closingIssuesReferences"))
                var pr = displayPR()
                let issue: (String) -> [String: Any] = { repo in ["id": "\(repo):7", "number": 7, "title": "Linked", "state": "OPEN", "url": "https://github.com/\(repo)/issues/7", "repository": ["id": repo, "nameWithOwner": repo]] }
                pr["closingIssuesReferences"] = displayPage([issue("example/repo"), issue("other/repo")])
                pr["mergeStateStatus"] = "UNKNOWN"; pr["mergeable"] = "UNKNOWN"; pr["potentialMergeCommit"] = ["oid": "test-merge"]
                let checks: [[String: Any]] = [["__typename": "CheckRun", "id": "check", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"],
                                             ["__typename": "StatusContext", "id": "status", "context": "legacy", "state": "FAILURE"]]
                return try displayResponse(["i0": displayRepo(["pullRequest": pr]), "ci": displayRepo(["object": ["oid": "local-sha", "statusCheckRollup": ["contexts": displayPage(checks)]]])])
            }
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "head_sha" }?.value, "local-sha")
            // Actions failure must not erase PRs, linked issues, or checks.
            return GitHubHTTPResponse(data: Data("{}".utf8), status: 404)
        }
        let service = GitHubDisplayService(api: displayAPI(transport))
        let summaries = await service.summaries(targets: [displayTarget()])
        let summary = try XCTUnwrap(summaries["feature"])
        let details = await service.details(target: displayTarget(), summary: summary)
        XCTAssertEqual(details.issues.count, 2); XCTAssertEqual(Set(details.issues.map(\.id)).count, 2)
        XCTAssertEqual(Set(details.checks.map(\.kind)), ["CheckRun", "StatusContext"])
        XCTAssertEqual(details.checks.first?.sha, "local-sha")
        XCTAssertTrue(details.issueFetch.isComplete); XCTAssertTrue(details.checkFetch.isComplete)
        XCTAssertEqual(details.actionFetch.phase, .failed); XCTAssertEqual(details.pullRequests.count, 1)
        XCTAssertEqual(details.pullRequests.first?.mergeStateStatus, "UNKNOWN")
        XCTAssertEqual(details.pullRequests.first?.testMergeSHA, "test-merge")
        let requests = await transport.requests; XCTAssertEqual(requests.count, 3)
    }

    func testActionSHAEventAttemptAndUnpublishedHEADRemainDistinct() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 { return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])]) }
            if request.url?.path == "/graphql" {
                var pr = displayPR(); pr["closingIssuesReferences"] = displayPage([])
                return try displayResponse(["i0": displayRepo(["pullRequest": pr]), "ci": displayRepo(["object": NSNull()])])
            }
            let run: (Int, Int, String, String) -> [String: Any] = { id, attempt, sha, event in
                ["id": id, "name": "build", "status": "completed", "conclusion": "success", "html_url": "https://github.com/example/repo/actions/runs/\(id)",
                 "head_sha": sha, "event": event, "run_attempt": attempt, "head_branch": "feature",
                 "repository": ["full_name": "example/repo"], "head_repository": ["full_name": "example/repo"]]
            }
            let runs = [run(1, 1, "local-sha", "push"), run(1, 2, "local-sha", "push"), run(2, 1, "old-sha", "push"),
                        run(3, 1, "test-merge", "pull_request"), run(4, 1, "local-sha", "merge_group"), run(5, 1, "local-sha", "pull_request")]
            return try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["total_count": runs.count, "workflow_runs": runs]), status: 200)
        }
        let service = GitHubDisplayService(api: displayAPI(transport))
        let summaries = await service.summaries(targets: [displayTarget()])
        let summary = try XCTUnwrap(summaries["feature"])
        let status = await service.details(target: displayTarget(), summary: summary)
        XCTAssertEqual(status.checkFetch.phase, .failed)
        XCTAssertEqual(status.actions.filter(\.isCurrent).map(\.runID), [1])
        XCTAssertEqual(status.actions.first { $0.runID == 1 }?.attempt, 2)
        XCTAssertEqual(status.actions.count, 5)
        XCTAssertNil(status.pullRequests.first?.mergeStateStatus)
    }
    func testCancellationReachesAuthenticatedHTTPTransport() async throws {
        let started = expectation(description: "transport started")
        let cancelled = expectation(description: "transport cancelled")
        let transport = DisplayCancellationTransport(started: started, cancelled: cancelled)
        let service = GitHubDisplayService(api: displayAPI(transport))
        let task = Task { await service.summaries(targets: [displayTarget()]) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(try XCTUnwrap(result["feature"]).mergeEvidenceLoaded)
    }

    func testInjectedClockCostAndItemBudgetsStopFurtherQueries() async throws {
        let clock = DisplayManualClock()
        let base = DisplayScriptTransport { _, _ in try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()], next: "next")])]) }
        let timed = GitHubDisplayService(api: displayAPI(DisplayAdvancingTransport(clock: clock, base: base), clock: clock), clock: clock)
        let timedResult = await timed.summaries(targets: [displayTarget()], timeout: 0.5)
        XCTAssertEqual(timedResult["feature"]?.pullRequestFetch.phase, .incomplete)
        let timedRequests = await base.requests; XCTAssertEqual(timedRequests.count, 1)
        var cost = GitHubDisplayLimits(); cost.maxCost = 1
        let limited = await GitHubDisplayService(api: displayAPI(base), limits: cost).summaries(targets: [displayTarget()])
        XCTAssertEqual(limited["feature"]?.pullRequestFetch.phase, .incomplete)
        var items = GitHubDisplayLimits(); items.maxItems = 1
        let itemTransport = DisplayScriptTransport { request, _ in
            XCTAssertTrue(try displayQuery(request).contains("pullRequests(first: 1"))
            return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])])
        }
        let itemResult = await GitHubDisplayService(api: displayAPI(itemTransport), limits: items).summaries(targets: [displayTarget(), displayTarget("other")])
        XCTAssertTrue(try XCTUnwrap(itemResult["feature"]).mergeEvidenceLoaded)
        XCTAssertEqual(itemResult["other"]?.pullRequestFetch.phase, .incomplete)
        let itemRequests = await itemTransport.requests; XCTAssertEqual(itemRequests.count, 1)
    }

    func testIssueCheckAndActionConnectionsPaginateWithoutPerPRFanout() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 { return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])]) }
            if request.url?.path == "/graphql" {
                let query = try displayQuery(request)
                if index == 3 {
                    XCTAssertTrue(query.contains("after: \"issue-next\"")); XCTAssertTrue(query.contains("after: \"check-next\""))
                }
                let issue: [String: Any] = ["id": "issue-\(index)", "number": index, "title": "Issue", "state": "OPEN", "url": "https://github.com/example/repo/issues/\(index)", "repository": ["id": "BASE", "nameWithOwner": "example/repo"]]
                var pr = displayPR(); pr["closingIssuesReferences"] = displayPage([issue], next: index == 2 ? "issue-next" : nil)
                let check: [String: Any] = ["__typename": "CheckRun", "id": "check-\(index)", "name": "check", "status": "COMPLETED", "conclusion": "SUCCESS"]
                return try displayResponse(["i0": displayRepo(["pullRequest": pr]), "ci": displayRepo(["object": ["oid": "local-sha", "statusCheckRollup": ["contexts": displayPage([check], next: index == 2 ? "check-next" : nil)]]])])
            }
            let ids = index == 4 ? Array(1...100) : [101]
            if index == 5 { XCTAssertTrue(request.url?.query?.contains("page=2") == true) }
            let runs: [[String: Any]] = ids.map { id in ["id": id, "name": "build", "status": "completed", "conclusion": "success", "html_url": "https://github.com/example/repo/actions/runs/\(id)", "head_sha": "local-sha", "event": "push", "run_attempt": 1, "head_branch": "feature", "repository": ["full_name": "example/repo"], "head_repository": ["full_name": "example/repo"]] }
            return try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["total_count": 101, "workflow_runs": runs]), status: 200)
        }
        let service = GitHubDisplayService(api: displayAPI(transport))
        let summaries = await service.summaries(targets: [displayTarget()])
        let details = await service.details(target: displayTarget(), summary: try XCTUnwrap(summaries["feature"]))
        XCTAssertEqual(details.issues.count, 2); XCTAssertEqual(details.checks.count, 2); XCTAssertEqual(details.actions.count, 101)
        XCTAssertTrue(details.issueFetch.isComplete); XCTAssertTrue(details.checkFetch.isComplete); XCTAssertTrue(details.actionFetch.isComplete)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 5)
    }

    func testReusedBranchWithKnownOldPRDiscoversNewPRAndWrongKnownNumberFailsClosed() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 { return try displayResponse(["k0": displayRepo(["pullRequest": displayPR(sha: "old")])]) }
            XCTAssertTrue(try displayQuery(request).contains("headRefName: \"feature\""))
            return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR(sha: "old"), displayPR(number: 202)])])])
        }
        let results = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget(known: [201])])
        let status = try XCTUnwrap(results["feature"])
        XCTAssertEqual(status.pullRequests.map(\.number), [201, 202])
        XCTAssertEqual(status.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "local-sha")?.number, 202)
        let wrong = DisplayScriptTransport { _, _ in try displayResponse(["k0": displayRepo(["pullRequest": displayPR(number: 999)])]) }
        let wrongResults = await GitHubDisplayService(api: displayAPI(wrong)).summaries(targets: [displayTarget(known: [201])])
        XCTAssertFalse(try XCTUnwrap(wrongResults["feature"]).mergeEvidenceLoaded)
    }

    func testMissingRepositoryIdentityIsIncompleteAndWrongHeadNodeIDCannotVerifyMerge() async throws {
        let missing = DisplayScriptTransport { _, _ in
            var pr = displayPR(); pr["headRepository"] = NSNull()
            return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([pr])])])
        }
        let missingResult = await GitHubDisplayService(api: displayAPI(missing)).summaries(targets: [displayTarget()])
        XCTAssertEqual(missingResult["feature"]?.pullRequestFetch.phase, .incomplete)
        XCTAssertFalse(try XCTUnwrap(missingResult["feature"]).mergeEvidenceLoaded)
        let wrong = DisplayScriptTransport { _, _ in
            var pr = displayPR(); pr["headRepository"] = ["id": "WRONG", "nameWithOwner": "example/repo"]
            return try displayResponse(["k0": displayRepo(["pullRequest": pr])])
        }
        let wrongResult = await GitHubDisplayService(api: displayAPI(wrong)).summaries(targets: [displayTarget(known: [201])])
        XCTAssertFalse(try XCTUnwrap(wrongResult["feature"]).mergeEvidenceLoaded)
    }

}
