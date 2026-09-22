import Foundation

public struct RepositoryScanResult: Sendable {
    public let snapshot: RepositorySnapshot
    public let sessionNotes: [String]
}

public final class RepositoryScanService: @unchecked Sendable {
    private let git: GitService
    private let sessions: SessionService
    private let github: GitHubService

    public init(git: GitService = GitService(), sessions: SessionService = SessionService(), github: GitHubService = GitHubService()) {
        self.git = git
        self.sessions = sessions
        self.github = github
    }

    public func scan(repositoryPath: String) async throws -> RepositoryScanResult {
        let discovery = sessions.discover()
        let local = try git.snapshot(repositoryPath: repositoryPath, sessions: discovery.sessions)
        let githubStatuses = await withTaskGroup(of: (String, GitHubStatus).self, returning: [String: GitHubStatus].self) { group in
            for branch in local.branches where !branch.isDetachedGroup {
                group.addTask {
                    (branch.id, self.github.status(repositoryPath: local.path, branch: branch.name))
                }
            }
            var statuses: [String: GitHubStatus] = [:]
            for await (branchID, status) in group { statuses[branchID] = status }
            return statuses
        }
        let enrichedBranches = local.branches.map { branch in
            BranchInfo(id: branch.id, name: branch.name, sha: branch.sha, upstream: branch.upstream, ahead: branch.ahead, behind: branch.behind, isMerged: branch.isMerged, remoteGone: branch.remoteGone, lastCommitAt: branch.lastCommitAt, isDefaultBranch: branch.isDefaultBranch, isDetachedGroup: branch.isDetachedGroup, defaultAhead: branch.defaultAhead, defaultBehind: branch.defaultBehind, worktrees: branch.worktrees, github: githubStatuses[branch.id] ?? .unavailable)
        }
        return RepositoryScanResult(snapshot: RepositorySnapshot(path: local.path, defaultBranch: local.defaultBranch, branches: enrichedBranches), sessionNotes: discovery.notes)
    }
}
