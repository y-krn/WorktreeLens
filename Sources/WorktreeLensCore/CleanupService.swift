import Foundation

public final class CleanupService: @unchecked Sendable {
    private let git: GitService
    private let sessions: SessionService

    public init(git: GitService = GitService(), sessions: SessionService = SessionService()) {
        self.git = git
        self.sessions = sessions
    }

    public func decide(worktree: WorktreeInfo, branch: BranchInfo? = nil, requireMerged: Bool = true, now: Date = Date(), staleDays: Int? = nil) -> CleanupDecision {
        if worktree.isLocked { return CleanupDecision(allowed: false, reason: .lockedWorktree) }
        if !worktree.isClean { return CleanupDecision(allowed: false, reason: .dirtyWorktree) }
        if worktree.hasActiveSession { return CleanupDecision(allowed: false, reason: .activeSession) }
        if worktree.hasUnknownSession { return CleanupDecision(allowed: false, reason: .unknownSessionActivity) }
        if worktree.isDetached {
            if staleDays != nil { return CleanupDecision(allowed: false, reason: .detachedWorktree) }
        } else if requireMerged && branch?.isMerged != true {
            return CleanupDecision(allowed: false, reason: branch == nil ? .missingBranch : .unmergedBranch)
        }
        if let staleDays {
            guard let lastActivity = worktree.lastActivity, now.timeIntervalSince(lastActivity) >= TimeInterval(staleDays * 86_400) else { return CleanupDecision(allowed: false, reason: .notStale) }
        }
        return CleanupDecision(allowed: true)
    }

    public func previewRemoveWorktree(snapshot: RepositorySnapshot, path: String) -> CleanupPreview {
        guard let match = locateWorktree(snapshot, path: path) else {
            return CleanupPreview(operation: .removeWorktree, repositoryPath: snapshot.path, items: [CleanupPreviewItem(id: path, target: path, allowed: false, reason: .missingBranch)])
        }
        let decision = decide(worktree: match.worktree, branch: match.branch)
        return CleanupPreview(operation: .removeWorktree, repositoryPath: snapshot.path, items: [item(id: path, target: path, decision: decision)])
    }

    public func previewDeleteBranch(snapshot: RepositorySnapshot, name: String) -> CleanupPreview {
        let decision: CleanupDecision
        if let branch = snapshot.branches.first(where: { $0.name == name }) {
            decision = branchDecision(branch)
        } else {
            decision = CleanupDecision(allowed: false, reason: .missingBranch)
        }
        return CleanupPreview(operation: .deleteBranch, repositoryPath: snapshot.path, items: [item(id: name, target: name, decision: decision)])
    }

    public func previewPrune(snapshot: RepositorySnapshot) -> CleanupPreview {
        CleanupPreview(operation: .prune, repositoryPath: snapshot.path, items: [CleanupPreviewItem(id: "prune", target: "Unreachable worktree metadata", allowed: true)])
    }

    public func previewMergedBranches(snapshot: RepositorySnapshot) -> CleanupPreview {
        let items = snapshot.branches.filter { !$0.isDetachedGroup }.map { branch in
            item(id: branch.name, target: branch.name, decision: branchDecision(branch))
        }
        return CleanupPreview(operation: .deleteMergedBranches, repositoryPath: snapshot.path, items: items)
    }

    public func previewStaleWorktrees(snapshot: RepositorySnapshot, staleDays: Int, now: Date = Date()) -> CleanupPreview {
        let items = snapshot.branches.flatMap { branch in
            branch.worktrees.map { worktree in
                item(id: worktree.path, target: worktree.path, decision: decide(worktree: worktree, branch: branch, requireMerged: true, now: now, staleDays: staleDays))
            }
        }
        return CleanupPreview(operation: .removeStaleWorktrees, repositoryPath: snapshot.path, items: items, staleDays: staleDays)
    }

    public func previewRemoteGoneBranches(snapshot: RepositorySnapshot) -> CleanupPreview {
        let items = snapshot.branches.filter { $0.remoteGone }.map { branch in
            item(id: branch.name, target: branch.name, decision: branchDecision(branch))
        }
        return CleanupPreview(operation: .deleteRemoteGoneBranches, repositoryPath: snapshot.path, items: items)
    }

    public func execute(_ preview: CleanupPreview) -> [String] {
        var completed: [String] = []
        let currentSessions = sessions.discover().sessions
        for target in preview.allowedItems {
            switch preview.operation {
            case .removeWorktree:
                if executeRemoveWorktree(repositoryPath: preview.repositoryPath, path: target.id, sessions: currentSessions) { completed.append(target.id) }
            case .deleteBranch:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id) { completed.append(target.id) }
            case .prune:
                if (try? git.pruneWorktrees(repositoryPath: preview.repositoryPath)) != nil { completed.append(target.id) }
            case .deleteMergedBranches:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id) { completed.append(target.id) }
            case .removeStaleWorktrees:
                if executeRemoveStale(repositoryPath: preview.repositoryPath, path: target.id, staleDays: preview.staleDays ?? 7, sessions: currentSessions) { completed.append(target.id) }
            case .deleteRemoteGoneBranches:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id) { completed.append(target.id) }
            }
        }
        return completed
    }

    private func branchDecision(_ branch: BranchInfo) -> CleanupDecision {
        if branch.isDetachedGroup { return CleanupDecision(allowed: false, reason: .detachedWorktree) }
        if branch.isDefaultBranch { return CleanupDecision(allowed: false, reason: .defaultBranch) }
        if !branch.isMerged { return CleanupDecision(allowed: false, reason: .unmergedBranch) }
        if !branch.worktrees.isEmpty { return CleanupDecision(allowed: false, reason: .worktreeAttached) }
        return CleanupDecision(allowed: true)
    }

    private func executeRemoveWorktree(repositoryPath: String, path: String, sessions: [SessionRecord]) -> Bool {
        guard let match = try? git.cleanupWorktree(repositoryPath: repositoryPath, path: path, sessions: sessions), decide(worktree: match.worktree, branch: match.branch).allowed else { return false }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    private func executeDeleteBranch(repositoryPath: String, name: String) -> Bool {
        guard let branch = try? git.cleanupBranch(repositoryPath: repositoryPath, name: name), branchDecision(branch).allowed else { return false }
        return (try? git.deleteBranch(repositoryPath: repositoryPath, branch: name)) != nil
    }

    private func executeRemoveStale(repositoryPath: String, path: String, staleDays: Int, sessions: [SessionRecord]) -> Bool {
        guard let match = try? git.cleanupWorktree(repositoryPath: repositoryPath, path: path, sessions: sessions) else { return false }
        guard decide(worktree: match.worktree, branch: match.branch, requireMerged: true, now: Date(), staleDays: staleDays).allowed else { return false }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    private func locateWorktree(_ snapshot: RepositorySnapshot, path: String) -> (worktree: WorktreeInfo, branch: BranchInfo)? {
        for branch in snapshot.branches {
            if let worktree = branch.worktrees.first(where: { $0.path == path }) { return (worktree, branch) }
        }
        return nil
    }

    private func item(id: String, target: String, decision: CleanupDecision) -> CleanupPreviewItem {
        CleanupPreviewItem(id: id, target: target, allowed: decision.allowed, reason: decision.reason)
    }
}
