import XCTest
@testable import WorktreeLensCore

private actor StoreRaceGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<GitHubHTTPResponse, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func send() async throws -> GitHubHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release(_ result: Result<GitHubHTTPResponse, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private actor StoreRaceClock: GitHubClock {
    let entered: XCTestExpectation
    private var blockFirst = true
    private var continuation: CheckedContinuation<Date, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func now() async -> Date {
        guard blockFirst else { return Date(timeIntervalSince1970: 1_000) }
        blockFirst = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func sleep(seconds: TimeInterval) async throws {}

    func release() {
        continuation?.resume(returning: Date(timeIntervalSince1970: 1_000))
        continuation = nil
    }
}

final class GitHubStateStoreRaceTests: XCTestCase {
    func testCancelledOldFlightCannotCompleteReplacementFlight() async throws {
        let store = GitHubStateStore()
        let request = URLRequest(url: URL(string: "https://api.github.com/repos/example/repo/actions/runs")!)
        let revision = UUID()
        let oldStarted = expectation(description: "old request started")
        let newStarted = expectation(description: "replacement request started")
        let oldGate = StoreRaceGate(started: oldStarted)
        let newGate = StoreRaceGate(started: newStarted)

        let old = Task {
            try await store.send(request, accountIdentifier: "github.com:42", sessionRevision: revision) { _ in
                try await oldGate.send()
            }
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        old.cancel()
        do {
            _ = try await old.value
            XCTFail("Old subscriber should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let fresh = Task {
            try await store.send(request, accountIdentifier: "github.com:42", sessionRevision: revision) { _ in
                try await newGate.send()
            }
        }
        await fulfillment(of: [newStarted], timeout: 2)
        await oldGate.release(.failure(CancellationError()))

        // Let the obsolete task finish while the replacement flight is still waiting.
        for _ in 0..<1_000 { await Task.yield() }
        let waiters = await store.activeRequestWaiterCount(request, accountIdentifier: "github.com:42")
        XCTAssertEqual(waiters, 1)

        await newGate.release(.success(GitHubHTTPResponse(data: Data("new".utf8), status: 200)))
        let response = try await fresh.value
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "new")
    }

    func testLogoutDuringFinishCannotRestoreOldETag() async throws {
        let entered = expectation(description: "finish awaits clock")
        let clock = StoreRaceClock(entered: entered)
        let store = GitHubStateStore(clock: clock)
        let request = URLRequest(url: URL(string: "https://api.github.com/repos/example/repo/actions/runs")!)
        let old = Task {
            try await store.send(request, accountIdentifier: "github.com:42", sessionRevision: UUID()) { _ in
                GitHubHTTPResponse(data: Data("old".utf8), status: 200, headers: ["ETag": "old-tag"])
            }
        }

        await fulfillment(of: [entered], timeout: 2)
        await store.invalidateAccount(accountIdentifier: "github.com:42")
        await clock.release()
        _ = try? await old.value

        let response = try await store.send(request, accountIdentifier: "github.com:42", sessionRevision: UUID()) { outbound in
            XCTAssertNil(outbound.value(forHTTPHeaderField: "If-None-Match"))
            return GitHubHTTPResponse(data: Data("new".utf8), status: 200)
        }
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "new")
    }

    func testCurrentActionFlagRemainsScopedToCachedBranch() async throws {
        let store = GitHubStateStore()
        let feature = displayTarget("feature")
        let main = displayTarget("main")
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        func status(isCurrent: Bool) -> GitHubStatus {
            GitHubStatus(issues: [], pullRequests: [], actions: [GitHubActionRun(
                id: "example/repo:55:1", name: "Main push", status: "completed", conclusion: "success", url: nil,
                headSHA: "local-sha", event: "push", runID: 55, attempt: 1,
                repositoryName: "example/repo", isCurrent: isCurrent)], error: nil,
                actionFetch: GitHubFetchState(phase: .loaded, fetchedAt: fetchedAt), localSHA: "local-sha")
        }

        _ = await store.recordStatus(accountIdentifier: "github.com:42", target: feature,
                                     repositoryID: "BASE", status: status(isCurrent: false))
        _ = await store.recordStatus(accountIdentifier: "github.com:42", target: main,
                                     repositoryID: "BASE", status: status(isCurrent: true))

        let featureStatus = await store.cachedStatus(accountIdentifier: "github.com:42", target: feature)
        let mainStatus = await store.cachedStatus(accountIdentifier: "github.com:42", target: main)
        let cachedFeature = try XCTUnwrap(featureStatus)
        let cachedMain = try XCTUnwrap(mainStatus)
        XCTAssertFalse(try XCTUnwrap(cachedFeature.actions.first).isCurrent)
        XCTAssertTrue(try XCTUnwrap(cachedMain.actions.first).isCurrent)
    }
}
