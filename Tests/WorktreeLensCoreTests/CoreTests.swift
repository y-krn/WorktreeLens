import XCTest
@testable import WorktreeLensCore

final class CoreTests: XCTestCase {
    private struct StaticRunner: ProcessRunning {
        let output: String
        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            ProcessResult(status: 0, stdout: output)
        }
    }

    private struct RoutingRunner: ProcessRunning {
        let handler: @Sendable ([String]) throws -> ProcessResult

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            try handler(arguments)
        }
    }

    private final class RecordingRunner: @unchecked Sendable, ProcessRunning {
        private let lock = NSLock()
        private(set) var arguments: [[String]] = []

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            lock.lock()
            self.arguments.append(arguments)
            lock.unlock()
            return try LocalProcessRunner().run(executable, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
        }
    }

    func testRepositorySelectionKeepsBranchAndWorktreeInSync() {
        let worktree = WorktreeInfo(id: "/tmp/alpha", path: "/tmp/alpha", branch: "alpha", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        let branches = ["alpha", "beta", "charlie"].map { name in
            BranchInfo(id: name, name: name, sha: name, upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: name == "alpha" ? [worktree] : [])
        }
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "alpha", branches: branches)

        var selection = RepositorySelection.branch("alpha")
        XCTAssertEqual(selection.branchID(in: snapshot), "alpha")
        selection = .branch("beta")
        XCTAssertEqual(selection.branchID(in: snapshot), "beta")
        selection = .branch("charlie")
        XCTAssertEqual(selection.branchID(in: snapshot), "charlie")

        selection = .worktree(worktree.id)
        XCTAssertEqual(selection.branchID(in: snapshot), "alpha")
        XCTAssertEqual(selection.worktreeID(in: snapshot), worktree.id)

        selection = .branch("beta")
        XCTAssertEqual(selection.branchID(in: snapshot), "beta")
        XCTAssertNil(selection.worktreeID(in: snapshot))
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

    func testChatGPTJSONFixtureParsesExplicitCwdAndAssociatesWorktree() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-chatgpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let git = LocalProcessRunner()
        func runGit(_ arguments: [String]) throws {
            let result = try git.run("/usr/bin/git", arguments: ["-C", repository.path] + arguments, currentDirectory: nil)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        try runGit(["init", "-b", "main"])
        try runGit(["config", "user.email", "worktree-lens@example.invalid"])
        try runGit(["config", "user.name", "Worktree Lens Test"])
        FileManager.default.createFile(atPath: repository.appendingPathComponent("fixture.txt").path, contents: Data("fixture\n".utf8))
        try runGit(["add", "."])
        try runGit(["commit", "-m", "fixture"])

        let id = "chatgpt-fixture-1"
        let root = repository.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = "[{\"id\":\"\(id)\",\"title\":\"Desktop fixture\",\"updatedAt\":1790063182.0,\"cwd\":\"\(repository.path)\",\"branch\":\"main\",\"url\":\"chatgpt://sessions/\(id)\"}]"
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions.json").path, contents: Data(json.utf8))
        let provider = ChatGPTSessionProvider(
            home: repository.path,
            activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))
        )

        let discovery = provider.discover()
        let session = try XCTUnwrap(discovery.sessions.first)
        XCTAssertEqual(session.id, "chatgpt-\(id)")
        XCTAssertEqual(session.provider, .chatGPT)
        XCTAssertEqual(session.title, "Desktop fixture")
        XCTAssertEqual(session.cwd, repository.path)
        XCTAssertEqual(session.branch, "main")
        XCTAssertEqual(session.activity, .inactive)
        XCTAssertTrue(session.evidence.contains("explicit cwd/id"))
        XCTAssertEqual(session.url, URL(string: "chatgpt://sessions/\(id)"))

        let snapshot = try GitService().snapshot(repositoryPath: repository.path, sessions: discovery.sessions)
        XCTAssertEqual(snapshot.branches.flatMap(\.worktrees).flatMap(\.sessions).map(\.id), [session.id])
    }

    func testChatGPTOnlyAcceptsExplicitAbsoluteCwd() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-chatgpt-cwd-(UUID().uuidString)")
        let root = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cases = [
            (cwd: "/tmp/repo", accepted: true),
            (cwd: "repo", accepted: false),
            (cwd: "./repo", accepted: false),
            (cwd: "~/repo", accepted: false)
        ]
        for (index, testCase) in cases.enumerated() {
            let json = "[{\"id\":\"cwd-\(index)\",\"title\":\"cwd fixture\",\"cwd\":\"\(testCase.cwd)\"}]"
            try Data(json.utf8).write(to: root.appendingPathComponent("sessions.json"), options: .atomic)
            let sessions = ChatGPTSessionProvider(
                home: home.path,
                activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))
            ).discover().sessions
            XCTAssertEqual(sessions.isEmpty, !testCase.accepted, "cwd=\(testCase.cwd)")
        }
    }

    func testChatGPTSessionWithoutExplicitPathIsNotLinked() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-no-chatgpt-home-\(UUID().uuidString)")
        let root = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions.json").path, contents: Data("[{\"id\":\"no-path\",\"title\":\"No path\"}]".utf8))
        let provider = ChatGPTSessionProvider(
            home: home.path,
            activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))
        )

        let result = provider.discover()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("explicit cwd + session ID metadataなし") })
    }

    func testSameThreadIDIsNotReturnedByBothProviders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-provider-dedup-\(UUID().uuidString)")
        let state = home.appendingPathComponent(".codex/sqlite/state_5.sqlite")
        let jsonRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jsonRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: state.path, contents: Data())

        let id = "shared-thread"
        let output = "{\"id\":\"\(id)\",\"title\":\"Codex\",\"updated_at\":1790063182,\"cwd\":\"\(home.path)\",\"branch\":\"main\"}\n"
        let chatGPTJSON = "[{\"id\":\"\(id)\",\"title\":\"ChatGPT\",\"cwd\":\"\(home.path)\"}]"
        FileManager.default.createFile(atPath: jsonRoot.appendingPathComponent("sessions.json").path, contents: Data(chatGPTJSON.utf8))

        let result = SessionService(home: home.path, runner: StaticRunner(output: output)).discover()

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.provider, .codex)
        XCTAssertEqual(result.sessions.first?.id, "codex-\(id)")
    }

    func testChatGPTMalformedAndOversizedJSONIsSkippedSafely() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-chatgpt-json-\(UUID().uuidString)")
        let root = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions.json").path, contents: Data("{not-json".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("state.json").path, contents: Data(repeating: 0x78, count: 2_000_001))

        let result = ChatGPTSessionProvider(
            home: home.path,
            activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))
        ).discover()

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("skipped=2") })
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

    func testSquashMergeEquivalentUsesGitHubVerifiedEvidenceAndExpectedSHADeletion() async throws {
        try await assertGitHubVerifiedDeletion(prNumber: 123)
    }

    func testRebaseMergeEquivalentUsesGitHubVerifiedEvidenceAndExpectedSHADeletion() async throws {
        try await assertGitHubVerifiedDeletion(prNumber: 124)
    }

    func testGitHubVerificationRequiresMergedStateBaseBranchHeadBranchAndExactSHA() {
        let mergedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let makePR: (String, String, String) -> GitHubPullRequest = { state, base, sha in
            GitHubPullRequest(id: "pr-1", number: 1, title: "feature", state: state, isDraft: false, baseRefName: base, headRefName: "feature", headRefOid: sha, mergedAt: state == "MERGED" ? mergedAt : nil, url: nil)
        }
        let valid = GitHubStatus(issues: [], pullRequests: [makePR("MERGED", "main", "abc")], actions: [], error: nil)
        XCTAssertNotNil(valid.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "abc"))
        XCTAssertNil(valid.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "different"))
        XCTAssertNil(GitHubStatus(issues: [], pullRequests: [makePR("MERGED", "develop", "abc")], actions: [], error: nil).verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "abc"))
        XCTAssertNil(GitHubStatus(issues: [], pullRequests: [makePR("OPEN", "main", "abc")], actions: [], error: nil).verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "abc"))
        XCTAssertNil(GitHubStatus(issues: [], pullRequests: [makePR("MERGED", "main", "abc")], actions: [], error: "offline", isLoaded: false).verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "abc"))
    }

    func testGitHubUnavailableAndDefaultBranchRemainBlocked() {
        let unavailableBranch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
        let unavailablePreview = CleanupService().previewDeleteBranch(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [unavailableBranch]), name: "feature")
        XCTAssertFalse(unavailablePreview.items[0].allowed)
        XCTAssertEqual(unavailableBranch.mergeStatus, "GitHub verification unavailable")

        let defaultBranch = BranchInfo(id: "main", name: "main", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: nil, isDefaultBranch: true, worktrees: [])
        let defaultPreview = CleanupService().previewDeleteBranch(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [defaultBranch]), name: "main")
        XCTAssertEqual(defaultPreview.items[0].reason, CleanupBlockReason.defaultBranch)
        XCTAssertFalse(defaultPreview.items[0].allowed)
    }

    func testGitHubVerifiedPreviewBlocksWhenBranchSHAChangesBeforeExecute() async throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let github = GitHubService(runner: verifiedGitHubRunner(number: 125, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let enriched = await RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github).enrichGitHub(local: local)
        let preview = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github).previewDeleteBranch(snapshot: enriched, name: "feature")
        XCTAssertTrue(preview.items[0].allowed)

        _ = try runGit(["-C", fixture.repository.path, "switch", "feature"])
        FileManager.default.createFile(atPath: fixture.repository.appendingPathComponent("later.txt").path, contents: Data("later\n".utf8))
        _ = try runGit(["-C", fixture.repository.path, "add", "."])
        _ = try runGit(["-C", fixture.repository.path, "commit", "-m", "later"])

        XCTAssertTrue(CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github).execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    func testRemoteGoneGitHubVerifiedBranchIsAllowed() async throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let github = GitHubService(runner: verifiedGitHubRunner(number: 126, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let remoteGoneBranch = branch.withMergeEvidence(.githubVerified(prNumber: 126, mergedAt: mergedAt), github: status)
            .withRemoteGone(true)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [remoteGoneBranch])
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        XCTAssertTrue(preview.items[0].allowed)
        XCTAssertEqual(cleanup.execute(preview), ["feature"])
    }

    private func assertGitHubVerifiedDeletion(prNumber: Int) async throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = RecordingRunner()
        let git = GitService(runner: recorder)
        let github = GitHubService(runner: verifiedGitHubRunner(number: prNumber, sha: fixture.featureSHA), executable: "gh")
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let scanner = RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let enriched = await scanner.enrichGitHub(local: local)
        let branch = try XCTUnwrap(enriched.branches.first { $0.name == "feature" })
        XCTAssertFalse(branch.mergeEvidence == .gitAncestor)
        if case .githubVerified(let number, _) = branch.mergeEvidence {
            XCTAssertEqual(number, prNumber)
        } else {
            XCTFail("expected GitHub verified evidence")
        }

        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let preview = cleanup.previewDeleteBranch(snapshot: enriched, name: "feature")
        XCTAssertTrue(preview.items[0].allowed)
        XCTAssertEqual(preview.items[0].expectedSHA, fixture.featureSHA)
        XCTAssertEqual(cleanup.execute(preview), ["feature"])
        XCTAssertTrue(recorder.arguments.contains { $0.suffix(4).elementsEqual(["update-ref", "-d", "refs/heads/feature", fixture.featureSHA]) })
        XCTAssertFalse(recorder.arguments.flatMap { $0 }.contains("-D"))
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    private func verifiedGitHubRunner(number: Int, sha: String) -> RoutingRunner {
        let mergedAt = "2026-01-01T00:00:00Z"
        let pullRequest = "[{\"number\":\(number),\"title\":\"feature\",\"state\":\"MERGED\",\"isDraft\":false,\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(sha)\",\"mergedAt\":\"\(mergedAt)\",\"url\":\"https://github.com/example/repo/pull/\(number)\"}]"
        return RoutingRunner { arguments in
            if arguments.starts(with: ["pr", "list"]) { return ProcessResult(status: 0, stdout: pullRequest) }
            if arguments.starts(with: ["pr", "view"]) { return ProcessResult(status: 0, stdout: "[]") }
            if arguments.starts(with: ["run", "list"]) { return ProcessResult(status: 0, stdout: "[]") }
            return ProcessResult(status: 0, stdout: "[]")
        }
    }

    private func makeFeatureRepository() throws -> (root: URL, repository: URL, featureSHA: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-github-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init", "-b", "main", repository.path])
        _ = try runGit(["-C", repository.path, "config", "user.email", "worktree-lens@example.invalid"])
        _ = try runGit(["-C", repository.path, "config", "user.name", "Worktree Lens Test"])
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("base.txt"))
        _ = try runGit(["-C", repository.path, "add", "."])
        _ = try runGit(["-C", repository.path, "commit", "-m", "base"])
        _ = try runGit(["-C", repository.path, "switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: repository.appendingPathComponent("feature.txt"))
        _ = try runGit(["-C", repository.path, "add", "."])
        _ = try runGit(["-C", repository.path, "commit", "-m", "feature"])
        let sha = try runGit(["-C", repository.path, "rev-parse", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runGit(["-C", repository.path, "switch", "main"])
        return (root, repository, sha)
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let result = try LocalProcessRunner().run("/usr/bin/git", arguments: arguments, currentDirectory: nil)
        XCTAssertTrue(result.succeeded, result.stderr)
        return result.stdout
    }
}
