import Foundation

public struct CleanupBranchState: Sendable {
    public let name: String
    public let sha: String
    public let defaultBranch: String?
    public let isDefaultBranch: Bool
    public let worktreePaths: [String]
    public let isGitAncestor: Bool

    public init(name: String, sha: String, defaultBranch: String?, isDefaultBranch: Bool, worktreePaths: [String], isGitAncestor: Bool) {
        self.name = name
        self.sha = sha
        self.defaultBranch = defaultBranch
        self.isDefaultBranch = isDefaultBranch
        self.worktreePaths = worktreePaths
        self.isGitAncestor = isGitAncestor
    }
}

public struct CleanupRepositoryContext: Sendable {
    public let path: String
    public let defaultBranch: String?
    public let defaultRef: String?
    public let defaultLocator: CleanupDefaultBranchLocator?

    public init(path: String, defaultBranch: String?, defaultRef: String?, defaultLocator: CleanupDefaultBranchLocator? = nil) {
        self.path = path
        self.defaultBranch = defaultBranch
        self.defaultRef = defaultRef
        self.defaultLocator = defaultLocator
    }
}

public enum CleanupDefaultBranchLocator: Sendable {
    case symbolicRemoteHead(remote: String)
    case remoteShow(remote: String)
    case local
}

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
            parseBranch(record: String(record), root: root, defaultBranch: defaultBranch, worktrees: worktrees, includeCleanupUIData: true)
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
        _ = try run(["-C", repositoryPath, "worktree", "remove", path])
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

    public func defaultBranchName(repositoryPath: String, canonicalPath: String? = nil) throws -> String? {
        let root = try canonicalPath ?? canonicalRepositoryPath(repositoryPath)
        return try resolveDefaultBranch(root)?.name
    }

    public func cleanupContext(repositoryPath: String) throws -> CleanupRepositoryContext {
        let root = try canonicalRepositoryPath(repositoryPath)
        let branch = try resolveDefaultBranch(root)
        return CleanupRepositoryContext(path: root, defaultBranch: branch?.name, defaultRef: branch?.ref, defaultLocator: branch?.locator)
    }

    public func validateCleanupDefaultBranch(_ context: CleanupRepositoryContext) -> Bool {
        revalidatedCleanupContext(context) != nil
    }

    /// Resolves and validates the default ref again before destructive cleanup.
    public func revalidatedCleanupContext(_ context: CleanupRepositoryContext) -> CleanupRepositoryContext? {
        guard let expectedName = context.defaultBranch,
              let expectedRef = context.defaultRef,
              let locator = context.defaultLocator,
              let branch = freshCleanupDefaultBranch(context.path, expectedName: expectedName, locator: locator),
              branch.name == expectedName,
              branch.ref == expectedRef else { return nil }
        return CleanupRepositoryContext(path: context.path, defaultBranch: branch.name, defaultRef: branch.ref, defaultLocator: branch.locator)
    }

    public func isGitAncestor(repositoryPath: String, branch: String, defaultRef: String) -> Bool {
        isAncestor(root: repositoryPath, branch: branch, defaultRef: defaultRef)
    }

    private func freshCleanupDefaultBranch(_ root: String, expectedName: String, locator: CleanupDefaultBranchLocator) -> DefaultBranch? {
        switch locator {
        case .symbolicRemoteHead(let remote):
            guard let result = try? run(["-C", root, "symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"]) else { return nil }
            let symbolic = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard symbolic == "\(remote)/\(expectedName)" else { return nil }
            return DefaultBranch(name: expectedName, ref: symbolic, locator: locator)
        case .remoteShow(let remote):
            if let symbolic = try? run(["-C", root, "symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"]),
               !symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            guard let result = try? run(["-C", root, "remote", "show", "-n", remote]),
                  let current = remoteShowHeadBranch(result.stdout),
                  current == expectedName else { return nil }
            guard let hasRemoteRef = remoteTrackingRefExists(root: root, remote: remote, branch: expectedName) else { return nil }
            let ref = hasRemoteRef ? "\(remote)/\(expectedName)" : expectedName
            return DefaultBranch(name: expectedName, ref: ref, locator: locator)
        case .local:
            guard let remotes = try? run(["-C", root, "remote"]) else { return nil }
            for remote in remotes.stdout.split(whereSeparator: \.isNewline).map(String.init) {
                if let symbolic = try? run(["-C", root, "symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"]),
                   !symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                guard let shown = try? run(["-C", root, "remote", "show", "-n", remote]) else { return nil }
                if remoteShowHeadBranch(shown.stdout) != nil { return nil }
            }
            guard let result = try? run(["-C", root, "for-each-ref", "--format=%(refname:short)", "refs/heads/main", "refs/heads/master"]) else { return nil }
            let candidates = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
            guard candidates == [expectedName] else { return nil }
            return DefaultBranch(name: expectedName, ref: expectedName, locator: locator)
        }
    }

    /// Revalidates one branch without rebuilding the repository-wide snapshot.
    public func cleanupBranch(repositoryPath: String, name: String) throws -> BranchInfo? {
        let root = try canonicalRepositoryPath(repositoryPath)
        let defaultBranch = try resolveDefaultBranch(root)
        let records = try worktreeRecords(repositoryPath: root)
        let attached = placeholderWorktrees(records: records, branch: name)
        guard let record = try branchRecord(repositoryPath: root, name: name) else { return nil }
        return parseBranch(record: record, root: root, defaultBranch: defaultBranch, worktrees: attached, includeCleanupUIData: false)
    }

    /// Revalidates only the state required before deleting one branch.
    public func cleanupBranchState(repositoryPath: String, name: String, canonicalPath: String? = nil, verifyGitAncestor: Bool = true, context: CleanupRepositoryContext? = nil) throws -> CleanupBranchState? {
        let root = try context?.path ?? canonicalPath ?? canonicalRepositoryPath(repositoryPath)
        let defaultBranch: DefaultBranch?
        if let context {
            guard let fresh = revalidatedCleanupContext(context), let name = fresh.defaultBranch, let ref = fresh.defaultRef, let locator = fresh.defaultLocator else { return nil }
            defaultBranch = DefaultBranch(name: name, ref: ref, locator: locator)
        } else {
            defaultBranch = try resolveDefaultBranch(root)
        }
        let records = try worktreeRecords(repositoryPath: root)
        guard let record = try cleanupStateBranchRecord(repositoryPath: root, name: name) else { return nil }
        let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 2 else { return nil }
        let worktreePaths = records.compactMap { record -> String? in
            guard record["branch"]?.replacingOccurrences(of: "refs/heads/", with: "") == name else { return nil }
            return record["worktree"]
        }
        return CleanupBranchState(
            name: name,
            sha: fields[1],
            defaultBranch: defaultBranch?.name,
            isDefaultBranch: defaultBranch?.name == name,
            worktreePaths: worktreePaths,
            isGitAncestor: verifyGitAncestor && (defaultBranch.map { isAncestor(root: root, branch: name, defaultRef: $0.ref) } ?? false)
        )
    }

    /// Minimal fresh worktree state for the last guard before removal.
    public func cleanupWorktreeState(repositoryPath: String, path: String, sessions: [SessionRecord], context: CleanupRepositoryContext) throws -> WorktreeInfo {
        let records = try worktreeRecords(repositoryPath: context.path)
        // The first record is the main worktree, which is never a removal target.
        guard let index = records.firstIndex(where: { isPath($0["worktree"] ?? "", equalTo: path) }), index > 0,
              let worktree = try makeWorktree(record: records[index], defaultBranch: nil, sessions: sessions, includeCleanupUIData: false) else {
            throw ProcessRunnerError.failed("Worktree missing, main, or invalid")
        }
        return worktree
    }

    /// True when a branch, remote-tracking ref, or tag still contains `sha`, so removing a detached worktree loses no commits.
    public func isReachableFromRefs(repositoryPath: String, sha: String) -> Bool {
        guard let result = try? run(["-C", repositoryPath, "for-each-ref", "--contains", sha, "--count=1", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"]) else { return false }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Revalidates one worktree's status, branch relation, and linked sessions.
    public func cleanupWorktree(repositoryPath: String, path: String, sessions: [SessionRecord], includeCleanupUIData: Bool = false, includeMergeEvidence: Bool = true, canonicalPath: String? = nil, context: CleanupRepositoryContext? = nil) throws -> (worktree: WorktreeInfo, branch: BranchInfo?) {
        let root = try context?.path ?? canonicalPath ?? canonicalRepositoryPath(repositoryPath)
        let defaultBranch: DefaultBranch?
        if let context, let name = context.defaultBranch, let ref = context.defaultRef {
            guard let locator = context.defaultLocator else { throw ProcessRunnerError.failed("Default branch locator missing") }
            defaultBranch = DefaultBranch(name: name, ref: ref, locator: locator)
        } else {
            defaultBranch = try context == nil ? resolveDefaultBranch(root) : nil
        }
        let records = try worktreeRecords(repositoryPath: root)
        guard let record = records.first(where: { isPath($0["worktree"] ?? "", equalTo: path) }) else {
            throw ProcessRunnerError.failed("Worktree missing")
        }
        guard let worktree = try makeWorktree(record: record, defaultBranch: defaultBranch, sessions: sessions, includeCleanupUIData: includeCleanupUIData) else {
            throw ProcessRunnerError.failed("Worktree record invalid")
        }
        let branch = try worktree.branch.flatMap { try cleanupBranchRecord(repositoryPath: root, name: $0, defaultBranch: defaultBranch, records: records, includeMergeEvidence: includeMergeEvidence) }
        return (worktree, branch)
    }

    // Pass separators as literal control characters. Git's ref-filter on macOS
    // does not expand the pretty-format `%xNN` spelling here.
    private let branchFormat = "%(refname:short)\u{1f}%(objectname)\u{1f}%(upstream:short)\u{1f}%(upstream:track)\u{1f}%(committerdate:iso8601-strict)\u{1e}"

    private struct DefaultBranch: Sendable {
        let name: String
        let ref: String
        let locator: CleanupDefaultBranchLocator
    }

    private func branchRecord(repositoryPath: String, name: String) throws -> String? {
        let output = try run(["-C", repositoryPath, "for-each-ref", "--format=\(branchFormat)", "refs/heads/\(name)"]).stdout
        return output.split(separator: "\u{1e}", omittingEmptySubsequences: true).map(String.init).first
    }

    private func cleanupStateBranchRecord(repositoryPath: String, name: String) throws -> String? {
        let output = try run(["-C", repositoryPath, "for-each-ref", "--format=%(refname:short)\u{1f}%(objectname)\u{1e}", "refs/heads/\(name)"]).stdout
        return output.split(separator: "\u{1e}", omittingEmptySubsequences: true).map(String.init).first
    }

    private func cleanupBranchRecord(repositoryPath: String, name: String, defaultBranch: DefaultBranch?, records: [[String: String]], includeMergeEvidence: Bool = true) throws -> BranchInfo? {
        guard let record = try branchRecord(repositoryPath: repositoryPath, name: name) else { return nil }
        return parseBranch(record: record, root: repositoryPath, defaultBranch: defaultBranch, worktrees: placeholderWorktrees(records: records, branch: name), includeCleanupUIData: false, includeMergeEvidence: includeMergeEvidence)
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
                return DefaultBranch(name: symbolic.replacingOccurrences(of: "\(remote)/", with: ""), ref: symbolic, locator: .symbolicRemoteHead(remote: remote))
            }
            if let shown = try? run(["-C", root, "remote", "show", "-n", remote]).stdout,
               let name = remoteShowHeadBranch(shown) {
                let remoteRef = "refs/remotes/\(remote)/\(name)"
                let ref = (try? run(["-C", root, "show-ref", "--verify", "--quiet", remoteRef])).map { _ in "\(remote)/\(name)" } ?? name
                return DefaultBranch(name: String(name), ref: ref, locator: .remoteShow(remote: remote))
            }
        }

        let conventional = ["main", "master"].filter { (try? run(["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/\($0)"])) != nil }
        guard conventional.count == 1 else { return nil }
        return DefaultBranch(name: conventional[0], ref: conventional[0], locator: .local)
    }

    private func remoteShowHeadBranch(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("HEAD branch:") }),
              let name = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty,
              !(name.hasPrefix("(") && name.hasSuffix(")")) else { return nil }
        return String(name)
    }

    private func remoteTrackingRefExists(root: String, remote: String, branch: String) -> Bool? {
        do {
            let result = try runner.run(gitPath, arguments: ["-C", root, "show-ref", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], currentDirectory: nil, timeout: nil)
            if result.succeeded { return true }
            return result.status == 1 ? false : nil
        } catch {
            return nil
        }
    }

    private func parseBranch(record: String, root: String, defaultBranch: DefaultBranch?, worktrees: [WorktreeInfo], includeCleanupUIData: Bool, includeMergeEvidence: Bool = true) -> BranchInfo? {
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
        let relation = includeCleanupUIData ? (defaultBranch.flatMap { defaultDelta(root: root, branch: name, defaultRef: $0.ref) } ?? (ahead: 0, behind: 0)) : (ahead: 0, behind: 0)
        let merged = includeMergeEvidence && (defaultBranch.map { isAncestor(root: root, branch: name, defaultRef: $0.ref) } ?? false)
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

    private func makeWorktree(record: [String: String], defaultBranch: DefaultBranch?, sessions: [SessionRecord], includeCleanupUIData: Bool = true) throws -> WorktreeInfo? {
        guard let path = record["worktree"], let head = record["HEAD"] else { return nil }
        let branch = record["branch"]?.replacingOccurrences(of: "refs/heads/", with: "")
        let detached = branch == nil || record["detached"] != nil
        let status = try? runStatus(path)
        let lastActivity = includeCleanupUIData ? (try? lastCommitDate(path)) : nil
        let delta = includeCleanupUIData ? (defaultBranch.flatMap { defaultDelta(root: path, branch: head, defaultRef: $0.ref) } ?? (ahead: 0, behind: 0)) : (ahead: 0, behind: 0)
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
