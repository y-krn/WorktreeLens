import Combine
import XCTest
@testable import WorktreeLensApp
@testable import WorktreeLensCore

@MainActor
final class RepositoryViewCacheTests: XCTestCase {
    private final class CountingScanner: RepositoryScanning, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: [RepositoryLocalScanResult]]
        private(set) var sessionScans = 0
        private(set) var gitScans: [String: Int] = [:]
        private(set) var bulkRefreshes: [String: Int] = [:]
        private let blockedBulkCall: (path: String, call: Int, expectation: XCTestExpectation)?
        private var blockedBulkContinuation: CheckedContinuation<RepositorySnapshot, Never>?

        init(results: [String: [RepositoryLocalScanResult]], blockedBulkCall: (path: String, call: Int, expectation: XCTestExpectation)? = nil) {
            self.results = results
            self.blockedBulkCall = blockedBulkCall
        }

        func scanSessions() -> SessionDiscoveryResult {
            lock.lock(); defer { lock.unlock() }
            sessionScans += 1
            return SessionDiscoveryResult(sessions: [], notes: [])
        }

        func readGit(repositoryPath: String, discovery: SessionDiscoveryResult) throws -> RepositoryLocalScanResult {
            lock.lock(); defer { lock.unlock() }
            gitScans[repositoryPath, default: 0] += 1
            guard var versions = results[repositoryPath], !versions.isEmpty else {
                throw NSError(domain: "CountingScanner", code: 1)
            }
            let result = versions.removeFirst()
            results[repositoryPath] = versions
            return RepositoryLocalScanResult(snapshot: result.snapshot, sessionNotes: result.sessionNotes)
        }

        func enrichGitHub(local: RepositoryLocalScanResult, progress: @escaping @Sendable (Int, Int) -> Void) async -> RepositorySnapshot {
            let call = recordBulkRefresh(for: local.snapshot.path)
            if let blockedBulkCall, blockedBulkCall.path == local.snapshot.path, blockedBulkCall.call == call {
                return await withCheckedContinuation { continuation in
                    lock.lock(); blockedBulkContinuation = continuation; lock.unlock()
                    blockedBulkCall.expectation.fulfill()
                }
            }
            return local.snapshot
        }

        func counts(for path: String) -> (git: Int, bulk: Int) {
            lock.lock(); defer { lock.unlock() }
            return (gitScans[path, default: 0], bulkRefreshes[path, default: 0])
        }

        func releaseBlockedBulkRefresh() {
            lock.lock(); let pending = blockedBulkContinuation; blockedBulkContinuation = nil; lock.unlock()
            pending?.resume(returning: RepositorySnapshot(path: "/released", defaultBranch: nil, branches: []))
        }

        private func recordBulkRefresh(for path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            bulkRefreshes[path, default: 0] += 1
            return bulkRefreshes[path, default: 0]
        }
    }

    private final class BlockingDetailLoader: GitHubDetailLoading, @unchecked Sendable {
        let started: XCTestExpectation
        private let lock = NSLock()
        private var paths: [String] = []
        private var continuation: CheckedContinuation<GitHubStatus, Never>?

        init(started: XCTestExpectation) { self.started = started }

        func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval) async -> GitHubStatus {
            record(path: repositoryPath)
            return await withCheckedContinuation { continuation in
                lock.lock(); self.continuation = continuation; lock.unlock()
                started.fulfill()
            }
        }

        func release() {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil))
        }

        var requestedPaths: [String] {
            lock.lock(); defer { lock.unlock() }
            return paths
        }

        private func record(path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.append(path)
        }
    }

    func testRepositorySwitchRestoresSnapshotNotesAndSelectionWithoutRefresh() async throws {
        let a = localResult(path: "/tmp/cache-A", branch: "a-branch", worktree: "a-worktree", notes: ["note A"])
        let b = localResult(path: "/tmp/cache-B", branch: "b-branch", worktree: "b-worktree", notes: ["note B"])
        let scanner = CountingScanner(results: [a.snapshot.path: [a], b.snapshot.path: [b]])
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner)

        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        model.selectWorktree(id: "a-worktree")
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: a.snapshot.path)

        XCTAssertEqual(model.snapshot?.id, a.snapshot.id)
        XCTAssertEqual(model.sessionNotes, ["note A"])
        XCTAssertEqual(model.selection, .worktree("a-worktree"))
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, 1)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, 1)
        XCTAssertEqual(scanner.counts(for: b.snapshot.path).git, 1)
        XCTAssertEqual(scanner.counts(for: b.snapshot.path).bulk, 1)
        XCTAssertEqual(scanner.sessionScans, 2)
    }

    func testExplicitRefreshFetchesFreshDataAndUpdatesCachedView() async throws {
        let first = localResult(path: "/tmp/fresh-A", branch: "old")
        let second = localResult(path: "/tmp/fresh-A", branch: "new")
        let other = localResult(path: "/tmp/fresh-B", branch: "other")
        let scanner = CountingScanner(results: [first.snapshot.path: [first, second], other.snapshot.path: [other]])
        let model = makeModel(paths: [first.snapshot.path, other.snapshot.path], scanner: scanner)

        model.selectRepository(path: first.snapshot.path)
        await waitForRefresh(model)
        model.refreshSelected()
        await waitForRefresh(model)
        model.selectRepository(path: other.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: first.snapshot.path)

        XCTAssertEqual(model.snapshot?.branches.first?.id, "new")
        XCTAssertEqual(scanner.counts(for: first.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: first.snapshot.path).bulk, 2)
    }

    func testFirstLoadSwitchedDuringBulkDoesNotLeavePartialCache() async throws {
        let bulkStarted = expectation(description: "A initial bulk refresh blocked")
        let partialA = localResult(path: "/tmp/partial-first-A", branch: "partial")
        let freshA = localResult(path: "/tmp/partial-first-A", branch: "fresh")
        let b = localResult(path: "/tmp/partial-first-B", branch: "b")
        let scanner = CountingScanner(
            results: [partialA.snapshot.path: [partialA, freshA], b.snapshot.path: [b]],
            blockedBulkCall: (path: partialA.snapshot.path, call: 1, expectation: bulkStarted)
        )
        let model = makeModel(paths: [partialA.snapshot.path, b.snapshot.path], scanner: scanner)

        model.selectRepository(path: partialA.snapshot.path)
        await fulfillment(of: [bulkStarted], timeout: 2)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.snapshot?.branches.first?.id, "partial")
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: partialA.snapshot.path)
        await waitForRefresh(model, branchID: "fresh")
        scanner.releaseBlockedBulkRefresh()
        await Task.yield()

        XCTAssertEqual(model.snapshot?.branches.first?.id, "fresh")
        XCTAssertEqual(scanner.counts(for: partialA.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: partialA.snapshot.path).bulk, 2)
    }

    func testInterruptedExplicitRefreshRestoresPriorCompletedCacheAndSelection() async throws {
        let refreshBulkStarted = expectation(description: "A explicit refresh bulk blocked")
        let completedA = localResult(path: "/tmp/partial-refresh-A", branches: ["complete", "chosen"])
        let partialA = localResult(path: "/tmp/partial-refresh-A", branches: ["partial", "chosen"])
        let b = localResult(path: "/tmp/partial-refresh-B", branch: "b")
        let scanner = CountingScanner(
            results: [completedA.snapshot.path: [completedA, partialA], b.snapshot.path: [b]],
            blockedBulkCall: (path: completedA.snapshot.path, call: 2, expectation: refreshBulkStarted)
        )
        let model = makeModel(paths: [completedA.snapshot.path, b.snapshot.path], scanner: scanner)

        model.selectRepository(path: completedA.snapshot.path)
        await waitForRefresh(model)
        model.selectBranch(id: "chosen")
        model.refreshSelected()
        await fulfillment(of: [refreshBulkStarted], timeout: 2)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["partial", "chosen"])
        model.selectBranch(id: "partial")
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: completedA.snapshot.path)
        scanner.releaseBlockedBulkRefresh()
        await Task.yield()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["complete", "chosen"])
        XCTAssertEqual(model.selection, .branch("chosen"))
        XCTAssertEqual(scanner.counts(for: completedA.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: completedA.snapshot.path).bulk, 2)
    }

    func testCleanupCompletionRefreshesAndReplacesCachedSnapshot() async throws {
        let first = localResult(path: "/tmp/cleanup-A", branch: "before-cleanup")
        let refreshed = localResult(path: "/tmp/cleanup-A", branch: "after-cleanup")
        let other = localResult(path: "/tmp/cleanup-B", branch: "other")
        let scanner = CountingScanner(results: [first.snapshot.path: [first, refreshed], other.snapshot.path: [other]])
        let model = makeModel(paths: [first.snapshot.path, other.snapshot.path], scanner: scanner, git: GitService(runner: SuccessfulRunner()))

        model.selectRepository(path: first.snapshot.path)
        await waitForRefresh(model)
        let preview = model.cleanup.previewPrune(snapshot: first.snapshot)
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForRefresh(model, branchID: "after-cleanup")
        model.selectRepository(path: other.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: first.snapshot.path)

        XCTAssertEqual(model.snapshot?.branches.first?.id, "after-cleanup")
        XCTAssertEqual(scanner.counts(for: first.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: first.snapshot.path).bulk, 2)
    }

    func testDeterministicCleanupPatchesSnapshotAndCacheWithoutScanning() async throws {
        let a = localResult(path: "/tmp/cleanup-patch-A", branch: "feature", worktree: "feature-wt")
        let b = localResult(path: "/tmp/cleanup-patch-B", branch: "other")
        let scanner = CountingScanner(results: [a.snapshot.path: [a], b.snapshot.path: [b]])
        let result = CleanupExecutionResult(completedTargetIDs: ["feature-wt"], removedWorktreePaths: ["\(a.snapshot.path)/feature-wt"])
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner, cleanupExecutor: { _ in result })

        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        model.selectWorktree(id: "feature-wt")
        let before = scanner.counts(for: a.snapshot.path)
        let branchBefore = try XCTUnwrap(model.snapshot?.branches.first)
        let preview = CleanupPreview(operation: .removeWorktree, repositoryPath: a.snapshot.path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForCleanup(model)

        XCTAssertEqual(model.snapshot?.branches.first?.worktrees, [])
        XCTAssertEqual(model.snapshot?.branches.first?.github, branchBefore.github)
        XCTAssertEqual(model.selection, .branch("feature"))
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, before.git)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, before.bulk)
        XCTAssertEqual(scanner.sessionScans, 1)

        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: a.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.first?.worktrees, [])
        XCTAssertEqual(model.selection, .branch("feature"))
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, before.git)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, before.bulk)
    }

    func testBranchCleanupPatchesWithoutFullRefresh() async throws {
        let a = localResult(path: "/tmp/cleanup-branch-A", branches: ["keep", "delete"])
        let result = CleanupExecutionResult(completedTargetIDs: ["delete"], deletedLocalBranches: ["delete"])
        let scanner = CountingScanner(results: [a.snapshot.path: [a]])
        let model = makeModel(paths: [a.snapshot.path], scanner: scanner, cleanupExecutor: { _ in result })
        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        let before = scanner.counts(for: a.snapshot.path)

        let preview = CleanupPreview(operation: .deleteBranch, repositoryPath: a.snapshot.path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForCleanup(model)

        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["keep"])
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, before.git)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, before.bulk)
        XCTAssertEqual(scanner.sessionScans, 1)
    }

    func testRefreshAutoRemovesMergedWorktreesOnlyWhenEnabled() async throws {
        let path = "/tmp/auto-merged-A"
        let mergedPath = "\(path)/merged-wt"
        let merged = WorktreeInfo(id: "merged-wt", path: mergedPath, branch: nil, head: "sha", isBare: false, isLocked: false, isDetached: true, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        let ahead = WorktreeInfo(id: "ahead-wt", path: "\(path)/ahead-wt", branch: nil, head: "sha2", isBare: false, isLocked: false, isDetached: true, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil, defaultAhead: 1)
        let group = BranchInfo(id: "detached", name: "Detached worktrees", sha: "sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, isDetachedGroup: true, worktrees: [merged, ahead])
        let local = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: path, defaultBranch: "main", branches: [group]), sessionNotes: [])
        final class Calls: @unchecked Sendable { var previews: [CleanupPreview] = [] }
        let calls = Calls()
        let executor: @Sendable (CleanupPreview) -> CleanupExecutionResult = { preview in
            calls.previews.append(preview)
            return CleanupExecutionResult(completedTargetIDs: [mergedPath], removedWorktreePaths: [mergedPath])
        }

        let disabled = makeModel(paths: [path], scanner: CountingScanner(results: [path: [local]]), cleanupExecutor: executor)
        disabled.selectRepository(path: path)
        await waitForRefresh(disabled)
        XCTAssertTrue(calls.previews.isEmpty)

        let enabled = makeModel(paths: [path], scanner: CountingScanner(results: [path: [local]]), cleanupExecutor: executor)
        enabled.autoRemoveMergedWorktrees = true
        enabled.selectRepository(path: path)
        await waitForRefresh(enabled)
        let removed = expectation(description: "auto cleanup applied")
        let cancellable = enabled.$snapshot.first { $0?.branches.flatMap(\.worktrees).contains { $0.path == mergedPath } == false }.sink { _ in removed.fulfill() }
        await fulfillment(of: [removed], timeout: 5)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(calls.previews.map(\.operation), [.removeMergedWorktrees])
        XCTAssertEqual(calls.previews.first?.allowedItems.map(\.target), [mergedPath], "worktrees ahead of the default branch are not candidates")
        XCTAssertEqual(enabled.snapshot?.branches.flatMap(\.worktrees).map(\.path), ["\(path)/ahead-wt"])
        XCTAssertEqual(enabled.statusMessage, "Auto-removed 1 merged worktree(s)")
        XCTAssertEqual(enabled.cleanupExecutionState, .idle, "automatic cleanup does not open the preview flow")
    }

    func testRemovingLastDetachedWorktreeRemovesEmptyGroupFromSnapshotAndCache() async throws {
        let path = "/tmp/cleanup-detached-A"
        let detachedPath = "\(path)/detached-wt"
        let worktree = WorktreeInfo(id: "detached-wt", path: detachedPath, branch: nil, head: "detached-sha", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        let detachedGroup = BranchInfo(id: "detached-group", name: "Detached worktrees", sha: "detached-sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, isDetachedGroup: true, worktrees: [worktree])
        let a = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: path, defaultBranch: "main", branches: [detachedGroup]), sessionNotes: [])
        let b = localResult(path: "/tmp/cleanup-detached-B", branch: "other")
        let scanner = CountingScanner(results: [path: [a], b.snapshot.path: [b]])
        let result = CleanupExecutionResult(completedTargetIDs: [detachedPath], removedWorktreePaths: [detachedPath])
        let model = makeModel(paths: [path, b.snapshot.path], scanner: scanner, cleanupExecutor: { _ in result })

        model.selectRepository(path: path)
        await waitForRefresh(model)
        model.selectWorktree(id: "detached-wt")
        let before = scanner.counts(for: path)
        let preview = CleanupPreview(operation: .removeWorktree, repositoryPath: path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForCleanup(model)

        XCTAssertEqual(model.snapshot?.branches, [])
        XCTAssertNil(model.selection)
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: path)
        XCTAssertEqual(model.snapshot?.branches, [])
        XCTAssertNil(model.selection)
        XCTAssertEqual(scanner.counts(for: path).git, before.git)
        XCTAssertEqual(scanner.counts(for: path).bulk, before.bulk)
        XCTAssertEqual(scanner.sessionScans, 2)
    }

    func testGroupedCleanupPatchesOnlySuccessfulMutationsIncludingPartialFailure() async throws {
        let a = localResult(path: "/tmp/cleanup-partial-A", branches: ["first", "second"], worktrees: ["first": "first-wt", "second": "second-wt"])
        let scanner = CountingScanner(results: [a.snapshot.path: [a]])
        let model = makeModel(paths: [a.snapshot.path], scanner: scanner)
        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        let before = scanner.counts(for: a.snapshot.path)

        model.publishCleanupResult(
            CleanupExecutionResult(completedTargetIDs: ["first"], removedWorktreePaths: ["/tmp/cleanup-partial-A/first-wt"]),
            repositoryPath: a.snapshot.path
        )
        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["first", "second"])

        model.selectBranch(id: "second")
        model.publishCleanupResult(
            CleanupExecutionResult(completedTargetIDs: ["second"], removedWorktreePaths: ["/tmp/cleanup-partial-A/second-wt"], deletedLocalBranches: ["second"]),
            repositoryPath: a.snapshot.path
        )
        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["first"])
        XCTAssertEqual(model.selection, .branch("first"))
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, before.git)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, before.bulk)
        XCTAssertEqual(scanner.sessionScans, 1)
    }

    func testCleanupResultForPreviousRepositoryUpdatesCacheWithoutPublishing() async throws {
        let a = localResult(path: "/tmp/cleanup-switch-A", branch: "a", worktree: "a-wt")
        let b = localResult(path: "/tmp/cleanup-switch-B", branch: "b")
        let scanner = CountingScanner(results: [a.snapshot.path: [a], b.snapshot.path: [b]])
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner)
        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        let before = scanner.counts(for: a.snapshot.path)

        model.publishCleanupResult(
            CleanupExecutionResult(completedTargetIDs: ["a-wt"], removedWorktreePaths: ["\(a.snapshot.path)/a-wt"]),
            repositoryPath: a.snapshot.path
        )
        XCTAssertEqual(model.selectedPath, b.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.first?.id, "b")
        model.selectRepository(path: a.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.first?.worktrees, [])
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, before.git)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, before.bulk)
    }

    func testCleanupInvalidatesBlockedRefreshBeforePublishingPatch() async throws {
        let blocked = expectation(description: "refresh bulk blocked")
        let cleanupStarted = expectation(description: "cleanup executor started")
        let releaseCleanup = DispatchSemaphore(value: 0)
        let initial = localResult(path: "/tmp/cleanup-refresh-A", branches: ["chosen", "obsolete"])
        let refreshing = localResult(path: initial.snapshot.path, branches: ["transient", "obsolete", "chosen"])
        let other = localResult(path: "/tmp/cleanup-refresh-B", branch: "other")
        let scanner = CountingScanner(
            results: [initial.snapshot.path: [initial, refreshing], other.snapshot.path: [other]],
            blockedBulkCall: (path: initial.snapshot.path, call: 2, expectation: blocked)
        )
        let result = CleanupExecutionResult(completedTargetIDs: ["obsolete"], deletedLocalBranches: ["obsolete"])
        let model = makeModel(paths: [initial.snapshot.path, other.snapshot.path], scanner: scanner, cleanupExecutor: { _ in
            cleanupStarted.fulfill()
            releaseCleanup.wait()
            return result
        })
        model.selectRepository(path: initial.snapshot.path)
        await waitForRefresh(model)

        let preview = CleanupPreview(operation: .deleteBranch, repositoryPath: initial.snapshot.path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await fulfillment(of: [cleanupStarted], timeout: 2)
        model.refreshSelected()
        await fulfillment(of: [blocked], timeout: 2)
        releaseCleanup.signal()
        await waitForCleanup(model)
        scanner.releaseBlockedBulkRefresh()
        await Task.yield()

        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["chosen"])
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(scanner.counts(for: initial.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: initial.snapshot.path).bulk, 2)
        model.selectRepository(path: other.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: initial.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["chosen"])
        XCTAssertEqual(scanner.counts(for: initial.snapshot.path).git, 2)
    }

    func testCleanupDuringInitialGitHubEnrichmentFallsBackWithoutCachingPartialSnapshot() async throws {
        let blocked = expectation(description: "initial GitHub enrichment blocked")
        let initialPartial = localResult(path: "/tmp/cleanup-first-load-A", branches: ["partial-only", "obsolete"])
        let afterCleanup = localResult(path: initialPartial.snapshot.path, branches: ["keep"])
        let scanner = CountingScanner(
            results: [initialPartial.snapshot.path: [initialPartial, afterCleanup]],
            blockedBulkCall: (path: initialPartial.snapshot.path, call: 1, expectation: blocked)
        )
        let result = CleanupExecutionResult(completedTargetIDs: ["obsolete"], deletedLocalBranches: ["obsolete"])
        let model = makeModel(paths: [initialPartial.snapshot.path], scanner: scanner, cleanupExecutor: { _ in result })
        model.selectRepository(path: initialPartial.snapshot.path)
        await fulfillment(of: [blocked], timeout: 2)

        let preview = CleanupPreview(operation: .deleteBranch, repositoryPath: initialPartial.snapshot.path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForRefresh(model, branchID: "keep")
        scanner.releaseBlockedBulkRefresh()
        await Task.yield()

        XCTAssertEqual(model.snapshot?.branches.map(\.id), ["keep"])
        XCTAssertEqual(scanner.counts(for: initialPartial.snapshot.path).git, 2)
        XCTAssertEqual(scanner.counts(for: initialPartial.snapshot.path).bulk, 2)
        XCTAssertEqual(scanner.sessionScans, 2)
    }

    func testCleanupInvalidatesLateGitHubDetailForPatchedSnapshot() async throws {
        let detailStarted = expectation(description: "lazy detail started")
        let a = localResult(path: "/tmp/cleanup-detail-A", branch: "feature", worktree: "feature-wt", githubLoaded: false)
        let scanner = CountingScanner(results: [a.snapshot.path: [a]])
        let result = CleanupExecutionResult(completedTargetIDs: ["feature-wt"], removedWorktreePaths: ["\(a.snapshot.path)/feature-wt"])
        let detail = BlockingDetailLoader(started: detailStarted)
        let model = makeModel(paths: [a.snapshot.path], scanner: scanner, detailLoader: detail, cleanupExecutor: { _ in result })
        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        await fulfillment(of: [detailStarted], timeout: 2)
        let originalStatus = try XCTUnwrap(model.snapshot?.branches.first?.github)

        let preview = CleanupPreview(operation: .removeWorktree, repositoryPath: a.snapshot.path, items: [])
        model.cleanupPreview = preview
        model.executeCleanup(preview)
        await waitForCleanup(model)
        detail.release()
        await Task.yield()

        XCTAssertEqual(model.snapshot?.branches.first?.worktrees, [])
        XCTAssertEqual(model.snapshot?.branches.first?.github, originalStatus)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, 1)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).bulk, 1)
    }

    func testOldInFlightRefreshCannotPublishAfterRepositorySwitch() async throws {
        let started = expectation(description: "first scan started")
        let release = DispatchSemaphore(value: 0)
        let a = localResult(path: "/tmp/inflight-A", branch: "a")
        let b = localResult(path: "/tmp/inflight-B", branch: "b")
        let scanner = FirstScanBlockingScanner(firstPath: a.snapshot.path, firstResult: a, secondResult: b, started: started, release: release)
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner)

        model.selectRepository(path: a.snapshot.path)
        await fulfillment(of: [started], timeout: 2)
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        release.signal()
        await Task.yield()

        XCTAssertEqual(model.selectedPath, b.snapshot.path)
        XCTAssertEqual(model.snapshot?.path, b.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.first?.id, "b")
    }

    func testRemovingRepositoryDiscardsItsCacheAndRestoresNextRepository() async throws {
        let a = localResult(path: "/tmp/remove-A", branch: "a")
        let b = localResult(path: "/tmp/remove-B", branch: "b")
        let scanner = CountingScanner(results: [a.snapshot.path: [a, a], b.snapshot.path: [b]])
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner)

        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        model.selectRepository(path: a.snapshot.path)
        model.removeSelectedRepository()
        XCTAssertEqual(model.selectedPath, b.snapshot.path)
        XCTAssertEqual(model.snapshot?.path, b.snapshot.path)
        XCTAssertEqual(scanner.counts(for: b.snapshot.path).git, 1)

        model.register(url: URL(fileURLWithPath: a.snapshot.path))
        await waitForRefresh(model)
        XCTAssertEqual(scanner.counts(for: a.snapshot.path).git, 2)
    }

    func testLateLazyGitHubDetailCannotPublishIntoNextRepository() async throws {
        let detailStarted = expectation(description: "lazy detail started")
        let a = localResult(path: "/tmp/detail-A", branch: "a", githubLoaded: false)
        let b = localResult(path: "/tmp/detail-B", branch: "b")
        let scanner = CountingScanner(results: [a.snapshot.path: [a], b.snapshot.path: [b]])
        let detail = BlockingDetailLoader(started: detailStarted)
        let model = makeModel(paths: [a.snapshot.path, b.snapshot.path], scanner: scanner, detailLoader: detail)

        model.selectRepository(path: a.snapshot.path)
        await waitForRefresh(model)
        await fulfillment(of: [detailStarted], timeout: 2)
        model.selectRepository(path: b.snapshot.path)
        await waitForRefresh(model)
        detail.release()
        await Task.yield()

        XCTAssertEqual(model.snapshot?.path, b.snapshot.path)
        XCTAssertEqual(model.snapshot?.branches.first?.id, "b")
        XCTAssertEqual(detail.requestedPaths, [a.snapshot.path])
    }

    private func makeModel(paths: [String], scanner: any RepositoryScanning, detailLoader: (any GitHubDetailLoading)? = nil, git: GitService = GitService(), cleanupExecutor: (@Sendable (CleanupPreview) -> CleanupExecutionResult)? = nil) -> ApplicationModel {
        let suite = "RepositoryViewCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RepositoryStore(defaults: defaults)
        paths.forEach(store.add)
        return ApplicationModel(loadRepositories: false, repositoryStore: store, git: git, detailLoader: detailLoader, scanner: scanner, cleanupExecutor: cleanupExecutor)
    }

    private func localResult(path: String, branch: String, worktree: String? = nil, notes: [String] = [], githubLoaded: Bool = true) -> RepositoryLocalScanResult {
        let worktrees = worktree.map { [WorktreeInfo(id: $0, path: "\(path)/\($0)", branch: branch, head: "sha", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)] } ?? []
        let branchInfo = BranchInfo(id: branch, name: branch, sha: "sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: worktrees, github: githubLoaded ? GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil) : .unavailable)
        let snapshot = RepositorySnapshot(path: path, defaultBranch: "main", branches: [branchInfo])
        return RepositoryLocalScanResult(snapshot: snapshot, sessionNotes: notes)
    }

    private func localResult(path: String, branches: [String], notes: [String] = [], worktrees: [String: String] = [:]) -> RepositoryLocalScanResult {
        let branchInfos = branches.map { branch in
            let attached = worktrees[branch].map { id in
                [WorktreeInfo(id: id, path: "\(path)/\(id)", branch: branch, head: "sha-\(branch)", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)]
            } ?? []
            return BranchInfo(id: branch, name: branch, sha: "sha-\(branch)", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: attached, github: GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil))
        }
        return RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: path, defaultBranch: "main", branches: branchInfos), sessionNotes: notes)
    }

    private func waitForRefresh(_ model: ApplicationModel, branchID: String? = nil) async {
        let finished = expectation(description: "refresh finished for \(model.selectedPath ?? "none")")
        let cancellable = Publishers.CombineLatest(model.$snapshot, model.$isLoading)
            .first { snapshot, isLoading in
                !isLoading && snapshot?.path == model.selectedPath && (branchID == nil || snapshot?.branches.contains { $0.id == branchID } == true)
            }
            .sink { _ in
                finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(cancellable) {}
    }

    private func waitForCleanup(_ model: ApplicationModel) async {
        let finished = expectation(description: "cleanup finished")
        let cancellable = model.$cleanupExecutionState.first { state in
            if case .completed = state { return true }
            return false
        }.sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(cancellable) {}
    }
}

private struct SuccessfulRunner: ProcessRunning {
    func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
        ProcessResult(status: 0)
    }
}

private final class FirstScanBlockingScanner: RepositoryScanning, @unchecked Sendable {
    let firstPath: String
    let firstResult: RepositoryLocalScanResult
    let secondResult: RepositoryLocalScanResult
    let started: XCTestExpectation
    let release: DispatchSemaphore
    private let lock = NSLock()
    private var reads = 0

    init(firstPath: String, firstResult: RepositoryLocalScanResult, secondResult: RepositoryLocalScanResult, started: XCTestExpectation, release: DispatchSemaphore) {
        self.firstPath = firstPath
        self.firstResult = firstResult
        self.secondResult = secondResult
        self.started = started
        self.release = release
    }

    func scanSessions() -> SessionDiscoveryResult { SessionDiscoveryResult(sessions: [], notes: []) }

    func readGit(repositoryPath: String, discovery: SessionDiscoveryResult) throws -> RepositoryLocalScanResult {
        if repositoryPath == firstPath {
            started.fulfill()
            release.wait()
            return firstResult
        }
        return secondResult
    }

    func enrichGitHub(local: RepositoryLocalScanResult, progress: @escaping @Sendable (Int, Int) -> Void) async -> RepositorySnapshot { local.snapshot }
}
