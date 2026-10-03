import Foundation

public final class GitHubService: @unchecked Sendable {
    private let runner: any ProcessRunning
    private let configuredExecutable: String?
    private let display: GitHubDisplayService
    private let resolver: GitHubRepositoryResolver
    private let refreshMetrics: GitHubRefreshMetrics

    public init(runner: any ProcessRunning = LocalProcessRunner(), executable: String? = nil,
                api: GitHubAPIClient? = nil, resolver: GitHubRepositoryResolver = GitHubRepositoryResolver(),
                clock: any GitHubClock = SystemGitHubClock(), limits: GitHubDisplayLimits = GitHubDisplayLimits(),
                refreshMetrics: GitHubRefreshMetrics = GitHubRefreshMetrics()) {
        self.runner = runner
        self.configuredExecutable = executable
        let client = api ?? GitHubAPIClient(authentication: GitHubDeviceFlowProvider(clientID: UserDefaults.standard.string(forKey: "githubAppClientID") ?? ""))
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
        do {
            try Task.checkCancellation()
            guard let target = try resolver.targets(path: repositoryPath, branches: [branchInfo]).first else {
                return GitHubStatus(issues: [], pullRequests: branchInfo.github.pullRequests, actions: [], error: "GitHub repository unresolved.", isLoaded: false)
            }
            return await display.details(target: target, summary: branchInfo.github, timeout: timeout)
        } catch {
            return GitHubStatus(issues: [], pullRequests: branchInfo.github.pullRequests, actions: [], error: error.localizedDescription, isLoaded: false)
        }
    }

    /// Synchronous compatibility entry point for legacy cleanup callers. Display uses statusAsync.
    public func status(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) -> GitHubStatus {
        cleanupStatus(repositoryPath: repositoryPath, branch: branch, timeout: timeout)
    }

    public func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubStatus {
        guard let info = try? GitService().snapshot(repositoryPath: repositoryPath, sessions: []).branches.first(where: { $0.name == branch }) else {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: "Local branch unavailable.", isLoaded: false)
        }
        return await statusAsync(repositoryPath: repositoryPath, branchInfo: info, timeout: timeout)
    }

    /// Fetches only the PR fields required by destructive cleanup verification.
    public func cleanupStatus(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) -> GitHubStatus {
        do {
            let prs = try query(repositoryPath: repositoryPath, arguments: ["pr", "list", "--state", "all", "--head", branch, "--json", "number,state,baseRefName,headRefName,headRefOid,mergedAt"], timeout: timeout)
            return GitHubStatus(issues: [], pullRequests: prs.compactMap(pullRequest), actions: [], error: nil, isLoaded: true)
        } catch {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: error.localizedDescription, isLoaded: false)
        }
    }

    /// Fetches one known PR directly so destructive cleanup does not enumerate PRs for the branch.
    public func cleanupStatus(repositoryPath: String, pullRequestNumber: Int, timeout: TimeInterval = GitHubService.requestTimeout) -> GitHubStatus {
        do {
            let pr = try queryObject(repositoryPath: repositoryPath, arguments: ["pr", "view", String(pullRequestNumber), "--json", "number,state,baseRefName,headRefName,headRefOid,mergedAt"], timeout: timeout)
            return GitHubStatus(issues: [], pullRequests: [pullRequest(pr)].compactMap { $0 }, actions: [], error: nil, isLoaded: true)
        } catch {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: error.localizedDescription, isLoaded: false)
        }
    }

    private func query(repositoryPath: String, arguments: [String], timeout: TimeInterval) throws -> [[String: Any]] {
        let executable: String
        if let configuredExecutable {
            executable = configuredExecutable
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") {
            executable = "/opt/homebrew/bin/gh"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh") {
            executable = "/usr/local/bin/gh"
        } else {
            throw ProcessRunnerError.executableNotFound("gh")
        }
        let fallback = try runner.run(executable, arguments: arguments, currentDirectory: repositoryPath, timeout: timeout)
        if fallback.timedOut { throw ProcessRunnerError.timedOut("gh") }
        guard fallback.succeeded else { throw ProcessRunnerError.failed(fallback.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = fallback.stdout.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProcessRunnerError.failed("Invalid JSON from gh")
        }
        return json
    }

    private func queryObject(repositoryPath: String, arguments: [String], timeout: TimeInterval) throws -> [String: Any] {
        let executable: String
        if let configuredExecutable {
            executable = configuredExecutable
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") {
            executable = "/opt/homebrew/bin/gh"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh") {
            executable = "/usr/local/bin/gh"
        } else {
            throw ProcessRunnerError.executableNotFound("gh")
        }
        let result = try runner.run(executable, arguments: arguments, currentDirectory: repositoryPath, timeout: timeout)
        if result.timedOut { throw ProcessRunnerError.timedOut("gh") }
        guard result.succeeded else { throw ProcessRunnerError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = result.stdout.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessRunnerError.failed("Invalid JSON from gh")
        }
        return json
    }

    private func pullRequest(_ raw: [String: Any]) -> GitHubPullRequest? {
        guard let number = raw["number"] as? Int, let state = raw["state"] as? String else { return nil }
        let title = raw["title"] as? String ?? ""
        let mergedAt = (raw["mergedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubPullRequest(id: "pr-\(number)", number: number, title: title, state: state, isDraft: raw["isDraft"] as? Bool ?? false, baseRefName: raw["baseRefName"] as? String, headRefName: raw["headRefName"] as? String, headRefOid: raw["headRefOid"] as? String, mergedAt: mergedAt, url: URL(string: raw["url"] as? String ?? ""))
    }

}
