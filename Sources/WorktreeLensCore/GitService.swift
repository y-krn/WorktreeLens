import Foundation

public final class GitService: @unchecked Sendable {
    private let runner: any ProcessRunning
    private let gitPath: String

    public init(runner: any ProcessRunning = LocalProcessRunner(), gitPath: String = "/usr/bin/git") {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func canonicalRepositoryPath(_ path: String) throws -> String {
        try run(["-C", path, "rev-parse", "--show-toplevel"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func snapshot(repositoryPath: String, sessions: [SessionRecord] = []) throws -> RepositorySnapshot {
        let root = try canonicalRepositoryPath(repositoryPath)
        let defaultBranch = try resolveDefaultBranch(root)
        let worktrees = try worktreeList(repositoryPath: root, defaultBranch: defaultBranch, sessions: sessions)
        let output = try run(["-C", root, "for-each-ref", "--format=\(branchFormat)", "refs/heads"]).stdout
        var branches = output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            parseBranch(record: String(record), root: root, defaultBranch: defaultBranch, worktrees: worktrees)
        }

        let detached = worktrees.filter(\.isDetached)
        if !detached.isEmpty {
            branches.append(BranchInfo(id: "detached", name: "Detached worktrees", sha: detached.first?.head ?? "", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: detached.compactMap(\.lastActivity).max(), isDetachedGroup: true, worktrees: detached))
        }
        return RepositorySnapshot(path: root, defaultBranch: defaultBranch?.name, branches: branches.sorted { $0.isDetachedGroup == false && $1.isDetachedGroup == true })
    }

    public func worktreeList(repositoryPath: String) throws -> [WorktreeInfo] {
        try worktreeList(repositoryPath: repositoryPath, defaultBranch: try? resolveDefaultBranch(repositoryPath), sessions: [])
    }

    public func removeWorktree(repositoryPath: String, path: String) throws {
        _ = try run(["-C", repositoryPath, "worktree", "remove", "--quiet", path])
    }

    public func pruneWorktrees(repositoryPath: String) throws {
        _ = try run(["-C", repositoryPath, "worktree", "prune"])
    }

    public func deleteBranch(repositoryPath: String, branch: String) throws {
        _ = try run(["-C", repositoryPath, "branch", "-d", branch])
    }

    public func deleteBranchVerified(repositoryPath: String, branch: String, expectedOldSHA: String) throws {
        _ = try run(["-C", repositoryPath, "update-ref", "-d", "refs/heads/\(branch)", expectedOldSHA])
    }

    public func defaultBranchName(repositoryPath: String) throws -> String? {
        try resolveDefaultBranch(canonicalRepositoryPath(repositoryPath))?.name
    }

    /// Revalidates one branch without rebuilding the repository-wide snapshot.
    public func cleanupBranch(repositoryPath: String, name: String) throws -> BranchInfo? {
        let root = try canonicalRepositoryPath(repositoryPath)
        let defaultBranch = try resolveDefaultBranch(root)
        let records = try worktreeRecords(repositoryPath: root)
        let attached = placeholderWorktrees(records: records, branch: name)
        guard let record = try branchRecord(repositoryPath: root, name: name) else { return nil }
        return parseBranch(record: record, root: root, defaultBranch: defaultBranch, worktrees: attached)
    }

    /// Revalidates one worktree's status, branch relation, and linked sessions.
    public func cleanupWorktree(repositoryPath: String, path: String, sessions: [SessionRecord]) throws -> (worktree: WorktreeInfo, branch: BranchInfo?) {
        let root = try canonicalRepositoryPath(repositoryPath)
        let defaultBranch = try resolveDefaultBranch(root)
        let records = try worktreeRecords(repositoryPath: root)
        guard let record = records.first(where: { isPath($0["worktree"] ?? "", equalTo: path) }) else {
            throw ProcessRunnerError.failed("Worktree missing")
        }
        guard let worktree = try makeWorktree(record: record, defaultBranch: defaultBranch, sessions: sessions) else {
            throw ProcessRunnerError.failed("Worktree record invalid")
        }
        let branch = try worktree.branch.flatMap { try cleanupBranchRecord(repositoryPath: root, name: $0, defaultBranch: defaultBranch, records: records) }
        return (worktree, branch)
    }

    // Pass separators as literal control characters. Git's ref-filter on macOS
    // does not expand the pretty-format `%xNN` spelling here.
    private let branchFormat = "%(refname:short)\u{1f}%(objectname)\u{1f}%(upstream:short)\u{1f}%(upstream:track)\u{1f}%(committerdate:iso8601-strict)\u{1e}"

    private struct DefaultBranch: Sendable {
        let name: String
        let ref: String
    }

    private func branchRecord(repositoryPath: String, name: String) throws -> String? {
        let output = try run(["-C", repositoryPath, "for-each-ref", "--format=\(branchFormat)", "refs/heads/\(name)"]).stdout
        return output.split(separator: "\u{1e}", omittingEmptySubsequences: true).map(String.init).first
    }

    private func cleanupBranchRecord(repositoryPath: String, name: String, defaultBranch: DefaultBranch?, records: [[String: String]]) throws -> BranchInfo? {
        guard let record = try branchRecord(repositoryPath: repositoryPath, name: name) else { return nil }
        return parseBranch(record: record, root: repositoryPath, defaultBranch: defaultBranch, worktrees: placeholderWorktrees(records: records, branch: name))
    }

    private func placeholderWorktrees(records: [[String: String]], branch: String) -> [WorktreeInfo] {
        records.compactMap { record in
            guard record["branch"]?.replacingOccurrences(of: "refs/heads/", with: "") == branch, let path = record["worktree"] else { return nil }
            return WorktreeInfo(id: path, path: path, branch: branch, head: record["HEAD"] ?? "", isBare: record["bare"] != nil, isLocked: record["locked"] != nil, isClean: false, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        }
    }

    private func resolveDefaultBranch(_ root: String) throws -> DefaultBranch? {
        let remotes = try run(["-C", root, "remote"]).stdout.split(whereSeparator: \.isNewline).map(String.init)
        for remote in remotes {
            if let symbolic = try? run(["-C", root, "symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !symbolic.isEmpty {
                return DefaultBranch(name: symbolic.replacingOccurrences(of: "\(remote)/", with: ""), ref: symbolic)
            }
            if let shown = try? run(["-C", root, "remote", "show", "-n", remote]).stdout,
               let line = shown.split(whereSeparator: \.isNewline).first(where: { $0.contains("HEAD branch:") }),
               let name = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty {
                let remoteRef = "refs/remotes/\(remote)/\(name)"
                let ref = (try? run(["-C", root, "show-ref", "--verify", "--quiet", remoteRef])).map { _ in "\(remote)/\(name)" } ?? name
                return DefaultBranch(name: String(name), ref: ref)
            }
        }

        let conventional = ["main", "master"].filter { (try? run(["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/\($0)"])) != nil }
        guard conventional.count == 1 else { return nil }
        return DefaultBranch(name: conventional[0], ref: conventional[0])
    }

    private func parseBranch(record: String, root: String, defaultBranch: DefaultBranch?, worktrees: [WorktreeInfo]) -> BranchInfo? {
        let normalizedRecord = record.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = normalizedRecord.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return nil }
        let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let tracking = fields[3]
        let aheadBehind = tracking.split(separator: ",").reduce(into: (ahead: 0, behind: 0)) { result, item in
            let value = item.trimmingCharacters(in: .whitespaces)
            let number = Int(value.filter(\.isNumber)) ?? 0
            if value.contains("ahead") { result.ahead = number }
            if value.contains("behind") { result.behind = number }
        }
        let branchWorktrees = worktrees.filter { $0.branch == name }
        let relation = defaultBranch.flatMap { defaultDelta(root: root, branch: name, defaultRef: $0.ref) } ?? (ahead: 0, behind: 0)
        let merged = defaultBranch.map { isAncestor(root: root, branch: name, defaultRef: $0.ref) } ?? false
        return BranchInfo(id: name, name: name, sha: fields[1], upstream: fields[2].isEmpty ? nil : fields[2], ahead: aheadBehind.ahead, behind: aheadBehind.behind, isMerged: merged, remoteGone: tracking.contains("gone"), lastCommitAt: strictDate(fields[4]), isDefaultBranch: defaultBranch?.name == name, defaultAhead: relation.ahead, defaultBehind: relation.behind, worktrees: branchWorktrees, mergeEvidence: merged ? .gitAncestor : MergeEvidence.none)
    }

    private func worktreeList(repositoryPath: String, defaultBranch: DefaultBranch?, sessions: [SessionRecord]) throws -> [WorktreeInfo] {
        try worktreeRecords(repositoryPath: repositoryPath).compactMap { try makeWorktree(record: $0, defaultBranch: defaultBranch, sessions: sessions) }
    }

    private func worktreeRecords(repositoryPath: String) throws -> [[String: String]] {
        let output = try run(["-C", repositoryPath, "worktree", "list", "--porcelain"]).stdout
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                if !current.isEmpty { records.append(current); current = [:] }
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { current[parts[0]] = parts[1] }
            else if parts.count == 1 { current[parts[0]] = "" }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    private func makeWorktree(record: [String: String], defaultBranch: DefaultBranch?, sessions: [SessionRecord]) throws -> WorktreeInfo? {
        guard let path = record["worktree"], let head = record["HEAD"] else { return nil }
        let branch = record["branch"]?.replacingOccurrences(of: "refs/heads/", with: "")
        let detached = branch == nil || record["detached"] != nil
        let status = try? runStatus(path)
        let lastActivity = try? lastCommitDate(path)
        let delta = defaultBranch.flatMap { defaultDelta(root: path, branch: head, defaultRef: $0.ref) } ?? (ahead: 0, behind: 0)
        return WorktreeInfo(id: path, path: path, branch: branch, head: head, isBare: record["bare"] != nil, isLocked: record["locked"] != nil, isDetached: detached, isClean: status?.clean ?? false, stagedCount: status?.staged ?? 0, unstagedCount: status?.unstaged ?? 0, untrackedCount: status?.untracked ?? 0, lastActivity: lastActivity ?? nil, defaultAhead: delta.ahead, defaultBehind: delta.behind, sessions: sessions.filter { session in
                guard let cwd = session.cwd else { return false }
                return isPath(cwd, within: path) || isPath(path, within: cwd)
            })
    }

    private func isAncestor(root: String, branch: String, defaultRef: String) -> Bool {
        (try? run(["-C", root, "merge-base", "--is-ancestor", branch, defaultRef])).map { $0.succeeded } ?? false
    }

    private func defaultDelta(root: String, branch: String, defaultRef: String) -> (ahead: Int, behind: Int)? {
        guard let result = try? run(["-C", root, "rev-list", "--left-right", "--count", "\(defaultRef)...\(branch)"]) else { return nil }
        let values = result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard values.count >= 2 else { return nil }
        return (ahead: values[1], behind: values[0])
    }

    private func runStatus(_ path: String) throws -> (clean: Bool, staged: Int, unstaged: Int, untracked: Int) {
        let output = try run(["-C", path, "status", "--porcelain=v1"]).stdout
        var staged = 0, unstaged = 0, untracked = 0
        for line in output.split(separator: "\n") {
            let chars = Array(line)
            if chars.first == "?" { untracked += 1; continue }
            if chars.count > 0 && chars[0] != " " { staged += 1 }
            if chars.count > 1 && chars[1] != " " { unstaged += 1 }
        }
        return (staged == 0 && unstaged == 0 && untracked == 0, staged, unstaged, untracked)
    }

    private func lastCommitDate(_ path: String) throws -> Date? {
        let value = try run(["-C", path, "log", "-1", "--format=%cI"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return strictDate(value)
    }

    private func strictDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        let result = try runner.run(gitPath, arguments: arguments, currentDirectory: nil)
        guard result.succeeded else { throw ProcessRunnerError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result
    }

    private func isPath(_ candidate: String, within root: String) -> Bool {
        let candidatePath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func isPath(_ lhs: String, equalTo rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }
}
