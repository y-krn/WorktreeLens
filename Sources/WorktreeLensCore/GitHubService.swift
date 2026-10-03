import Foundation

public final class GitHubService: @unchecked Sendable {
    private let api: GitHubAPIClient
    private let display: GitHubDisplayService
    private let resolver: GitHubRepositoryResolver
    private let refreshMetrics: GitHubRefreshMetrics

    public init(api: GitHubAPIClient? = nil, resolver: GitHubRepositoryResolver = GitHubRepositoryResolver(),
                clock: any GitHubClock = SystemGitHubClock(), limits: GitHubDisplayLimits = GitHubDisplayLimits(),
                refreshMetrics: GitHubRefreshMetrics = GitHubRefreshMetrics()) {
        let client = api ?? GitHubAPIClient(authentication: GitHubDeviceFlowProvider(clientID: UserDefaults.standard.string(forKey: "githubAppClientID") ?? ""))
        self.api = client
        self.refreshMetrics = refreshMetrics
        self.display = GitHubDisplayService(api: client, clock: clock, limits: limits, metrics: refreshMetrics)
        self.resolver = resolver
    }

    public func refreshMetricsSnapshot() -> [GitHubTargetRefreshMetric] {
        refreshMetrics.snapshot()
    }

    public static let requestTimeout: TimeInterval = 10

    public func summariesAsync(repositoryPath: String, branches: [BranchInfo], timeout: TimeInterval = GitHubService.requestTimeout) async -> [String: GitHubStatus] {
        do {
            try Task.checkCancellation()
            let targets = try resolver.targets(path: repositoryPath, branches: branches)
            var statuses = await display.summaries(targets: targets, timeout: timeout)
            for branch in branches where statuses[branch.id] == nil {
                let error = "GitHub repository unresolved. Select a base repository with git config worktreelens.githubRepository owner/repo."
                statuses[branch.id] = GitHubStatus(issues: [], pullRequests: [], actions: [], error: error, isLoaded: false,
                    mergeEvidenceLoaded: false, pullRequestFetch: GitHubFetchState(phase: .failed, error: error), localSHA: branch.sha)
            }
            return statuses
        } catch {
            return Dictionary(uniqueKeysWithValues: branches.map { branch in
                (branch.id, GitHubStatus(issues: [], pullRequests: [], actions: [], error: error.localizedDescription, isLoaded: false,
                    mergeEvidenceLoaded: false, pullRequestFetch: GitHubFetchState(phase: .failed, error: error.localizedDescription), localSHA: branch.sha))
            })
        }
    }

    public func cachedStatusesAsync(repositoryPath: String, branches: [BranchInfo]) async -> [String: GitHubStatus] {
        do {
            let targets = try resolver.targets(path: repositoryPath, branches: branches)
            return await display.cachedStatuses(targets: targets)
        } catch {
            return [:]
        }
    }

    public func statusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubStatus {
        await statusAsync(repositoryPath: repositoryPath, branchInfo: branchInfo, timeout: timeout, refreshSummary: false)
    }

    public func refreshStatusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubStatus {
        await statusAsync(repositoryPath: repositoryPath, branchInfo: branchInfo, timeout: timeout, refreshSummary: true)
    }

    private func statusAsync(repositoryPath: String, branchInfo: BranchInfo, timeout: TimeInterval,
                             refreshSummary: Bool) async -> GitHubStatus {
        do {
            try Task.checkCancellation()
            guard let target = try resolver.targets(path: repositoryPath, branches: [branchInfo]).first else {
                return GitHubStatus(issues: [], pullRequests: branchInfo.github.pullRequests, actions: [], error: "GitHub repository unresolved.", isLoaded: false)
            }
            return await display.details(target: target, summary: branchInfo.github, timeout: timeout,
                                         refreshSummary: refreshSummary)
        } catch {
            return GitHubStatus(issues: [], pullRequests: branchInfo.github.pullRequests, actions: [], error: error.localizedDescription, isLoaded: false)
        }
    }

    public func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubStatus {
        guard let info = try? GitService().snapshot(repositoryPath: repositoryPath, sessions: []).branches.first(where: { $0.name == branch }) else {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: "Local branch unavailable.", isLoaded: false)
        }
        return await statusAsync(repositoryPath: repositoryPath, branchInfo: info, timeout: timeout)
    }

    /// Resolves authentication before Cleanup begins its destructive steps. This never starts Device Flow.
    public func prepareCleanupVerification(repositoryPath: String, branches: [BranchInfo]) async throws {
        let targets = try resolver.targets(path: repositoryPath, branches: branches)
        guard targets.count == branches.count else { throw CleanupVerificationError.repositoryUnresolved }
        _ = try await api.requestContext()
    }

    /// Gets fresh GitHub evidence without reading or updating display state or sharing its in-flight requests.
    public func verifyCleanupPullRequest(repositoryPath: String, branch: String, localSHA: String,
                                         defaultBranch: String, knownNumber: Int? = nil,
                                         timeout: TimeInterval = GitHubService.requestTimeout) async throws -> GitHubPullRequest {
        if let knownNumber, knownNumber <= 0 { throw CleanupVerificationError.invalidPullRequestNumber }
        let localBranch = BranchInfo(id: branch, name: branch, sha: localSHA, upstream: nil, ahead: 0, behind: 0,
                                     isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
        guard let target = try resolver.targets(path: repositoryPath, branches: [localBranch]).first else {
            throw CleanupVerificationError.repositoryUnresolved
        }

        let context = try await api.requestContext()
        let deadline = Date().addingTimeInterval(timeout)
        var cursor: String?
        var fetched = 0
        var requests = 0
        var totalCost = 0
        var selected: CleanupWirePullRequest?
        var identity: CleanupRepositoryPair?
        while true {
            guard requests < Self.cleanupMaxRequests, fetched < Self.cleanupMaxPullRequests else {
                throw CleanupVerificationError.incomplete
            }
            requests += 1
            let response: GitHubGraphQLResult<CleanupGraphData> = try await api.graphQL(
                query: cleanupQuery(target: target, knownNumber: knownNumber, cursor: cursor),
                variables: [String: String](), deadline: deadline, context: context, shareInFlight: false)
            guard !response.hasErrors, let base = response.data?.base, let head = response.data?.head,
                  base.nameWithOwner.caseInsensitiveCompare(target.base.fullName) == .orderedSame,
                  head.nameWithOwner.caseInsensitiveCompare(target.head.fullName) == .orderedSame,
                  !(base.isFork == true && !target.explicitBase) else { throw CleanupVerificationError.identityUnavailable }
            let pair = CleanupRepositoryPair(baseID: base.id, headID: head.id)
            if let identity, identity != pair { throw CleanupVerificationError.identityChanged }
            identity = pair
            guard let requestCost = response.data?.rateLimitCost else { throw CleanupVerificationError.incomplete }
            totalCost += requestCost
            guard totalCost <= Self.cleanupMaxCost else { throw CleanupVerificationError.incomplete }

            if let knownNumber {
                guard let pr = base.pullRequest, pr.number == knownNumber else { throw CleanupVerificationError.pullRequestUnavailable }
                selected = pr
                break
            }

            guard let page = base.pullRequests, let nodes = page.nodes else { throw CleanupVerificationError.incomplete }
            fetched += nodes.count
            let matches = nodes.compactMap { $0 }.filter {
                $0.baseRefName == defaultBranch && $0.headRefName == branch && $0.headRefOid == localSHA &&
                $0.baseRepository?.nameWithOwner.caseInsensitiveCompare(target.base.fullName) == .orderedSame &&
                $0.headRepository?.nameWithOwner.caseInsensitiveCompare(target.head.fullName) == .orderedSame
            }
            if matches.count > 1 { throw CleanupVerificationError.ambiguousPullRequest }
            if let match = matches.first {
                if let selected, selected.number != match.number { throw CleanupVerificationError.ambiguousPullRequest }
                selected = match
            }
            if !page.pageInfo.hasNextPage { break }
            guard let next = page.pageInfo.endCursor, next != cursor else { throw CleanupVerificationError.incomplete }
            cursor = next
        }

        guard let selected, let identity,
              selected.number > 0,
              selected.state.uppercased() == "MERGED",
              let mergedAtText = selected.mergedAt,
              let mergedAt = parseCleanupDate(mergedAtText),
              selected.baseRefName == defaultBranch,
              selected.headRefName == branch,
              selected.headRefOid == localSHA,
              selected.baseRepository?.id == identity.baseID,
              selected.baseRepository?.nameWithOwner.caseInsensitiveCompare(target.base.fullName) == .orderedSame,
              selected.headRepository?.id == identity.headID,
              selected.headRepository?.nameWithOwner.caseInsensitiveCompare(target.head.fullName) == .orderedSame,
              knownNumber == nil || selected.number == knownNumber else { throw CleanupVerificationError.pullRequestMismatch }
        return selected.model(mergedAt: mergedAt)
    }

    private static let cleanupMaxRequests = 40
    private static let cleanupMaxPullRequests = 2_000
    private static let cleanupMaxCost = 1_000
    private static let cleanupPRFields = "number state baseRefName headRefName headRefOid mergedAt url baseRepository { id nameWithOwner } headRepository { id nameWithOwner }"

    private func parseCleanupDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private func cleanupQuery(target: GitHubBranchTarget, knownNumber: Int?, cursor: String?) -> String {
        func literal(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
        let baseFields: String
        if let knownNumber {
            baseFields = "pullRequest(number: \(knownNumber)) { \(Self.cleanupPRFields) }"
        } else {
            let after = cursor.map { ", after: \(literal($0))" } ?? ""
            baseFields = "pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], headRefName: \(literal(target.branch)), orderBy: {field: UPDATED_AT, direction: DESC}\(after)) { nodes { \(Self.cleanupPRFields) } pageInfo { hasNextPage endCursor } }"
        }
        return "query { base: repository(owner: \(literal(target.base.owner)), name: \(literal(target.base.name))) { id nameWithOwner isFork \(baseFields) } head: repository(owner: \(literal(target.head.owner)), name: \(literal(target.head.name))) { id nameWithOwner } rateLimit { cost } }"
    }
}

private enum CleanupVerificationError: Error, LocalizedError {
    case repositoryUnresolved, invalidPullRequestNumber, incomplete, identityUnavailable, identityChanged
    case pullRequestUnavailable, ambiguousPullRequest, pullRequestMismatch
    var errorDescription: String? {
        switch self {
        case .repositoryUnresolved: return "GitHub repository identity could not be resolved."
        case .invalidPullRequestNumber: return "Expected GitHub PR number is invalid."
        case .incomplete: return "GitHub cleanup verification was incomplete."
        case .identityUnavailable: return "GitHub repository identity could not be verified."
        case .identityChanged: return "GitHub repository identity changed during verification."
        case .pullRequestUnavailable: return "Expected GitHub PR could not be retrieved."
        case .ambiguousPullRequest: return "Multiple GitHub PRs match this branch and SHA."
        case .pullRequestMismatch: return "GitHub PR no longer matches the cleanup target."
        }
    }
}

private struct CleanupRepositoryPair: Equatable {
    let baseID: String
    let headID: String
}

private struct CleanupGraphData: Decodable, Sendable {
    let base: CleanupGraphRepository?
    let head: CleanupGraphRepository?
    let rateLimit: CleanupRateLimit?
    var rateLimitCost: Int? { rateLimit?.cost }
}

private struct CleanupRateLimit: Decodable, Sendable { let cost: Int }

private struct CleanupGraphRepository: Decodable, Sendable {
    let id: String
    let nameWithOwner: String
    let isFork: Bool?
    let pullRequest: CleanupWirePullRequest?
    let pullRequests: CleanupPullRequestPage?
}

private struct CleanupPullRequestPage: Decodable, Sendable {
    let nodes: [CleanupWirePullRequest?]?
    let pageInfo: CleanupPageInfo
}

private struct CleanupPageInfo: Decodable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct CleanupWireRepository: Decodable, Sendable {
    let id: String
    let nameWithOwner: String
}

private struct CleanupWirePullRequest: Decodable, Sendable {
    let number: Int
    let state: String
    let baseRefName: String?
    let headRefName: String?
    let headRefOid: String?
    let mergedAt: String?
    let url: String?
    let baseRepository: CleanupWireRepository?
    let headRepository: CleanupWireRepository?
    func model(mergedAt: Date) -> GitHubPullRequest {
        GitHubPullRequest(id: "pr-\(number)", number: number, title: "", state: state, isDraft: false,
                          baseRefName: baseRefName, headRefName: headRefName, headRefOid: headRefOid,
                          mergedAt: mergedAt, url: URL(string: url ?? ""),
                          baseRepositoryID: baseRepository?.id, headRepositoryID: headRepository?.id,
                          baseRepositoryName: baseRepository?.nameWithOwner, headRepositoryName: headRepository?.nameWithOwner)
    }
}
