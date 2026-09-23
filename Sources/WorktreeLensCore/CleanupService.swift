import Foundation

public final class CleanupService: @unchecked Sendable {
    private let git: GitService
    private let sessions: any SessionDiscovering
    private let github: GitHubService

    public init(git: GitService = GitService(), sessions: any SessionDiscovering = SessionService(), github: GitHubService = GitHubService()) {
        self.git = git
        self.sessions = sessions
        self.github = github
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
        return CleanupPreview(operation: .removeWorktree, repositoryPath: snapshot.path, items: [item(id: path, target: path, decision: decision, detail: match.branch.mergeStatus, expectedSHA: match.worktree.head)])
    }

    public func previewDeleteBranch(snapshot: RepositorySnapshot, name: String) -> CleanupPreview {
        let decision: CleanupDecision
        if let branch = snapshot.branches.first(where: { $0.name == name }) {
            decision = branchDecision(branch, defaultBranch: snapshot.defaultBranch)
        } else {
            decision = CleanupDecision(allowed: false, reason: .missingBranch)
        }
        let branch = snapshot.branches.first(where: { $0.name == name })
        return CleanupPreview(operation: .deleteBranch, repositoryPath: snapshot.path, items: [item(id: name, target: name, decision: decision, detail: branch?.mergeStatus, expectedSHA: branch?.sha)])
    }

    public func previewPrune(snapshot: RepositorySnapshot) -> CleanupPreview {
        CleanupPreview(operation: .prune, repositoryPath: snapshot.path, items: [CleanupPreviewItem(id: "prune", target: "Unreachable worktree metadata", allowed: true)])
    }

    public func previewMergedBranches(snapshot: RepositorySnapshot) -> CleanupPreview {
        let groups = snapshot.branches.filter { !$0.isDetachedGroup }.map { branch in
            mergedBranchGroup(branch: branch, defaultBranch: snapshot.defaultBranch)
        }
        return CleanupPreview(operation: .deleteMergedBranches, repositoryPath: snapshot.path, items: groupItems(groups), groups: groups)
    }

    public func previewStaleWorktrees(snapshot: RepositorySnapshot, staleDays: Int, now: Date = Date()) -> CleanupPreview {
        let items = snapshot.branches.flatMap { branch in
            branch.worktrees.map { worktree in
                item(id: worktree.path, target: worktree.path, decision: decide(worktree: worktree, branch: branch, requireMerged: true, now: now, staleDays: staleDays), detail: branch.mergeStatus, expectedSHA: branch.sha)
            }
        }
        return CleanupPreview(operation: .removeStaleWorktrees, repositoryPath: snapshot.path, items: items, staleDays: staleDays)
    }

    public func previewRemoteGoneBranches(snapshot: RepositorySnapshot) -> CleanupPreview {
        let groups = snapshot.branches.filter(\.remoteGone).map { branch in
            mergedBranchGroup(branch: branch, defaultBranch: snapshot.defaultBranch)
        }
        return CleanupPreview(operation: .deleteRemoteGoneBranches, repositoryPath: snapshot.path, items: groupItems(groups), groups: groups)
    }

    public func execute(_ preview: CleanupPreview) -> [String] {
        var completed: [String] = []
        if preview.operation == .deleteMergedBranches || preview.operation == .deleteRemoteGoneBranches {
            if !preview.groups.isEmpty {
                let needsSessionSafety = preview.groups.contains { $0.allowed && $0.steps.contains { $0.step == .removeWorktree } }
                let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
                if needsSessionSafety && sessionCache == nil { return completed }
                let context: CleanupRepositoryContext?
                let canonicalPath: String
                if preview.groups.count == 1 && !needsSessionSafety {
                    guard let path = try? git.canonicalRepositoryPath(preview.repositoryPath) else { return completed }
                    canonicalPath = path
                    context = nil
                } else {
                    guard let cleanupContext = try? git.cleanupContext(repositoryPath: preview.repositoryPath), cleanupContext.defaultBranch != nil else { return completed }
                    canonicalPath = cleanupContext.path
                    context = cleanupContext
                }
                for group in preview.groups where group.allowed {
                    if executeMergedBranch(repositoryPath: canonicalPath, canonicalPath: canonicalPath, context: context, group: group, sessionCache: sessionCache) {
                        completed.append(group.branchName)
                    }
                }
            } else {
                for target in preview.allowedItems {
                    if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id, expectedSHA: target.expectedSHA) {
                        completed.append(target.id)
                    }
                }
            }
            return completed
        }

        let needsSessionSafety = preview.operation == .removeWorktree || preview.operation == .removeStaleWorktrees
        let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
        if needsSessionSafety && sessionCache == nil { return completed }
        let context = needsSessionSafety ? try? git.cleanupContext(repositoryPath: preview.repositoryPath) : nil
        if needsSessionSafety && context == nil { return completed }
        for target in preview.allowedItems {
            switch preview.operation {
            case .removeWorktree:
                if executeRemoveWorktree(repositoryPath: preview.repositoryPath, path: target.id, expectedSHA: target.expectedSHA, sessionCache: sessionCache, context: context) { completed.append(target.id) }
            case .deleteBranch:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id, expectedSHA: target.expectedSHA) { completed.append(target.id) }
            case .prune:
                if (try? git.pruneWorktrees(repositoryPath: preview.repositoryPath)) != nil { completed.append(target.id) }
            case .deleteMergedBranches:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, name: target.id, expectedSHA: target.expectedSHA) { completed.append(target.id) }
            case .removeStaleWorktrees:
                if executeRemoveStale(repositoryPath: preview.repositoryPath, path: target.id, expectedSHA: target.expectedSHA, staleDays: preview.staleDays ?? 7, sessionCache: sessionCache) { completed.append(target.id) }
            case .deleteRemoteGoneBranches:
                break
            }
        }
        return completed
    }

    private func branchDecision(_ branch: BranchInfo, defaultBranch: String?, allowAttachedWorktrees: Bool = false) -> CleanupDecision {
        if branch.isDetachedGroup { return CleanupDecision(allowed: false, reason: .detachedWorktree) }
        guard let defaultBranch else { return CleanupDecision(allowed: false, reason: .noDefaultBranch) }
        if branch.isDefaultBranch || branch.name == defaultBranch { return CleanupDecision(allowed: false, reason: .defaultBranch) }
        if !allowAttachedWorktrees && !branch.worktrees.isEmpty { return CleanupDecision(allowed: false, reason: .worktreeAttached) }
        if branch.isMerged { return CleanupDecision(allowed: true) }
        if !branch.github.isLoaded, branch.github.error != nil { return CleanupDecision(allowed: false, reason: .githubVerificationUnavailable) }
        return CleanupDecision(allowed: false, reason: .unmergedBranch)
    }

    private func mergedBranchGroup(branch: BranchInfo, defaultBranch: String?) -> CleanupPreviewGroup {
        let branchDecision = branchDecision(branch, defaultBranch: defaultBranch, allowAttachedWorktrees: true)
        let worktreeSteps = branch.worktrees.map { worktree in
            let decision = branchDecision.allowed ? decide(worktree: worktree, branch: branch) : branchDecision
            return item(id: "\(branch.name):worktree:\(worktree.path)", target: worktree.path, decision: decision, detail: worktreeDetail(worktree: worktree, mergeStatus: branch.mergeStatus), expectedSHA: branch.sha, step: .removeWorktree)
        }
        let firstBlocked = worktreeSteps.first(where: { !$0.allowed })
        let deleteDecision: CleanupDecision
        if !branchDecision.allowed {
            deleteDecision = branchDecision
        } else if let firstBlocked {
            deleteDecision = CleanupDecision(allowed: false, reason: firstBlocked.reason)
        } else {
            deleteDecision = CleanupDecision(allowed: true)
        }
        let deleteDetail = branch.mergeStatus + (deleteDecision.allowed ? " · worktrees complete" : " · blocked")
        let deleteStep = item(id: "\(branch.name):branch", target: branch.name, decision: deleteDecision, detail: deleteDetail, expectedSHA: branch.sha, step: .deleteBranch)
        return CleanupPreviewGroup(branchName: branch.name, expectedSHA: branch.sha, expectedDefaultBranch: defaultBranch, mergeEvidence: branch.mergeEvidence, steps: worktreeSteps + [deleteStep])
    }

    private func groupItems(_ groups: [CleanupPreviewGroup]) -> [CleanupPreviewItem] {
        groups.map { group in
            let decision = group.steps.last.map { CleanupDecision(allowed: $0.allowed, reason: $0.reason) } ?? CleanupDecision(allowed: false, reason: .missingBranch)
            return item(id: group.branchName, target: group.branchName, decision: decision, detail: group.steps.last?.detail, expectedSHA: group.expectedSHA, step: .deleteBranch)
        }
    }

    private func worktreeDetail(worktree: WorktreeInfo, mergeStatus: String) -> String {
        let cleanliness = worktree.isClean ? "clean" : "dirty"
        let sessionState: String
        if worktree.sessions.isEmpty {
            sessionState = "session: none"
        } else {
            let states = worktree.sessions.map { $0.activity.rawValue.lowercased() }.joined(separator: ", ")
            sessionState = "session: \(states)"
        }
        return "\(cleanliness) · \(sessionState) · \(mergeStatus)"
    }

    private func executeMergedBranch(repositoryPath: String, canonicalPath: String, context: CleanupRepositoryContext?, group: CleanupPreviewGroup, sessionCache: SessionCleanupSafetyChecking?) -> Bool {
        guard group.allowed, let expectedSHA = group.expectedSHA else { return false }
        let plannedPaths = group.steps.filter { $0.step == .removeWorktree }.map(\.target)
        if plannedPaths.isEmpty {
            return executeDeleteBranch(repositoryPath: repositoryPath, canonicalPath: canonicalPath, name: group.branchName, expectedSHA: expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch, mergeEvidence: group.mergeEvidence, context: context)
        }
        guard let context else { return false }
        for (index, path) in plannedPaths.enumerated() {
            guard executeRemoveWorktree(repositoryPath: canonicalPath, path: path, expectedSHA: expectedSHA, sessionCache: sessionCache, mergeEvidence: group.mergeEvidence, expectedDefaultBranch: group.expectedDefaultBranch, canonicalPath: canonicalPath, context: context, expectedWorktreePaths: Array(plannedPaths.dropFirst(index))) else { return false }
        }
        return executeDeleteBranch(repositoryPath: repositoryPath, canonicalPath: canonicalPath, name: group.branchName, expectedSHA: expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch, mergeEvidence: group.mergeEvidence, context: context)
    }

    private func executeRemoveWorktree(repositoryPath: String, path: String, expectedSHA: String?, sessionCache: SessionCleanupSafetyChecking?, mergeEvidence: MergeEvidence? = nil, expectedDefaultBranch: String? = nil, canonicalPath: String? = nil, context: CleanupRepositoryContext?, expectedWorktreePaths: [String] = []) -> Bool {
        guard let context,
              let sessions = sessionCache?.cachedMetadata(), let match = try? git.cleanupWorktree(repositoryPath: canonicalPath ?? repositoryPath, path: path, sessions: sessions, includeMergeEvidence: false, canonicalPath: canonicalPath, context: context) else { return false }
        guard let expectedSHA, match.worktree.head == expectedSHA else { return false }
        if !match.worktree.isDetached && (context.defaultBranch == nil || context.defaultRef == nil) { return false }
        let branch = match.worktree.isDetached ? match.branch : revalidatedBranch(repositoryPath: canonicalPath ?? repositoryPath, branch: match.branch, expectedSHA: expectedSHA, mergeEvidence: mergeEvidence, expectedDefaultBranch: expectedDefaultBranch, canonicalPath: canonicalPath, context: context)
        guard decide(worktree: match.worktree, branch: branch).allowed else { return false }
        if !expectedWorktreePaths.isEmpty {
            guard let currentBranch = match.branch,
                  Set(currentBranch.worktrees.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) == Set(expectedWorktreePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return false }
        }
        guard let freshSessions = sessionCache?.freshSessionsForRemoval(),
              let freshWorktree = try? git.cleanupWorktreeState(repositoryPath: canonicalPath ?? repositoryPath, path: path, sessions: freshSessions, context: context),
              freshWorktree.head == expectedSHA,
              decide(worktree: freshWorktree, branch: branch).allowed else { return false }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    private func executeDeleteBranch(repositoryPath: String, name: String, expectedSHA: String?) -> Bool {
        executeDeleteBranch(repositoryPath: repositoryPath, canonicalPath: nil, name: name, expectedSHA: expectedSHA, expectedDefaultBranch: nil, mergeEvidence: nil)
    }

    private func executeDeleteBranch(repositoryPath: String, canonicalPath: String?, name: String, expectedSHA: String?, expectedDefaultBranch: String?, mergeEvidence: MergeEvidence?, context: CleanupRepositoryContext? = nil) -> Bool {
        let executionRoot = canonicalPath ?? repositoryPath
        let verifyGitAncestor: Bool
        if case .githubVerified = mergeEvidence { verifyGitAncestor = false } else { verifyGitAncestor = true }
        guard let branch = try? git.cleanupBranchState(repositoryPath: executionRoot, name: name, canonicalPath: executionRoot, verifyGitAncestor: verifyGitAncestor, context: context),
              let expectedSHA,
              branch.sha == expectedSHA,
              let defaultBranch = branch.defaultBranch,
              expectedDefaultBranch == nil || defaultBranch == expectedDefaultBranch,
              branch.name != defaultBranch,
              !branch.isDefaultBranch,
              branch.worktreePaths.isEmpty else { return false }
        if case .githubVerified(let prNumber, _) = mergeEvidence {
            let status = github.cleanupStatus(repositoryPath: executionRoot, pullRequestNumber: prNumber)
            guard let verified = status.verifiedMergedPullRequest(defaultBranch: defaultBranch, branchName: branch.name, localSHA: branch.sha),
                  verified.number == prNumber else { return false }
            return (try? git.deleteBranchVerified(repositoryPath: executionRoot, branch: name, expectedOldSHA: expectedSHA)) != nil
        }
        if branch.isGitAncestor {
            return (try? git.deleteBranch(repositoryPath: executionRoot, branch: name)) != nil
        }

        let status = github.cleanupStatus(repositoryPath: executionRoot, branch: branch.name)
        guard let verified = status.verifiedMergedPullRequest(defaultBranch: defaultBranch, branchName: branch.name, localSHA: branch.sha),
              verified.mergedAt != nil else { return false }
        return (try? git.deleteBranchVerified(repositoryPath: executionRoot, branch: name, expectedOldSHA: expectedSHA)) != nil
    }

    private func executeRemoveStale(repositoryPath: String, path: String, expectedSHA: String?, staleDays: Int, sessionCache: SessionCleanupSafetyChecking?) -> Bool {
        guard let sessions = sessionCache?.cachedMetadata() else { return false }
        guard let match = try? git.cleanupWorktree(repositoryPath: repositoryPath, path: path, sessions: sessions, includeCleanupUIData: true) else { return false }
        let branch = revalidatedBranch(repositoryPath: repositoryPath, branch: match.branch, expectedSHA: expectedSHA)
        guard decide(worktree: match.worktree, branch: branch, requireMerged: true, now: Date(), staleDays: staleDays).allowed else { return false }
        guard let freshSessions = sessionCache?.freshSessionsForRemoval(),
              let freshMatch = try? git.cleanupWorktree(repositoryPath: repositoryPath, path: path, sessions: freshSessions, includeCleanupUIData: true),
              freshMatch.worktree.head == expectedSHA,
              decide(worktree: freshMatch.worktree, branch: branch, requireMerged: true, now: Date(), staleDays: staleDays).allowed else { return false }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    private func makeSessionSafetyCache() -> SessionCleanupSafetyChecking? {
        if let cache = sessions.makeCleanupSafetyCache() { return cache }
        return DiscoverySessionSafetyCache(sessions: sessions)
    }

    private func revalidatedBranch(repositoryPath: String, branch: BranchInfo?, expectedSHA: String?, mergeEvidence: MergeEvidence? = nil, expectedDefaultBranch: String? = nil, canonicalPath: String? = nil, context: CleanupRepositoryContext? = nil) -> BranchInfo? {
        guard let branch else { return nil }
        guard let expectedSHA, branch.sha == expectedSHA else { return nil }
        let evidence = mergeEvidence ?? branch.mergeEvidence
        let defaultBranch: String?
        var freshContext: CleanupRepositoryContext?
        if let context {
            freshContext = git.revalidatedCleanupContext(context)
            defaultBranch = freshContext?.defaultBranch
        } else {
            freshContext = try? git.cleanupContext(repositoryPath: canonicalPath ?? repositoryPath)
            defaultBranch = freshContext?.defaultBranch
        }
        guard let defaultBranch,
              expectedDefaultBranch == nil || defaultBranch == expectedDefaultBranch else { return nil }
        if evidence == .gitAncestor || evidence == .none {
            guard let defaultRef = freshContext?.defaultRef else { return nil }
            if git.isGitAncestor(repositoryPath: canonicalPath ?? repositoryPath, branch: branch.name, defaultRef: defaultRef) {
                return branch.withMergeEvidence(.gitAncestor)
            }
            if evidence == .gitAncestor { return nil }
        }
        let status: GitHubStatus
        if case .githubVerified(let prNumber, _) = evidence {
            status = github.cleanupStatus(repositoryPath: repositoryPath, pullRequestNumber: prNumber)
        } else {
            status = github.cleanupStatus(repositoryPath: repositoryPath, branch: branch.name)
        }
        guard let verified = status.verifiedMergedPullRequest(defaultBranch: defaultBranch, branchName: branch.name, localSHA: branch.sha), let mergedAt = verified.mergedAt else { return nil }
        if case .githubVerified(let prNumber, _) = evidence, verified.number != prNumber { return nil }
        return branch.withMergeEvidence(.githubVerified(prNumber: verified.number, mergedAt: mergedAt), github: status)
    }

    private func locateWorktree(_ snapshot: RepositorySnapshot, path: String) -> (worktree: WorktreeInfo, branch: BranchInfo)? {
        for branch in snapshot.branches {
            if let worktree = branch.worktrees.first(where: { $0.path == path }) { return (worktree, branch) }
        }
        return nil
    }

    private func item(id: String, target: String, decision: CleanupDecision, detail: String? = nil, expectedSHA: String? = nil, step: CleanupPlanStep? = nil) -> CleanupPreviewItem {
        CleanupPreviewItem(id: id, target: target, allowed: decision.allowed, reason: decision.reason, detail: detail, expectedSHA: expectedSHA, step: step)
    }
}

private final class DiscoverySessionSafetyCache: SessionCleanupSafetyChecking, @unchecked Sendable {
    private let sessions: any SessionDiscovering
    private var cached: [SessionRecord]?

    init(sessions: any SessionDiscovering) { self.sessions = sessions }

    func cachedMetadata() -> [SessionRecord]? {
        if let cached { return cached }
        let records = sessions.discover().sessions.map { record in
            SessionRecord(id: record.id, provider: record.provider, title: record.title, updatedAt: record.updatedAt, cwd: record.cwd, branch: record.branch, url: record.url, activity: .inactive, evidence: record.evidence)
        }
        cached = records
        return records
    }

    func freshSessionsForRemoval() -> [SessionRecord]? { sessions.discover().sessions }
}
