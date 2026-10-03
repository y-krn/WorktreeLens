import XCTest
@testable import WorktreeLensApp
import WorktreeLensCore

private struct GitRefreshMetadataRunner: ProcessRunning {
    let gitDirectory: String
    let commonDirectory: String
    let headBranch: String

    func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
        if arguments.contains("--absolute-git-dir") { return ProcessResult(status: 0, stdout: gitDirectory) }
        if arguments.contains("--git-common-dir") { return ProcessResult(status: 0, stdout: commonDirectory) }
        if arguments.contains("symbolic-ref") { return ProcessResult(status: 0, stdout: headBranch) }
        if arguments.contains("for-each-ref") {
            return ProcessResult(status: 0, stdout: "refs/remotes/upstream/\(headBranch)\n")
        }
        if arguments.contains("rev-parse"), let ref = arguments.last {
            if ref == "HEAD" { return ProcessResult(status: 0, stdout: "head-sha") }
            if ref == "refs/heads/\(headBranch)" { return ProcessResult(status: 0, stdout: "branch-sha") }
            if ref == "refs/remotes/upstream/\(headBranch)" { return ProcessResult(status: 0, stdout: "upstream-sha") }
        }
        if arguments.contains("--local") { return ProcessResult(status: 0, stdout: "branch.config\u{0}value\u{0}") }
        if arguments.contains("remote") { return ProcessResult(status: 0, stdout: "upstream\thttps://github.com/example/repo.git (fetch)\n") }
        return ProcessResult(status: 1)
    }
}

@MainActor
private final class ManualRefreshTimer: RefreshTimerHandle {
    let due: Date
    let action: @MainActor () -> Void
    var cancelled = false
    init(due: Date, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
    func cancel() { cancelled = true }
}

@MainActor
private final class ManualRefreshClock: RefreshClock {
    private(set) var now = Date(timeIntervalSince1970: 10_000)
    private var timers: [ManualRefreshTimer] = []
    private(set) var scheduledIntervals: [TimeInterval] = []

    func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any RefreshTimerHandle {
        scheduledIntervals.append(interval)
        let timer = ManualRefreshTimer(due: now.addingTimeInterval(interval), action: action)
        timers.append(timer)
        return timer
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        while let index = timers.indices.filter({ !timers[$0].cancelled && timers[$0].due <= now })
            .min(by: { timers[$0].due < timers[$1].due }) {
            let timer = timers.remove(at: index)
            guard !timer.cancelled else { continue }
            timer.action()
        }
        timers.removeAll(where: \.cancelled)
    }

    var activeTimerCount: Int { timers.filter { !$0.cancelled }.count }
}

@MainActor
private final class ManualRefreshSubscription: RefreshEventSubscription {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class ManualRefreshEventSource: RefreshEventSource {
    private(set) var onChange: (@MainActor () -> Void)?
    private(set) var lastSubscription: ManualRefreshSubscription?
    private(set) var watchedTargets: [RefreshTarget] = []

    func watch(target: RefreshTarget, onChange: @escaping @MainActor () -> Void) -> any RefreshEventSubscription {
        let subscription = ManualRefreshSubscription()
        lastSubscription = subscription
        watchedTargets.append(target)
        self.onChange = onChange
        return subscription
    }

    func emitChange() { onChange?() }
}

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
    func testActiveCIPollsAtConfiguredInterval() async {
        let clock = ManualRefreshClock()
        let events = ManualRefreshEventSource()
        let active = status(now: clock.now, activeCI: true)
        let refreshed = expectation(description: "CI status refreshed")
        let coordinator = RefreshCoordinator(policy: GitHubRefreshPolicy(jitterFraction: 0), clock: clock,
            eventSource: events, refresh: { _ in refreshed.fulfill(); return active },
            readIdentity: { _ in nil }, identityChanged: { _, _ in nil })

        coordinator.select(target(), status: active)
        XCTAssertEqual(clock.scheduledIntervals.last, 20)
        clock.advance(by: 20)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(clock.scheduledIntervals.last, 20)
    }

    func testUnchangedStatusBacksOffAndCaps() {
        let policy = GitHubRefreshPolicy(jitterFraction: 0)
        let status = status(now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(policy.nextInterval(for: status, unchangedPolls: 0), 60)
        XCTAssertEqual(policy.nextInterval(for: status, unchangedPolls: 1), 120)
        XCTAssertEqual(policy.nextInterval(for: status, unchangedPolls: 20), 900)
    }

    func testBackgroundStopsTimerAndResumeRevalidatesStaleSelection() async {
        let clock = ManualRefreshClock()
        let events = ManualRefreshEventSource()
        let staleAfter = 30.0
        let policy = GitHubRefreshPolicy(staleAfter: staleAfter, jitterFraction: 0)
        let fresh = status(now: clock.now)
        let resumed = expectation(description: "foreground refresh")
        var calls = 0
        let coordinator = RefreshCoordinator(policy: policy, clock: clock, eventSource: events,
            refresh: { _ in calls += 1; resumed.fulfill(); return fresh },
            readIdentity: { _ in nil }, identityChanged: { _, _ in nil })

        coordinator.select(target(), status: fresh)
        XCTAssertEqual(events.watchedTargets.count, 1)
        coordinator.setForeground(false)
        XCTAssertTrue(events.lastSubscription?.cancelled == true)
        XCTAssertEqual(clock.activeTimerCount, 0)
        clock.advance(by: 3_600)
        XCTAssertEqual(calls, 0)
        coordinator.setForeground(true)
        clock.advance(by: 0.25)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    func testHeadOrUpstreamIdentityEventRefreshesOnlySelectedTarget() async {
        let clock = ManualRefreshClock()
        let events = ManualRefreshEventSource()
        let before = target()
        let afterIdentity = GitBranchRefreshIdentity(branchName: before.branchName, sha: "sha-2",
            upstream: "refs/remotes/origin/feature", upstreamSHA: "upstream-2", headBranch: "feature",
            headSHA: "sha-2", configurationFingerprint: "remote-2")
        let refreshed = expectation(description: "changed Git identity refreshed")
        var requested: [RefreshTarget] = []
        let coordinator = RefreshCoordinator(policy: GitHubRefreshPolicy(jitterFraction: 0), clock: clock,
            eventSource: events, refresh: { next in requested.append(next); refreshed.fulfill(); return self.status(now: clock.now, sha: next.sha) },
            readIdentity: { _ in afterIdentity },
            identityChanged: { old, identity in
                let next = RefreshTarget(path: old.path, branchID: old.branchID, branchName: identity.branchName,
                    identity: identity, gitPath: old.gitPath, tracksWorktreeHead: old.tracksWorktreeHead)
                return RefreshIdentityUpdate(target: next, status: self.status(now: clock.now, sha: identity.sha))
            })

        coordinator.select(before, status: status(now: clock.now))
        events.emitChange()
        events.emitChange()
        events.emitChange()
        clock.advance(by: 0.25)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.map(\.branchID), [before.branchID])
        XCTAssertEqual(requested.first?.sha, "sha-2")
    }

    func testFreshSelectedCacheDoesNotRefreshUntilScheduledPoll() {
        let clock = ManualRefreshClock()
        let events = ManualRefreshEventSource()
        let fresh = status(now: clock.now)
        var calls = 0
        let coordinator = RefreshCoordinator(policy: GitHubRefreshPolicy(jitterFraction: 0), clock: clock,
            eventSource: events, refresh: { _ in calls += 1; return fresh },
            readIdentity: { _ in nil }, identityChanged: { _, _ in nil })

        coordinator.select(target(), status: fresh)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(clock.scheduledIntervals.last, 60)
    }

    func testLinkedWorktreeIdentityReadsItsHEADAndWatchesSharedRefs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshIdentity-\(UUID().uuidString)")
        let common = root.appendingPathComponent("repo.git")
        let gitDirectory = common.appendingPathComponent("worktrees/linked")
        for path in [gitDirectory, common.appendingPathComponent("refs/heads"),
                     common.appendingPathComponent("refs/remotes/upstream")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = GitRefreshMetadataRunner(gitDirectory: gitDirectory.path,
                                              commonDirectory: common.path, headBranch: "checked-out")
        let git = GitService(runner: runner)

        let identity = try git.refreshIdentity(repositoryPath: root.path, branchName: "previous", tracksWorktreeHead: true)
        XCTAssertEqual(identity.branchName, "checked-out")
        XCTAssertEqual(identity.sha, "branch-sha")
        XCTAssertEqual(identity.upstreamSHA, "upstream-sha")
        XCTAssertEqual(identity.headSHA, "head-sha")

        let paths = try git.refreshWatchPaths(repositoryPath: root.path, branchName: "previous", tracksWorktreeHead: true)
        XCTAssertTrue(paths.contains(gitDirectory.path))
        XCTAssertTrue(paths.contains(common.path))
        XCTAssertTrue(paths.contains(common.appendingPathComponent("refs/heads").path))
        XCTAssertTrue(paths.contains(common.appendingPathComponent("refs/remotes/upstream").path))
    }

    private func target() -> RefreshTarget {
        let identity = GitBranchRefreshIdentity(branchName: "feature", sha: "sha-1",
            upstream: "refs/remotes/origin/feature", upstreamSHA: "upstream-1",
            headBranch: "feature", headSHA: "sha-1", configurationFingerprint: "remote-1")
        return RefreshTarget(path: "/repo", branchID: "feature", branchName: "feature", identity: identity)
    }

    private func status(now: Date, sha: String = "sha-1", activeCI: Bool = false) -> GitHubStatus {
        let fetched = GitHubFetchState(phase: .loaded, fetchedAt: now)
        let actions = activeCI ? [GitHubActionRun(id: "run-1", name: "Build", status: "in_progress",
            conclusion: nil, url: nil, headSHA: sha, event: "push", runID: 1, attempt: 1,
            repositoryName: "example/repo", isCurrent: true)] : []
        return GitHubStatus(issues: [], pullRequests: [], actions: actions, error: nil, isLoaded: true,
            mergeEvidenceLoaded: true, checks: [], pullRequestFetch: fetched, issueFetch: fetched,
            checkFetch: fetched, actionFetch: fetched, localSHA: sha)
    }
}
