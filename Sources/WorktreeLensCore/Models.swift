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
    public let isMerged: Bool
    public let remoteGone: Bool
    public let lastCommitAt: Date?
    public let isDefaultBranch: Bool
    public let isDetachedGroup: Bool
    public let defaultAhead: Int
    public let defaultBehind: Int
    public let worktrees: [WorktreeInfo]
    public let github: GitHubStatus

    public init(id: String, name: String, sha: String, upstream: String?, ahead: Int, behind: Int, isMerged: Bool, remoteGone: Bool, lastCommitAt: Date?, isDefaultBranch: Bool = false, isDetachedGroup: Bool = false, defaultAhead: Int = 0, defaultBehind: Int = 0, worktrees: [WorktreeInfo], github: GitHubStatus = .unavailable) {
        self.id = id
        self.name = name
        self.sha = sha
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isMerged = isMerged
        self.remoteGone = remoteGone
        self.lastCommitAt = lastCommitAt
        self.isDefaultBranch = isDefaultBranch
        self.isDetachedGroup = isDetachedGroup
        self.defaultAhead = defaultAhead
        self.defaultBehind = defaultBehind
        self.worktrees = worktrees
        self.github = github
    }
}

public struct GitHubStatus: Hashable, Sendable {
    public let issues: [GitHubIssue]
    public let pullRequests: [GitHubPullRequest]
    public let actions: [GitHubActionRun]
    public let error: String?

    public static let unavailable = GitHubStatus(issues: [], pullRequests: [], actions: [], error: nil)

    public init(issues: [GitHubIssue], pullRequests: [GitHubPullRequest], actions: [GitHubActionRun], error: String?) {
        self.issues = issues
        self.pullRequests = pullRequests
        self.actions = actions
        self.error = error
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
    public let mergedAt: Date?
    public let url: URL?
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
        case .commandFailed(let message): return message
        }
    }
}

public enum CleanupOperation: String, Sendable {
    case removeWorktree = "Remove worktree"
    case deleteBranch = "Delete branch"
    case prune = "Prune worktree metadata"
    case deleteMergedBranches = "Delete merged branches"
    case removeStaleWorktrees = "Remove stale worktrees"
    case deleteRemoteGoneBranches = "Delete remote-gone branches"
}

public struct CleanupPreviewItem: Identifiable, Sendable {
    public let id: String
    public let target: String
    public let allowed: Bool
    public let reason: CleanupBlockReason?

    public init(id: String, target: String, allowed: Bool, reason: CleanupBlockReason? = nil) {
        self.id = id
        self.target = target
        self.allowed = allowed
        self.reason = reason
    }
}

public struct CleanupPreview: Identifiable, Sendable {
    public let id = UUID()
    public let operation: CleanupOperation
    public let repositoryPath: String
    public let items: [CleanupPreviewItem]
    public let staleDays: Int?

    public init(operation: CleanupOperation, repositoryPath: String, items: [CleanupPreviewItem], staleDays: Int? = nil) {
        self.operation = operation
        self.repositoryPath = repositoryPath
        self.items = items
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
