import Foundation
import Dispatch
import Darwin
import WorktreeLensCore

struct RefreshTarget: Hashable, Sendable {
    let path: String
    let gitPath: String
    let branchID: String
    let branchName: String
    let identity: GitBranchRefreshIdentity
    let tracksWorktreeHead: Bool

    var sha: String { identity.sha }

    init(path: String, branchID: String, branchName: String, identity: GitBranchRefreshIdentity,
         gitPath: String? = nil, tracksWorktreeHead: Bool = false) {
        self.path = path
        self.gitPath = gitPath ?? path
        self.branchID = branchID
        self.branchName = branchName
        self.identity = identity
        self.tracksWorktreeHead = tracksWorktreeHead
    }
}

struct RefreshIdentityUpdate {
    let target: RefreshTarget
    let status: GitHubStatus
}

@MainActor
protocol RefreshTimerHandle: AnyObject {
    func cancel()
}

@MainActor
protocol RefreshClock: AnyObject {
    var now: Date { get }
    func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any RefreshTimerHandle
}

@MainActor
private final class TaskRefreshTimer: RefreshTimerHandle {
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        task = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() { task?.cancel(); task = nil }
}

@MainActor
final class SystemRefreshClock: RefreshClock {
    var now: Date { Date() }
    func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any RefreshTimerHandle {
        TaskRefreshTimer(interval: interval, action: action)
    }
}

@MainActor
protocol RefreshEventSubscription: AnyObject {
    func cancel()
}

@MainActor
protocol RefreshEventSource: AnyObject {
    func watch(target: RefreshTarget, onChange: @escaping @MainActor () -> Void) -> any RefreshEventSubscription
}

@MainActor
private final class DispatchWatchSubscription: RefreshEventSubscription {
    private var sources: [any DispatchSourceFileSystemObject] = []

    init(paths: [String], onChange: @escaping @MainActor () -> Void) {
        let queue = DispatchQueue(label: "WorktreeLens.git-metadata-watch", qos: .utility)
        for path in Set(paths) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend], queue: queue)
            source.setEventHandler { Task { @MainActor in onChange() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    deinit { sources.forEach { $0.cancel() } }
}

@MainActor
final class GitMetadataEventSource: RefreshEventSource {
    private let git: GitService
    init(git: GitService) { self.git = git }

    func watch(target: RefreshTarget, onChange: @escaping @MainActor () -> Void) -> any RefreshEventSubscription {
        let paths = (try? git.refreshWatchPaths(repositoryPath: target.gitPath, branchName: target.branchName,
                                                tracksWorktreeHead: target.tracksWorktreeHead)) ?? []
        return DispatchWatchSubscription(paths: paths, onChange: onChange)
    }
}

@MainActor
final class RefreshCoordinator {
    typealias Refresh = @MainActor (RefreshTarget) async -> GitHubStatus?
    typealias ReadIdentity = @Sendable (RefreshTarget) async -> GitBranchRefreshIdentity?
    typealias IdentityChanged = @MainActor (RefreshTarget, GitBranchRefreshIdentity) async -> RefreshIdentityUpdate?

    private let policy: GitHubRefreshPolicy
    private let clock: any RefreshClock
    private let eventSource: any RefreshEventSource
    private let refresh: Refresh
    private let readIdentity: ReadIdentity
    private let identityChanged: IdentityChanged
    private var target: RefreshTarget?
    private var status: GitHubStatus = .unavailable
    private var foreground = true
    private var inFlight = false
    private var externalRefreshPending = false
    private var requestGeneration = UUID()
    private var refreshTimer: (any RefreshTimerHandle)?
    private var debounceTimer: (any RefreshTimerHandle)?
    private var watch: (any RefreshEventSubscription)?
    private var automaticTask: Task<Void, Never>?
    private var unchangedPolls = 0
    private var lastFingerprint: String?
    private var lastAttemptAt: Date?
    private var identityCheckInFlight = false
    private var identityCheckGeneration = UUID()
    private let jitter: @Sendable () -> Double

    init(policy: GitHubRefreshPolicy = GitHubRefreshPolicy(), clock: any RefreshClock,
         eventSource: any RefreshEventSource, jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) },
         refresh: @escaping Refresh, readIdentity: @escaping ReadIdentity, identityChanged: @escaping IdentityChanged) {
        self.policy = policy
        self.clock = clock
        self.eventSource = eventSource
        self.jitter = jitter
        self.refresh = refresh
        self.readIdentity = readIdentity
        self.identityChanged = identityChanged
    }

    func select(_ target: RefreshTarget?, status: GitHubStatus = .unavailable, externalRefreshPending: Bool = false,
                suppressImmediateRefresh: Bool = false) {
        guard let target else { clear(); return }
        let changed = self.target != target
        if changed {
            cancelScheduledWork()
            automaticTask?.cancel()
            automaticTask = nil
            identityCheckGeneration = UUID()
            identityCheckInFlight = false
            requestGeneration = UUID()
            inFlight = false
            self.externalRefreshPending = false
            unchangedPolls = 0
            lastFingerprint = policy.fingerprint(status)
            lastAttemptAt = latestAttempt(status)
        }
        self.target = target
        self.status = status
        self.externalRefreshPending = externalRefreshPending
        guard foreground else { return }
        if changed { installWatch() }
        if externalRefreshPending { cancelRefreshTimer(); return }
        if suppressImmediateRefresh { scheduleNext(); return }
        if policy.needsRefresh(status, localSHA: target.sha, now: clock.now), retryIsDue(for: status) {
            beginRefresh()
        } else if changed || refreshTimer == nil {
            scheduleNext()
        }
    }

    func externalRefreshFinished(status newStatus: GitHubStatus?) {
        guard target != nil else { return }
        externalRefreshPending = false
        complete(status: newStatus)
    }

    func suspend() {
        cancelRefreshTimer()
        cancelDebounceTimer()
        automaticTask?.cancel()
        automaticTask = nil
        identityCheckGeneration = UUID()
        identityCheckInFlight = false
        requestGeneration = UUID()
        inFlight = false
        watch?.cancel()
        watch = nil
        externalRefreshPending = false
    }

    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        cancelRefreshTimer()
        cancelDebounceTimer()
        watch?.cancel()
        watch = nil
        if !active { identityCheckGeneration = UUID(); identityCheckInFlight = false }
        guard active, target != nil else { return }
        installWatch()
        metadataChanged()
    }

    func clear() {
        cancelScheduledWork()
        automaticTask?.cancel()
        automaticTask = nil
        identityCheckGeneration = UUID()
        identityCheckInFlight = false
        requestGeneration = UUID()
        target = nil
        status = .unavailable
        inFlight = false
        externalRefreshPending = false
        lastAttemptAt = nil
        lastFingerprint = nil
        unchangedPolls = 0
    }

    private func installWatch() {
        watch?.cancel()
        guard foreground, let target else { return }
        watch = eventSource.watch(target: target) { [weak self] in self?.metadataChanged() }
    }

    private func metadataChanged() {
        guard foreground, let target else { return }
        cancelRefreshTimer()
        cancelDebounceTimer()
        identityCheckInFlight = true
        identityCheckGeneration = UUID()
        let generation = identityCheckGeneration
        debounceTimer = clock.schedule(after: 0.25) { [weak self] in
            guard let self, self.target == target, self.identityCheckGeneration == generation, self.foreground else { return }
            self.debounceTimer = nil
            Task {
                let identity = await self.readIdentity(target)
                guard self.target == target, self.identityCheckGeneration == generation, self.foreground else { return }
                guard let identity, identity != target.identity else {
                    self.identityCheckInFlight = false
                    if self.policy.needsRefresh(self.status, localSHA: target.sha, now: self.clock.now), self.retryIsDue(for: self.status) {
                        self.beginRefresh()
                    } else {
                        self.scheduleNext()
                    }
                    return
                }
                guard let update = await self.identityChanged(target, identity) else {
                    guard self.identityCheckGeneration == generation else { return }
                    self.clear()
                    return
                }
                guard self.target == target, self.identityCheckGeneration == generation else { return }
                self.target = update.target
                self.status = update.status
                self.identityCheckInFlight = false
                self.requestGeneration = UUID()
                self.inFlight = false
                self.externalRefreshPending = false
                self.unchangedPolls = 0
                self.lastFingerprint = self.policy.fingerprint(self.status)
                self.lastAttemptAt = nil
                self.installWatch()
                self.beginRefresh()
            }
        }
    }

    private func beginRefresh() {
        guard foreground, !inFlight, !externalRefreshPending, !identityCheckInFlight, let target else { return }
        cancelRefreshTimer()
        inFlight = true
        let generation = UUID()
        requestGeneration = generation
        let before = policy.fingerprint(status)
        lastAttemptAt = clock.now
        automaticTask = Task {
            let updated = await refresh(target)
            guard self.requestGeneration == generation, self.target == target else { return }
            self.automaticTask = nil
            self.inFlight = false
            self.complete(status: updated, previousFingerprint: before)
        }
    }

    private func complete(status newStatus: GitHubStatus?, previousFingerprint: String? = nil) {
        if let newStatus { status = newStatus }
        let fingerprint = policy.fingerprint(status)
        let previous = previousFingerprint ?? lastFingerprint
        if let previous, previous == fingerprint { unchangedPolls += 1 }
        else { unchangedPolls = 0 }
        lastFingerprint = fingerprint
        lastAttemptAt = clock.now
        scheduleNext()
    }

    private func scheduleNext() {
        cancelRefreshTimer()
        guard foreground, !inFlight, !externalRefreshPending, !identityCheckInFlight, let target else { return }
        let seconds = policy.nextInterval(for: status, unchangedPolls: unchangedPolls, jitter: jitter())
        let generation = requestGeneration
        refreshTimer = clock.schedule(after: seconds) { [weak self] in
            guard let self, self.foreground, self.target == target, self.requestGeneration == generation else { return }
            self.refreshTimer = nil
            self.beginRefresh()
        }
    }

    private func retryIsDue(for status: GitHubStatus) -> Bool {
        let latest = latestAttempt(status) ?? lastAttemptAt
        guard let latest else { return true }
        if !status.isLoaded && ![status.pullRequestFetch, status.issueFetch, status.checkFetch, status.actionFetch].contains(where: { $0.phase == .failed || $0.phase == .incomplete }) {
            return true
        }
        return clock.now.timeIntervalSince(latest) >= policy.failureRetryInterval
    }

    private func latestAttempt(_ status: GitHubStatus) -> Date? {
        [status.pullRequestFetch, status.issueFetch, status.checkFetch, status.actionFetch].compactMap(\.lastAttemptAt).max()
    }

    private func cancelRefreshTimer() { refreshTimer?.cancel(); refreshTimer = nil }
    private func cancelDebounceTimer() { debounceTimer?.cancel(); debounceTimer = nil }
    private func cancelScheduledWork() {
        cancelRefreshTimer(); cancelDebounceTimer(); watch?.cancel(); watch = nil
    }
}
