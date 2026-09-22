import Foundation

public enum SessionProviderKind: String, Codable, Sendable {
    case codex = "Codex"
    case chatGPT = "ChatGPT"
}

public enum SessionActivity: String, Codable, Sendable {
    case active = "Active"
    case inactive = "Inactive"
    case unknown = "Unknown"
}

public struct SessionRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: SessionProviderKind
    public let title: String
    public let updatedAt: Date?
    public let cwd: String?
    public let branch: String?
    public let url: URL?
    public let activity: SessionActivity
    public let evidence: String

    public init(id: String, provider: SessionProviderKind, title: String, updatedAt: Date?, cwd: String?, branch: String?, url: URL?, activity: SessionActivity, evidence: String) {
        self.id = id
        self.provider = provider
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.branch = branch
        self.url = url
        self.activity = activity
        self.evidence = evidence
    }
}

public struct WorktreeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let branch: String?
    public let head: String
    public let isBare: Bool
    public let isLocked: Bool
    public let isDetached: Bool
    public let isClean: Bool
    public let stagedCount: Int
    public let unstagedCount: Int
    public let untrackedCount: Int
    public let lastActivity: Date?
    public let defaultAhead: Int
    public let defaultBehind: Int
    public let sessions: [SessionRecord]

    public var hasActiveSession: Bool { sessions.contains { $0.activity == .active } }
    public var hasUnknownSession: Bool { sessions.contains { $0.activity == .unknown } }

    public init(id: String, path: String, branch: String?, head: String, isBare: Bool, isLocked: Bool, isDetached: Bool = false, isClean: Bool, stagedCount: Int, unstagedCount: Int, untrackedCount: Int, lastActivity: Date?, defaultAhead: Int = 0, defaultBehind: Int = 0, sessions: [SessionRecord] = []) {
        self.id = id
        self.path = path
        self.branch = branch
        self.head = head
        self.isBare = isBare
        self.isLocked = isLocked
        self.isDetached = isDetached
        self.isClean = isClean
        self.stagedCount = stagedCount
        self.unstagedCount = unstagedCount
        self.untrackedCount = untrackedCount
        self.lastActivity = lastActivity
        self.defaultAhead = defaultAhead
        self.defaultBehind = defaultBehind
        self.sessions = sessions
    }
}

public struct BranchInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sha: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let mergeEvidence: MergeEvidence
    public let remoteGone: Bool
    public let lastCommitAt: Date?
    public let isDefaultBranch: Bool
    public let isDetachedGroup: Bool
    public let defaultAhead: Int
    public let defaultBehind: Int
    public let worktrees: [WorktreeInfo]
    public let github: GitHubStatus

    public init(id: String, name: String, sha: String, upstream: String?, ahead: Int, behind: Int, isMerged: Bool, remoteGone: Bool, lastCommitAt: Date?, isDefaultBranch: Bool = false, isDetachedGroup: Bool = false, defaultAhead: Int = 0, defaultBehind: Int = 0, worktrees: [WorktreeInfo], github: GitHubStatus = .unavailable, mergeEvidence: MergeEvidence? = nil) {
        self.id = id
        self.name = name
        self.sha = sha
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.mergeEvidence = mergeEvidence ?? (isMerged ? .gitAncestor : .none)
        self.remoteGone = remoteGone
        self.lastCommitAt = lastCommitAt
        self.isDefaultBranch = isDefaultBranch
        self.isDetachedGroup = isDetachedGroup
        self.defaultAhead = defaultAhead
        self.defaultBehind = defaultBehind
        self.worktrees = worktrees
        self.github = github
    }

    public var isMerged: Bool { mergeEvidence.isMerged }

    public var mergeStatus: String {
        switch mergeEvidence {
        case .gitAncestor: return "Merged · Git"
        case .githubVerified(let prNumber, _): return "Merged · GitHub verified · PR #\(prNumber)"
        case .none: return github.mergeEvidenceLoaded ? "Not merged" : "GitHub verification unavailable"
        }
    }

    public func withMergeEvidence(_ evidence: MergeEvidence, github: GitHubStatus? = nil) -> BranchInfo {
        BranchInfo(id: id, name: name, sha: sha, upstream: upstream, ahead: ahead, behind: behind, isMerged: evidence.isMerged, remoteGone: remoteGone, lastCommitAt: lastCommitAt, isDefaultBranch: isDefaultBranch, isDetachedGroup: isDetachedGroup, defaultAhead: defaultAhead, defaultBehind: defaultBehind, worktrees: worktrees, github: github ?? self.github, mergeEvidence: evidence)
    }

    public func withGitHubStatus(_ status: GitHubStatus) -> BranchInfo {
        BranchInfo(id: id, name: name, sha: sha, upstream: upstream, ahead: ahead, behind: behind, isMerged: isMerged, remoteGone: remoteGone, lastCommitAt: lastCommitAt, isDefaultBranch: isDefaultBranch, isDetachedGroup: isDetachedGroup, defaultAhead: defaultAhead, defaultBehind: defaultBehind, worktrees: worktrees, github: status, mergeEvidence: mergeEvidence)
    }

    public func withRemoteGone(_ value: Bool) -> BranchInfo {
        BranchInfo(id: id, name: name, sha: sha, upstream: upstream, ahead: ahead, behind: behind, isMerged: isMerged, remoteGone: value, lastCommitAt: lastCommitAt, isDefaultBranch: isDefaultBranch, isDetachedGroup: isDetachedGroup, defaultAhead: defaultAhead, defaultBehind: defaultBehind, worktrees: worktrees, github: github, mergeEvidence: mergeEvidence)
    }
}

public enum MergeEvidence: Hashable, Sendable {
    case gitAncestor
    case githubVerified(prNumber: Int, mergedAt: Date)
    case none

    public var isMerged: Bool {
        if case .none = self { return false }
        return true
    }
}

public struct GitHubMergeEvidence: Sendable {
    public let pullRequests: [GitHubPullRequest]
    public let error: String?

    public init(pullRequests: [GitHubPullRequest], error: String? = nil) {
        self.pullRequests = pullRequests
        self.error = error
    }

    public var isLoaded: Bool { error == nil }
}

public enum RepositorySelection: Hashable, Sendable {
    case branch(String)
    case worktree(String)

    public func branchID(in snapshot: RepositorySnapshot) -> String? {
        switch self {
        case .branch(let id):
            return snapshot.branches.contains { $0.id == id } ? id : nil
        case .worktree(let id):
            return snapshot.branches.first { branch in
                branch.worktrees.contains { $0.id == id }
            }?.id
        }
    }

    public func worktreeID(in snapshot: RepositorySnapshot) -> String? {
        guard case .worktree(let id) = self else { return nil }
        return snapshot.branches.flatMap(\.worktrees).contains { $0.id == id } ? id : nil
    }
}

public struct GitHubStatus: Hashable, Sendable {
    public let issues: [GitHubIssue]
    public let pullRequests: [GitHubPullRequest]
    public let actions: [GitHubActionRun]
    public let error: String?
    public let isLoaded: Bool
    public let mergeEvidenceLoaded: Bool

    public static let unavailable = GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil, isLoaded: false, mergeEvidenceLoaded: false)

    public init(issues: [GitHubIssue], pullRequests: [GitHubPullRequest], actions: [GitHubActionRun], error: String?, isLoaded: Bool = true, mergeEvidenceLoaded: Bool? = nil) {
        self.issues = issues
        self.pullRequests = pullRequests
        self.actions = actions
        self.error = error
        self.isLoaded = isLoaded
        self.mergeEvidenceLoaded = mergeEvidenceLoaded ?? isLoaded
    }

    public func verifiedMergedPullRequest(defaultBranch: String, branchName: String, localSHA: String) -> GitHubPullRequest? {
        guard mergeEvidenceLoaded, error == nil else { return nil }
        return pullRequests.first { pullRequest in
            pullRequest.state.uppercased() == "MERGED" &&
            pullRequest.mergedAt != nil &&
            pullRequest.baseRefName == defaultBranch &&
            pullRequest.headRefName == branchName &&
            pullRequest.headRefOid == localSHA
        }
    }
}

public struct GitHubIssue: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let state: String
    public let url: URL?
}

public struct GitHubPullRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let state: String
    public let isDraft: Bool
    public let baseRefName: String?
    public let headRefName: String?
    public let headRefOid: String?
    public let mergedAt: Date?
    public let url: URL?

    public init(id: String, number: Int, title: String, state: String, isDraft: Bool, baseRefName: String?, headRefName: String?, headRefOid: String?, mergedAt: Date?, url: URL?) {
        self.id = id
        self.number = number
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.mergedAt = mergedAt
        self.url = url
    }
}

public struct GitHubActionRun: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let conclusion: String?
    public let url: URL?
}

public struct RepositorySnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let defaultBranch: String?
    public let branches: [BranchInfo]
    public let refreshedAt: Date

    public init(path: String, defaultBranch: String?, branches: [BranchInfo], refreshedAt: Date = Date()) {
        self.id = path
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.refreshedAt = refreshedAt
    }
}

public enum CleanupBlockReason: Equatable, Sendable {
    case dirtyWorktree
    case unmergedBranch
    case activeSession
    case unknownSessionActivity
    case lockedWorktree
    case missingBranch
    case notStale
    case noDefaultBranch
    case detachedWorktree
    case defaultBranch
    case worktreeAttached
    case githubVerificationUnavailable
    case commandFailed(String)

    public var message: String {
        switch self {
        case .dirtyWorktree: return "Dirty worktree"
        case .unmergedBranch: return "Unmerged branch"
        case .activeSession: return "Active session linked"
        case .unknownSessionActivity: return "Session activity unknown"
        case .lockedWorktree: return "Locked worktree"
        case .missingBranch: return "Branch missing"
        case .notStale: return "Not stale"
        case .noDefaultBranch: return "Default branch unknown"
        case .detachedWorktree: return "Detached worktree"
        case .defaultBranch: return "Default branch cannot be deleted"
        case .worktreeAttached: return "Branch has worktree"
        case .githubVerificationUnavailable: return "GitHub verification unavailable"
        case .commandFailed(let message): return message
        }
    }
}

public enum CleanupOperation: String, Sendable {
    case removeWorktree = "Remove worktree"
    case deleteBranch = "Delete branch"
    case prune = "Prune worktree metadata"
    case deleteMergedBranches = "Clean up merged branches"
    case removeStaleWorktrees = "Remove stale worktrees"
    case deleteRemoteGoneBranches = "Delete remote-gone branches"
}

public enum CleanupPlanStep: String, Sendable {
    case removeWorktree = "Will remove worktree"
    case deleteBranch = "Then delete branch"
}

public struct CleanupPreviewItem: Identifiable, Sendable {
    public let id: String
    public let target: String
    public let allowed: Bool
    public let reason: CleanupBlockReason?
    public let detail: String?
    public let expectedSHA: String?
    public let step: CleanupPlanStep?

    public init(id: String, target: String, allowed: Bool, reason: CleanupBlockReason? = nil, detail: String? = nil, expectedSHA: String? = nil, step: CleanupPlanStep? = nil) {
        self.id = id
        self.target = target
        self.allowed = allowed
        self.reason = reason
        self.detail = detail
        self.expectedSHA = expectedSHA
        self.step = step
    }
}

public struct CleanupPreviewGroup: Identifiable, Sendable {
    public let id: String
    public let branchName: String
    public let expectedSHA: String?
    public let steps: [CleanupPreviewItem]

    public init(branchName: String, expectedSHA: String?, steps: [CleanupPreviewItem]) {
        self.id = branchName
        self.branchName = branchName
        self.expectedSHA = expectedSHA
        self.steps = steps
    }

    public var allowed: Bool { steps.allSatisfy(\.allowed) }
}

public struct CleanupPreview: Identifiable, Sendable {
    public let id = UUID()
    public let operation: CleanupOperation
    public let repositoryPath: String
    public let items: [CleanupPreviewItem]
    public let groups: [CleanupPreviewGroup]
    public let staleDays: Int?

    public init(operation: CleanupOperation, repositoryPath: String, items: [CleanupPreviewItem], staleDays: Int? = nil, groups: [CleanupPreviewGroup] = []) {
        self.operation = operation
        self.repositoryPath = repositoryPath
        self.items = items
        self.groups = groups
        self.staleDays = staleDays
    }

    public var allowedItems: [CleanupPreviewItem] { items.filter(\.allowed) }
}

public struct CleanupDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reason: CleanupBlockReason?

    public init(allowed: Bool, reason: CleanupBlockReason? = nil) {
        self.allowed = allowed
        self.reason = reason
    }
}
