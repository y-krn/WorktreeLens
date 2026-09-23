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

        init(results: [String: [RepositoryLocalScanResult]]) { self.results = results }

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
            recordBulkRefresh(for: local.snapshot.path)
            return local.snapshot
        }

        func counts(for path: String) -> (git: Int, bulk: Int) {
            lock.lock(); defer { lock.unlock() }
            return (gitScans[path, default: 0], bulkRefreshes[path, default: 0])
        }

        private func recordBulkRefresh(for path: String) {
            lock.lock(); defer { lock.unlock() }
            bulkRefreshes[path, default: 0] += 1
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

    private func makeModel(paths: [String], scanner: any RepositoryScanning, detailLoader: (any GitHubDetailLoading)? = nil, git: GitService = GitService()) -> ApplicationModel {
        let suite = "RepositoryViewCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RepositoryStore(defaults: defaults)
        paths.forEach(store.add)
        return ApplicationModel(loadRepositories: false, repositoryStore: store, git: git, detailLoader: detailLoader, scanner: scanner)
    }

    private func localResult(path: String, branch: String, worktree: String? = nil, notes: [String] = [], githubLoaded: Bool = true) -> RepositoryLocalScanResult {
        let worktrees = worktree.map { [WorktreeInfo(id: $0, path: "\(path)/\($0)", branch: branch, head: "sha", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)] } ?? []
        let branchInfo = BranchInfo(id: branch, name: branch, sha: "sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: worktrees, github: githubLoaded ? GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil) : .unavailable)
        let snapshot = RepositorySnapshot(path: path, defaultBranch: "main", branches: [branchInfo])
        return RepositoryLocalScanResult(snapshot: snapshot, sessionNotes: notes)
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
