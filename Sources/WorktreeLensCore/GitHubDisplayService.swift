import Foundation

public struct GitHubRepositoryIdentity: Hashable, Sendable {
    public let owner: String
    public let name: String
    public var fullName: String { "\(owner)/\(name)" }
    public init?(fullName: String) {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        owner = String(parts[0]); name = String(parts[1])
    }
    public static func remote(_ value: String) -> Self? {
        let path: String
        if value.hasPrefix("git@github.com:") { path = String(value.dropFirst("git@github.com:".count)) }
        else if let url = URL(string: value), url.host?.lowercased() == "github.com",
                ["https", "ssh"].contains(url.scheme ?? ""), url.password == nil, url.query == nil, url.fragment == nil {
            path = String(url.path.drop(while: { $0 == "/" }))
        } else { return nil }
        return Self(fullName: path.hasSuffix(".git") ? String(path.dropLast(4)) : path)
    }
}

public struct GitHubBranchTarget: Hashable, Sendable {
    public let branchID: String
    public let branch: String
    public let sha: String
    public let base: GitHubRepositoryIdentity
    public let head: GitHubRepositoryIdentity
    public let knownNumbers: [Int]
    public let explicitBase: Bool
    public init(branchID: String, branch: String, sha: String, base: GitHubRepositoryIdentity, head: GitHubRepositoryIdentity,
                knownNumbers: [Int] = [], explicitBase: Bool = false) {
        self.branchID = branchID; self.branch = branch; self.sha = sha; self.base = base; self.head = head
        self.knownNumbers = knownNumbers; self.explicitBase = explicitBase
    }
}

/// Resolves all branches from one local config read; origin is never assumed to be the PR base.
public struct GitHubRepositoryResolver: Sendable {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = LocalProcessRunner()) { self.runner = runner }
    public func targets(path: String, branches: [BranchInfo]) throws -> [GitHubBranchTarget] {
        let output = try runner.run("/usr/bin/git", arguments: ["-C", path, "config", "--list"], currentDirectory: nil, timeout: 10)
        guard output.succeeded else { throw ProcessRunnerError.failed("Cannot resolve GitHub remotes.") }
        var config: [String: [String]] = [:]
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { config[String(parts[0]), default: []].append(String(parts[1])) }
        }
        var remotes: [String: GitHubRepositoryIdentity] = [:]
        for (key, values) in config where key.hasPrefix("remote.") && key.hasSuffix(".url") {
            // Multiple URLs with different repository identities are ambiguous.
            let ids = Set(values.compactMap(GitHubRepositoryIdentity.remote))
            if ids.count == 1, ids.count == Set(values).count {
                remotes[String(key.dropFirst(7).dropLast(4))] = ids.first
            }
        }
        let explicitValue = config["worktreelens.githubrepository"]?.last
        let explicit = explicitValue.flatMap(GitHubRepositoryIdentity.init(fullName:))
        if explicitValue != nil && explicit == nil { return [] }
        return branches.compactMap { branch in
            guard !branch.isDetachedGroup else { return nil }
            let remoteName = config["branch.\(branch.name).remote"]?.last
            let head = remoteName.flatMap { remotes[$0] }
            let base = explicit ?? remotes["upstream"] ?? (Set(remotes.values).count == 1 ? remotes.values.first : nil)
            guard let base else { return nil }
            // A configured but unresolvable upstream cannot silently become the base repository.
            guard remoteName == nil || head != nil else { return nil }
            guard head != nil || Set(remotes.values).count <= 1 else { return nil }
            let numbers = branch.github.pullRequests.filter {
                $0.baseRepositoryName?.lowercased() == base.fullName.lowercased() &&
                $0.headRepositoryName?.lowercased() == (head ?? base).fullName.lowercased() && $0.headRefName == branch.name
            }.map(\.number)
            return GitHubBranchTarget(branchID: branch.id, branch: branch.name, sha: branch.sha, base: base, head: head ?? base,
                                      knownNumbers: numbers, explicitBase: explicit != nil || remotes["upstream"] != nil)
        }
    }
}

public struct GitHubDisplayLimits: Sendable {
    public var batchSize = 10
    public var pageSize = 30
    public var maxRequests = 40
    public var maxItems = 2_000
    public var maxCost = 1_000
    public init() {}
}

public struct GitHubTargetRefreshMetric: Hashable, Sendable {
    public let branchID: String
    public let baseRepository: String
    public let headRepository: String
    public let branch: String
    public let sha: String
    public let refreshCount: Int
    public let apiRequestCount: Int
    public let lastAPIRequestCount: Int
    public let totalLatency: TimeInterval
    public let lastLatency: TimeInterval
}

public final class GitHubRefreshMetrics: @unchecked Sendable {
    private struct Key: Hashable {
        let branchID: String
        let baseRepository: String
        let headRepository: String
        let branch: String
        let sha: String
        init(_ target: GitHubBranchTarget) {
            branchID = target.branchID; baseRepository = target.base.fullName; headRepository = target.head.fullName
            branch = target.branch; sha = target.sha
        }
    }
    private struct Value {
        var refreshCount = 0
        var apiRequestCount = 0
        var lastAPIRequestCount = 0
        var totalLatency: TimeInterval = 0
        var lastLatency: TimeInterval = 0
    }
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    public init() {}

    public func snapshot() -> [GitHubTargetRefreshMetric] {
        lock.lock(); defer { lock.unlock() }
        return values.map { key, value in
            GitHubTargetRefreshMetric(branchID: key.branchID, baseRepository: key.baseRepository,
                headRepository: key.headRepository, branch: key.branch, sha: key.sha,
                refreshCount: value.refreshCount, apiRequestCount: value.apiRequestCount,
                lastAPIRequestCount: value.lastAPIRequestCount, totalLatency: value.totalLatency,
                lastLatency: value.lastLatency)
        }.sorted {
            ($0.baseRepository, $0.branch, $0.sha, $0.branchID) < ($1.baseRepository, $1.branch, $1.sha, $1.branchID)
        }
    }

    fileprivate func record(target: GitHubBranchTarget, apiRequestCount: Int, latency: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        var value = values[Key(target)] ?? Value()
        value.refreshCount += 1
        value.apiRequestCount += apiRequestCount
        value.lastAPIRequestCount = apiRequestCount
        value.lastLatency = max(0, latency)
        value.totalLatency += value.lastLatency
        values[Key(target)] = value
    }
}

private struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }
private struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    let nodes: [Node?]?
    let pageInfo: PageInfo
    var availableNodes: [Node?] { nodes ?? [] }
    var isIncomplete: Bool { nodes == nil || availableNodes.contains { $0 == nil } }
}
private struct WireIdentity: Decodable, Sendable { let id: String; let nameWithOwner: String }
private struct WireIssue: Decodable, Sendable {
    let id: String; let number: Int; let title: String; let state: String; let url: String; let repository: WireIdentity
    var model: GitHubIssue {
        GitHubIssue(id: id, number: number, title: title, state: state, url: URL(string: url),
                    repositoryID: repository.id, repositoryName: repository.nameWithOwner)
    }
}
private struct WirePR: Decodable, Sendable {
    let id: String; let number: Int; let title: String; let state: String; let isDraft: Bool
    let baseRefName: String; let headRefName: String; let headRefOid: String; let mergedAt: String?; let url: String
    let baseRepository: WireIdentity?; let headRepository: WireIdentity?
    let mergeStateStatus: String?; let mergeable: String?; let potentialMergeCommit: WireOID?
    let closingIssuesReferences: Connection<WireIssue>?
    var model: GitHubPullRequest {
        GitHubPullRequest(id: id, number: number, title: title, state: state, isDraft: isDraft, baseRefName: baseRefName,
                          headRefName: headRefName, headRefOid: headRefOid, mergedAt: mergedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                          url: URL(string: url), baseRepositoryID: baseRepository?.id, headRepositoryID: headRepository?.id,
                          baseRepositoryName: baseRepository?.nameWithOwner, headRepositoryName: headRepository?.nameWithOwner,
                          mergeStateStatus: mergeStateStatus, mergeable: mergeable, testMergeSHA: potentialMergeCommit?.oid)
    }
}
private struct WireOID: Decodable, Sendable { let oid: String }
private struct WireCheck: Decodable, Sendable {
    let __typename: String
    let id: String
    let name: String?; let context: String?; let status: String?; let conclusion: String?; let state: String?
    func model(sha: String) -> GitHubCheck {
        GitHubCheck(id: id, name: name ?? context ?? "Unknown", kind: __typename, result: conclusion ?? state ?? status ?? "UNKNOWN", sha: sha)
    }
}
private struct WireCommit: Decodable, Sendable {
    let oid: String
    let statusCheckRollup: Rollup?
    struct Rollup: Decodable, Sendable { let contexts: Connection<WireCheck>? }
}
private struct WireRepo: Decodable, Sendable {
    let id: String; let nameWithOwner: String; let isFork: Bool
    let pullRequests: Connection<WirePR>?
    let pullRequest: WirePR?
    let object: WireCommit?
}
private struct WireRate: Decodable, Sendable { let cost: Int }
private struct GraphData: Decodable, Sendable {
    let repositories: [String: WireRepo]
    let cost: Int
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        var repos: [String: WireRepo] = [:]
        for key in values.allKeys where key.stringValue != "rateLimit" {
            if let repo = try values.decodeIfPresent(WireRepo.self, forKey: key) { repos[key.stringValue] = repo }
        }
        repositories = repos
        cost = try values.decodeIfPresent(WireRate.self, forKey: Key(stringValue: "rateLimit")!)?.cost ?? 0
    }
    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
private struct WireRuns: Decodable, Sendable {
    let total_count: Int; let workflow_runs: [Run]
    struct Run: Decodable, Sendable {
        let id: Int; let name: String?; let status: String; let conclusion: String?; let html_url: String
        let head_sha: String; let event: String; let run_attempt: Int; let head_branch: String?
        let repository: Repo; let head_repository: Repo?
        struct Repo: Decodable, Sendable { let full_name: String }
    }
}

/// Display evidence only. Destructive cleanup must still perform its independent final verification.
public struct GitHubDisplayService: Sendable {
    private let api: GitHubAPIClient
    private let stateStore: GitHubStateStore
    private let clock: any GitHubClock
    private let limits: GitHubDisplayLimits
    private let metrics: GitHubRefreshMetrics
    public init(api: GitHubAPIClient, clock: any GitHubClock = SystemGitHubClock(), limits: GitHubDisplayLimits = GitHubDisplayLimits(), metrics: GitHubRefreshMetrics = GitHubRefreshMetrics()) {
        self.api = api; self.stateStore = api.stateStore; self.clock = clock; self.limits = limits; self.metrics = metrics
    }
    private static let prFields = """
    id number title state isDraft baseRefName headRefName headRefOid mergedAt url
    baseRepository { id nameWithOwner } headRepository { id nameWithOwner }
    """
    private static let issueFields = "id number title state url repository { id nameWithOwner }"
    private static let checkFields = """
    __typename ... on CheckRun { id name status conclusion } ... on StatusContext { id context state }
    """
    private func literal(_ value: String) -> String {
        // JSON string escaping is valid for a GraphQL string literal; no query text comes from unescaped branch names.
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
    private func repository(_ target: GitHubBranchTarget, fields: String) -> String {
        "repository(owner: \(literal(target.base.owner)), name: \(literal(target.base.name))) { id nameWithOwner isFork \(fields) }"
    }
    private func accepted(_ pr: WirePR, target: GitHubBranchTarget, repo: WireRepo) -> Bool {
        let sameRepository = target.head.fullName.lowercased() == target.base.fullName.lowercased()
        return repo.nameWithOwner.lowercased() == target.base.fullName.lowercased() &&
        pr.baseRepository?.id == repo.id && pr.baseRepository?.nameWithOwner.lowercased() == target.base.fullName.lowercased() &&
        pr.headRepository?.nameWithOwner.lowercased() == target.head.fullName.lowercased() &&
        (!sameRepository || pr.headRepository?.id == repo.id) && pr.headRefName == target.branch
    }
    private struct Budget {
        var requests = 0; var items = 0; var cost = 0
        var requestsByTarget: [String: Int] = [:]
        let deadline: Date
        let requestContext: GitHubRequestContext?
    }
    private func available(_ budget: Budget) async -> Bool {
        let now = await clock.now()
        return !Task.isCancelled && budget.requests < limits.maxRequests && budget.items < limits.maxItems &&
        budget.cost < limits.maxCost && now < budget.deadline
    }
    private func bounded<Value: Sendable>(deadline: Date, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let remaining = deadline.timeIntervalSince(await clock.now())
        guard remaining > 0 else { throw ProcessRunnerError.failed("GitHub retrieval deadline reached.") }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(seconds: remaining)
                try Task.checkCancellation()
                throw ProcessRunnerError.failed("GitHub retrieval deadline reached.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func query(_ fields: String, budget: inout Budget, targets: [GitHubBranchTarget] = []) async throws -> GitHubGraphQLResult<GraphData> {
        guard await available(budget) else { throw ProcessRunnerError.failed("GitHub retrieval budget exhausted.") }
        budget.requests += 1
        for target in targets { budget.requestsByTarget[target.branchID, default: 0] += 1 }
        let deadline = budget.deadline
        let requestContext = budget.requestContext
        let result: GitHubGraphQLResult<GraphData> = try await bounded(deadline: deadline) {
            try await api.graphQL(query: "query { \(fields) rateLimit { cost } }", variables: [String: String](),
                                  deadline: deadline, context: requestContext)
        }
        budget.cost += result.data?.cost ?? limits.maxCost
        return result
    }
    public func summaries(targets: [GitHubBranchTarget], timeout: TimeInterval = 10) async -> [String: GitHubStatus] {
        let startedAt = await clock.now()
        let context = try? await api.requestContext()
        var budget = Budget(deadline: (await clock.now()).addingTimeInterval(timeout), requestContext: context)
        let result = await summaries(targets: targets, budget: &budget)
        let completedAt = await clock.now()
        for target in targets {
            metrics.record(target: target, apiRequestCount: budget.requestsByTarget[target.branchID, default: 0],
                           latency: completedAt.timeIntervalSince(startedAt))
        }
        return result
    }
    public func cachedStatuses(targets: [GitHubBranchTarget]) async -> [String: GitHubStatus] {
        guard let context = try? await api.requestContext() else { return [:] }
        var result: [String: GitHubStatus] = [:]
        for target in targets {
            if let status = await stateStore.cachedStatus(accountIdentifier: context.accountIdentifier, target: target) {
                result[target.branchID] = status
            }
        }
        return result
    }
    private func summaries(targets: [GitHubBranchTarget], budget: inout Budget) async -> [String: GitHubStatus] {
        let accountIdentifier = budget.requestContext?.accountIdentifier
        var result: [String: GitHubStatus] = [:]
        let size = max(1, min(limits.batchSize, 20))
        for start in stride(from: 0, to: targets.count, by: size) {
            let batch = Array(targets[start..<min(start + size, targets.count)])
            var repositoryIDs: [Int: String] = [:]
            var pending = batch.indices.map { ($0, Optional<String>.none) }
            var found: [Int: [WirePR]] = [:]
            var errors: [Int: String] = [:]
            var incomplete = Set<Int>()
            // A known number is fetched directly. Branch connections remain targeted and paginate only as needed.
            var knownPending = batch.indices.flatMap { index in batch[index].knownNumbers.map { (index, $0) } }
            pending.removeAll { !batch[$0.0].knownNumbers.isEmpty }
            while (!pending.isEmpty || !knownPending.isEmpty), await available(budget) {
                let remainingItems = max(1, limits.maxItems - budget.items)
                let known = Array(knownPending.prefix(min(size, remainingItems))); knownPending.removeFirst(known.count)
                let work = Array(pending.prefix(min(size - known.count, remainingItems - known.count))); pending.removeFirst(work.count)
                let pageSize = max(1, min(limits.pageSize, 100, (remainingItems - known.count) / max(1, work.count)))
                let fields = work.enumerated().map { offset, item in
                    let cursor = item.1.map { ", after: \(literal($0))" } ?? ""
                    return "b\(offset): " + repository(batch[item.0], fields: "pullRequests(first: \(pageSize), headRefName: \(literal(batch[item.0].branch)), orderBy: {field: CREATED_AT, direction: DESC}\(cursor)) { nodes { \(Self.prFields) } pageInfo { hasNextPage endCursor } }")
                } + known.enumerated().map { offset, item in
                    "k\(offset): " + repository(batch[item.0], fields: "pullRequest(number: \(item.1)) { \(Self.prFields) }")
                }
                do {
                    let requestedIDs = Set(work.map { batch[$0.0].branchID } + known.map { batch[$0.0].branchID })
                    let requestTargets = batch.filter { requestedIDs.contains($0.branchID) }
                    let response = try await query(fields.joined(separator: "\n"), budget: &budget, targets: requestTargets)
                    for (offset, item) in work.enumerated() {
                        let index = item.0
                        guard let repo = response.data?.repositories["b\(offset)"], let page = repo.pullRequests,
                              !repo.isFork || batch[index].explicitBase else {
                            errors[index] = "GitHub repository or PR connection unresolved."; continue
                        }
                        repositoryIDs[index] = repo.id
                        budget.items += page.availableNodes.count
                        found[index, default: []] += page.availableNodes.compactMap { $0 }.filter { accepted($0, target: batch[index], repo: repo) }
                        if page.availableNodes.compactMap({ $0 }).contains(where: { $0.headRefName == batch[index].branch && ($0.headRepository == nil || $0.baseRepository == nil) }) {
                            incomplete.insert(index); errors[index] = "GitHub PR repository identity unavailable."
                        }
                        if response.hasErrors(at: "b\(offset)") || page.isIncomplete {
                            incomplete.insert(index); errors[index] = "GitHub GraphQL partial response."
                        }
                        if page.pageInfo.hasNextPage {
                            if let cursor = page.pageInfo.endCursor, cursor != item.1 { pending.append((index, cursor)) }
                            else { incomplete.insert(index) }
                        }
                    }
                    for (offset, item) in known.enumerated() {
                        guard let repo = response.data?.repositories["k\(offset)"], let pr = repo.pullRequest,
                              (!repo.isFork || batch[item.0].explicitBase), pr.number == item.1, accepted(pr, target: batch[item.0], repo: repo) else {
                            errors[item.0] = "Known GitHub PR identity unresolved."; continue
                        }
                        repositoryIDs[item.0] = repo.id
                        budget.items += 1; found[item.0, default: []].append(pr)
                        // A closed, unmerged PR can be replaced without changing the branch SHA.
                        let needsDiscovery = pr.headRefOid != batch[item.0].sha || (pr.state == "CLOSED" && pr.mergedAt == nil)
                        if needsDiscovery, !pending.contains(where: { $0.0 == item.0 }) {
                            pending.append((item.0, nil))
                        }
                        if response.hasErrors(at: "k\(offset)") { incomplete.insert(item.0); errors[item.0] = "GitHub GraphQL partial response." }
                    }
                } catch {
                    for item in work { errors[item.0] = error.localizedDescription }
                    for item in known { errors[item.0] = error.localizedDescription }
                }
            }
            for item in pending { incomplete.insert(item.0) }
            for item in knownPending { incomplete.insert(item.0) }
            let deadlineReached = (await clock.now()) >= budget.deadline
            for index in batch.indices {
                let prs = Array(Dictionary(found[index, default: []].map { ($0.id, $0.model) }, uniquingKeysWith: { _, latest in latest }).values).sorted { $0.number < $1.number }
                if budget.items > limits.maxItems || budget.cost > limits.maxCost || deadlineReached { incomplete.insert(index) }
                let phase: GitHubFetchState.Phase = incomplete.contains(index) ? .incomplete : errors[index] == nil ? .loaded : prs.isEmpty ? .failed : .incomplete
                let attemptedAt = await clock.now()
                let fetch = GitHubFetchState(phase: phase, fetchedAt: phase == .loaded ? attemptedAt : nil,
                                             lastAttemptAt: attemptedAt,
                                             error: errors[index] ?? (phase == .incomplete ? "GitHub retrieval incomplete." : nil))
                let status = GitHubStatus(issues: [], pullRequests: prs, actions: [], error: fetch.error,
                    isLoaded: false, mergeEvidenceLoaded: fetch.isComplete, pullRequestFetch: fetch, localSHA: batch[index].sha)
                if let accountIdentifier {
                    result[batch[index].branchID] = await stateStore.recordStatus(accountIdentifier: accountIdentifier,
                        target: batch[index], repositoryID: repositoryIDs[index],
                        sessionRevision: budget.requestContext?.revision, status: status)
                } else {
                    result[batch[index].branchID] = status
                }
            }
        }
        return result
    }

    public func details(target: GitHubBranchTarget, summary: GitHubStatus, timeout: TimeInterval = 10,
                        refreshSummary: Bool = false) async -> GitHubStatus {
        let startedAt = await clock.now()
        let context = try? await api.requestContext()
        let accountIdentifier = context?.accountIdentifier
        var budget = Budget(deadline: (await clock.now()).addingTimeInterval(timeout), requestContext: context)
        var resolvedRepositoryID: String?
        var prs = summary.pullRequests
        var prFetch = summary.pullRequestFetch
        if refreshSummary || prFetch.phase == .notRequested {
            let loaded = await summaries(targets: [target], budget: &budget)
            if let status = loaded[target.branchID] { prs = status.pullRequests; prFetch = status.pullRequestFetch }
        }
        var issues: [GitHubIssue] = []; var checks: [GitHubCheck] = []; var actions: [GitHubActionRun] = []
        var issueFetch = GitHubFetchState.notRequested
        var checkFetch = GitHubFetchState.notRequested
        var actionFetch = GitHubFetchState.notRequested
        var issuePending = prs.map { ($0.number, Optional<String>.none) }
        var checkPending = true
        var checkCursor: String?
        var issueError: String?; var checkError: String?
        var issuesIncomplete = false; var checksIncomplete = false
        while (!issuePending.isEmpty || checkPending), await available(budget) {
            let remainingItems = max(1, limits.maxItems - budget.items)
            let work = Array(issuePending.prefix(max(0, min(limits.batchSize, 20, remainingItems - (checkPending ? 1 : 0))))); issuePending.removeFirst(work.count)
            let pageSize = max(1, min(100, remainingItems / max(1, work.count + (checkPending ? 1 : 0))))
            let fields = work.enumerated().map { index, item in
                let cursor = item.1.map { ", after: \(literal($0))" } ?? ""
                return "i\(index): " + repository(target, fields: "pullRequest(number: \(item.0)) { \(Self.prFields) mergeStateStatus mergeable potentialMergeCommit { oid } closingIssuesReferences(first: \(pageSize)\(cursor)) { nodes { \(Self.issueFields) } pageInfo { hasNextPage endCursor } } }")
            } + (checkPending ? ["ci: " + repository(target, fields: "object(expression: \(literal(target.sha))) { ... on Commit { oid statusCheckRollup { contexts(first: \(pageSize)\(checkCursor.map { ", after: \(literal($0))" } ?? "")) { nodes { \(Self.checkFields) } pageInfo { hasNextPage endCursor } } } } }")] : [])
            do {
                let response = try await query(fields.joined(separator: "\n"), budget: &budget, targets: [target])
                for (offset, item) in work.enumerated() {
                    guard let repo = response.data?.repositories["i\(offset)"], let pr = repo.pullRequest,
                          pr.number == item.0, accepted(pr, target: target, repo: repo) else {
                        issueError = "GitHub PR details unavailable."; issuesIncomplete = true
                        prFetch = GitHubFetchState(phase: .incomplete, fetchedAt: prFetch.fetchedAt,
                                                   lastAttemptAt: await clock.now(), stale: prFetch.fetchedAt != nil, error: issueError)
                        continue
                    }
                    resolvedRepositoryID = repo.id
                    if let index = prs.firstIndex(where: { $0.number == pr.number }) { prs[index] = pr.model }
                    let fetchedAt = prFetch.phase == .loaded ? await clock.now() : prFetch.fetchedAt
                    prFetch = GitHubFetchState(phase: prFetch.phase, fetchedAt: fetchedAt,
                                               lastAttemptAt: await clock.now(), stale: prFetch.stale, error: prFetch.error)
                    guard let page = pr.closingIssuesReferences else {
                        issueError = "GitHub linked issues unavailable."; issuesIncomplete = true; continue
                    }
                    issues += page.availableNodes.compactMap { $0?.model }; budget.items += page.availableNodes.count
                    if response.hasErrors(at: "i\(offset)") || page.isIncomplete { issuesIncomplete = true; issueError = "GitHub GraphQL partial response." }
                    if page.pageInfo.hasNextPage {
                        if let cursor = page.pageInfo.endCursor, cursor != item.1 { issuePending.append((item.0, cursor)) }
                        else { issuesIncomplete = true }
                    }
                }
                if checkPending {
                    if let repo = response.data?.repositories["ci"], repo.nameWithOwner.lowercased() == target.base.fullName.lowercased(),
                       let commit = repo.object, commit.oid == target.sha {
                        resolvedRepositoryID = repo.id
                        if let page = commit.statusCheckRollup?.contexts {
                            checks += page.availableNodes.compactMap { $0?.model(sha: commit.oid) }; budget.items += page.availableNodes.count
                            checkPending = page.pageInfo.hasNextPage
                            if checkPending {
                                if let cursor = page.pageInfo.endCursor, cursor != checkCursor { checkCursor = cursor }
                                else { checkPending = false; checksIncomplete = true }
                            }
                            if page.isIncomplete { checksIncomplete = true }
                        } else { checkPending = false }
                        if response.hasErrors(at: "ci") { checksIncomplete = true; checkError = "GitHub GraphQL partial response." }
                    } else { checkPending = false; checkError = "Local HEAD checks unavailable (unpublished or inaccessible SHA)." }
                }
            } catch {
                if !work.isEmpty { issueError = error.localizedDescription; issuesIncomplete = true }
                if checkPending { checkError = error.localizedDescription; checkPending = false }
            }
        }
        if budget.items > limits.maxItems || budget.cost > limits.maxCost { issuesIncomplete = true; checksIncomplete = true }
        let now = await clock.now()
        let issuePhase: GitHubFetchState.Phase = !prFetch.isComplete || issuesIncomplete || !issuePending.isEmpty ? .incomplete : .loaded
        let checkPhase: GitHubFetchState.Phase = checksIncomplete || checkPending ? .incomplete : checkError != nil ? (checks.isEmpty ? .failed : .incomplete) : .loaded
        issueFetch = GitHubFetchState(phase: issuePhase, fetchedAt: issuePhase == .loaded ? now : nil, lastAttemptAt: now, error: issueError)
        checkFetch = GitHubFetchState(phase: checkPhase, fetchedAt: checkPhase == .loaded ? now : nil, lastAttemptAt: now, error: checkError)
        var page = 1; var count = 0; var total = Int.max; var actionError: String?
        let actionPageSize = max(1, min(100, limits.maxItems - budget.items))
        while count < total, await available(budget) {
            do {
                budget.requests += 1
                budget.requestsByTarget[target.branchID, default: 0] += 1
                let deadline = budget.deadline
                let requestContext = budget.requestContext
                let path = "/repos/\(target.base.fullName)/actions/runs?head_sha=\(target.sha.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&per_page=\(actionPageSize)&page=\(page)"
                let runs: WireRuns = try await bounded(deadline: deadline) {
                    try await api.get(path: path, deadline: deadline, context: requestContext)
                }
                total = runs.total_count; count += runs.workflow_runs.count; budget.items += runs.workflow_runs.count
                actions += runs.workflow_runs.map { run in
                    GitHubActionRun(id: "\(run.repository.full_name):\(run.id):\(run.run_attempt)", name: run.name ?? "Workflow", status: run.status,
                                    conclusion: run.conclusion, url: URL(string: run.html_url), headSHA: run.head_sha, event: run.event,
                                    runID: run.id, attempt: run.run_attempt, repositoryName: run.repository.full_name,
                                    isCurrent: run.head_sha == target.sha && run.event == "push" && run.head_branch == target.branch &&
                                    run.repository.full_name.lowercased() == target.base.fullName.lowercased() &&
                                    run.head_repository?.full_name.lowercased() == target.head.fullName.lowercased())
                }
                if runs.workflow_runs.isEmpty && count < total { actionError = "GitHub Actions pagination incomplete."; break }
                page += 1
            } catch { actionError = error.localizedDescription; break }
        }
        // Keep the latest attempt for each run; other events remain explicitly historical/unverified.
        let latest = Dictionary(grouping: actions, by: { "\($0.repositoryName ?? ""):\($0.runID ?? 0)" }).values.compactMap {
            $0.max { ($0.attempt ?? 0) < ($1.attempt ?? 0) }
        }.sorted { ($0.runID ?? 0) > ($1.runID ?? 0) }
        let actionPhase: GitHubFetchState.Phase = budget.items > limits.maxItems ? .incomplete : actionError != nil ? (actions.isEmpty ? .failed : .incomplete) : count < total ? .incomplete : .loaded
        let actionAttemptedAt = await clock.now()
        actionFetch = GitHubFetchState(phase: actionPhase, fetchedAt: actionPhase == .loaded ? actionAttemptedAt : nil,
                                      lastAttemptAt: actionAttemptedAt, error: actionError)
        let status = GitHubStatus(issues: Array(Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values).sorted { $0.id < $1.id }, pullRequests: prs, actions: latest,
                            error: prFetch.error, isLoaded: true, mergeEvidenceLoaded: prFetch.isComplete, checks: Array(Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values).sorted { $0.id < $1.id },
                            pullRequestFetch: prFetch, issueFetch: issueFetch, checkFetch: checkFetch, actionFetch: actionFetch, localSHA: target.sha)
        let result: GitHubStatus
        if let accountIdentifier {
            result = await stateStore.recordStatus(accountIdentifier: accountIdentifier, target: target,
                repositoryID: resolvedRepositoryID, sessionRevision: budget.requestContext?.revision, status: status)
        } else {
            result = status
        }
        let completedAt = await clock.now()
        metrics.record(target: target, apiRequestCount: budget.requestsByTarget[target.branchID, default: 0],
                       latency: completedAt.timeIntervalSince(startedAt))
        return result
    }
}
