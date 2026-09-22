import Foundation

public final class GitHubService: @unchecked Sendable {
    private let runner: any ProcessRunning
    private let configuredExecutable: String?

    public init(runner: any ProcessRunning = LocalProcessRunner(), executable: String? = nil) {
        self.runner = runner
        self.configuredExecutable = executable
    }

    public static let requestTimeout: TimeInterval = 10

    /// Fetches all PR metadata needed to verify merge evidence for every local branch.
    /// The large limit makes gh paginate instead of silently using its default 30-item page.
    private static let mergeEvidenceLimit = "100000"

    public func mergeEvidence(repositoryPath: String, timeout: TimeInterval = GitHubService.requestTimeout) -> GitHubMergeEvidence {
        do {
            let prs = try query(repositoryPath: repositoryPath, arguments: ["pr", "list", "--state", "all", "--limit", Self.mergeEvidenceLimit, "--json", "number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergedAt,url"], timeout: timeout)
            return GitHubMergeEvidence(pullRequests: prs.compactMap(pullRequest))
        } catch {
            return GitHubMergeEvidence(pullRequests: [], error: error.localizedDescription)
        }
    }

    public func mergeEvidenceAsync(repositoryPath: String, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubMergeEvidence {
        await Task.detached(priority: .utility) {
            self.mergeEvidence(repositoryPath: repositoryPath, timeout: timeout)
        }.value
    }

    public func status(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) -> GitHubStatus {
        do {
            let deadline = Date().addingTimeInterval(timeout)
            func remainingTimeout() throws -> TimeInterval {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ProcessRunnerError.timedOut("gh") }
                return remaining
            }
            let prs = try query(repositoryPath: repositoryPath, arguments: ["pr", "list", "--state", "all", "--head", branch, "--json", "number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergedAt,url"], timeout: try remainingTimeout())
            let issues = prs.flatMap { pr -> [[String: Any]] in
                guard let number = pr["number"] as? Int else { return [] }
                guard let payloads = try? query(repositoryPath: repositoryPath, arguments: ["pr", "view", String(number), "--json", "closingIssuesReferences"], timeout: (try? remainingTimeout()) ?? 0),
                      let payload = payloads.first,
                      let references = payload["closingIssuesReferences"] as? [[String: Any]] else { return [] }
                return references
            }
            let runs = try query(repositoryPath: repositoryPath, arguments: ["run", "list", "--branch", branch, "--limit", "20", "--json", "databaseId,name,status,conclusion,url"], timeout: try remainingTimeout())
            return GitHubStatus(issues: issues.compactMap(issue), pullRequests: prs.compactMap(pullRequest), actions: runs.compactMap(action), error: nil, isLoaded: true)
        } catch {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: error.localizedDescription, isLoaded: false)
        }
    }

    public func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval = GitHubService.requestTimeout) async -> GitHubStatus {
        await Task.detached(priority: .utility) {
            self.status(repositoryPath: repositoryPath, branch: branch, timeout: timeout)
        }.value
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

    private func issue(_ raw: [String: Any]) -> GitHubIssue? {
        guard let number = raw["number"] as? Int, let title = raw["title"] as? String else { return nil }
        return GitHubIssue(id: "issue-\(number)", number: number, title: title, state: raw["state"] as? String ?? "linked", url: URL(string: raw["url"] as? String ?? ""))
    }

    private func pullRequest(_ raw: [String: Any]) -> GitHubPullRequest? {
        guard let number = raw["number"] as? Int, let state = raw["state"] as? String else { return nil }
        let title = raw["title"] as? String ?? ""
        let mergedAt = (raw["mergedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubPullRequest(id: "pr-\(number)", number: number, title: title, state: state, isDraft: raw["isDraft"] as? Bool ?? false, baseRefName: raw["baseRefName"] as? String, headRefName: raw["headRefName"] as? String, headRefOid: raw["headRefOid"] as? String, mergedAt: mergedAt, url: URL(string: raw["url"] as? String ?? ""))
    }

    private func action(_ raw: [String: Any]) -> GitHubActionRun? {
        guard let name = raw["name"] as? String, let status = raw["status"] as? String else { return nil }
        let id = String(describing: raw["databaseId"] ?? name)
        return GitHubActionRun(id: id, name: name, status: status, conclusion: raw["conclusion"] as? String, url: URL(string: raw["url"] as? String ?? ""))
    }
}
