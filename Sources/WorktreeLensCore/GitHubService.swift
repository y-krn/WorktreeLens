import Foundation

public final class GitHubService: @unchecked Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = LocalProcessRunner()) { self.runner = runner }

    public func status(repositoryPath: String, branch: String) -> GitHubStatus {
        do {
            let prs = try query(repositoryPath: repositoryPath, arguments: ["pr", "list", "--state", "all", "--head", branch, "--json", "number,title,state,isDraft,mergedAt,url"])
            let issues = prs.flatMap { pr -> [[String: Any]] in
                guard let number = pr["number"] as? Int else { return [] }
                guard let payloads = try? query(repositoryPath: repositoryPath, arguments: ["pr", "view", String(number), "--json", "closingIssuesReferences"]),
                      let payload = payloads.first,
                      let references = payload["closingIssuesReferences"] as? [[String: Any]] else { return [] }
                return references
            }
            let runs = try query(repositoryPath: repositoryPath, arguments: ["run", "list", "--branch", branch, "--limit", "20", "--json", "databaseId,name,status,conclusion,url"])
            return GitHubStatus(issues: issues.compactMap(issue), pullRequests: prs.compactMap(pullRequest), actions: runs.compactMap(action), error: nil)
        } catch {
            return GitHubStatus(issues: [], pullRequests: [], actions: [], error: error.localizedDescription)
        }
    }

    private func query(repositoryPath: String, arguments: [String]) throws -> [[String: Any]] {
        let executable: String
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") { executable = "/opt/homebrew/bin/gh" }
        else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh") { executable = "/usr/local/bin/gh" }
        else { throw ProcessRunnerError.executableNotFound("gh") }
        let fallback = try runner.run(executable, arguments: arguments, currentDirectory: repositoryPath)
        guard fallback.succeeded else { throw ProcessRunnerError.failed(fallback.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = fallback.stdout.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json
    }

    private func issue(_ raw: [String: Any]) -> GitHubIssue? {
        guard let number = raw["number"] as? Int, let title = raw["title"] as? String else { return nil }
        return GitHubIssue(id: "issue-\(number)", number: number, title: title, state: raw["state"] as? String ?? "linked", url: URL(string: raw["url"] as? String ?? ""))
    }

    private func pullRequest(_ raw: [String: Any]) -> GitHubPullRequest? {
        guard let number = raw["number"] as? Int, let title = raw["title"] as? String, let state = raw["state"] as? String else { return nil }
        let mergedAt = (raw["mergedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubPullRequest(id: "pr-\(number)", number: number, title: title, state: state, isDraft: raw["isDraft"] as? Bool ?? false, mergedAt: mergedAt, url: URL(string: raw["url"] as? String ?? ""))
    }

    private func action(_ raw: [String: Any]) -> GitHubActionRun? {
        guard let name = raw["name"] as? String, let status = raw["status"] as? String else { return nil }
        let id = String(describing: raw["databaseId"] ?? name)
        return GitHubActionRun(id: id, name: name, status: status, conclusion: raw["conclusion"] as? String, url: URL(string: raw["url"] as? String ?? ""))
    }
}
