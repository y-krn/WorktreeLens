import XCTest
@testable import WorktreeLensCore

final class CoreTests: XCTestCase {
    private struct StaticRunner: ProcessRunning {
        let output: String
        func run(_ executable: String, arguments: [String], currentDirectory: String?) throws -> ProcessResult {
            ProcessResult(status: 0, stdout: output)
        }
    }

    func testSessionActivityUsesOnlyExplicitProcessEvidence() {
        let active = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/local/bin/codex thread-123\n"))
        XCTAssertEqual(active.activity(for: "thread-123", provider: .codex).0, .active)

        let inactive = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/bin/other-process\n"))
        XCTAssertEqual(inactive.activity(for: "thread-123", provider: .codex).0, .inactive)

        let unknown = ProcessActivityProbe(runner: StaticRunner(output: "123 /Applications/Codex.app/Contents/MacOS/Codex\n"))
        XCTAssertEqual(unknown.activity(for: "thread-123", provider: .codex).0, .unknown)
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
        let preview = cleanup.previewDeleteBranch(repositoryPath: repository.path, name: "feature")
        XCTAssertEqual(preview.items.first?.reason, .unmergedBranch)
        XCTAssertFalse(preview.items.first?.allowed ?? true)
    }
}
