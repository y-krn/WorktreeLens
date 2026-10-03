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

    public func decide(worktree: WorktreeInfo, branch: BranchInfo? = nil, requireMerged: Bool = true) -> CleanupDecision {
        if worktree.isLocked { return CleanupDecision(allowed: false, reason: .lockedWorktree) }
        if !worktree.isClean { return CleanupDecision(allowed: false, reason: .dirtyWorktree) }
        if worktree.hasActiveSession { return CleanupDecision(allowed: false, reason: .activeSession) }
        if worktree.hasUnknownSession { return CleanupDecision(allowed: false, reason: .unknownSessionActivity) }
        if !worktree.isDetached && requireMerged && branch?.isMerged != true {
            return CleanupDecision(allowed: false, reason: branch == nil ? .missingBranch : .unmergedBranch)
        }
        return CleanupDecision(allowed: true)
    }

    public func previewRemoveWorktree(snapshot: RepositorySnapshot, path: String) -> CleanupPreview {
        guard let match = locateWorktree(snapshot, path: path) else {
            return CleanupPreview(operation: .removeWorktree, repositoryPath: snapshot.path, items: [CleanupPreviewItem(id: path, target: path, allowed: false, reason: .missingBranch)])
        }
        return CleanupPreview(operation: .removeWorktree, repositoryPath: snapshot.path, items: [keepBranchItem(worktree: match.worktree, branch: match.branch, snapshot: snapshot, processDirectories: sessions.processWorkingDirectories())])
    }

    private func keepBranchItem(worktree: WorktreeInfo, branch: BranchInfo, snapshot: RepositorySnapshot, processDirectories: [String]?) -> CleanupPreviewItem {
        // Preview only reports processes it can see; execution fails closed when the scan is unavailable.
        let decision: CleanupDecision
        if isSamePath(worktree.path, snapshot.path) {
            decision = CleanupDecision(allowed: false, reason: .mainWorktree)
        } else if let processDirectories, hasProcess(in: worktree.path, directories: processDirectories) {
            decision = CleanupDecision(allowed: false, reason: .processRunning)
        } else {
            decision = decide(worktree: worktree, requireMerged: false)
        }
        let kept = worktree.isDetached ? "detached HEAD must stay reachable" : "branch \(branch.name) kept"
        return CleanupPreviewItem(id: worktree.path, target: worktree.path, allowed: decision.allowed, reason: decision.reason, detail: worktreeDetail(worktree: worktree, mergeStatus: kept), expectedSHA: worktree.head)
    }

    public func previewDeleteBranch(snapshot: RepositorySnapshot, name: String) -> CleanupPreview {
        let decision: CleanupDecision
        if let branch = snapshot.branches.first(where: { $0.name == name }) {
            decision = branchDecision(branch, defaultBranch: snapshot.defaultBranch)
        } else {
            decision = CleanupDecision(allowed: false, reason: .missingBranch)
        }
        let branch = snapshot.branches.first(where: { $0.name == name })
        return CleanupPreview(operation: .deleteBranch, repositoryPath: snapshot.path, items: [item(id: name, target: name, decision: decision,
            detail: branch?.mergeStatus, expectedSHA: branch?.sha, expectedDefaultBranch: snapshot.defaultBranch,
            mergeEvidence: branch?.mergeEvidence)])
    }

    public func previewMergedBranches(snapshot: RepositorySnapshot) -> CleanupPreview {
        let groups = snapshot.branches.filter { !$0.isDetachedGroup }.map { branch in
            mergedBranchGroup(branch: branch, defaultBranch: snapshot.defaultBranch)
        }
        return CleanupPreview(operation: .deleteMergedBranches, repositoryPath: snapshot.path, items: groupItems(groups), groups: groups)
    }

    public func execute(_ preview: CleanupPreview) -> CleanupExecutionResult {
        var completed: [String] = []
        var removedWorktrees: [String] = []
        var deletedBranches: [String] = []
        if preview.operation == .deleteMergedBranches {
            var pruneRoot = preview.repositoryPath
            if !preview.groups.isEmpty {
                let needsSessionSafety = preview.groups.contains { $0.allowed && $0.steps.contains { $0.step == .removeWorktree } }
                let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
                if needsSessionSafety && sessionCache == nil { return CleanupExecutionResult() }
                let context: CleanupRepositoryContext?
                let canonicalPath: String
                if preview.groups.count == 1 && !needsSessionSafety {
                    guard let path = try? git.canonicalRepositoryPath(preview.repositoryPath) else { return CleanupExecutionResult() }
                    canonicalPath = path
                    context = nil
                } else {
                    guard let cleanupContext = try? git.cleanupContext(repositoryPath: preview.repositoryPath), cleanupContext.defaultBranch != nil else { return CleanupExecutionResult() }
                    canonicalPath = cleanupContext.path
                    context = cleanupContext
                }
                pruneRoot = canonicalPath
                for group in preview.groups where group.allowed {
                    let result = executeMergedBranch(repositoryPath: canonicalPath, canonicalPath: canonicalPath, context: context, group: group, sessionCache: sessionCache)
                    removedWorktrees.append(contentsOf: result.removedWorktreePaths)
                    deletedBranches.append(contentsOf: result.deletedLocalBranches)
                    if !result.removedWorktreePaths.isEmpty || !result.deletedLocalBranches.isEmpty { completed.append(group.branchName) }
                }
            }
            // Merged cleanup also drops metadata of worktrees whose directories are already gone.
            let pruned = (try? git.pruneWorktrees(repositoryPath: pruneRoot)) == true
            return CleanupExecutionResult(completedTargetIDs: completed, removedWorktreePaths: removedWorktrees, deletedLocalBranches: deletedBranches, requiresFullRefresh: pruned)
        }

        let needsSessionSafety = preview.operation == .removeWorktree
        let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
        if needsSessionSafety && sessionCache == nil { return CleanupExecutionResult() }
        let context = needsSessionSafety ? try? git.cleanupContext(repositoryPath: preview.repositoryPath) : nil
        if needsSessionSafety && context == nil { return CleanupExecutionResult() }
        for target in preview.allowedItems {
            switch preview.operation {
            case .removeWorktree:
                if executeRemoveWorktreeKeepingBranch(path: target.id, expectedSHA: target.expectedSHA, sessionCache: sessionCache, context: context) {
                    completed.append(target.id)
                    removedWorktrees.append(target.id)
                }
            case .deleteBranch, .deleteMergedBranches:
                if executeDeleteBranch(repositoryPath: preview.repositoryPath, canonicalPath: nil, name: target.id,
                    expectedSHA: target.expectedSHA, expectedDefaultBranch: target.expectedDefaultBranch,
                    mergeEvidence: target.mergeEvidence) {
                    completed.append(target.id)
                    deletedBranches.append(target.id)
                }
            }
        }
        return CleanupExecutionResult(completedTargetIDs: completed, removedWorktreePaths: removedWorktrees, deletedLocalBranches: deletedBranches)
    }

    public func executeAsync(_ preview: CleanupPreview) async -> CleanupExecutionResult {
        let githubTargets = githubVerificationTargets(preview)
        if !githubTargets.isEmpty {
            let branches = githubTargets.map { target in
                BranchInfo(id: target.name, name: target.name, sha: target.sha, upstream: nil, ahead: 0, behind: 0,
                    isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
            }
            do { try await github.prepareCleanupVerification(repositoryPath: preview.repositoryPath, branches: branches) }
            catch { return CleanupExecutionResult(failureReason: error.localizedDescription) }
        }

        var completed: [String] = []
        var removedWorktrees: [String] = []
        var deletedBranches: [String] = []
        var failureReason: String?
        if preview.operation == .deleteMergedBranches {
            var pruneRoot = preview.repositoryPath
            if !preview.groups.isEmpty {
                let needsSessionSafety = preview.groups.contains { $0.allowed && $0.steps.contains { $0.step == .removeWorktree } }
                let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
                if needsSessionSafety && sessionCache == nil { return CleanupExecutionResult() }
                let context: CleanupRepositoryContext?
                let canonicalPath: String
                if preview.groups.count == 1 && !needsSessionSafety {
                    guard let path = try? git.canonicalRepositoryPath(preview.repositoryPath) else { return CleanupExecutionResult() }
                    canonicalPath = path
                    context = nil
                } else {
                    guard let cleanupContext = try? git.cleanupContext(repositoryPath: preview.repositoryPath), cleanupContext.defaultBranch != nil else { return CleanupExecutionResult() }
                    canonicalPath = cleanupContext.path
                    context = cleanupContext
                }
                pruneRoot = canonicalPath
                for group in preview.groups where group.allowed {
                    let result = await executeMergedBranchAsync(repositoryPath: canonicalPath, canonicalPath: canonicalPath,
                        context: context, group: group, sessionCache: sessionCache)
                    removedWorktrees.append(contentsOf: result.removedWorktreePaths)
                    deletedBranches.append(contentsOf: result.deletedLocalBranches)
                    if !result.removedWorktreePaths.isEmpty || !result.deletedLocalBranches.isEmpty { completed.append(group.branchName) }
                    failureReason = failureReason ?? result.failureReason
                }
            }
            let pruned = (try? git.pruneWorktrees(repositoryPath: pruneRoot)) == true
            return CleanupExecutionResult(completedTargetIDs: completed, removedWorktreePaths: removedWorktrees,
                deletedLocalBranches: deletedBranches, requiresFullRefresh: pruned, failureReason: failureReason)
        }

        let needsSessionSafety = preview.operation == .removeWorktree
        let sessionCache = needsSessionSafety ? makeSessionSafetyCache() : nil
        if needsSessionSafety && sessionCache == nil { return CleanupExecutionResult() }
        let context = needsSessionSafety ? try? git.cleanupContext(repositoryPath: preview.repositoryPath) : nil
        if needsSessionSafety && context == nil { return CleanupExecutionResult() }
        for target in preview.allowedItems {
            switch preview.operation {
            case .removeWorktree:
                if executeRemoveWorktreeKeepingBranch(path: target.id, expectedSHA: target.expectedSHA,
                                                      sessionCache: sessionCache, context: context) {
                    completed.append(target.id)
                    removedWorktrees.append(target.id)
                }
            case .deleteBranch, .deleteMergedBranches:
                do {
                    if try await executeDeleteBranchAsync(repositoryPath: preview.repositoryPath, canonicalPath: nil,
                        name: target.id, expectedSHA: target.expectedSHA, expectedDefaultBranch: target.expectedDefaultBranch,
                        mergeEvidence: target.mergeEvidence, context: nil) {
                        completed.append(target.id)
                        deletedBranches.append(target.id)
                    }
                } catch { failureReason = failureReason ?? error.localizedDescription }
            }
        }
        return CleanupExecutionResult(completedTargetIDs: completed, removedWorktreePaths: removedWorktrees,
            deletedLocalBranches: deletedBranches, failureReason: failureReason)
    }

    private func githubVerificationTargets(_ preview: CleanupPreview) -> [(name: String, sha: String, defaultBranch: String?, evidence: MergeEvidence?)] {
        let candidates: [(String, String?, String?, MergeEvidence?)]
        if preview.operation == .deleteMergedBranches {
            candidates = preview.groups.filter(\.allowed).map { ($0.branchName, $0.expectedSHA, $0.expectedDefaultBranch, $0.mergeEvidence) }
        } else if preview.operation == .deleteBranch {
            candidates = preview.allowedItems.map { ($0.target, $0.expectedSHA, $0.expectedDefaultBranch, $0.mergeEvidence) }
        } else { return [] }
        return candidates.compactMap { name, expectedSHA, expectedDefaultBranch, evidence in
            if case .githubVerified = evidence {
                guard let expectedSHA else { return nil }
                return (name, expectedSHA, expectedDefaultBranch, evidence)
            }
            guard let state = try? git.cleanupBranchState(repositoryPath: preview.repositoryPath, name: name),
                  let expectedSHA, state.sha == expectedSHA,
                  expectedDefaultBranch == nil || state.defaultBranch == expectedDefaultBranch,
                  !state.isDefaultBranch, !state.isGitAncestor else { return nil }
            return (name, expectedSHA, expectedDefaultBranch, evidence)
        }
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
        let deleteStep = item(id: "\(branch.name):branch", target: branch.name, decision: deleteDecision, detail: deleteDetail,
            expectedSHA: branch.sha, expectedDefaultBranch: defaultBranch, step: .deleteBranch, mergeEvidence: branch.mergeEvidence)
        return CleanupPreviewGroup(branchName: branch.name, expectedSHA: branch.sha, expectedDefaultBranch: defaultBranch, mergeEvidence: branch.mergeEvidence, steps: worktreeSteps + [deleteStep])
    }

    private func groupItems(_ groups: [CleanupPreviewGroup]) -> [CleanupPreviewItem] {
        groups.map { group in
            let decision = group.steps.last.map { CleanupDecision(allowed: $0.allowed, reason: $0.reason) } ?? CleanupDecision(allowed: false, reason: .missingBranch)
            return item(id: group.branchName, target: group.branchName, decision: decision, detail: group.steps.last?.detail,
                expectedSHA: group.expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch,
                step: .deleteBranch, mergeEvidence: group.mergeEvidence)
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

    private func executeMergedBranch(repositoryPath: String, canonicalPath: String, context: CleanupRepositoryContext?, group: CleanupPreviewGroup, sessionCache: SessionCleanupSafetyChecking?) -> CleanupExecutionResult {
        guard group.allowed, let expectedSHA = group.expectedSHA else { return CleanupExecutionResult() }
        let plannedPaths = group.steps.filter { $0.step == .removeWorktree }.map(\.target)
        if plannedPaths.isEmpty {
            let deleted = executeDeleteBranch(repositoryPath: repositoryPath, canonicalPath: canonicalPath, name: group.branchName, expectedSHA: expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch, mergeEvidence: group.mergeEvidence, context: context)
            return CleanupExecutionResult(deletedLocalBranches: deleted ? [group.branchName] : [])
        }
        guard let context else { return CleanupExecutionResult() }
        var removed: [String] = []
        for (index, path) in plannedPaths.enumerated() {
            guard executeRemoveWorktree(repositoryPath: canonicalPath, path: path, expectedSHA: expectedSHA, sessionCache: sessionCache, mergeEvidence: group.mergeEvidence, expectedDefaultBranch: group.expectedDefaultBranch, canonicalPath: canonicalPath, context: context, expectedWorktreePaths: Array(plannedPaths.dropFirst(index)), expectedBranchName: group.branchName) else {
                return CleanupExecutionResult(removedWorktreePaths: removed)
            }
            removed.append(path)
        }
        let deleted = executeDeleteBranch(repositoryPath: repositoryPath, canonicalPath: canonicalPath, name: group.branchName, expectedSHA: expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch, mergeEvidence: group.mergeEvidence, context: context)
        return CleanupExecutionResult(removedWorktreePaths: removed, deletedLocalBranches: deleted ? [group.branchName] : [])
    }

    private func executeMergedBranchAsync(repositoryPath: String, canonicalPath: String, context: CleanupRepositoryContext?,
                                          group: CleanupPreviewGroup, sessionCache: SessionCleanupSafetyChecking?) async -> CleanupExecutionResult {
        guard group.allowed, let expectedSHA = group.expectedSHA else { return CleanupExecutionResult() }
        let plannedPaths = group.steps.filter { $0.step == .removeWorktree }.map(\.target)
        var removed: [String] = []
        do {
            if let context {
                for (index, path) in plannedPaths.enumerated() {
                    guard try await executeRemoveWorktreeAsync(repositoryPath: canonicalPath, path: path, expectedSHA: expectedSHA,
                        sessionCache: sessionCache, mergeEvidence: group.mergeEvidence,
                        expectedDefaultBranch: group.expectedDefaultBranch, canonicalPath: canonicalPath, context: context,
                        expectedWorktreePaths: Array(plannedPaths.dropFirst(index)), expectedBranchName: group.branchName) else {
                        return CleanupExecutionResult(removedWorktreePaths: removed)
                    }
                    removed.append(path)
                }
            } else if !plannedPaths.isEmpty { return CleanupExecutionResult() }
            let deleted = try await executeDeleteBranchAsync(repositoryPath: repositoryPath, canonicalPath: canonicalPath,
                name: group.branchName, expectedSHA: expectedSHA, expectedDefaultBranch: group.expectedDefaultBranch,
                mergeEvidence: group.mergeEvidence, context: context)
            return CleanupExecutionResult(removedWorktreePaths: removed,
                deletedLocalBranches: deleted ? [group.branchName] : [])
        } catch {
            return CleanupExecutionResult(removedWorktreePaths: removed, failureReason: error.localizedDescription)
        }
    }

    private func executeRemoveWorktree(repositoryPath: String, path: String, expectedSHA: String?, sessionCache: SessionCleanupSafetyChecking?, mergeEvidence: MergeEvidence? = nil, expectedDefaultBranch: String? = nil, canonicalPath: String? = nil, context: CleanupRepositoryContext?, expectedWorktreePaths: [String] = [], expectedBranchName: String? = nil) -> Bool {
        guard let context,
              let sessions = sessionCache?.cachedMetadata(), let match = try? git.cleanupWorktree(repositoryPath: canonicalPath ?? repositoryPath, path: path, sessions: sessions, includeMergeEvidence: false, canonicalPath: canonicalPath, context: context) else { return false }
        guard let expectedSHA, match.worktree.head == expectedSHA else { return false }
        if let expectedBranchName {
            guard !match.worktree.isDetached, match.worktree.branch == expectedBranchName,
                  match.branch?.name == expectedBranchName else { return false }
        }
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
              decide(worktree: freshWorktree, branch: branch).allowed,
              noProcessRunning(in: path) else { return false }
        if let expectedBranchName {
            guard !freshWorktree.isDetached, freshWorktree.branch == expectedBranchName else { return false }
        }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    private func executeRemoveWorktreeAsync(repositoryPath: String, path: String, expectedSHA: String?,
        sessionCache: SessionCleanupSafetyChecking?, mergeEvidence: MergeEvidence? = nil,
        expectedDefaultBranch: String? = nil, canonicalPath: String? = nil, context: CleanupRepositoryContext?,
        expectedWorktreePaths: [String] = [], expectedBranchName: String? = nil) async throws -> Bool {
        guard let context,
              let sessions = sessionCache?.cachedMetadata(),
              let match = try? git.cleanupWorktree(repositoryPath: canonicalPath ?? repositoryPath, path: path,
                  sessions: sessions, includeMergeEvidence: false, canonicalPath: canonicalPath, context: context) else { return false }
        guard let expectedSHA, match.worktree.head == expectedSHA else { return false }
        if let expectedBranchName {
            guard !match.worktree.isDetached, match.worktree.branch == expectedBranchName,
                  match.branch?.name == expectedBranchName else { return false }
        }
        if !match.worktree.isDetached && (context.defaultBranch == nil || context.defaultRef == nil) { return false }
        let branch: BranchInfo?
        if match.worktree.isDetached {
            branch = match.branch
        } else {
            branch = try await revalidatedBranchAsync(repositoryPath: canonicalPath ?? repositoryPath, branch: match.branch,
                expectedSHA: expectedSHA, mergeEvidence: mergeEvidence, expectedDefaultBranch: expectedDefaultBranch,
                canonicalPath: canonicalPath, context: context)
        }
        guard decide(worktree: match.worktree, branch: branch).allowed else { return false }
        if !expectedWorktreePaths.isEmpty {
            guard let currentBranch = match.branch,
                  Set(currentBranch.worktrees.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) ==
                    Set(expectedWorktreePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return false }
        }
        guard git.revalidatedCleanupContext(context) != nil,
              let freshSessions = sessionCache?.freshSessionsForRemoval(),
              let fresh = try? git.cleanupWorktree(repositoryPath: canonicalPath ?? repositoryPath, path: path,
                  sessions: freshSessions, includeMergeEvidence: false, canonicalPath: canonicalPath, context: context) else { return false }
        guard
              fresh.worktree.head == expectedSHA,
              fresh.worktree.isDetached || fresh.branch?.sha == expectedSHA,
              decide(worktree: fresh.worktree, branch: branch).allowed,
              noProcessRunning(in: path) else { return false }
        if !expectedWorktreePaths.isEmpty {
            guard let currentBranch = fresh.branch,
                  Set(currentBranch.worktrees.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) ==
                    Set(expectedWorktreePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return false }
        }
        if let expectedBranchName {
            guard !fresh.worktree.isDetached, fresh.worktree.branch == expectedBranchName,
                  fresh.branch?.name == expectedBranchName else { return false }
        }
        return (try? git.removeWorktree(repositoryPath: repositoryPath, path: path)) != nil
    }

    /// Removes only the checkout. Commits stay reachable through the branch (or, for detached HEADs, another ref).
    private func executeRemoveWorktreeKeepingBranch(path: String, expectedSHA: String?, sessionCache: SessionCleanupSafetyChecking?, context: CleanupRepositoryContext?) -> Bool {
        guard let context, let expectedSHA, !isSamePath(path, context.path),
              let sessions = sessionCache?.freshSessionsForRemoval(),
              let worktree = try? git.cleanupWorktreeState(repositoryPath: context.path, path: path, sessions: sessions, context: context),
              worktree.head == expectedSHA,
              decide(worktree: worktree, requireMerged: false).allowed,
              noProcessRunning(in: path) else { return false }
        if worktree.isDetached || worktree.branch == nil {
            guard git.isReachableFromRefs(repositoryPath: context.path, sha: expectedSHA) else { return false }
        }
        return (try? git.removeWorktree(repositoryPath: context.path, path: path)) != nil
    }

    /// Final guard: a process working inside the checkout (agent, shell, dev server) means it is still in use.
    private func noProcessRunning(in path: String) -> Bool {
        guard let directories = sessions.processWorkingDirectories() else { return false }
        return !hasProcess(in: path, directories: directories)
    }

    private func hasProcess(in path: String, directories: [String]) -> Bool {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return directories.contains { directory in
            let candidate = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    private func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
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
        if branch.isGitAncestor {
            return (try? git.deleteBranch(repositoryPath: executionRoot, branch: name)) != nil
        }
        return false
    }

    private func executeDeleteBranchAsync(repositoryPath: String, canonicalPath: String?, name: String, expectedSHA: String?,
        expectedDefaultBranch: String?, mergeEvidence: MergeEvidence?, context: CleanupRepositoryContext? = nil) async throws -> Bool {
        let executionRoot = canonicalPath ?? repositoryPath
        let verifiedNumber: Int?
        if case .githubVerified(let prNumber, _) = mergeEvidence { verifiedNumber = prNumber }
        else { verifiedNumber = nil }
        guard let expectedSHA else { return false }
        let defaultBranch: String
        if verifiedNumber != nil {
            guard let expectedDefaultBranch else { return false }
            defaultBranch = expectedDefaultBranch
        } else {
            guard let initial = try? git.cleanupBranchState(repositoryPath: executionRoot, name: name,
                      canonicalPath: executionRoot, verifyGitAncestor: true, context: context),
                  initial.sha == expectedSHA,
                  let currentDefaultBranch = initial.defaultBranch,
                  expectedDefaultBranch == nil || currentDefaultBranch == expectedDefaultBranch,
                  initial.name != currentDefaultBranch, !initial.isDefaultBranch, initial.worktreePaths.isEmpty else { return false }
            if initial.isGitAncestor {
                return (try? git.deleteBranch(repositoryPath: executionRoot, branch: name)) != nil
            }
            if case .gitAncestor = mergeEvidence { return false }
            defaultBranch = currentDefaultBranch
        }

        let verified = try await github.verifyCleanupPullRequest(repositoryPath: executionRoot, branch: name,
            localSHA: expectedSHA, defaultBranch: defaultBranch, knownNumber: verifiedNumber)
        guard verified.mergedAt != nil, verifiedNumber == nil || verified.number == verifiedNumber else { return false }

        // Re-read local refs after the network round trip; update-ref then enforces the exact old SHA.
        guard let current = try? git.cleanupBranchState(repositoryPath: executionRoot, name: name,
                  canonicalPath: executionRoot, verifyGitAncestor: false, context: context),
              current.sha == expectedSHA, current.defaultBranch == defaultBranch,
              expectedDefaultBranch == nil || current.defaultBranch == expectedDefaultBranch,
              current.name != current.defaultBranch, !current.isDefaultBranch, current.worktreePaths.isEmpty else { return false }
        return (try? git.deleteBranchVerified(repositoryPath: executionRoot, branch: name, expectedOldSHA: expectedSHA)) != nil
    }

    private func revalidatedBranchAsync(repositoryPath: String, branch: BranchInfo?, expectedSHA: String?,
        mergeEvidence: MergeEvidence? = nil, expectedDefaultBranch: String? = nil,
        canonicalPath: String? = nil, context: CleanupRepositoryContext? = nil) async throws -> BranchInfo? {
        guard let branch, let expectedSHA, branch.sha == expectedSHA else { return nil }
        let evidence = mergeEvidence ?? branch.mergeEvidence
        let freshContext = context.map { git.revalidatedCleanupContext($0) } ?? (try? git.cleanupContext(repositoryPath: canonicalPath ?? repositoryPath))
        guard let freshContext, let defaultBranch = freshContext.defaultBranch,
              expectedDefaultBranch == nil || defaultBranch == expectedDefaultBranch else { return nil }
        if evidence == .none || evidence == .gitAncestor {
            guard let defaultRef = freshContext.defaultRef else { return nil }
            if git.isGitAncestor(repositoryPath: canonicalPath ?? repositoryPath, branch: branch.name, defaultRef: defaultRef) {
                return branch.withMergeEvidence(.gitAncestor)
            }
            if evidence == .gitAncestor { return nil }
        }
        let knownNumber: Int?
        if case .githubVerified(let number, _) = evidence { knownNumber = number }
        else { knownNumber = nil }
        let verified = try await github.verifyCleanupPullRequest(repositoryPath: canonicalPath ?? repositoryPath,
            branch: branch.name, localSHA: branch.sha, defaultBranch: defaultBranch, knownNumber: knownNumber)
        guard let mergedAt = verified.mergedAt,
              knownNumber == nil || verified.number == knownNumber else { return nil }
        return branch.withMergeEvidence(.githubVerified(prNumber: verified.number, mergedAt: mergedAt))
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
        return nil
    }

    private func locateWorktree(_ snapshot: RepositorySnapshot, path: String) -> (worktree: WorktreeInfo, branch: BranchInfo)? {
        for branch in snapshot.branches {
            if let worktree = branch.worktrees.first(where: { $0.path == path }) { return (worktree, branch) }
        }
        return nil
    }

    private func item(id: String, target: String, decision: CleanupDecision, detail: String? = nil, expectedSHA: String? = nil,
                      expectedDefaultBranch: String? = nil, step: CleanupPlanStep? = nil,
                      mergeEvidence: MergeEvidence? = nil) -> CleanupPreviewItem {
        CleanupPreviewItem(id: id, target: target, allowed: decision.allowed, reason: decision.reason, detail: detail,
            expectedSHA: expectedSHA, expectedDefaultBranch: expectedDefaultBranch, step: step, mergeEvidence: mergeEvidence)
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
