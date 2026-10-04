import Foundation

public struct RepositoryScanResult: Sendable {
    public let snapshot: RepositorySnapshot
    public let sessionNotes: [String]
}

public struct RepositoryLocalScanResult: Sendable {
    public let snapshot: RepositorySnapshot
    public let sessionNotes: [String]

    public init(snapshot: RepositorySnapshot, sessionNotes: [String]) {
        self.snapshot = snapshot
        self.sessionNotes = sessionNotes
    }
}

public protocol RepositoryScanning: Sendable {
    func scanSessions() -> SessionDiscoveryResult
    func readGit(repositoryPath: String, discovery: SessionDiscoveryResult) throws -> RepositoryLocalScanResult
    func enrichGitHub(local: RepositoryLocalScanResult, progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void) async -> RepositorySnapshot
}

public final class RepositoryScanService: @unchecked Sendable, RepositoryScanning {
    private let git: GitService
    private let sessions: SessionService
    private let github: GitHubService

    public init(git: GitService = GitService(), sessions: SessionService = SessionService(), github: GitHubService = GitHubService()) {
        self.git = git
        self.sessions = sessions
        self.github = github
    }

    public func scanSessions() -> SessionDiscoveryResult {
        sessions.discover()
    }

    public func readGit(repositoryPath: String, discovery: SessionDiscoveryResult) throws -> RepositoryLocalScanResult {
        let local = try git.snapshot(repositoryPath: repositoryPath, sessions: discovery.sessions)
        return RepositoryLocalScanResult(snapshot: local, sessionNotes: discovery.notes)
    }

    public func localScan(repositoryPath: String) throws -> RepositoryLocalScanResult {
        try readGit(repositoryPath: repositoryPath, discovery: scanSessions())
    }

    public func scan(repositoryPath: String) async throws -> RepositoryScanResult {
        let local = try localScan(repositoryPath: repositoryPath)
        let snapshot = await enrichGitHub(local: local)
        return RepositoryScanResult(snapshot: snapshot, sessionNotes: local.sessionNotes)
    }

    public func enrichGitHub(local: RepositoryLocalScanResult, progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }) async -> RepositorySnapshot {
        let branches = local.snapshot.branches.filter { !$0.isDetachedGroup }
        guard !branches.isEmpty else { return local.snapshot }
        let statuses = await github.summariesAsync(repositoryPath: local.snapshot.path, branches: branches)
        guard !Task.isCancelled else { return local.snapshot }
        progress(1, 1)
        var enrichedBranches: [BranchInfo] = []
        let stackedBudget = GitHubStackedPRBudget()
        for branch in local.snapshot.branches {
            guard !branch.isDetachedGroup else { enrichedBranches.append(branch); continue }
            let status = statuses[branch.id] ?? .unavailable
            var enriched = branch.resolvingMergeEvidence(defaultBranch: local.snapshot.defaultBranch, status: status)
            if enriched.mergeEvidence != .gitAncestor,
               case .githubVerified = enriched.mergeEvidence {
                enrichedBranches.append(enriched)
                continue
            }
            if enriched.mergeEvidence != .gitAncestor,
               let defaultBranch = local.snapshot.defaultBranch,
               let pr = status.pullRequests.first(where: {
                   $0.state.uppercased() == "MERGED" && $0.mergedAt != nil &&
                   $0.headRefName == branch.name && $0.headRefOid == branch.sha &&
                   $0.baseRefName != nil && $0.baseRefName != defaultBranch
               }) {
                if await github.verifyStackedPRChain(repositoryPath: local.snapshot.path,
                    branch: branch.name, localSHA: branch.sha, defaultBranch: defaultBranch,
                    status: status, budget: stackedBudget) != nil, let mergedAt = pr.mergedAt {
                    enriched = enriched.withMergeEvidence(.stackedPR(prNumber: pr.number, mergedAt: mergedAt))
                }
            }
            enrichedBranches.append(enriched)
        }
        return RepositorySnapshot(path: local.snapshot.path, defaultBranch: local.snapshot.defaultBranch, branches: enrichedBranches)
    }
}
