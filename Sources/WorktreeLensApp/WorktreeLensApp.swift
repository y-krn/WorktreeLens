import SwiftUI
import UniformTypeIdentifiers
import AppKit
import WorktreeLensCore
#if KEYCHAIN_VERIFICATION
import Security
#endif

@main
struct WorktreeLensApp: App {
    @StateObject private var model: ApplicationModel
    @StateObject private var authentication: GitHubAuthenticationModel

    init() {
        let authentication = GitHubAuthenticationModel()
        _authentication = StateObject(wrappedValue: authentication)
        _model = StateObject(wrappedValue: ApplicationModel(github: GitHubService(api: GitHubAPIClient(authentication: authentication))))
        #if KEYCHAIN_VERIFICATION
        if CommandLine.arguments.contains("--verify-github-keychain") {
            do { try verifyGitHubKeychain(); exit(0) }
            catch { fputs("Keychain verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Worktree Lens") {
            ContentView(model: model)
                .frame(minWidth: 1_240, minHeight: 760)
                .tint(Color(red: 0.10, green: 0.54, blue: 0.56))
                .task { await authentication.restoreAccount() }
                .onAppear {
                    model.setApplicationActive(NSApp.isActive)
                    model.setGitHubMonitoringEnabled(authentication.account != nil)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.setApplicationActive(true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.setApplicationActive(false)
                }
                .onChange(of: authentication.account?.identifier) { _ in
                    model.invalidateGitHubAccountState(isAuthenticated: authentication.account != nil)
                }
        }
        Settings {
            GitHubAuthenticationSettings(model: authentication)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Register Repository…") { model.isImporterPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

enum CleanupExecutionState: Equatable {
    case idle
    case running
    case completed(Int)
}

protocol GitHubDetailLoading: Sendable {
    func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval) async -> GitHubStatus
    func statusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval) async -> GitHubStatus
    func refreshStatusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval) async -> GitHubStatus
}

extension GitHubDetailLoading {
    func statusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval) async -> GitHubStatus {
        await statusAsync(repositoryPath: repositoryPath, branch: branchInfo.name, timeout: timeout)
    }

    func refreshStatusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval) async -> GitHubStatus {
        await statusAsync(repositoryPath: repositoryPath, branchInfo: branchInfo, timeout: timeout)
    }
}

extension GitHubService: GitHubDetailLoading {}

@MainActor
final class ApplicationModel: ObservableObject {
    private struct RepositoryViewCache {
        var snapshot: RepositorySnapshot
        var sessionNotes: [String]
        var selection: RepositorySelection?
    }

    @Published var registeredPaths: [String]
    @Published var selectedPath: String?
    @Published var snapshot: RepositorySnapshot?
    @Published var selection: RepositorySelection?
    @Published var sessionNotes: [String] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var cleanupPreview: CleanupPreview?
    @Published var cleanupExecutionState: CleanupExecutionState = .idle
    @Published var isImporterPresented = false
    @Published var isLoading = false
    @Published var isCleanupPreviewLoading = false
    @Published var scanPhase: String?
    @Published var canCancelGitHub = false

    let repositoryStore: RepositoryStore
    let git: GitService
    let sessions: SessionService
    let github: GitHubService
    private let detailLoader: any GitHubDetailLoading
    private let cleanupExecutor: (@Sendable (CleanupPreview) -> CleanupExecutionResult)?
    let scanner: any RepositoryScanning
    lazy var cleanup = CleanupService(git: git, sessions: sessions, github: github)
    private var viewCache: [String: RepositoryViewCache] = [:]
    private var refreshToken = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskPath: String?
    private var githubDetailToken = UUID()
    private(set) var githubDetailTask: Task<Void, Never>?
    private var githubDetailTaskPath: String?
    private var cleanupPreviewToken = UUID()
    private let refreshClock: any RefreshClock
    private let refreshEventSource: any RefreshEventSource
    private let refreshPolicy: GitHubRefreshPolicy
    private let refreshJitter: @Sendable () -> Double
    private var refreshTargetResolutionToken = UUID()
    private var refreshIdentities: [String: GitBranchRefreshIdentity] = [:]
    private var githubMonitoringEnabled = false
    private lazy var refreshCoordinator: RefreshCoordinator = {
        let git = self.git
        return RefreshCoordinator(policy: refreshPolicy, clock: refreshClock, eventSource: refreshEventSource,
            jitter: refreshJitter,
            refresh: { [weak self] target in
                guard let self else { return nil }
                return await self.performAutomaticGitHubRefresh(target)
            },
            readIdentity: { target in
                await Task.detached {
                    try? git.refreshIdentity(repositoryPath: target.gitPath, branchName: target.branchName,
                                             tracksWorktreeHead: target.tracksWorktreeHead)
                }.value
            },
            identityChanged: { [weak self] target, identity in
                guard let self else { return nil }
                return await self.applyGitRefreshIdentity(target, identity: identity)
            })
    }()

    init(loadRepositories: Bool = true, repositoryStore: RepositoryStore = RepositoryStore(), git: GitService = GitService(), sessions: SessionService = SessionService(), github: GitHubService = GitHubService(), detailLoader: (any GitHubDetailLoading)? = nil, scanner injectedScanner: (any RepositoryScanning)? = nil, cleanupExecutor: (@Sendable (CleanupPreview) -> CleanupExecutionResult)? = nil, refreshClock: (any RefreshClock)? = nil, refreshEventSource: (any RefreshEventSource)? = nil, refreshPolicy: GitHubRefreshPolicy = GitHubRefreshPolicy(), refreshJitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }) {
        self.repositoryStore = repositoryStore
        self.git = git
        self.sessions = sessions
        self.github = github
        self.detailLoader = detailLoader ?? github
        self.cleanupExecutor = cleanupExecutor
        self.scanner = injectedScanner ?? RepositoryScanService(git: git, sessions: sessions, github: github)
        self.refreshClock = refreshClock ?? SystemRefreshClock()
        self.refreshEventSource = refreshEventSource ?? GitMetadataEventSource(git: git)
        self.refreshPolicy = refreshPolicy
        self.refreshJitter = refreshJitter
        registeredPaths = repositoryStore.paths
        selectedPath = nil
        if loadRepositories, let path = registeredPaths.first { selectRepository(path: path) }
    }

    func register(url: URL) {
        repositoryStore.add(url.path)
        registeredPaths = repositoryStore.paths
        selectRepository(path: URL(fileURLWithPath: url.path).standardizedFileURL.path)
    }

    func removeSelectedRepository() {
        guard let selectedPath else { return }
        refreshCoordinator.clear()
        invalidateRepositoryTasks()
        viewCache.removeValue(forKey: selectedPath)
        repositoryStore.remove(selectedPath)
        registeredPaths = repositoryStore.paths
        self.selectedPath = nil
        clearVisibleRepository()
        if let nextPath = registeredPaths.first { selectRepository(path: nextPath) }
    }

    func selectRepository(path: String) {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if selectedPath == canonicalPath { return }
        saveCurrentView()
        invalidateRepositoryTasks()
        refreshCoordinator.clear()
        selectedPath = canonicalPath
        errorMessage = nil
        statusMessage = nil
        if let cached = viewCache[canonicalPath] {
            snapshot = cached.snapshot
            sessionNotes = cached.sessionNotes
            selection = normalizedSelection(cached.selection, in: cached.snapshot)
            isLoading = false
            scanPhase = nil
            canCancelGitHub = false
            selectionDidChange()
        } else {
            clearVisibleRepository()
            refresh(path: canonicalPath)
        }
    }

    func invalidateGitHubAccountState(isAuthenticated: Bool) {
        githubMonitoringEnabled = isAuthenticated
        refreshCoordinator.clear()
        // Preserve the initial local scan: before its snapshot exists, there is no selection to reload.
        let preservingInitialScan = selectedPath != nil && isLoading && snapshot == nil && refreshTaskPath == selectedPath
        if preservingInitialScan {
            refreshTargetResolutionToken = UUID()
            githubDetailTask?.cancel()
            githubDetailTask = nil
            githubDetailTaskPath = nil
            githubDetailToken = UUID()
        } else {
            invalidateRepositoryTasks()
        }
        func withoutGitHub(_ snapshot: RepositorySnapshot) -> RepositorySnapshot {
            let branches = snapshot.branches.map { branch -> BranchInfo in
                let evidence: MergeEvidence
                if case .githubVerified = branch.mergeEvidence { evidence = .none }
                else { evidence = branch.mergeEvidence }
                return branch.withMergeEvidence(evidence, github: .unavailable)
            }
            return RepositorySnapshot(path: snapshot.path, defaultBranch: snapshot.defaultBranch,
                                      branches: branches, refreshedAt: snapshot.refreshedAt)
        }
        for path in Array(viewCache.keys) {
            guard var cached = viewCache[path] else { continue }
            cached.snapshot = withoutGitHub(cached.snapshot)
            viewCache[path] = cached
        }
        if let snapshot { self.snapshot = withoutGitHub(snapshot) }
        if !preservingInitialScan {
            isLoading = false
            canCancelGitHub = false
            scanPhase = nil
        }
        if isAuthenticated { selectionDidChange() }
    }

    func setGitHubMonitoringEnabled(_ enabled: Bool) {
        guard githubMonitoringEnabled != enabled else { return }
        githubMonitoringEnabled = enabled
        if enabled {
            selectionDidChange()
        } else {
            refreshTargetResolutionToken = UUID()
            refreshCoordinator.clear()
            githubDetailTask?.cancel()
            githubDetailTask = nil
            githubDetailTaskPath = nil
            githubDetailToken = UUID()
        }
    }

    func refreshSelected(includeGitHub: Bool = true) {
        guard let selectedPath else { return }
        refresh(path: selectedPath, includeGitHub: includeGitHub)
    }

    func refresh(path: String, includeGitHub: Bool = true) {
        guard selectedPath == path else { return }
        refreshTargetResolutionToken = UUID()
        refreshCoordinator.suspend()
        saveCurrentView()
        refreshTask?.cancel()
        githubDetailTask?.cancel()
        githubDetailToken = UUID()
        let token = UUID()
        refreshToken = token
        refreshTaskPath = path
        isLoading = true
        scanPhase = "Scanning sessions…"
        canCancelGitHub = false
        let scanner = self.scanner
        let github = self.github
        let previousBranches = !includeGitHub && self.snapshot?.path == path ? self.snapshot?.branches ?? [] : []
        refreshTask = Task.detached(priority: .userInitiated) {
            do {
                let discovery = scanner.scanSessions()
                let canReadGit = await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return false }
                    self.scanPhase = "Reading Git…"
                    return true
                }
                guard canReadGit else { return }
                let local = try scanner.readGit(repositoryPath: path, discovery: discovery)
                let cachedStatuses = includeGitHub
                    ? await github.cachedStatusesAsync(repositoryPath: path, branches: local.snapshot.branches)
                    : [:]
                let displayBranches = local.snapshot.branches.map { branch in
                    let status = includeGitHub
                        ? cachedStatuses[branch.id]
                        : previousBranches.first(where: { $0.id == branch.id && $0.name == branch.name && $0.sha == branch.sha })?.github
                    guard let status, status.localSHA == branch.sha else { return branch }
                    return branch.withGitHubStatus(includeGitHub ? status.markingRefresh() : status)
                }
                let enrichmentLocal = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: local.snapshot.path,
                    defaultBranch: local.snapshot.defaultBranch, branches: displayBranches, refreshedAt: local.snapshot.refreshedAt),
                    sessionNotes: local.sessionNotes)
                let canLoadGitHub = await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return false }
                    let previousSelection = self.snapshot?.path == enrichmentLocal.snapshot.path ? self.selection : nil
                    self.snapshot = enrichmentLocal.snapshot
                    self.sessionNotes = enrichmentLocal.sessionNotes
                    self.selection = self.normalizedSelection(previousSelection, in: enrichmentLocal.snapshot)
                    self.errorMessage = nil
                    self.saveCurrentView()
                    self.canCancelGitHub = includeGitHub
                    let total = local.snapshot.branches.contains { !$0.isDetachedGroup } ? 1 : 0
                    self.scanPhase = includeGitHub ? "Loading GitHub 0/\(total)…" : "Refreshing local state…"
                    return true
                }
                guard canLoadGitHub else { return }
                let enriched: RepositorySnapshot
                if includeGitHub {
                    enriched = await scanner.enrichGitHub(local: enrichmentLocal) { completed, total in
                        Task { @MainActor in
                            guard self.refreshToken == token else { return }
                            self.scanPhase = "Loading GitHub \(completed)/\(total)…"
                        }
                    }
                } else {
                    enriched = enrichmentLocal.snapshot
                }
                let cancelled = Task.isCancelled
                await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return }
                    if !cancelled {
                        self.snapshot = enriched
                        self.selection = self.normalizedSelection(self.selection, in: enriched)
                    }
                    self.isLoading = false
                    self.canCancelGitHub = false
                    self.scanPhase = nil
                    self.statusMessage = cancelled ? "GitHub loading cancelled" : nil
                    self.saveCurrentView()
                    if !cancelled { self.selectionDidChange() }
                }
            } catch {
                await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return }
                    self.snapshot = nil
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.canCancelGitHub = false
                    self.scanPhase = nil
                }
            }
        }
    }

    func cancelGitHub() {
        guard canCancelGitHub else { return }
        refreshTask?.cancel()
    }

    func branch(for worktree: WorktreeInfo) -> BranchInfo? {
        snapshot?.branches.first { $0.worktrees.contains { $0.id == worktree.id } }
    }

    var selectedBranchID: String? {
        guard let snapshot, let selection else { return nil }
        return selection.branchID(in: snapshot)
    }

    var selectedWorktreeID: String? {
        guard let snapshot, let selection else { return nil }
        return selection.worktreeID(in: snapshot)
    }

    func selectBranch(id: String) {
        guard snapshot?.branches.contains(where: { $0.id == id }) == true else {
            selection = nil
            return
        }
        selection = .branch(id)
        saveCurrentView()
    }

    func selectWorktree(id: String) {
        guard let snapshot, snapshot.branches.flatMap(\.worktrees).contains(where: { $0.id == id }) else {
            selection = nil
            return
        }
        selection = .worktree(id)
        saveCurrentView()
    }

    func selectionDidChange() {
        refreshCoordinator.clear()
        refreshTargetResolutionToken = UUID()
        let token = refreshTargetResolutionToken
        guard !isLoading, let path = selectedPath, let snapshot, snapshot.path == path,
              let branchID = selectedBranchID,
              let branch = snapshot.branches.first(where: { $0.id == branchID }), !branch.isDetachedGroup else {
            refreshCoordinator.select(nil)
            return
        }
        guard githubMonitoringEnabled else { return }
        loadGitHubDetailForCurrentSelection()
        let pendingBranch = branch
        let selectedWorktreePath = selectedWorktree()?.path
        let gitPath = selectedWorktreePath ?? path
        let tracksWorktreeHead = selectedWorktreePath != nil
        let provisional = RefreshTarget(path: path, branchID: branch.id, branchName: branch.name,
            identity: GitBranchRefreshIdentity(branchName: branch.name, sha: branch.sha, upstream: branch.upstream,
                                               upstreamSHA: nil, configurationFingerprint: ""),
            gitPath: gitPath, tracksWorktreeHead: tracksWorktreeHead)
        let git = self.git
        Task.detached {
            let identity = try? git.refreshIdentity(repositoryPath: gitPath, branchName: pendingBranch.name,
                                                    tracksWorktreeHead: tracksWorktreeHead)
            await MainActor.run {
                guard self.refreshTargetResolutionToken == token, self.selectedPath == path,
                      self.selectedBranchID == branchID, let current = self.selectedBranch() else { return }
                guard let identity else {
                    let fallback = RefreshTarget(path: path, branchID: current.id, branchName: current.name,
                        identity: GitBranchRefreshIdentity(branchName: current.name, sha: pendingBranch.sha,
                            upstream: pendingBranch.upstream, upstreamSHA: nil, configurationFingerprint: ""),
                        gitPath: gitPath, tracksWorktreeHead: tracksWorktreeHead)
                    let requestPending = self.githubDetailTaskPath == path && self.githubDetailTask != nil && !self.githubDetailTask!.isCancelled
                    self.refreshCoordinator.select(fallback, status: current.github, externalRefreshPending: requestPending)
                    return
                }
                let priorKey = self.refreshIdentityKey(path: path, branchID: current.id, gitPath: gitPath)
                let priorIdentity = self.refreshIdentities[priorKey]
                let identityChanged = priorIdentity.map { $0 != identity } ??
                    (identity.branchName != current.name || identity.sha != current.sha || identity.upstream != current.upstream)
                if identityChanged {
                    Task { @MainActor in
                        guard self.refreshTargetResolutionToken == token, self.selectedPath == path,
                              self.selectedBranchID == branchID else { return }
                        guard let update = await self.applyGitRefreshIdentity(provisional, identity: identity),
                              self.refreshTargetResolutionToken == token else {
                            self.refreshCoordinator.clear()
                            return
                        }
                        let requestPending = self.githubDetailTaskPath == path && self.githubDetailTask != nil && !self.githubDetailTask!.isCancelled
                        self.refreshCoordinator.select(update.target, status: update.status,
                                                       externalRefreshPending: requestPending)
                    }
                } else {
                    let resolved = RefreshTarget(path: path, branchID: current.id, branchName: current.name,
                        identity: identity, gitPath: gitPath, tracksWorktreeHead: tracksWorktreeHead)
                    self.refreshIdentities[priorKey] = identity
                    let requestPending = self.githubDetailTaskPath == path && self.githubDetailTask != nil && !self.githubDetailTask!.isCancelled
                    self.refreshCoordinator.select(resolved, status: current.github, externalRefreshPending: requestPending)
                }
            }
        }
    }

    private func loadGitHubDetailForCurrentSelection() {
        githubDetailTask?.cancel()
        githubDetailTask = nil
        githubDetailTaskPath = nil
        githubDetailToken = UUID()
        guard !isLoading,
              let path = selectedPath,
              let snapshot,
              snapshot.path == path,
              let branchID = selectedBranchID,
              let branch = snapshot.branches.first(where: { $0.id == branchID }),
              !branch.github.isLoaded else { return }

        githubDetailTask?.cancel()
        let token = UUID()
        githubDetailToken = token
        githubDetailTaskPath = path
        let refreshToken = self.refreshToken
        let detailLoader = self.detailLoader
        githubDetailTask = Task.detached(priority: .utility) {
            let status = await detailLoader.statusAsync(repositoryPath: path, branchInfo: branch, timeout: GitHubService.requestTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.githubDetailToken == token,
                      self.refreshToken == refreshToken,
                      self.selectedPath == path,
                      self.selectedBranchID == branchID,
                      self.snapshot?.path == path else { return }
                guard status.localSHA == nil || status.localSHA == branch.sha else {
                    self.githubDetailTask = nil
                    self.githubDetailTaskPath = nil
                    self.refreshCoordinator.externalRefreshFinished(status: nil)
                    return
                }
                guard let snapshot = self.snapshot,
                      let index = snapshot.branches.firstIndex(where: { $0.id == branchID && $0.sha == branch.sha }) else { return }
                var branches = snapshot.branches
                branches[index] = branches[index].resolvingMergeEvidence(defaultBranch: snapshot.defaultBranch, status: status)
                self.snapshot = RepositorySnapshot(path: snapshot.path, defaultBranch: snapshot.defaultBranch, branches: branches, refreshedAt: snapshot.refreshedAt)
                self.saveCurrentView()
                self.githubDetailTask = nil
                self.githubDetailTaskPath = nil
                self.refreshCoordinator.externalRefreshFinished(status: status)
            }
        }
    }

    func setApplicationActive(_ active: Bool) {
        refreshCoordinator.setForeground(active)
    }

    private func resumeRefreshCoordinatorAfterCleanup() {
        guard githubMonitoringEnabled, let path = selectedPath, let branch = selectedBranch(), !branch.isDetachedGroup else {
            refreshCoordinator.clear()
            return
        }
        refreshTargetResolutionToken = UUID()
        let token = refreshTargetResolutionToken
        let selectedWorktreePath = selectedWorktree()?.path
        let gitPath = selectedWorktreePath ?? path
        let tracksWorktreeHead = selectedWorktreePath != nil
        let git = self.git
        Task.detached {
            let identity = try? git.refreshIdentity(repositoryPath: gitPath, branchName: branch.name,
                                                    tracksWorktreeHead: tracksWorktreeHead)
            await MainActor.run {
                guard self.refreshTargetResolutionToken == token, self.selectedPath == path,
                      self.selectedBranchID == branch.id, let current = self.selectedBranch() else { return }
                let localIdentity = identity ?? GitBranchRefreshIdentity(branchName: current.name, sha: current.sha,
                    upstream: current.upstream, upstreamSHA: nil, configurationFingerprint: "")
                let target = RefreshTarget(path: path, branchID: current.id, branchName: current.name,
                    identity: localIdentity, gitPath: gitPath, tracksWorktreeHead: tracksWorktreeHead)
                self.refreshCoordinator.select(target, status: current.github, suppressImmediateRefresh: true)
            }
        }
    }

    func performAutomaticGitHubRefresh(_ target: RefreshTarget) async -> GitHubStatus? {
        guard selectedPath == target.path, selectedBranchID == target.branchID,
              let currentSnapshot = snapshot, currentSnapshot.path == target.path,
              let index = currentSnapshot.branches.firstIndex(where: { $0.id == target.branchID && $0.name == target.branchName && $0.sha == target.sha }) else { return nil }
        githubDetailTask?.cancel()
        githubDetailTask = nil
        githubDetailTaskPath = nil
        let token = UUID()
        githubDetailToken = token
        let requestBranch = currentSnapshot.branches[index]
        var refreshingBranches = currentSnapshot.branches
        refreshingBranches[index] = requestBranch.withGitHubStatus(requestBranch.github.markingRefresh())
        snapshot = RepositorySnapshot(path: currentSnapshot.path, defaultBranch: currentSnapshot.defaultBranch,
                                      branches: refreshingBranches, refreshedAt: currentSnapshot.refreshedAt)
        saveCurrentView()
        let status = await detailLoader.refreshStatusAsync(repositoryPath: target.path, branchInfo: requestBranch,
                                                           timeout: GitHubService.requestTimeout)
        guard status.localSHA == nil || status.localSHA == target.sha else { return nil }
        guard githubDetailToken == token, selectedPath == target.path, selectedBranchID == target.branchID,
              let latest = snapshot, latest.path == target.path,
              let latestIndex = latest.branches.firstIndex(where: { $0.id == target.branchID && $0.sha == target.sha }) else { return nil }
        var branches = latest.branches
        let updatedBranch = branches[latestIndex]
        branches[latestIndex] = updatedBranch.resolvingMergeEvidence(defaultBranch: latest.defaultBranch, status: status)
        snapshot = RepositorySnapshot(path: latest.path, defaultBranch: latest.defaultBranch,
                                      branches: branches, refreshedAt: latest.refreshedAt)
        saveCurrentView()
        return status
    }

    private func applyGitRefreshIdentity(_ target: RefreshTarget, identity: GitBranchRefreshIdentity) async -> RefreshIdentityUpdate? {
        guard selectedPath == target.path, let current = snapshot, current.path == target.path,
              let sourceIndex = current.branches.firstIndex(where: { $0.id == target.branchID && $0.name == target.branchName }) else { return nil }
        githubDetailTask?.cancel()
        githubDetailTask = nil
        githubDetailTaskPath = nil
        githubDetailToken = UUID()
        var branches = current.branches
        var destinationIndex = sourceIndex
        if target.tracksWorktreeHead && identity.branchName != target.branchName {
            guard case .worktree(let selectedWorktreeID) = selection,
                  let moved = branches[sourceIndex].worktrees.first(where: { $0.id == selectedWorktreeID }),
                  let resolvedIndex = branches.firstIndex(where: { $0.name == identity.branchName }) else { return nil }
            destinationIndex = resolvedIndex
            let movedWorktree = WorktreeInfo(id: moved.id, path: moved.path, branch: identity.branchName,
                head: identity.headSHA, isBare: moved.isBare, isLocked: moved.isLocked,
                isDetached: moved.isDetached, isClean: moved.isClean, stagedCount: moved.stagedCount,
                unstagedCount: moved.unstagedCount, untrackedCount: moved.untrackedCount,
                lastActivity: moved.lastActivity, defaultAhead: moved.defaultAhead,
                defaultBehind: moved.defaultBehind, sessions: moved.sessions)
            let source = branches[sourceIndex]
            branches[sourceIndex] = BranchInfo(id: source.id, name: source.name, sha: source.sha,
                upstream: source.upstream, ahead: source.ahead, behind: source.behind,
                isMerged: source.isMerged, remoteGone: source.remoteGone, lastCommitAt: source.lastCommitAt,
                isDefaultBranch: source.isDefaultBranch, isDetachedGroup: source.isDetachedGroup,
                defaultAhead: source.defaultAhead, defaultBehind: source.defaultBehind,
                worktrees: source.worktrees.filter { $0.id != selectedWorktreeID }, github: source.github,
                mergeEvidence: source.mergeEvidence)
            let destination = branches[destinationIndex]
            branches[destinationIndex] = BranchInfo(id: destination.id, name: destination.name,
                sha: destination.sha, upstream: destination.upstream, ahead: destination.ahead,
                behind: destination.behind, isMerged: destination.isMerged, remoteGone: destination.remoteGone,
                lastCommitAt: destination.lastCommitAt, isDefaultBranch: destination.isDefaultBranch,
                isDetachedGroup: destination.isDetachedGroup, defaultAhead: destination.defaultAhead,
                defaultBehind: destination.defaultBehind, worktrees: destination.worktrees + [movedWorktree],
                github: destination.github, mergeEvidence: destination.mergeEvidence)
        } else if target.tracksWorktreeHead && identity.headBranch == nil {
            return nil
        }
        let previousBranch = branches[destinationIndex]
        let updated = previousBranch.withRefreshIdentity(identity, github: .unavailable)
        let resolutionToken = refreshTargetResolutionToken
        let cachedStatuses = await github.cachedStatusesAsync(repositoryPath: target.path, branches: [updated])
        guard refreshTargetResolutionToken == resolutionToken, selectedPath == target.path else { return nil }
        let status = cachedStatuses[updated.id] ?? .unavailable
        branches[destinationIndex] = updated.resolvingMergeEvidence(defaultBranch: current.defaultBranch, status: status)
        snapshot = RepositorySnapshot(path: current.path, defaultBranch: current.defaultBranch,
                                      branches: branches, refreshedAt: current.refreshedAt)
        saveCurrentView()
        let updatedTarget = RefreshTarget(path: target.path, branchID: updated.id,
            branchName: updated.name, identity: identity, gitPath: target.gitPath,
            tracksWorktreeHead: target.tracksWorktreeHead)
        refreshIdentities[refreshIdentityKey(path: target.path, branchID: updated.id, gitPath: target.gitPath)] = identity
        return RefreshIdentityUpdate(target: updatedTarget, status: status)
    }

    private func refreshIdentityKey(path: String, branchID: String, gitPath: String) -> String {
        "\(path)\u{0}\(branchID)\u{0}\(gitPath)"
    }

    private func invalidateRepositoryTasks() {
        refreshTargetResolutionToken = UUID()
        refreshTask?.cancel()
        githubDetailTask?.cancel()
        refreshToken = UUID()
        githubDetailToken = UUID()
        refreshTask = nil
        refreshTaskPath = nil
        githubDetailTask = nil
        githubDetailTaskPath = nil
    }

    private func invalidateRepositoryTasks(for path: String) {
        if selectedPath == path { refreshTargetResolutionToken = UUID() }
        if refreshTaskPath == path {
            refreshTask?.cancel()
            refreshToken = UUID()
            refreshTask = nil
            refreshTaskPath = nil
        }
        if githubDetailTaskPath == path {
            githubDetailTask?.cancel()
            githubDetailToken = UUID()
            githubDetailTask = nil
            githubDetailTaskPath = nil
        }
    }

    private func clearVisibleRepository() {
        snapshot = nil
        selection = nil
        sessionNotes = []
        isLoading = false
        scanPhase = nil
        canCancelGitHub = false
    }

    private func saveCurrentView() {
        guard !isLoading, let selectedPath, let snapshot, snapshot.path == selectedPath else { return }
        viewCache[selectedPath] = RepositoryViewCache(snapshot: snapshot, sessionNotes: sessionNotes, selection: selection)
    }

    private func normalizedSelection(_ selection: RepositorySelection?, in snapshot: RepositorySnapshot) -> RepositorySelection? {
        if let selection, let branchID = selection.branchID(in: snapshot) {
            switch selection {
            case .branch:
                return .branch(branchID)
            case .worktree(let worktreeID):
                return snapshot.branches.flatMap(\.worktrees).contains { $0.id == worktreeID } ? .worktree(worktreeID) : .branch(branchID)
            }
        }
        return snapshot.branches.first.flatMap { branch in
            branch.worktrees.first.map { .worktree($0.id) } ?? .branch(branch.id)
        }
    }

    func selectedWorktree() -> WorktreeInfo? {
        guard let selectedWorktreeID else { return nil }
        return snapshot?.branches.flatMap(\.worktrees).first { $0.id == selectedWorktreeID }
    }

    func selectedBranch() -> BranchInfo? {
        guard let selectedBranchID else { return nil }
        return snapshot?.branches.first { $0.id == selectedBranchID }
    }

    func requestCleanupAfterMenuDismissal(_ request: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: request)
    }

    func requestRemoveSelectedWorktree() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path, let worktree = selectedWorktree() else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewRemoveWorktree(snapshot: snapshot, path: worktree.path) }
    }

    func requestDeleteSelectedBranch() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path, let branch = selectedBranch() else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewDeleteBranch(snapshot: snapshot, name: branch.name) }
    }

    func requestDeleteSelectedBranchAndWorktrees() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path, let branch = selectedBranch() else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewDeleteBranchAndWorktrees(snapshot: snapshot, name: branch.name) }
    }

    func requestDeleteMergedBranches() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewMergedBranches(snapshot: snapshot) }
    }

    func executeCleanup(_ preview: CleanupPreview) {
        guard cleanupExecutionState == .idle, !isCleanupPreviewLoading, cleanupPreview?.id == preview.id else { return }
        let repositoryPath = URL(fileURLWithPath: preview.repositoryPath).standardizedFileURL.path
        if selectedPath == repositoryPath { refreshCoordinator.suspend() }
        invalidateRepositoryTasks(for: repositoryPath)
        if selectedPath == repositoryPath {
            if let cached = viewCache[repositoryPath], cached.snapshot.path == repositoryPath {
                snapshot = cached.snapshot
                sessionNotes = cached.sessionNotes
                selection = normalizedSelection(cached.selection, in: cached.snapshot)
                isLoading = false
                scanPhase = nil
                canCancelGitHub = false
            } else {
                isLoading = true
                scanPhase = "Cleaning up…"
                canCancelGitHub = false
            }
        }
        cleanupExecutionState = .running
        let cleanup = self.cleanup
        let cleanupExecutor = self.cleanupExecutor
        Task.detached(priority: .userInitiated) {
            let result: CleanupExecutionResult
            if let cleanupExecutor { result = cleanupExecutor(preview) }
            else { result = await cleanup.executeAsync(preview) }
            await MainActor.run {
                guard self.cleanupPreview?.id == preview.id else { return }
                self.publishCleanupResult(result, repositoryPath: repositoryPath)
            }
        }
    }

    func publishCleanupResult(_ result: CleanupExecutionResult, repositoryPath: String) {
        cleanupExecutionState = .completed(result.count)
        if let failureReason = result.failureReason {
            statusMessage = result.count == 0
                ? "Cleanup stopped: \(failureReason)"
                : "Completed \(result.count) target(s); remaining cleanup stopped: \(failureReason)"
        } else {
            statusMessage = result.count == 0 ? "Completed 0 target(s) — no changes after final guard" : "Completed \(result.count) target(s)"
        }
        applyCleanupResult(result, repositoryPath: repositoryPath)
    }

    private func applyCleanupResult(_ result: CleanupExecutionResult, repositoryPath: String) {
        invalidateRepositoryTasks(for: repositoryPath)
        if result.requiresFullRefresh, selectedPath != repositoryPath {
            viewCache.removeValue(forKey: repositoryPath)
            return
        }
        if result.requiresFullRefresh {
            viewCache.removeValue(forKey: repositoryPath)
            if selectedPath == repositoryPath {
                isLoading = true
                scanPhase = nil
                refreshSelected(includeGitHub: false)
            }
            return
        }
        guard var cached = viewCache[repositoryPath], cached.snapshot.path == repositoryPath else {
            if selectedPath == repositoryPath {
                isLoading = true
                scanPhase = nil
                refreshSelected()
            }
            return
        }
        let original = cached.snapshot
        cached.snapshot = patchedSnapshot(original, with: result)
        let priorSelection = selectedPath == repositoryPath ? selection : cached.selection
        cached.selection = normalizedSelection(priorSelection, from: original, after: result, in: cached.snapshot)
        viewCache[repositoryPath] = cached
        if selectedPath == repositoryPath {
            snapshot = cached.snapshot
            sessionNotes = cached.sessionNotes
            selection = cached.selection
            isLoading = false
            scanPhase = nil
            canCancelGitHub = false
            resumeRefreshCoordinatorAfterCleanup()
        }
    }

    private func patchedSnapshot(_ snapshot: RepositorySnapshot, with result: CleanupExecutionResult) -> RepositorySnapshot {
        guard !result.removedWorktreePaths.isEmpty || !result.deletedLocalBranches.isEmpty else { return snapshot }
        let removedPaths = Set(result.removedWorktreePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let deletedBranches = Set(result.deletedLocalBranches)
        let branches = snapshot.branches.compactMap { branch -> BranchInfo? in
            guard !deletedBranches.contains(branch.name) else { return nil }
            let worktrees = branch.worktrees.filter { !removedPaths.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
            guard worktrees.count != branch.worktrees.count else { return branch }
            if branch.isDetachedGroup && worktrees.isEmpty { return nil }
            return BranchInfo(id: branch.id, name: branch.name, sha: branch.sha, upstream: branch.upstream, ahead: branch.ahead, behind: branch.behind, isMerged: branch.isMerged, remoteGone: branch.remoteGone, lastCommitAt: branch.lastCommitAt, isDefaultBranch: branch.isDefaultBranch, isDetachedGroup: branch.isDetachedGroup, defaultAhead: branch.defaultAhead, defaultBehind: branch.defaultBehind, worktrees: worktrees, github: branch.github, mergeEvidence: branch.mergeEvidence)
        }
        return RepositorySnapshot(path: snapshot.path, defaultBranch: snapshot.defaultBranch, branches: branches, refreshedAt: snapshot.refreshedAt)
    }

    private func normalizedSelection(_ selection: RepositorySelection?, from oldSnapshot: RepositorySnapshot, after result: CleanupExecutionResult, in newSnapshot: RepositorySnapshot) -> RepositorySelection? {
        if case .worktree(let id) = selection,
           let oldBranch = oldSnapshot.branches.first(where: { $0.worktrees.contains { $0.id == id } }),
           let oldWorktree = oldBranch.worktrees.first(where: { $0.id == id }),
           result.removedWorktreePaths.contains(URL(fileURLWithPath: oldWorktree.path).standardizedFileURL.path),
           newSnapshot.branches.contains(where: { $0.id == oldBranch.id }) {
            return .branch(oldBranch.id)
        }
        return normalizedSelection(selection, in: newSnapshot)
    }

    func cancelCleanupPreview() {
        guard cleanupExecutionState == .idle else { return }
        cleanupPreviewToken = UUID()
        cleanupPreview = nil
        cleanupExecutionState = .idle
    }

    func closeCleanupPreview() {
        guard case .completed = cleanupExecutionState else { return }
        cleanupPreview = nil
        cleanupExecutionState = .idle
    }

    private func requestPreview(_ operation: @escaping @Sendable () -> CleanupPreview) {
        if cleanupExecutionState == .running {
            statusMessage = "Cleanup already running"
            return
        }
        if case .completed = cleanupExecutionState, cleanupPreview == nil {
            cleanupExecutionState = .idle
        }
        guard cleanupExecutionState == .idle else {
            statusMessage = "Close the current cleanup preview first"
            return
        }
        let token = UUID()
        cleanupPreviewToken = token
        isCleanupPreviewLoading = true
        statusMessage = "Preparing cleanup…"
        Task.detached(priority: .userInitiated) {
            let preview = operation()
            await MainActor.run {
                guard self.cleanupPreviewToken == token else { return }
                self.isCleanupPreviewLoading = false
                self.cleanupExecutionState = .idle
                self.cleanupPreview = preview
                if preview.operation == .deleteMergedBranches, preview.displayedGroups.isEmpty {
                    self.statusMessage = "Nothing to clean up"
                } else {
                    self.statusMessage = nil
                }
            }
        }
    }

    private func canRequestCleanup() -> Bool {
        if cleanupExecutionState == .running {
            statusMessage = "Cleanup already running"
            return false
        }
        if case .completed = cleanupExecutionState, cleanupPreview == nil {
            cleanupExecutionState = .idle
        }
        guard let path = selectedPath, let snapshot, snapshot.path == path else {
            statusMessage = "Cleanup unavailable: no current repository snapshot"
            return false
        }
        return true
    }
}

struct ContentView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        HSplitView {
            repositorySidebar.frame(minWidth: 240, idealWidth: 270, maxWidth: 330)
            treePanel.frame(minWidth: 580)
            inspectorPanel.frame(minWidth: 340, idealWidth: 390, maxWidth: 470)
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.register(url: url) }
        }
        .alert("Worktree Lens", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.cleanupPreview) { preview in
            CleanupConfirmationView(preview: preview, model: model)
                .interactiveDismissDisabled(model.cleanupExecutionState != .idle)
        }
    }

    private var repositorySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Repositories", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Button { model.isImporterPresented = true } label: { Image(systemName: "plus") }
                    .help("Register repository")
            }
            .padding()
            Divider()
            List(selection: Binding(get: { model.selectedPath }, set: { path in
                if let path { model.selectRepository(path: path) }
            })) {
                ForEach(model.registeredPaths, id: \.self) { path in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(path))
                    .contextMenu {
                        Button("Remove Registration", role: .destructive) {
                            model.selectRepository(path: path)
                            model.removeSelectedRepository()
                        }
                    }
                }
            }
            if model.registeredPaths.isEmpty {
                EmptyStateView(title: "No repository", systemImage: "folder.badge.plus", message: "Register a local Git repository")
                    .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var treePanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.snapshot?.name ?? "Worktree Lens")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    if let snapshot = model.snapshot {
                        Text("Default branch: \(snapshot.defaultBranch ?? "Unknown")")
                            .font(.caption)
                            .foregroundStyle(snapshot.defaultBranch == nil ? .orange : .secondary)
                    } else {
                        Text("Register a repository to begin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let scanPhase = model.scanPhase { Text(scanPhase).font(.caption).foregroundStyle(.secondary) }
                if model.isLoading || model.isCleanupPreviewLoading { ProgressView().controlSize(.small) }
                if model.canCancelGitHub { Button("Cancel GitHub") { model.cancelGitHub() } }
                Button { model.refreshSelected() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { model.requestDeleteMergedBranches() } label: { Label("Clean Up…", systemImage: "trash") }
                    .help("Remove merged branches and their worktrees")
            }
            .padding()
            Divider()
            if let snapshot = model.snapshot {
                List(selection: $model.selection) {
                    Section {
                        ForEach(snapshot.branches) { branch in
                            DisclosureGroup {
                                ForEach(branch.worktrees) { worktree in
                                    DisclosureGroup {
                                        ForEach(worktree.sessions) { session in
                                            SessionTreeRow(session: session)
                                        }
                                    } label: {
                                        WorktreeRow(worktree: worktree)
                                            .contextMenu {
                                                Button("Copy Worktree Path") {
                                                    WorktreePathClipboard.copy(worktree, to: SystemClipboardWriter())
                                                }
                                                Button("Remove Worktree…") {
                                                    model.selectWorktree(id: worktree.id)
                                                    model.requestCleanupAfterMenuDismissal { model.requestRemoveSelectedWorktree() }
                                                }
                                            }
                                    }
                                    .tag(RepositorySelection.worktree(worktree.id))
                                }
                            } label: {
                                BranchRow(branch: branch)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        if !branch.isDetachedGroup {
                                            Button("Delete Branch…") {
                                                model.selectBranch(id: branch.id)
                                                model.requestCleanupAfterMenuDismissal { model.requestDeleteSelectedBranch() }
                                            }
                                            if !branch.worktrees.isEmpty {
                                                Button("Remove Worktree and Delete Branch…") {
                                                    model.selectBranch(id: branch.id)
                                                    model.requestCleanupAfterMenuDismissal { model.requestDeleteSelectedBranchAndWorktrees() }
                                                }
                                            }
                                        }
                                    }
                                    .tag(RepositorySelection.branch(branch.id))
                                    .onTapGesture { model.selectBranch(id: branch.id) }
                            }
                        }
                    } header: {
                        Text("Repo → Branch → Worktree → Session")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.selection) { _ in model.selectionDidChange() }
            } else {
                EmptyStateView(title: "No snapshot", systemImage: "arrow.triangle.2.circlepath", message: "Refresh after registering a Git repository")
            }
            if !model.sessionNotes.isEmpty {
                DisclosureGroup("Read-only session scan") {
                    ForEach(model.sessionNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if let statusMessage = model.statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
    }

    private var inspectorPanel: some View {
        ScrollView {
            if let worktree = model.selectedWorktree() {
                WorktreeDetail(worktree: worktree, branch: model.branch(for: worktree), defaultBranch: model.snapshot?.defaultBranch)
            } else if let branch = model.selectedBranch() {
                BranchDetail(branch: branch, defaultBranch: model.snapshot?.defaultBranch)
            } else {
                EmptyStateView(title: "Select a branch or worktree", systemImage: "sidebar.right", message: nil)
            }
        }
        .padding()
    }
}

struct BranchRow: View {
    let branch: BranchInfo

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: branch.isDetachedGroup ? "scissors" : (branch.isDefaultBranch ? "star" : "arrow.triangle.branch"))
                .foregroundStyle(branch.isDetachedGroup ? .orange : (branch.isDefaultBranch ? .yellow : (branch.isMerged ? .green : .blue)))
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name).fontWeight(.semibold)
                if branch.isDetachedGroup {
                    Text("Branch unavailable · detached HEAD").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(branch.sha.prefix(8)) · Δdefault +\(branch.defaultAhead) / -\(branch.defaultBehind)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Badge(text: branch.mergeStatus, color: branch.isMerged ? .green : .orange)
            if branch.remoteGone { Badge(text: "remote gone", color: .orange) }
        }
        .padding(.vertical, 3)
    }
}

struct WorktreeRow: View {
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: worktree.isDetached ? "scissors" : (worktree.isClean ? "checkmark.seal" : "exclamationmark.triangle"))
                .foregroundStyle(worktree.isDetached ? .orange : (worktree.isClean ? .green : .orange))
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: worktree.path).lastPathComponent).fontWeight(.medium)
                Text(worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !worktree.isClean { Badge(text: "dirty", color: .orange) }
            if !worktree.sessions.isEmpty { Text("\(worktree.sessions.count)").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

struct SessionTreeRow: View {
    let session: SessionRecord
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(activityColor).frame(width: 7, height: 7)
            Text(session.provider.rawValue).font(.caption.weight(.semibold))
            Text(session.title).lineLimit(1)
            Spacer()
            Text(session.activity.rawValue).font(.caption2).foregroundStyle(activityColor)
            if let updatedAt = session.updatedAt { Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary) }
            if let url = session.url { Button("Open") { openURL(url) }.buttonStyle(.link).font(.caption2) }
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
    }

    private var activityColor: Color {
        switch session.activity {
        case .active: return .red
        case .inactive: return .secondary
        case .unknown: return .orange
        }
    }
}

struct BranchDetail: View {
    let branch: BranchInfo
    let defaultBranch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Branch").font(.system(.title2, design: .rounded).weight(.bold))
            LabeledContent("Name", value: branch.name)
            LabeledContent("SHA", value: String(branch.sha.prefix(12)))
            LabeledContent("Default", value: branch.isDefaultBranch ? "Yes" : (defaultBranch ?? "Unknown"))
            LabeledContent("Merge status", value: branch.mergeStatus)
            LabeledContent("Default diff", value: "+\(branch.defaultAhead) / -\(branch.defaultBehind)")
            Divider()
            GitHubDetail(status: branch.github)
        }
    }
}

struct WorktreeDetail: View {
    let worktree: WorktreeInfo
    let branch: BranchInfo?
    let defaultBranch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Worktree").font(.system(.title2, design: .rounded).weight(.bold))
            LabeledContent("Path", value: worktree.path)
            LabeledContent("HEAD", value: String(worktree.head.prefix(12)))
            LabeledContent("Branch", value: worktree.branch ?? "Detached HEAD")
            LabeledContent("Status", value: worktree.isClean ? "Clean" : "Dirty")
            LabeledContent("Default diff", value: "+\(worktree.defaultAhead) / -\(worktree.defaultBehind)")
            if !worktree.isClean { Text("staged \(worktree.stagedCount) · unstaged \(worktree.unstagedCount) · untracked \(worktree.untrackedCount)").font(.caption).foregroundStyle(.orange) }
            if let defaultBranch { Text("Compared with \(defaultBranch)").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("Sessions").font(.headline)
            if worktree.sessions.isEmpty {
                Text("No explicit session path evidence").foregroundStyle(.secondary)
            } else {
                ForEach(worktree.sessions) { SessionDetail(session: $0) }
            }
            if let branch { GitHubDetail(status: branch.github) }
        }
    }
}

struct SessionDetail: View {
    let session: SessionRecord
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(session.provider.rawValue).font(.caption.bold()); Text(session.activity.rawValue).font(.caption2).foregroundStyle(.secondary) }
            Text(session.title)
            if let updatedAt = session.updatedAt { Text("Updated \(updatedAt, style: .relative)").font(.caption).foregroundStyle(.secondary) }
            Text(session.evidence).font(.caption2).foregroundStyle(.secondary)
            if let url = session.url { Button("Open session") { openURL(url) }.buttonStyle(.link) }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GitHubDetail: View {
    let status: GitHubStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub").font(.headline)
            if let error = status.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            ForEach([("PR", status.pullRequestFetch), ("Issues", status.issueFetch), ("Checks", status.checkFetch), ("Actions", status.actionFetch)], id: \.0) { name, fetch in
                Text("\(name) · \(fetch.phase.rawValue)\(fetch.stale ? " · stale" : "")\(fetch.error.map { " · " + $0 } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = fetch.fetchedAt { Text("Data \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                if let date = fetch.lastAttemptAt { Text("Checked \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(status.pullRequests) { pr in
                Text("PR #\(pr.number) · \(pr.state) · merge \(pr.mergeStateStatus ?? "unverified") · \(pr.mergeable ?? "UNKNOWN")").font(.caption)
                Text("\(pr.headRepositoryName ?? "unknown"):\(pr.headRefName ?? "unknown") → \(pr.baseRepositoryName ?? "unknown"):\(pr.baseRefName ?? "unknown") · SHA \(String((pr.headRefOid ?? "unknown").prefix(12)))")
                    .font(.caption2).foregroundStyle(.secondary)
                if let sha = pr.testMergeSHA { Text("Test merge SHA \(sha.prefix(12)) · conditions unverified").font(.caption2) }
            }
            ForEach(status.checks) { check in
                Text("\(check.kind) · \(check.name) · \(check.result) · SHA \(check.sha.prefix(12))").font(.caption)
            }
            ForEach(status.actions) { run in
                Text("Action · \(run.name) · \(run.conclusion ?? run.status) · \(run.isCurrent ? "local HEAD" : "history / unverified")")
                    .font(.caption)
                Text("SHA \((run.headSHA ?? "unknown").prefix(12)) · \(run.event ?? "unknown") · attempt \(run.attempt ?? 0)").font(.caption2)
            }
            ForEach(status.issues) { issue in
                Text("Issue \(issue.repositoryName ?? "unknown")#\(issue.number) · \(issue.title)").font(.caption)
            }
        }
    }
}

struct CleanupConfirmationView: View {
    let preview: CleanupPreview
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm cleanup").font(.system(.title2, design: .rounded).weight(.bold))
            Text(preview.operation.rawValue).foregroundStyle(.secondary)
            if preview.operation == .deleteMergedBranches, preview.displayedGroups.isEmpty {
                Text("Nothing to clean up")
                    .font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if !preview.isGrouped {
                        ForEach(preview.items) { item in
                            cleanupItem(item)
                        }
                    } else {
                        ForEach(preview.displayedGroups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.branchName).font(.headline)
                                ForEach(group.steps) { item in
                                    cleanupItem(item)
                                }
                            }
                        }
                    }
                }
            }
            Text("Allowed \(allowedCount) / total \(totalCount). Final guards run again immediately before each operation.")
                .font(.caption).foregroundStyle(.secondary)
            executionStatus
            actionArea
        }
        .padding(22)
        .frame(width: 600, height: 470)
    }

    @ViewBuilder
    private var executionStatus: some View {
        switch model.cleanupExecutionState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Running cleanup…")
            }
        case .completed(let count):
            VStack(alignment: .leading, spacing: 4) {
                Text("Completed \(count) target(s)")
                if count == 0 {
                    Text("No changes after final guard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        HStack {
            Spacer()
            switch model.cleanupExecutionState {
            case .idle:
                Button("Cancel") { model.cancelCleanupPreview() }
                Button("Run allowed targets") { model.executeCleanup(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled(allowedCount == 0)
            case .running:
                Button("Cancel") { model.cancelCleanupPreview() }
                    .disabled(true)
            case .completed:
                Button("Close") { model.closeCleanupPreview() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var allowedCount: Int {
        preview.isGrouped ? preview.displayedGroups.filter(\.allowed).count : preview.allowedItems.count
    }

    private var totalCount: Int {
        preview.isGrouped ? preview.displayedGroups.count : preview.items.count
    }

    @ViewBuilder
    private func cleanupItem(_ item: CleanupPreviewItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(item.allowed ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                if let step = item.step { Text(step.rawValue).font(.subheadline.weight(.semibold)) }
                Text(item.target).lineLimit(2)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(item.allowed ? .green : .secondary) }
                if let reason = item.reason {
                    Text(reason.message).font(.caption).foregroundStyle(.orange)
                    if case .processRunningDetails(let processes) = reason {
                        ForEach(processes, id: \.self) { process in
                            Text(process.summary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

extension CleanupPreview {
    /// Merged cleanup plans every branch; unmerged and default branches are never candidates, so they stay out of view.
    var displayedGroups: [CleanupPreviewGroup] {
        guard operation == .deleteMergedBranches else { return groups }
        return groups.filter { group in
            let reason = group.steps.last?.reason
            return reason != .unmergedBranch && reason != .defaultBranch
        }
    }

    var isGrouped: Bool { operation == .deleteMergedBranches || !groups.isEmpty }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


@MainActor
final class GitHubAuthenticationModel: ObservableObject, GitHubAuthenticationProviding {
    @Published var clientID: String
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var prompt: GitHubDevicePrompt?
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    private var provider: GitHubDeviceFlowProvider
    private let http = GitHubHTTPClient()
    private var configuredClientID: String
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    init() {
        let clientID = UserDefaults.standard.string(forKey: "githubAppClientID") ?? ""
        self.clientID = clientID
        configuredClientID = clientID
        provider = GitHubDeviceFlowProvider(clientID: clientID, http: http)
    }

    func authorization() async throws -> GitHubAuthorization { try await provider.authorization() }
    func invalidate(_ authorization: GitHubAuthorization) async throws { try await provider.invalidate(authorization) }
    func isCurrent(_ authorization: GitHubAuthorization) async -> Bool { await provider.isCurrent(authorization) }

    func restoreAccount() async {
        do { account = try await provider.state().account }
        catch { message = error.localizedDescription }
    }

    func signIn() {
        guard !isBusy else { return }
        let id = UUID()
        let previousAccountIdentifier = account?.identifier
        operationID = id
        isBusy = true; message = nil; prompt = nil
        task = Task {
            do {
                let configured = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                if configured != configuredClientID {
                    try await provider.logout()
                    if let previousAccountIdentifier {
                        await GitHubStateStore.shared.invalidateAccount(accountIdentifier: previousAccountIdentifier)
                    }
                    account = nil
                    provider = GitHubDeviceFlowProvider(clientID: configured, http: http)
                    configuredClientID = configured
                    UserDefaults.standard.set(configured, forKey: "githubAppClientID")
                }
                let account = try await provider.authenticate { prompt in
                    await MainActor.run {
                        guard self.operationID == id else { return }
                        self.prompt = prompt
                        NSWorkspace.shared.open(prompt.verificationURL)
                    }
                }
                guard operationID == id else { return }
                if let previousAccountIdentifier, previousAccountIdentifier != account.identifier {
                    await GitHubStateStore.shared.invalidateAccount(accountIdentifier: previousAccountIdentifier)
                }
                self.account = account
                message = "Signed in as \(account.login)."
            } catch is CancellationError {
                if operationID == id { message = "Sign-in cancelled." }
            } catch {
                if operationID == id { message = error.localizedDescription }
            }
            if operationID == id { isBusy = false; prompt = nil; task = nil }
        }
    }

    func cancel() { task?.cancel() }

    func logout() {
        let previousAccountIdentifier = account?.identifier
        task?.cancel()
        let id = UUID()
        operationID = id
        isBusy = true; prompt = nil; message = nil
        task = Task {
            do { try await provider.logout(); message = "Signed out." }
            catch { message = error.localizedDescription }
            if let previousAccountIdentifier {
                await GitHubStateStore.shared.invalidateAccount(accountIdentifier: previousAccountIdentifier)
            }
            account = nil
            if operationID == id { isBusy = false; task = nil }
        }
    }

    func verifyRead() {
        guard !isBusy else { return }
        let id = UUID()
        operationID = id
        isBusy = true; message = nil
        task = Task {
            do {
                let user = try await GitHubAPIClient(authentication: provider, http: http).currentUser()
                if operationID == id { account = user; message = "Authenticated API read succeeded: \(user.login)." }
            } catch is CancellationError {
                if operationID == id { message = "API read cancelled." }
            } catch {
                if operationID == id { message = error.localizedDescription }
            }
            if operationID == id {
                account = try? await provider.state().account
                isBusy = false; task = nil
            }
        }
    }
}

struct GitHubAuthenticationSettings: View {
    @ObservedObject var model: GitHubAuthenticationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub App Authentication").font(.headline)
            TextField("GitHub App client ID", text: $model.clientID).disabled(model.isBusy)
            Text("Enable Device Flow and install your GitHub App on the selected repositories before signing in.")
                .font(.caption).foregroundStyle(.secondary)
            if let account = model.account { Text("Account: \(account.login)") }
            if let prompt = model.prompt {
                Text("Enter code: \(prompt.userCode)").textSelection(.enabled)
                Link("Open GitHub authorization", destination: prompt.verificationURL)
                Text("Expires: \(prompt.expiresAt.formatted())").font(.caption)
            }
            HStack {
                Button("Sign In") { model.signIn() }.disabled(model.isBusy || model.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Verify API Read") { model.verifyRead() }.disabled(model.isBusy || model.account == nil)
                Button("Sign Out") { model.logout() }.disabled(model.isBusy || model.account == nil)
                if model.isBusy { Button("Cancel") { model.cancel() }; ProgressView().controlSize(.small) }
            }
            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
            Text("PR display and Cleanup verification use the authenticated GitHub API.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 520)
        .task { await model.restoreAccount() }
    }
}


#if KEYCHAIN_VERIFICATION
/// Compiled only by the signed-app verification build, never by normal Debug/Release builds.
private func verifyGitHubKeychain() throws {
    let clientID = "verification-" + UUID().uuidString
    let store = KeychainGitHubCredentialStore(clientID: clientID)
    defer { try? store.delete() }
    guard try store.load() == nil else { throw GitHubAuthError.invalidResponse }
    func fixture(_ token: String) -> GitHubCredentials {
        GitHubCredentials(accessToken: token, refreshToken: "synthetic-refresh", expiresAt: nil, refreshExpiresAt: nil,
                          account: GitHubAccount(id: 0, login: "verification"))
    }
    try store.save(fixture("synthetic-first"))
    guard try store.load()?.accessToken == "synthetic-first" else { throw GitHubAuthError.invalidResponse }
    try store.save(fixture("synthetic-updated"))
    guard try store.load()?.accessToken == "synthetic-updated" else { throw GitHubAuthError.invalidResponse }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ykrn.WorktreeLens.github.com." + clientID,
        kSecAttrAccount as String: "active-user", kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true, kSecReturnAttributes as String: true]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { throw GitHubAuthError.keychain(status) }
    guard let attributes = result as? [String: Any],
          attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
          attributes[kSecAttrSynchronizable as String] as? Bool == false else { throw GitHubAuthError.invalidResponse }
    try store.delete()
    guard try store.load() == nil else { throw GitHubAuthError.invalidResponse }
    print("Data Protection Keychain: save/read/update/delete passed; WhenUnlockedThisDeviceOnly; synchronization disabled.")
}
#endif
