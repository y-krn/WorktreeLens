import XCTest
@testable import WorktreeLensCore

final class CoreTests: XCTestCase {
    private struct StaticRunner: ProcessRunning {
        let output: String
        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            ProcessResult(status: 0, stdout: output)
        }
    }

    func testSessionActivityUsesOnlyExplicitProcessEvidence() {
        let active = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/local/bin/codex thread-123\n"))
        let activeSnapshot = active.snapshot()
        XCTAssertEqual(active.activity(for: "thread-123", provider: .codex, snapshot: activeSnapshot).0, .active)

        let inactive = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/bin/other-process\n"))
        let inactiveSnapshot = inactive.snapshot()
        XCTAssertEqual(inactive.activity(for: "thread-123", provider: .codex, snapshot: inactiveSnapshot).0, .inactive)

        let unknown = ProcessActivityProbe(runner: StaticRunner(output: "123 /Applications/Codex.app/Contents/MacOS/Codex\n"))
        let unknownSnapshot = unknown.snapshot()
        XCTAssertEqual(unknown.activity(for: "thread-123", provider: .codex, snapshot: unknownSnapshot).0, .unknown)
    }

    func testSessionActivitySnapshotIsReusableAcrossSessions() {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        struct CountingRunner: ProcessRunning {
            let counter: Counter
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                counter.value += 1
                return ProcessResult(status: 0, stdout: "123 /usr/bin/other-process\n")
            }
        }

        let counter = Counter()
        let probe = ProcessActivityProbe(runner: CountingRunner(counter: counter))
        let snapshot = probe.snapshot()
        _ = probe.activity(for: "session-a", provider: .codex, snapshot: snapshot)
        _ = probe.activity(for: "session-b", provider: .chatGPT, snapshot: snapshot)
        XCTAssertEqual(counter.value, 1)

        counter.value = 0
        _ = SessionService(home: "/tmp/worktree-lens-no-session-home-\(UUID().uuidString)", runner: CountingRunner(counter: counter)).discover()
        XCTAssertEqual(counter.value, 1)
    }

    func testLocalProcessRunnerDrainsLargeStdoutAndStderr() throws {
        let result = try LocalProcessRunner().run("/bin/zsh", arguments: ["-c", "i=0; while ((i < 200000)); do print -n x; ((i++)); done & i=0; while ((i < 200000)); do print -nu2 y; ((i++)); done; wait"], currentDirectory: nil)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(result.stdout.count, 200000)
        XCTAssertEqual(result.stderr.count, 200000)
    }

    func testDirtyWorktreeIsNeverRemovable() {
        let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: false, stagedCount: 1, unstagedCount: 0, untrackedCount: 0, lastActivity: Date())
        let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
        let decision = CleanupService().decide(worktree: worktree, branch: branch)
        XCTAssertEqual(decision, CleanupDecision(allowed: false, reason: .dirtyWorktree))
    }

    func testUnknownSessionActivityIsNeverRemovable() {
        let session = SessionRecord(id: "codex-1", provider: .codex, title: "Session", updatedAt: nil, cwd: "/tmp/wt", branch: "feature", url: nil, activity: .unknown, evidence: "threads.cwd")
        let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: Date(), sessions: [session])
        let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
        let decision = CleanupService().decide(worktree: worktree, branch: branch)
        XCTAssertEqual(decision, CleanupDecision(allowed: false, reason: .unknownSessionActivity))
    }

    func testInactiveCleanMergedWorktreeCanBeRemoved() {
        let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: Date())
        let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
        XCTAssertTrue(CleanupService().decide(worktree: worktree, branch: branch).allowed)
    }

    func testCleanupPreviewUsesProvidedSnapshotWithoutGitScan() {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        struct CountingRunner: ProcessRunning {
            let counter: Counter

            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                counter.value += 1
                return ProcessResult(status: 0)
            }
        }

        let counter = Counter()
        let branches = (0..<100).map { index in
            BranchInfo(id: "branch-(index)", name: "branch-(index)", sha: "sha-(index)", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: nil, worktrees: [])
        }
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: branches)
        let cleanup = CleanupService(git: GitService(runner: CountingRunner(counter: counter)), sessions: SessionService(home: "/tmp/no-session-home"))

        let preview = cleanup.previewMergedBranches(snapshot: snapshot)

        XCTAssertEqual(preview.items.count, 100)
        XCTAssertEqual(counter.value, 0)
    }

    func testStaleRequiresInactiveCleanMergedAndAgeThreshold() {
        let old = Date(timeIntervalSince1970: 1)
        let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: old)
        let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: old, worktrees: [worktree])
        XCTAssertTrue(CleanupService().decide(worktree: worktree, branch: branch, now: Date(timeIntervalSince1970: 8 * 86_400 + 1), staleDays: 7).allowed)
    }

    func testFeatureMergedIntoAnotherFeatureButNotDefaultIsBlocked() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let runner = LocalProcessRunner()
        func git(_ arguments: [String]) throws {
            let result = try runner.run("/usr/bin/git", arguments: ["-C", repository.path] + arguments, currentDirectory: nil)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "worktree-lens@example.invalid"])
        try git(["config", "user.name", "Worktree Lens Test"])
        FileManager.default.createFile(atPath: repository.appendingPathComponent("base.txt").path, contents: Data("base\n".utf8))
        try git(["add", "."]); try git(["commit", "-m", "base"])
        try git(["switch", "-c", "feature"])
        FileManager.default.createFile(atPath: repository.appendingPathComponent("feature.txt").path, contents: Data("feature\n".utf8))
        try git(["add", "."]); try git(["commit", "-m", "feature"])
        try git(["switch", "-c", "other-feature"])

        let service = GitService()
        let snapshot = try service.snapshot(repositoryPath: repository.path)
        let feature = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" })
        XCTAssertEqual(snapshot.defaultBranch, "main")
        XCTAssertFalse(feature.isMerged)
        let cleanup = CleanupService(git: service, sessions: SessionService(home: repository.appendingPathComponent("no-session-home").path))
        let preview = cleanup.previewDeleteBranch(snapshot: snapshot, name: "feature")
        XCTAssertEqual(preview.items.first?.reason, .unmergedBranch)
        XCTAssertFalse(preview.items.first?.allowed ?? true)
    }

    func testSnapshotParsesAllBranchesAndAssociatesWorktrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repository")
        let remote = root.appendingPathComponent("remote.git")
        let alphaWorktree = root.appendingPathComponent("attached-alpha")
        let betaWorktree = root.appendingPathComponent("attached-beta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = LocalProcessRunner()
        func git(_ arguments: [String], in path: URL = repository) throws -> String {
            let result = try runner.run("/usr/bin/git", arguments: ["-C", path.path] + arguments, currentDirectory: nil)
            XCTAssertTrue(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
            return result.stdout
        }
        func commit(_ name: String) throws {
            FileManager.default.createFile(atPath: repository.appendingPathComponent(name).path, contents: Data(name.utf8))
            _ = try git(["add", "."])
            _ = try git(["commit", "-m", name])
        }

        _ = try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", repository.path], currentDirectory: nil)
        _ = try git(["config", "user.email", "worktree-lens@example.invalid"])
        _ = try git(["config", "user.name", "Worktree Lens Test"])
        try commit("base.txt")

        _ = try git(["switch", "-c", "merged"])
        try commit("merged.txt")
        _ = try git(["switch", "main"])
        _ = try git(["merge", "--no-ff", "merged", "-m", "merge merged"])

        _ = try git(["switch", "-c", "delta"])
        try commit("delta.txt")
        _ = try git(["switch", "main"])

        _ = try git(["switch", "-c", "gone"])
        _ = try git(["switch", "main"])
        _ = try git(["init", "--bare", remote.path], in: root)
        _ = try git(["remote", "add", "origin", remote.path])
        _ = try git(["push", "origin", "main"])
        let remoteHead = try runner.run("/usr/bin/git", arguments: ["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], currentDirectory: nil)
        XCTAssertTrue(remoteHead.succeeded, remoteHead.stderr)
        _ = try git(["remote", "set-head", "origin", "main"])
        _ = try git(["push", "-u", "origin", "gone"])
        _ = try git(["update-ref", "-d", "refs/remotes/origin/gone"])

        _ = try git(["switch", "-c", "attached-alpha"])
        _ = try git(["switch", "main"])
        _ = try git(["switch", "-c", "attached-beta"])
        _ = try git(["switch", "main"])
        _ = try git(["worktree", "add", alphaWorktree.path, "attached-alpha"])
        _ = try git(["worktree", "add", betaWorktree.path, "attached-beta"])

        let snapshot = try GitService().snapshot(repositoryPath: repository.path)
        let expectedNames: Set<String> = ["main", "merged", "delta", "gone", "attached-alpha", "attached-beta"]
        let branches = Dictionary(uniqueKeysWithValues: snapshot.branches.map { ($0.name, $0) })

        XCTAssertEqual(Set(branches.keys), expectedNames)
        XCTAssertTrue(snapshot.branches.allSatisfy { $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        XCTAssertEqual(snapshot.defaultBranch, "main")
        XCTAssertEqual(branches["attached-alpha"]?.worktrees.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }, [alphaWorktree.resolvingSymlinksInPath().path])
        XCTAssertEqual(branches["attached-beta"]?.worktrees.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }, [betaWorktree.resolvingSymlinksInPath().path])
        XCTAssertTrue(branches["merged"]?.isMerged == true)
        XCTAssertFalse(branches["delta"]?.isMerged ?? true)
        XCTAssertEqual(branches["delta"]?.defaultAhead, 1)
        XCTAssertEqual(branches["delta"]?.defaultBehind, 0)
        XCTAssertTrue(branches["gone"]?.remoteGone == true)

        let cleanup = CleanupService(git: GitService(), sessions: SessionService(home: root.appendingPathComponent("no-session-home").path))
        let remoteGonePreview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        XCTAssertEqual(remoteGonePreview.items.map(\.target), ["gone"])
        XCTAssertTrue(remoteGonePreview.items.first?.allowed == true)

        let alphaSnapshotPath = try XCTUnwrap(branches["attached-alpha"]?.worktrees.first?.path)
        let worktreePreview = cleanup.previewRemoveWorktree(snapshot: snapshot, path: alphaSnapshotPath)
        XCTAssertTrue(worktreePreview.items.first?.allowed == true, String(describing: worktreePreview.items.first?.reason))
        FileManager.default.createFile(atPath: URL(fileURLWithPath: alphaSnapshotPath).appendingPathComponent("dirty.txt").path, contents: Data("dirty\n".utf8))
        XCTAssertTrue(cleanup.execute(worktreePreview).isEmpty)

        let mergedPreview = cleanup.previewMergedBranches(snapshot: snapshot)
        XCTAssertTrue(mergedPreview.items.contains { $0.target == "merged" && $0.allowed })
        _ = try git(["reset", "--hard", "HEAD~1"])
        XCTAssertTrue(cleanup.execute(mergedPreview).isEmpty)
    }
}
