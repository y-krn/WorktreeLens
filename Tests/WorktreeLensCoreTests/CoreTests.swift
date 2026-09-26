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

    private final class CountingSessionDiscovery: @unchecked Sendable, SessionDiscovering {
        private(set) var count = 0

        func discover() -> SessionDiscoveryResult {
            count += 1
            return SessionDiscoveryResult(sessions: [], notes: [])
        }
    }

    private final class StubRecordingRunner: @unchecked Sendable, ProcessRunning {
        private(set) var arguments: [[String]] = []
        private(set) var currentDirectories: [String?] = []
        private let response: ([String]) -> ProcessResult

        init(response: @escaping ([String]) -> ProcessResult) {
            self.response = response
        }

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            self.arguments.append(arguments)
            self.currentDirectories.append(currentDirectory)
            return response(arguments)
        }
    }

    private final class FailingWorktreeRemovalRunner: @unchecked Sendable, ProcessRunning {
        private(set) var arguments: [[String]] = []

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            self.arguments.append(arguments)
            if arguments.contains("worktree") && arguments.contains("remove") {
                return ProcessResult(status: 1, stderr: "injected worktree removal failure")
            }
            return try LocalProcessRunner().run(executable, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
        }
    }

    private final class AddingWorktreeAfterRemovalRunner: @unchecked Sendable, ProcessRunning {
        let repositoryPath: String
        let replacementPath: String
        private(set) var arguments: [[String]] = []
        private var added = false

        init(repositoryPath: String, replacementPath: String) {
            self.repositoryPath = repositoryPath
            self.replacementPath = replacementPath
        }

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            self.arguments.append(arguments)
            let result = try LocalProcessRunner().run(executable, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
            if !added, result.succeeded, arguments.contains("worktree"), arguments.contains("remove") {
                added = true
                _ = try LocalProcessRunner().run(executable, arguments: ["-C", repositoryPath, "worktree", "add", replacementPath, "feature"], currentDirectory: nil, timeout: timeout)
            }
            return result
        }
    }

    private final class RemovingRemoteTrackingRefRunner: @unchecked Sendable, ProcessRunning {
        let repositoryPath: String
        private(set) var arguments: [[String]] = []
        private(set) var removed = false

        init(repositoryPath: String) { self.repositoryPath = repositoryPath }

        func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
            self.arguments.append(arguments)
            if arguments.contains("remote"), arguments.contains("show"), arguments.contains("-n"), arguments.contains("origin") {
                return ProcessResult(status: 0, stdout: "* remote origin\n  HEAD branch: main\n")
            }
            let result = try LocalProcessRunner().run(executable, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
            if !removed, result.succeeded, arguments.contains("show-ref"), arguments.contains("refs/remotes/origin/main") {
                removed = true
                _ = try LocalProcessRunner().run(executable, arguments: ["-C", repositoryPath, "update-ref", "-d", "refs/remotes/origin/main"], currentDirectory: nil, timeout: timeout)
            }
            return result
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

    func testSessionActivityMatchingAcrossManyProcessLines() {
        let output = [
            "1 /usr/bin/other-process",
            "2 /usr/local/bin/codex --thread THREAD-ABC",
            "3 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "4 /usr/local/bin/claude --resume claude-a",
            "5 /usr/bin/tail thread-",
            "6 split-id"
        ].joined(separator: "\n") + "\n"
        let probe = ProcessActivityProbe(runner: StaticRunner(output: output))
        let snapshot = probe.snapshot()
        XCTAssertEqual(probe.activity(for: "thread-abc", provider: .codex, snapshot: snapshot).0, .active, "session ID match is case-insensitive")
        XCTAssertEqual(probe.activity(for: "other", provider: .codex, snapshot: snapshot).0, .active, "session ID matches as a substring")
        XCTAssertEqual(probe.activity(for: "thread-\nsplit", provider: .codex, snapshot: snapshot).0, .inactive, "match must not span process lines")
        XCTAssertEqual(probe.activity(for: "missing", provider: .codex, snapshot: snapshot).0, .inactive)
        XCTAssertEqual(probe.activity(for: "missing", provider: .chatGPT, snapshot: snapshot).0, .unknown)
        XCTAssertEqual(probe.activity(for: "claude-a", provider: .claude, snapshot: snapshot).0, .active)
        XCTAssertEqual(probe.activity(for: "claude-b", provider: .claude, snapshot: snapshot).0, .unknown)
        XCTAssertEqual(probe.activity(for: "THREAD-ABC", provider: .claude, snapshot: snapshot).0, .unknown, "Claude requires an exact argument on a claude process")
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

    func testCleanupSafetyCacheRefreshesOnlyChangedProviderAndFindsNewChatGPTSession() throws {
        final class Counter: @unchecked Sendable {
            var ps = 0
            var sqlite = 0
            var psOutput = "123 /usr/bin/other-process\n"
        }
        struct Runner: ProcessRunning {
            let counter: Counter
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                if executable == "/bin/ps" {
                    counter.ps += 1
                    return ProcessResult(status: 0, stdout: counter.psOutput)
                }
                if executable == "/usr/bin/sqlite3" {
                    counter.sqlite += 1
                    return ProcessResult(status: 0, stdout: "")
                }
                return ProcessResult(status: 1)
            }
        }

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sqlite = home.appendingPathComponent(".codex/sqlite")
        let chatRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
        try Data().write(to: sqlite.appendingPathComponent("state_5.sqlite"))
        try Data().write(to: sqlite.appendingPathComponent("codex-dev.db"))
        let sessionsFile = chatRoot.appendingPathComponent("sessions.json")
        try Data("[{\"id\":\"first\",\"cwd\":\"/tmp/worktree\"}]".utf8).write(to: sessionsFile)
        let counter = Counter()
        let service = SessionService(home: home.path, runner: Runner(counter: counter))
        let cache = try XCTUnwrap(service.makeCleanupSafetyCache())

        XCTAssertEqual(cache.cachedMetadata()?.map(\.id), ["chatgpt-first"])
        XCTAssertEqual(counter.sqlite, 2)
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id), ["chatgpt-first"])
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id), ["chatgpt-first"])
        XCTAssertEqual(counter.sqlite, 2, "unchanged Codex databases must not be queried again")

        let addedSessionFile = chatRoot.appendingPathComponent("conversations.json")
        try Data("[{\"id\":\"second\",\"cwd\":\"/tmp/worktree\"}]".utf8).write(to: addedSessionFile)
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id).sorted(), ["chatgpt-first", "chatgpt-second"])
        XCTAssertEqual(counter.sqlite, 2, "ChatGPT source change must not refresh unchanged Codex metadata")
        XCTAssertEqual(counter.ps, 3, "activity check must use a fresh process scan for each removal")
        try FileManager.default.removeItem(at: addedSessionFile)
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id), ["chatgpt-first"], "candidate removal must invalidate cached ChatGPT metadata")
        try Data("wal update".utf8).write(to: sqlite.appendingPathComponent("state_5.sqlite-wal"))
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id), ["chatgpt-first"])
        XCTAssertEqual(counter.sqlite, 4, "Codex WAL changes must refresh Codex metadata only")
    }

    func testCleanupSafetyCacheDetectsSessionBecomingActiveAndUnknown() throws {
        final class Counter: @unchecked Sendable {
            var ps = 0
            var activeAt = 2
            var unknownAt: Int?
        }
        struct Runner: ProcessRunning {
            let counter: Counter
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                if executable == "/bin/ps" {
                    counter.ps += 1
                    if counter.ps == counter.unknownAt { return ProcessResult(status: 0, stdout: "123 /Applications/Codex.app/Contents/MacOS/Codex\n") }
                    if counter.ps >= counter.activeAt { return ProcessResult(status: 0, stdout: "123 /usr/local/bin/codex session-1\n") }
                    return ProcessResult(status: 0, stdout: "123 /usr/bin/other-process\n")
                }
                if executable == "/usr/bin/sqlite3", arguments.contains(where: { $0.contains("state_5.sqlite?") }) {
                    return ProcessResult(status: 0, stdout: "{\"id\":\"session-1\",\"title\":\"fixture\",\"cwd\":\"/tmp/worktree\"}\n")
                }
                return ProcessResult(status: 0, stdout: "")
            }
        }

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-active-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sqlite = home.appendingPathComponent(".codex/sqlite")
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: true)
        try Data().write(to: sqlite.appendingPathComponent("state_5.sqlite"))
        let counter = Counter()
        let service = SessionService(home: home.path, runner: Runner(counter: counter))
        let cache = try XCTUnwrap(service.makeCleanupSafetyCache())
        XCTAssertEqual(cache.cachedMetadata()?.map(\.activity), [.inactive])
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.activity), [.inactive])
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.activity), [.active])
        counter.activeAt = 99
        counter.unknownAt = 3
        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.activity), [.unknown])
    }

    func testCleanupSafetyCacheFailsClosedWhenFreshnessCannotBeRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-stale-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let badRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: badRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: badRoot)
        let cache = try XCTUnwrap(SessionService(home: home.path).makeCleanupSafetyCache())
        XCTAssertNil(cache.cachedMetadata())
        XCTAssertNil(cache.freshSessionsForRemoval())
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

    func testClaudeHistoryUsesExplicitProjectAndDeduplicatesSessionRows() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-history-\(UUID().uuidString)")
        let source = home.appendingPathComponent(".claude/history.jsonl")
        let worktree = home.appendingPathComponent("repos/exact-worktree")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let gitRunner = LocalProcessRunner()
        func runGit(_ arguments: [String]) throws {
            let result = try gitRunner.run("/usr/bin/git", arguments: ["-C", worktree.path] + arguments, currentDirectory: nil)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        try runGit(["init", "-b", "main"])
        try runGit(["config", "user.email", "worktree-lens@example.invalid"])
        try runGit(["config", "user.name", "Worktree Lens Test"])
        try Data("fixture\n".utf8).write(to: worktree.appendingPathComponent("fixture.txt"))
        try runGit(["add", "."])
        try runGit(["commit", "-m", "fixture"])
        let rows = [
            "{\"sessionId\":\"claude-session-1\",\"project\":\"\(worktree.path)\",\"display\":\"First title\",\"timestamp\":1700000000}",
            "{\"sessionId\":\"claude-session-1\",\"project\":\"\(worktree.path)\",\"display\":\"Latest title\",\"timestamp\":1700000001}"
        ].joined(separator: "\n")
        try Data((rows + "\n").utf8).write(to: source)

        let session = try XCTUnwrap(ClaudeSessionProvider(home: home.path, activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))).discover().sessions.first)

        XCTAssertEqual(session.id, "claude-claude-session-1")
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.title, "Latest title")
        XCTAssertEqual(session.cwd, worktree.path)
        XCTAssertNil(session.url)
        XCTAssertEqual(session.activity, .inactive)
        let snapshot = try GitService().snapshot(repositoryPath: worktree.path, sessions: [session])
        XCTAssertEqual(snapshot.branches.flatMap(\.worktrees).flatMap(\.sessions).map(\.id), [session.id])
    }

    func testClaudeProjectsFallbackReadsOnlySessionsAbsentFromHistory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-fallback-\(UUID().uuidString)")
        let project = home.appendingPathComponent(".claude/projects/slug")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = "{\"sessionId\":\"fallback-id\",\"cwd\":\"/tmp/explicit-worktree\",\"gitBranch\":\"feature\",\"timestamp\":1700000010,\"title\":\"Transcript title\"}\n"
        try Data(transcript.utf8).write(to: project.appendingPathComponent("fallback-id.jsonl"))
        let history = home.appendingPathComponent(".claude/history.jsonl")
        try Data("{\"sessionId\":\"fallback-id\",\"display\":\"No project\"}\n".utf8).write(to: history)

        let result = ClaudeSessionProvider(home: home.path, activityProbe: ProcessActivityProbe(runner: StaticRunner(output: ""))).discover()

        XCTAssertEqual(result.sessions.map(\.id), ["claude-fallback-id"])
        XCTAssertEqual(result.sessions.first?.cwd, "/tmp/explicit-worktree")
        XCTAssertEqual(result.sessions.first?.branch, "feature")
        XCTAssertEqual(result.sessions.first?.title, "Transcript title")

        for (processes, activity) in [("123 claude --resume fallback-id\n", SessionActivity.active), ("123 claude\n", SessionActivity.unknown)] {
            let restored = try XCTUnwrap(ClaudeSessionProvider(home: home.path, activityProbe: ProcessActivityProbe(runner: StaticRunner(output: processes))).discover().sessions.first)
            XCTAssertEqual(restored.activity, activity)
            let worktree = WorktreeInfo(id: "/tmp/explicit-worktree", path: "/tmp/explicit-worktree", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: Date(), sessions: [restored])
            let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
            XCTAssertFalse(CleanupService().decide(worktree: worktree, branch: branch).allowed)
        }
    }

    func testClaudeMalformedAndMissingSourcesAreSafe() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-malformed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let history = home.appendingPathComponent(".claude/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{bad json}\n{\"sessionId\":\"missing-cwd\",\"display\":\"No project\"}\n".utf8).write(to: history)
        let provider = ClaudeSessionProvider(home: home.path, activityProbe: ProcessActivityProbe(runner: StaticRunner(output: "")))

        XCTAssertTrue(provider.discover().sessions.isEmpty)
        XCTAssertNotNil(provider.sourceFingerprint())
        try FileManager.default.removeItem(at: history)
        XCTAssertTrue(provider.discover().sessions.isEmpty)
        XCTAssertNotNil(provider.sourceFingerprint())
    }

    func testClaudeActivityIsFailClosedAndInactiveSessionCanPassCleanupDecision() throws {
        let id = "claude-active-id"
        let activeProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/local/bin/claude --resume \(id)\n"))
        let unknownProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 /opt/homebrew/bin/claude\n"))
        let bareProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 claude\n"))
        let nonExactIDProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/local/bin/claude --resume \(id)-suffix\n"))
        let unrelatedProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 /tmp/claude-data/tool\n"))
        let inactiveProbe = ProcessActivityProbe(runner: StaticRunner(output: "123 /usr/bin/other-process\n"))
        let fixtureHome = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-activity-\(UUID().uuidString)")
        let history = fixtureHome.appendingPathComponent(".claude/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureHome) }
        try Data("{\"sessionId\":\"\(id)\",\"project\":\"/tmp/wt\"}\n".utf8).write(to: history)
        let activeSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: activeProbe).discover().sessions.first)
        let unknownSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: unknownProbe).discover().sessions.first)
        let bareSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: bareProbe).discover().sessions.first)
        let nonExactIDSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: nonExactIDProbe).discover().sessions.first)
        let unrelatedSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: unrelatedProbe).discover().sessions.first)
        let inactiveSession = try XCTUnwrap(ClaudeSessionProvider(home: fixtureHome.path, activityProbe: inactiveProbe).discover().sessions.first)
        XCTAssertEqual(activeSession.activity, .active)
        XCTAssertEqual(unknownSession.activity, .unknown)
        XCTAssertEqual(bareSession.activity, .unknown)
        XCTAssertEqual(nonExactIDSession.activity, .unknown)
        XCTAssertEqual(unrelatedSession.activity, .inactive)
        XCTAssertEqual(inactiveSession.activity, .inactive)

        func decision(_ session: SessionRecord) -> CleanupDecision {
            let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: Date(), sessions: [session])
            let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
            return CleanupService().decide(worktree: worktree, branch: branch)
        }
        XCTAssertEqual(decision(activeSession).reason, .activeSession)
        XCTAssertEqual(decision(unknownSession).reason, .unknownSessionActivity)
        XCTAssertTrue(decision(inactiveSession).allowed)
    }

    func testClaudeSourceMutationInvalidatesOnlyClaudeMetadataCache() throws {
        final class Counter: @unchecked Sendable { var processScans = 0; var sqlite = 0 }
        struct Runner: ProcessRunning {
            let counter: Counter
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                if executable == "/bin/ps" { counter.processScans += 1; return ProcessResult(status: 0, stdout: "123 /usr/bin/other-process\n") }
                if executable == "/usr/bin/sqlite3" { counter.sqlite += 1; return ProcessResult(status: 0, stdout: "") }
                return ProcessResult(status: 0, stdout: "")
            }
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-cache-\(UUID().uuidString)")
        let history = home.appendingPathComponent(".claude/history.jsonl")
        let sqlite = home.appendingPathComponent(".codex/sqlite")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: true)
        try Data().write(to: sqlite.appendingPathComponent("state_5.sqlite"))
        try Data().write(to: history)
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let service = SessionService(home: home.path, runner: Runner(counter: counter))
        let cache = try XCTUnwrap(service.makeCleanupSafetyCache())
        XCTAssertEqual(cache.cachedMetadata()?.count, 0)
        let before = service.metrics.snapshot()
        XCTAssertEqual(cache.freshSessionsForRemoval()?.count, 0)
        let unchanged = service.metrics.snapshot()
        XCTAssertEqual(unchanged.claudeFileReads, before.claudeFileReads, "unchanged Claude source must not be reparsed")
        XCTAssertEqual(counter.processScans, 1, "one fresh process snapshot is shared across providers")
        try Data("{\"sessionId\":\"new-claude\",\"project\":\"/tmp/wt\"}\n".utf8).write(to: history)

        XCTAssertEqual(cache.freshSessionsForRemoval()?.map(\.id), ["claude-new-claude"])
        let after = service.metrics.snapshot()
        XCTAssertEqual(after.codexSQLiteQueries, before.codexSQLiteQueries)
        XCTAssertEqual(after.chatGPTMetadataScans, before.chatGPTMetadataScans)
        XCTAssertGreaterThan(after.claudeFileReads, unchanged.claudeFileReads, "changed Claude source must be reparsed")
        XCTAssertEqual(counter.processScans, 2, "each removal freshness check uses one shared process snapshot")
    }

    func testCleanupSafetyCacheBlocksClaudeProcessesWithoutKnownSessionMetadata() throws {
        final class Counter: @unchecked Sendable { var processScans = 0 }
        struct Runner: ProcessRunning {
            let counter: Counter
            let processes: String
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                if executable == "/bin/ps" { counter.processScans += 1; return ProcessResult(status: 0, stdout: processes) }
                return ProcessResult(status: 0, stdout: "")
            }
        }

        for processLine in ["123 claude\n", "123 claude --resume unknown-id\n"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-unresolved-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            let counter = Counter()
            let cache = try XCTUnwrap(SessionService(home: home.path, runner: Runner(counter: counter, processes: processLine)).makeCleanupSafetyCache())

            XCTAssertNil(cache.freshSessionsForRemoval(), "unresolved Claude process must fail closed: \(processLine)")
            XCTAssertEqual(counter.processScans, 1, "one process snapshot per fresh cleanup check")
        }

        let knownHome = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-known-\(UUID().uuidString)")
        let history = knownHome.appendingPathComponent(".claude/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: knownHome) }
        try Data("{\"sessionId\":\"known-session\",\"project\":\"/tmp/wt\"}\n".utf8).write(to: history)
        let knownCounter = Counter()
        let knownCache = try XCTUnwrap(SessionService(home: knownHome.path, runner: Runner(counter: knownCounter, processes: "123 /opt/homebrew/bin/claude --resume known-session\n")).makeCleanupSafetyCache())
        XCTAssertEqual(knownCache.freshSessionsForRemoval()?.map(\.activity), [.active])
        XCTAssertEqual(knownCounter.processScans, 1)

        let inactiveCounter = Counter()
        let inactiveHome = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-claude-absent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inactiveHome) }
        let inactiveCache = try XCTUnwrap(SessionService(home: inactiveHome.path, runner: Runner(counter: inactiveCounter, processes: "123 /usr/bin/unrelated\n")).makeCleanupSafetyCache())
        XCTAssertEqual(inactiveCache.freshSessionsForRemoval()?.count, 0)
        XCTAssertEqual(inactiveCounter.processScans, 1)

        let worktree = WorktreeInfo(id: "/tmp/wt", path: "/tmp/wt", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: Date())
        let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: Date(), worktrees: [worktree])
        XCTAssertTrue(CleanupService().decide(worktree: worktree, branch: branch).allowed)
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

    func testStandaloneRemoveHandlesMultipleDetachedWorktreesWithDifferentHEADs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-detached-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repository")
        let firstPath = root.appendingPathComponent("detached-first")
        let secondPath = root.appendingPathComponent("detached-second")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try runGit(["init", "-b", "main", repository.path])
        _ = try runGit(["-C", repository.path, "config", "user.email", "worktree-lens@example.invalid"])
        _ = try runGit(["-C", repository.path, "config", "user.name", "Worktree Lens Test"])
        for (name, contents) in [("one.txt", "one\n"), ("two.txt", "two\n"), ("three.txt", "three\n")] {
            try Data(contents.utf8).write(to: repository.appendingPathComponent(name))
            _ = try runGit(["-C", repository.path, "add", "."])
            _ = try runGit(["-C", repository.path, "commit", "-m", name])
        }
        _ = try runGit(["-C", repository.path, "worktree", "add", "--detach", firstPath.path, "HEAD~1"])
        _ = try runGit(["-C", repository.path, "worktree", "add", "--detach", secondPath.path, "HEAD~2"])

        let gitRecorder = RecordingRunner()
        let git = GitService(runner: gitRecorder)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: root.appendingPathComponent("no-sessions").path))
        let snapshot = try git.snapshot(repositoryPath: repository.path)
        let detached = try XCTUnwrap(snapshot.branches.first(where: \.isDetachedGroup))
        let first = try XCTUnwrap(detached.worktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == firstPath.resolvingSymlinksInPath().path })
        let second = try XCTUnwrap(detached.worktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == secondPath.resolvingSymlinksInPath().path })
        XCTAssertNotEqual(first.head, second.head)

        let firstPreview = cleanup.previewRemoveWorktree(snapshot: snapshot, path: first.path)
        let secondPreview = cleanup.previewRemoveWorktree(snapshot: snapshot, path: second.path)
        XCTAssertEqual(firstPreview.items[0].expectedSHA, first.head)
        XCTAssertEqual(secondPreview.items[0].expectedSHA, second.head)
        XCTAssertEqual(cleanup.execute(firstPreview).removedWorktreePaths, [first.path])
        XCTAssertEqual(cleanup.execute(secondPreview).removedWorktreePaths, [second.path])

        let remaining = try git.snapshot(repositoryPath: repository.path).branches.flatMap(\.worktrees)
        XCTAssertFalse(remaining.contains { $0.path == first.path || $0.path == second.path })
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
        let result = cleanup.execute(mergedPreview)
        XCTAssertTrue(result.deletedLocalBranches.isEmpty)
        XCTAssertTrue(result.removedWorktreePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        XCTAssertTrue((try GitService().snapshot(repositoryPath: repository.path)).branches.contains { $0.name == "merged" })
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

    func testRefreshBulkFetchesMergeEvidenceOnceForManyBranches() async throws {
        final class Counter: @unchecked Sendable {
            var arguments: [[String]] = []
        }

        let counter = Counter()
        let featurePR = "[{\"number\":201,\"title\":\"old feature\",\"state\":\"MERGED\",\"isDraft\":false,\"baseRefName\":\"main\",\"headRefName\":\"feature-99\",\"headRefOid\":\"sha-99\",\"mergedAt\":\"2026-01-01T00:00:00Z\",\"url\":\"https://github.com/example/repo/pull/201\"}]"
        let runner = RoutingRunner { arguments in
            counter.arguments.append(arguments)
            if arguments.starts(with: ["pr", "list"]) { return ProcessResult(status: 0, stdout: featurePR) }
            XCTFail("unexpected GitHub command: \(arguments.joined(separator: " "))")
            return ProcessResult(status: 1)
        }
        let branches = [
            BranchInfo(id: "main", name: "main", sha: "main-sha", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: false, lastCommitAt: nil, isDefaultBranch: true, worktrees: [])
        ] + (0..<100).map { index in
            BranchInfo(id: "feature-\(index)", name: "feature-\(index)", sha: "sha-\(index)", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
        }
        let local = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: branches), sessionNotes: [])
        let scanner = RepositoryScanService(github: GitHubService(runner: runner, executable: "gh"))

        let enriched = await scanner.enrichGitHub(local: local)

        XCTAssertEqual(counter.arguments.filter { $0.starts(with: ["pr", "list"]) }.count, 1)
        XCTAssertTrue(counter.arguments.allSatisfy { !$0.starts(with: ["pr", "view"]) && !$0.starts(with: ["run", "list"]) })
        let verified = try XCTUnwrap(enriched.branches.first { $0.name == "feature-99" })
        XCTAssertTrue(verified.isMerged)
        XCTAssertTrue(verified.github.mergeEvidenceLoaded)
        XCTAssertFalse(verified.github.isLoaded)
        XCTAssertEqual(verified.mergeEvidence, .githubVerified(prNumber: 201, mergedAt: try XCTUnwrap(verified.github.pullRequests.first?.mergedAt)))
    }

    func testRefreshGitHubFailureKeepsLocalSnapshotAndFailsClosed() async {
        let branch = BranchInfo(id: "feature", name: "feature", sha: "feature-sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
        let local = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [branch]), sessionNotes: ["local"])
        let runner = RoutingRunner { _ in throw ProcessRunnerError.failed("offline") }
        let scanner = RepositoryScanService(github: GitHubService(runner: runner, executable: "gh"))

        let enriched = await scanner.enrichGitHub(local: local)

        XCTAssertEqual(enriched.path, local.snapshot.path)
        XCTAssertEqual(enriched.branches.map(\.id), local.snapshot.branches.map(\.id))
        XCTAssertEqual(enriched.branches.first?.worktrees, local.snapshot.branches.first?.worktrees)
        XCTAssertFalse(enriched.branches[0].github.mergeEvidenceLoaded)
        XCTAssertFalse(enriched.branches[0].isMerged)
        XCTAssertEqual(enriched.branches[0].mergeStatus, "GitHub verification unavailable")
        XCTAssertFalse(CleanupService().previewDeleteBranch(snapshot: enriched, name: "feature").items[0].allowed)
    }

    func testBulkMergeEvidenceRequiresExactBaseHeadAndSHA() async throws {
        let branch = BranchInfo(id: "feature", name: "feature", sha: "local-sha", upstream: nil, ahead: 0, behind: 0, isMerged: false, remoteGone: false, lastCommitAt: nil, worktrees: [])
        let pullRequest = "[{\"number\":202,\"title\":\"feature\",\"state\":\"MERGED\",\"isDraft\":false,\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"different-sha\",\"mergedAt\":\"2026-01-01T00:00:00Z\",\"url\":\"https://github.com/example/repo/pull/202\"}]"
        let runner = RoutingRunner { arguments in
            ProcessResult(status: 0, stdout: arguments.starts(with: ["pr", "list"]) ? pullRequest : "[]")
        }
        let local = RepositoryLocalScanResult(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [branch]), sessionNotes: [])
        let scanner = RepositoryScanService(github: GitHubService(runner: runner, executable: "gh"))

        let enriched = await scanner.enrichGitHub(local: local)

        XCTAssertTrue(enriched.branches[0].github.mergeEvidenceLoaded)
        XCTAssertFalse(enriched.branches[0].isMerged)
        XCTAssertEqual(enriched.branches[0].mergeStatus, "Not merged")
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
        let gitRecorder = RecordingRunner()
        let git = GitService(runner: gitRecorder)
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
        let beforeCleanup = gitRecorder.arguments.count
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(gitRecorder.arguments.count - beforeCleanup, 7, "standalone verified branch deletion process count")
    }

    func testRemoteGoneGitHubVerifiedAttachedWorktreeIsRemovedBeforeBranch() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 131, sha: fixture.featureSHA), executable: "gh")
        let gitRecorder = RecordingRunner()
        let git = GitService(runner: gitRecorder)
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let remoteGoneBranch = branch.withMergeEvidence(.githubVerified(prNumber: 131, mergedAt: mergedAt), github: status).withRemoteGone(true)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [remoteGoneBranch])
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)

        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        let group = try XCTUnwrap(preview.groups.first)
        XCTAssertEqual(group.steps.map(\.step), [.removeWorktree, .deleteBranch])
        XCTAssertTrue(group.steps.allSatisfy(\.allowed))
        XCTAssertTrue(group.steps[0].detail?.contains("clean") == true)
        XCTAssertTrue(group.steps[0].detail?.contains("session: none") == true)
        let beforeCleanup = gitRecorder.arguments.count
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(gitRecorder.arguments.count - beforeCleanup, 17, "one-worktree GitHub grouped cleanup process count")
        print("CLEANUP_GIT_SUBPROCESS grouped_github_worktree=\(gitRecorder.arguments.count - beforeCleanup)")
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testMergedGitHubVerifiedAttachedWorktreeIsRemovedWhenRemoteRemains() async throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])

        let github = GitHubService(runner: verifiedGitHubRunner(number: 137, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        XCTAssertFalse(branch.remoteGone)
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let enrichedBranch = branch.withMergeEvidence(.githubVerified(prNumber: 137, mergedAt: mergedAt), github: status)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [enrichedBranch])
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)

        let preview = cleanup.previewMergedBranches(snapshot: snapshot)
        let group = try XCTUnwrap(preview.groups.first)
        XCTAssertEqual(group.steps.map(\.step), [.removeWorktree, .deleteBranch])
        XCTAssertTrue(group.allowed)
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertTrue((try runGit(["-C", fixture.repository.path, "show-ref", "--verify", "refs/remotes/origin/feature"])).contains(fixture.featureSHA))
    }

    func testMergedGitAncestorAttachedWorktreeIsRemovedWhenRemoteRemains() throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        _ = try runGit(["-C", fixture.repository.path, "push", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])

        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        XCTAssertTrue(branch.isMerged)
        XCTAssertFalse(branch.remoteGone)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path))

        let preview = cleanup.previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch]))
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertTrue((try runGit(["-C", fixture.repository.path, "show-ref", "--verify", "refs/remotes/origin/feature"])).contains(fixture.featureSHA))
    }

    func testMergedBranchWithoutWorktreeUsesBranchOnlyPlan() async throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])

        let github = GitHubService(runner: verifiedGitHubRunner(number: 138, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let branch = try XCTUnwrap((try git.snapshot(repositoryPath: fixture.repository.path)).branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let mergedBranch = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: mergedAt), github: status)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [mergedBranch])
        let sessionDiscovery = CountingSessionDiscovery()
        let executionRecorder = RecordingRunner()
        let cleanup = CleanupService(git: GitService(runner: executionRecorder), sessions: sessionDiscovery, github: github)

        let preview = cleanup.previewMergedBranches(snapshot: snapshot)
        XCTAssertEqual(preview.groups.first?.steps.map(\.step), [.deleteBranch])
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(sessionDiscovery.count, 0)
        XCTAssertEqual(executionRecorder.arguments.count, 6)
        XCTAssertEqual(executionRecorder.arguments.filter { $0.contains("for-each-ref") }.count, 1)
        XCTAssertFalse(executionRecorder.arguments.contains { $0.contains("merge-base") })
        XCTAssertEqual(executionRecorder.arguments.filter { $0.contains("update-ref") && $0.contains("-d") }.count, 1)
        XCTAssertTrue((try runGit(["-C", fixture.repository.path, "show-ref", "--verify", "refs/remotes/origin/feature"])).contains(fixture.featureSHA))
    }

    func testTenGitHubVerifiedBranchOnlyGroupsAvoidMergeBaseAndUseExactPRViews() throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])
        for index in 2...10 {
            _ = try runGit(["-C", fixture.repository.path, "branch", "feature-\(index)", "feature"])
        }

        let gitRecorder = RecordingRunner()
        let ghRecorder = StubRecordingRunner { arguments in
            guard arguments.starts(with: ["pr", "view"]), let prNumber = arguments.dropFirst(2).first,
                  let number = Int(prNumber) else { return ProcessResult(status: 1, stderr: "unexpected gh command") }
            let branchName = number == 1 ? "feature" : "feature-\(number)"
            let response = "{\"number\":\(number),\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"\(branchName)\",\"headRefOid\":\"\(fixture.featureSHA)\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"
            return ProcessResult(status: 0, stdout: response)
        }
        let git = GitService(runner: gitRecorder)
        let local = try GitService().snapshot(repositoryPath: fixture.repository.path)
        let branches = local.branches.compactMap { branch -> BranchInfo? in
            guard branch.name == "feature" || branch.name.hasPrefix("feature-") else { return nil }
            let number = branch.name == "feature" ? 1 : Int(branch.name.dropFirst("feature-".count)) ?? 0
            return branch.withMergeEvidence(.githubVerified(prNumber: number, mergedAt: Date(timeIntervalSince1970: 1)))
        }
        XCTAssertEqual(branches.count, 10)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: ghRecorder, executable: "gh"))
        let preview = cleanup.previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: branches))

        XCTAssertEqual(cleanup.execute(preview).count, 10)
        let gitArguments = gitRecorder.arguments
        XCTAssertEqual(gitArguments.count, 43)
        XCTAssertEqual(ghRecorder.arguments.count, 10)
        XCTAssertFalse(gitArguments.contains { $0.contains("merge-base") })
        XCTAssertEqual(gitArguments.filter { $0.contains("update-ref") && $0.contains("-d") }.count, 10)
        XCTAssertTrue(ghRecorder.arguments.allSatisfy { $0.starts(with: ["pr", "view"]) })
        XCTAssertEqual(gitArguments.filter { $0.contains("branch") && $0.contains("-D") }.count, 0)
    }

    func testTenGroupedWorktreeCleanupSessionOperationMeasurement() throws {
        struct SessionRunner: ProcessRunning {
            func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult {
                if executable == "/bin/ps" { return ProcessResult(status: 0, stdout: "123 /usr/bin/other-process\n") }
                if executable == "/usr/bin/sqlite3" { return ProcessResult(status: 0, stdout: "") }
                return ProcessResult(status: 1)
            }
        }

        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var worktreePaths: [URL] = []
        for index in 1...10 {
            let name = index == 1 ? "feature" : "feature-\(index)"
            if index > 1 { _ = try runGit(["-C", fixture.repository.path, "branch", name, "feature"]) }
            let path = fixture.root.appendingPathComponent("worktree-\(index)")
            _ = try runGit(["-C", fixture.repository.path, "worktree", "add", path.path, name])
            worktreePaths.append(path)
        }

        let home = fixture.root.appendingPathComponent("session-home")
        let sqlite = home.appendingPathComponent(".codex/sqlite")
        let chatRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
        try Data().write(to: sqlite.appendingPathComponent("state_5.sqlite"))
        try Data().write(to: sqlite.appendingPathComponent("codex-dev.db"))
        try Data("[]".utf8).write(to: chatRoot.appendingPathComponent("sessions.json"))

        let metrics = SessionDiscoveryMetrics()
        let sessionService = SessionService(home: home.path, runner: SessionRunner(), metrics: metrics)
        for _ in 0..<10 {
            _ = sessionService.discover()
        }
        let before = metrics.snapshot()
        metrics.reset()

        let local = try GitService().snapshot(repositoryPath: fixture.repository.path)
        let branches = local.branches.compactMap { branch -> BranchInfo? in
            guard let index = Int(branch.name == "feature" ? "1" : branch.name.replacingOccurrences(of: "feature-", with: "")), (1...10).contains(index) else { return nil }
            return branch.withMergeEvidence(.githubVerified(prNumber: index, mergedAt: Date(timeIntervalSince1970: 1)))
        }
        XCTAssertEqual(branches.count, 10)
        let github = GitHubService(runner: StubRecordingRunner { arguments in
            guard arguments.starts(with: ["pr", "view"]), let number = arguments.dropFirst(2).first, let index = Int(number) else { return ProcessResult(status: 1) }
            let name = index == 1 ? "feature" : "feature-\(index)"
            let body = "{\"number\":\(index),\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"\(name)\",\"headRefOid\":\"\(fixture.featureSHA)\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"
            return ProcessResult(status: 0, stdout: body)
        }, executable: "gh")
        let cleanup = CleanupService(git: GitService(), sessions: sessionService, github: github)
        let preview = cleanup.previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: branches))
        XCTAssertEqual(preview.groups.count, 10)
        XCTAssertTrue(preview.groups.allSatisfy { $0.steps.filter { $0.step == .removeWorktree }.count == 1 })
        XCTAssertEqual(cleanup.execute(preview).count, 10)

        let after = metrics.snapshot()
        print("SESSION_METRICS before=\(before) total=\(before.totalOperations) after=\(after) total=\(after.totalOperations)")
        XCTAssertEqual(before.processScans, 10)
        XCTAssertEqual(before.codexSQLiteQueries, 20)
        XCTAssertEqual(before.chatGPTMetadataScans, 10)
        XCTAssertEqual(before.chatGPTFileReads, 10)
        XCTAssertEqual(before.providerFingerprintCalls, 0)
        XCTAssertEqual(after.processScans, 10)
        XCTAssertEqual(after.codexSQLiteQueries, 2)
        XCTAssertLessThan(after.chatGPTMetadataScans, before.chatGPTMetadataScans)
        XCTAssertLessThan(after.chatGPTFileReads, before.chatGPTFileReads)
        XCTAssertGreaterThan(after.providerFingerprintCalls, 0)
        XCTAssertLessThan(after.chatGPTDirectoryEnumerations, before.chatGPTDirectoryEnumerations)
        XCTAssertLessThanOrEqual(after.fileAttributeChecks, 400, "fingerprint stat work must stay within the measured bound")
        XCTAssertLessThanOrEqual(after.totalOperations, 450, "session operation count must stay within the measured bound")
        XCTAssertTrue(worktreePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testTenGroupSessionSafetyElapsedSmokeRepeats() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-lens-elapsed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sqliteDirectory = home.appendingPathComponent(".codex/sqlite")
        let chatRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        try FileManager.default.createDirectory(at: sqliteDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
        let runner = LocalProcessRunner()
        let statePath = sqliteDirectory.appendingPathComponent("state_5.sqlite")
        let catalogPath = sqliteDirectory.appendingPathComponent("codex-dev.db")
        let stateSQL = "CREATE TABLE threads (id TEXT, title TEXT, updated_at REAL, updated_at_ms REAL, cwd TEXT, git_branch TEXT);"
        let catalogSQL = "CREATE TABLE local_thread_catalog (thread_id TEXT, display_title TEXT, source_updated_at REAL, cwd TEXT, git_branch TEXT);"
        XCTAssertTrue(try runner.run("/usr/bin/sqlite3", arguments: [statePath.path, stateSQL], currentDirectory: nil).succeeded)
        XCTAssertTrue(try runner.run("/usr/bin/sqlite3", arguments: [catalogPath.path, catalogSQL], currentDirectory: nil).succeeded)
        try Data("[]".utf8).write(to: chatRoot.appendingPathComponent("sessions.json"))
        let service = SessionService(home: home.path, runner: runner)

        func elapsed(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return ProcessInfo.processInfo.systemUptime - start
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<3 {
            before.append(elapsed { for _ in 0..<10 { _ = service.discover() } })
            after.append(elapsed {
                guard let cache = service.makeCleanupSafetyCache() else { XCTFail("Missing cleanup cache"); return }
                XCTAssertNotNil(cache.cachedMetadata())
                for _ in 0..<10 { XCTAssertNotNil(cache.freshSessionsForRemoval()) }
            })
        }
        print("SESSION_ELAPSED_SECONDS groups=10x1 repeats=3 before=\(before) after=\(after)")
    }

    func testTenGitAncestorBranchOnlyGroupsKeepFreshMergeBaseChecks() throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        _ = try runGit(["-C", fixture.repository.path, "push", "origin", "main"])
        for index in 2...10 {
            _ = try runGit(["-C", fixture.repository.path, "branch", "feature-\(index)", "feature"])
        }
        let gitRecorder = RecordingRunner()
        let git = GitService(runner: gitRecorder)
        let local = try GitService().snapshot(repositoryPath: fixture.repository.path)
        let branches = local.branches.filter { $0.name == "feature" || $0.name.hasPrefix("feature-") }
        XCTAssertEqual(branches.count, 10)
        XCTAssertTrue(branches.allSatisfy { $0.mergeEvidence == .gitAncestor })
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path))
        let preview = cleanup.previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: branches))

        XCTAssertEqual(cleanup.execute(preview).count, 10)
        XCTAssertEqual(gitRecorder.arguments.count, 53)
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("merge-base") }.count, 10)
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("branch") && $0.contains("-d") }.count, 10)
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("branch") && $0.contains("-D") }.count, 0)
    }

    func testKnownPRExactVerificationFailsClosedForWrongOrMissingFields() throws {
        let invalidResponses: [(String, String)] = [
            ("wrong PR number", "{\"number\":139,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"SHA\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"),
            ("missing PR", "{}"),
            ("unmerged PR", "{\"number\":138,\"state\":\"OPEN\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"SHA\",\"mergedAt\":null}"),
            ("base mismatch", "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"develop\",\"headRefName\":\"feature\",\"headRefOid\":\"SHA\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"),
            ("head mismatch", "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"other\",\"headRefOid\":\"SHA\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"),
            ("PR SHA mismatch", "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"other-sha\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}")
        ]

        for (label, response) in invalidResponses {
            let fixture = try makeFeatureRepository()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let originalBranch = try XCTUnwrap(GitService().snapshot(repositoryPath: fixture.repository.path).branches.first { $0.name == "feature" })
            let planned = originalBranch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
            let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [planned])
            let gh = GitHubService(runner: StubRecordingRunner { _ in ProcessResult(status: 0, stdout: response) }, executable: "gh")
            let cleanup = CleanupService(git: GitService(), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: gh)
            let preview = cleanup.previewMergedBranches(snapshot: snapshot)

            XCTAssertTrue(cleanup.execute(preview).isEmpty, label)
            XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" }, label)
        }
    }

    func testBranchOnlyPreviewBlocksAttachedWorktreeAndDefaultBranchDrift() throws {
        do {
            let fixture = try makeFeatureRepository()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: fixture.repository.path).branches.first { $0.name == "feature" })
            let planned = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
            let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [planned]))
            let attachedPath = fixture.root.appendingPathComponent("late-worktree")
            _ = try runGit(["-C", fixture.repository.path, "worktree", "add", attachedPath.path, "feature"])
            let exactPR = "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(fixture.featureSHA)\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"
            let cleanup = CleanupService(git: GitService(), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: StubRecordingRunner { _ in ProcessResult(status: 0, stdout: exactPR) }, executable: "gh"))

            XCTAssertTrue(cleanup.execute(preview).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachedPath.path))
            XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        }

        do {
            let fixture = try makeFeatureRepository()
            let remotePath = fixture.root.appendingPathComponent("remote.git")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try runGit(["init", "--bare", remotePath.path])
            _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
            _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
            _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
            _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "main"])
            let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: fixture.repository.path).branches.first { $0.name == "feature" })
            let planned = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
            let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [planned]))
            _ = try runGit(["-C", fixture.repository.path, "remote", "set-head", "origin", "feature"])
            let cleanup = CleanupService(git: GitService(), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: StubRecordingRunner { _ in XCTFail("default drift must block before gh verification"); return ProcessResult(status: 1) }, executable: "gh"))

            XCTAssertTrue(cleanup.execute(preview).isEmpty)
            XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        }
    }

    func testRemoteWithUnresolvedDefaultKeepsUniqueLocalMainFallbackForSafeWorktreeCleanup() throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("empty-remote.git")
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])

        let recorder = RecordingRunner()
        let git = GitService(runner: recorder)
        let snapshot = try git.snapshot(repositoryPath: fixture.repository.path)
        XCTAssertEqual(snapshot.defaultBranch, "main")
        XCTAssertTrue(try XCTUnwrap(snapshot.branches.first { $0.name == "feature" }).isMerged)
        let attachedPath = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" }?.worktrees.first?.path)
        let preview = CleanupService().previewRemoveWorktree(snapshot: snapshot, path: attachedPath)
        XCTAssertTrue(preview.items[0].allowed, "blocked: \(String(describing: preview.items[0].reason))")
        let beforeCleanup = recorder.arguments.count
        XCTAssertEqual(CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path)).execute(preview).removedWorktreePaths, [attachedPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachedPath))
        let count = recorder.arguments.count - beforeCleanup
        XCTAssertLessThan(count, 20)
        print("CLEANUP_GIT_SUBPROCESS safe_worktree_local_fallback=\(count)")

        let cachedContext = try git.cleanupContext(repositoryPath: fixture.repository.path)
        XCTAssertEqual(cachedContext.defaultRef, "main")
        _ = try runGit(["-C", fixture.repository.path, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        XCTAssertFalse(git.validateCleanupDefaultBranch(cachedContext), "newly resolvable remote default must invalidate local fallback")
        XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    func testDefaultRefSourceDriftAfterContextAcquisitionBlocksGroupedMutation() throws {
        let fixture = try makeFeatureRepository()
        let remotePath = fixture.root.appendingPathComponent("remote.git")
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["init", "--bare", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        _ = try runGit(["-C", fixture.repository.path, "remote", "add", "origin", remotePath.path])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "main"])
        _ = try runGit(["-C", fixture.repository.path, "push", "-u", "origin", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "fetch", "origin"])
        _ = try runGit(["-C", fixture.repository.path, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])

        let git = GitService()
        let snapshot = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" })
        XCTAssertTrue(branch.isMerged)
        XCTAssertEqual(snapshot.defaultBranch, "main")
        let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: snapshot.path, defaultBranch: snapshot.defaultBranch, branches: [branch]))
        XCTAssertEqual(preview.groups.count, 1)
        let runner = RemovingRemoteTrackingRefRunner(repositoryPath: fixture.repository.path)
        let cleanup = CleanupService(git: GitService(runner: runner), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path))

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue(runner.removed, "fixture must change default ref source after context acquisition")
        XCTAssertFalse(runner.arguments.contains { $0.contains("worktree") && $0.contains("remove") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    func testBranchOnlyPreviewBlocksLocalSHADriftBeforeGitHubVerification() throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: fixture.repository.path).branches.first { $0.name == "feature" })
        let planned = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
        let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [planned]))
        _ = try runGit(["-C", fixture.repository.path, "switch", "feature"])
        _ = try runGit(["-C", fixture.repository.path, "commit", "--allow-empty", "-m", "advance feature"])
        _ = try runGit(["-C", fixture.repository.path, "switch", "main"])
        let cleanup = CleanupService(git: GitService(), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: StubRecordingRunner { _ in XCTFail("local SHA drift must block before gh verification"); return ProcessResult(status: 1) }, executable: "gh"))

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue((try GitService().snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    func testGroupedBranchOnlyExecutionUsesCanonicalRootForGitHubAndDeletion() throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registeredPath = fixture.root.appendingPathComponent("registered-repository")
        try FileManager.default.createSymbolicLink(at: registeredPath, withDestinationURL: fixture.repository)
        let canonicalPath = try GitService().canonicalRepositoryPath(registeredPath.path)
        XCTAssertNotEqual(registeredPath.path, canonicalPath)
        let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: canonicalPath).branches.first { $0.name == "feature" })
        let planned = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
        let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: registeredPath.path, defaultBranch: "main", branches: [planned]))
        let gitRecorder = RecordingRunner()
        let exactPR = "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(fixture.featureSHA)\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"
        let ghRecorder = StubRecordingRunner { _ in ProcessResult(status: 0, stdout: exactPR) }
        let cleanup = CleanupService(git: GitService(runner: gitRecorder), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: ghRecorder, executable: "gh"))

        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(ghRecorder.currentDirectories.compactMap { $0 }, [canonicalPath])
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("rev-parse") && $0.contains("--show-toplevel") }.count, 1)
        XCTAssertTrue(gitRecorder.arguments.contains { $0.starts(with: ["-C", canonicalPath]) && $0.contains("update-ref") && $0.contains("-d") })
        XCTAssertEqual(gitRecorder.arguments.filter { $0.starts(with: ["-C", registeredPath.path]) }.count, 1)
    }

    func testGroupedWorktreeRevalidationAndRemovalUseCanonicalRoot() throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registeredPath = fixture.root.appendingPathComponent("registered-repository")
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        try FileManager.default.createSymbolicLink(at: registeredPath, withDestinationURL: fixture.repository)
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let canonicalPath = try GitService().canonicalRepositoryPath(registeredPath.path)
        XCTAssertNotEqual(registeredPath.path, canonicalPath)
        let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: canonicalPath).branches.first { $0.name == "feature" })
        let planned = branch.withMergeEvidence(.githubVerified(prNumber: 138, mergedAt: Date(timeIntervalSince1970: 1)))
        let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: registeredPath.path, defaultBranch: "main", branches: [planned]))
        let gitRecorder = RecordingRunner()
        let exactPR = "{\"number\":138,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(fixture.featureSHA)\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}"
        let ghRecorder = StubRecordingRunner { _ in ProcessResult(status: 0, stdout: exactPR) }
        let cleanup = CleanupService(git: GitService(runner: gitRecorder), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: GitHubService(runner: ghRecorder, executable: "gh"))

        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(ghRecorder.currentDirectories.compactMap { $0 }, [canonicalPath, canonicalPath])
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("rev-parse") && $0.contains("--show-toplevel") }.count, 1)
        XCTAssertTrue(gitRecorder.arguments.contains { $0.starts(with: ["-C", canonicalPath]) && $0.contains("worktree") && $0.contains("remove") })
        XCTAssertTrue(gitRecorder.arguments.contains { $0.starts(with: ["-C", canonicalPath]) && $0.contains("update-ref") && $0.contains("-d") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertEqual(gitRecorder.arguments.filter { $0.starts(with: ["-C", registeredPath.path]) }.count, 1)
    }

    func testGroupedGitAncestorBranchDeletionUsesCanonicalRoot() throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        let registeredPath = fixture.root.appendingPathComponent("registered-repository")
        try FileManager.default.createSymbolicLink(at: registeredPath, withDestinationURL: fixture.repository)
        let canonicalPath = try GitService().canonicalRepositoryPath(registeredPath.path)
        XCTAssertNotEqual(registeredPath.path, canonicalPath)
        let branch = try XCTUnwrap(GitService().snapshot(repositoryPath: canonicalPath).branches.first { $0.name == "feature" })
        XCTAssertEqual(branch.mergeEvidence, .gitAncestor)
        let preview = CleanupService().previewMergedBranches(snapshot: RepositorySnapshot(path: registeredPath.path, defaultBranch: "main", branches: [branch]))
        let gitRecorder = RecordingRunner()
        let cleanup = CleanupService(git: GitService(runner: gitRecorder), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path))

        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertLessThanOrEqual(gitRecorder.arguments.count, 20, "one-worktree Git-ancestor grouped cleanup process budget")
        print("CLEANUP_GIT_SUBPROCESS git_ancestor_branch_only=\(gitRecorder.arguments.count)")
        XCTAssertTrue(gitRecorder.arguments.contains { $0.starts(with: ["-C", canonicalPath, "branch", "-d"]) })
        XCTAssertEqual(gitRecorder.arguments.filter { $0.contains("rev-parse") && $0.contains("--show-toplevel") }.count, 1)
        XCTAssertEqual(gitRecorder.arguments.filter { $0.starts(with: ["-C", registeredPath.path]) }.count, 1)
    }

    func testCleanupGitHubVerificationFetchesMergeEvidenceOnly() throws {
        let sha = String(repeating: "a", count: 40)
        let runner = StubRecordingRunner { arguments in
            if arguments.starts(with: ["pr", "list"]) {
                return ProcessResult(status: 0, stdout: "[{\"number\":12,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"" + sha + "\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}]")
            }
            return ProcessResult(status: 0, stdout: "[]")
        }
        let status = GitHubService(runner: runner, executable: "gh").cleanupStatus(repositoryPath: "/tmp/repository", branch: "feature")

        XCTAssertNotNil(status.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: sha))
        XCTAssertEqual(runner.arguments.count, 1)
        XCTAssertEqual(Array(runner.arguments.first?.prefix(2) ?? []), ["pr", "list"])
        XCTAssertFalse(runner.arguments.flatMap { $0 }.contains("closingIssuesReferences"))
        XCTAssertFalse(runner.arguments.contains { $0.starts(with: ["pr", "view"]) })
        XCTAssertFalse(runner.arguments.contains { $0.starts(with: ["run", "list"]) })
    }

    func testRemoteGoneGitAncestorAttachedWorktreeIsRemovedBeforeBranch() throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "switch", "main"])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        XCTAssertEqual(branch.mergeEvidence, .gitAncestor)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch.withRemoteGone(true)])
        let recorder = RecordingRunner()
        let cleanup = CleanupService(git: GitService(runner: recorder), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path))

        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(recorder.arguments.count, 19, "one-worktree Git-ancestor grouped cleanup process count")
        print("CLEANUP_GIT_SUBPROCESS grouped_git_ancestor_worktree=\(recorder.arguments.count)")
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    func testRemoteGonePreviewKeepsUnmergedBranchBlockedAlongsideVerifiedMergedBranch() async throws {
        let fixture = try makeFeatureRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let git = GitService()
        let github = GitHubService(runner: verifiedGitHubRunner(number: 140, sha: fixture.featureSHA), executable: "gh")
        let mainSHA = try runGit(["-C", fixture.repository.path, "rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runGit(["-C", fixture.repository.path, "switch", "-c", "unmerged", mainSHA])
        FileManager.default.createFile(atPath: fixture.repository.appendingPathComponent("unmerged.txt").path, contents: Data("unmerged\n".utf8))
        _ = try runGit(["-C", fixture.repository.path, "add", "."])
        _ = try runGit(["-C", fixture.repository.path, "commit", "-m", "unmerged branch"])
        _ = try runGit(["-C", fixture.repository.path, "switch", "main"])
        _ = try runGit(["-C", fixture.repository.path, "merge", "--no-ff", "feature", "-m", "merge feature"])

        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let feature = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let unmerged = try XCTUnwrap(local.branches.first { $0.name == "unmerged" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let branches = [
            feature.withMergeEvidence(.githubVerified(prNumber: 140, mergedAt: mergedAt), github: status).withRemoteGone(true),
            unmerged.withRemoteGone(true)
        ]
        let preview = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
            .previewRemoteGoneBranches(snapshot: RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: branches))

        XCTAssertEqual(preview.groups.count, 2)
        XCTAssertEqual(preview.groups.filter(\.allowed).count, 1)
        XCTAssertEqual(preview.groups.first { $0.branchName == "unmerged" }?.steps.last?.reason, .unmergedBranch)
    }

    func testRemoteGoneUnsafeAttachedWorktreeBlocksBranchCleanup() {
        let reasons: [(CleanupBlockReason, WorktreeInfo)] = [
            (.dirtyWorktree, WorktreeInfo(id: "dirty", path: "/tmp/dirty", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: false, stagedCount: 1, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)),
            (.lockedWorktree, WorktreeInfo(id: "locked", path: "/tmp/locked", branch: "feature", head: "abc", isBare: false, isLocked: true, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)),
            (.activeSession, WorktreeInfo(id: "active", path: "/tmp/active", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil, sessions: [SessionRecord(id: "active", provider: .codex, title: "active", updatedAt: nil, cwd: "/tmp/active", branch: "feature", url: nil, activity: .active, evidence: "explicit cwd")])),
            (.unknownSessionActivity, WorktreeInfo(id: "unknown", path: "/tmp/unknown", branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil, sessions: [SessionRecord(id: "unknown", provider: .codex, title: "unknown", updatedAt: nil, cwd: "/tmp/unknown", branch: "feature", url: nil, activity: .unknown, evidence: "explicit cwd")]))
        ]

        for (reason, worktree) in reasons {
            let branch = BranchInfo(id: "feature", name: "feature", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: true, lastCommitAt: nil, worktrees: [worktree])
            let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [branch])
            let preview = CleanupService().previewRemoteGoneBranches(snapshot: snapshot)
            XCTAssertFalse(preview.groups[0].allowed)
            XCTAssertEqual(preview.groups[0].steps.last?.reason, reason)
        }
    }

    func testRemoteGoneWorktreeBecomesDirtyAfterPreviewAndBranchRemains() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 132, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch.withMergeEvidence(.githubVerified(prNumber: 132, mergedAt: mergedAt), github: status).withRemoteGone(true)])
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        try Data("dirty\n".utf8).write(to: worktreePath.appendingPathComponent("dirty.txt"))

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testRemoteGoneBranchSHAChangeAfterPreviewBlocksAllActions() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 133, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch.withMergeEvidence(.githubVerified(prNumber: 133, mergedAt: mergedAt), github: status).withRemoteGone(true)])
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        try Data("changed\n".utf8).write(to: worktreePath.appendingPathComponent("changed.txt"))
        _ = try runGit(["-C", worktreePath.path, "add", "."])
        _ = try runGit(["-C", worktreePath.path, "commit", "-m", "changed"])

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testRemoteGoneGitHubVerificationFailureAfterPreviewLeavesWorktreeAndBranch() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let goodGitHub = GitHubService(runner: verifiedGitHubRunner(number: 134, sha: fixture.featureSHA), executable: "gh")
        let failedGitHub = GitHubService(runner: RoutingRunner { _ in throw ProcessRunnerError.failed("offline") }, executable: "gh")
        let git = GitService()
        let local = try git.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = goodGitHub.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch.withMergeEvidence(.githubVerified(prNumber: 134, mergedAt: mergedAt), github: status).withRemoteGone(true)])
        let preview = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: goodGitHub).previewRemoteGoneBranches(snapshot: snapshot)

        XCTAssertTrue(CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: failedGitHub).execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testRemoteGoneWorktreeRemovalFailureNeverAttemptsBranchDeletion() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 135, sha: fixture.featureSHA), executable: "gh")
        let readWriteGit = GitService()
        let local = try readWriteGit.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let remoteGoneBranch = branch.withMergeEvidence(.githubVerified(prNumber: 135, mergedAt: mergedAt), github: status).withRemoteGone(true)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [remoteGoneBranch])
        let failingRunner = FailingWorktreeRemovalRunner()
        let cleanup = CleanupService(git: GitService(runner: failingRunner), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue(failingRunner.arguments.contains { $0.contains("worktree") && $0.contains("remove") })
        XCTAssertFalse(failingRunner.arguments.contains { $0.contains("branch") && $0.contains("-d") })
        XCTAssertFalse(failingRunner.arguments.contains { $0.contains("update-ref") && $0.contains("-d") })
        XCTAssertTrue((try readWriteGit.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testRemoteGoneBranchDeletionBlockedWhenAnotherWorktreeAppearsAfterRemoval() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        let replacementPath = fixture.root.appendingPathComponent("replacement-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 136, sha: fixture.featureSHA), executable: "gh")
        let readWriteGit = GitService()
        let local = try readWriteGit.snapshot(repositoryPath: fixture.repository.path)
        let branch = try XCTUnwrap(local.branches.first { $0.name == "feature" })
        let status = github.status(repositoryPath: fixture.repository.path, branch: "feature")
        let mergedAt = try XCTUnwrap(status.pullRequests.first?.mergedAt)
        let snapshot = RepositorySnapshot(path: fixture.repository.path, defaultBranch: "main", branches: [branch.withMergeEvidence(.githubVerified(prNumber: 136, mergedAt: mergedAt), github: status).withRemoteGone(true)])
        let runner = AddingWorktreeAfterRemovalRunner(repositoryPath: fixture.repository.path, replacementPath: replacementPath.path)
        let cleanup = CleanupService(git: GitService(runner: runner), sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)

        let preview = cleanup.previewRemoteGoneBranches(snapshot: snapshot)
        let plannedPath = try XCTUnwrap(preview.groups.first?.steps.first(where: { $0.step == .removeWorktree })?.target)
        let result = cleanup.execute(preview)
        XCTAssertEqual(result.removedWorktreePaths, [plannedPath])
        XCTAssertTrue(result.deletedLocalBranches.isEmpty)
        XCTAssertTrue((try readWriteGit.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementPath.path))
        XCTAssertTrue(runner.arguments.contains { $0.contains("branch") && $0.contains("-d") } == false)
    }

    func testRemoteGoneDefaultBranchRemainsBlocked() {
        let worktree = WorktreeInfo(id: "main-wt", path: "/tmp/main-wt", branch: "main", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        let branch = BranchInfo(id: "main", name: "main", sha: "abc", upstream: nil, ahead: 0, behind: 0, isMerged: true, remoteGone: true, lastCommitAt: nil, isDefaultBranch: true, worktrees: [worktree])
        let preview = CleanupService().previewRemoteGoneBranches(snapshot: RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [branch]))

        XCTAssertFalse(preview.groups[0].allowed)
        XCTAssertEqual(preview.groups[0].steps.last?.reason, .defaultBranch)
    }

    func testGitHubVerifiedCleanWorktreeCanBeRemovedAfterFinalRevalidation() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 127, sha: fixture.featureSHA), executable: "gh")
        let recorder = RecordingRunner()
        let git = GitService(runner: recorder)
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let scanner = RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let enriched = await scanner.enrichGitHub(local: local)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let actualPath = try XCTUnwrap(enriched.branches.flatMap(\.worktrees).first { $0.branch == "feature" }?.path)
        let preview = cleanup.previewRemoveWorktree(snapshot: enriched, path: actualPath)
        XCTAssertTrue(preview.items[0].allowed)
        XCTAssertEqual(preview.items[0].expectedSHA, fixture.featureSHA)
        let beforeCleanup = recorder.arguments.count
        XCTAssertEqual(cleanup.execute(preview).removedWorktreePaths, [actualPath])
        XCTAssertEqual(recorder.arguments.count - beforeCleanup, 13, "safe worktree removal process count")
        print("CLEANUP_GIT_SUBPROCESS safe_worktree=\(recorder.arguments.count - beforeCleanup)")
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.flatMap(\.worktrees).contains { $0.path == actualPath })
    }

    func testGitHubVerifiedStaleWorktreeCanBeRemovedAfterFinalRevalidation() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 128, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let scanner = RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let enriched = await scanner.enrichGitHub(local: local)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let actualPath = try XCTUnwrap(enriched.branches.flatMap(\.worktrees).first { $0.branch == "feature" }?.path)
        let preview = cleanup.previewStaleWorktrees(snapshot: enriched, staleDays: 0)
        XCTAssertTrue(preview.items.contains { $0.target == actualPath && $0.allowed })
        XCTAssertEqual(cleanup.execute(preview).removedWorktreePaths, [actualPath])
    }

    func testGitHubVerifiedWorktreeSHAChangeBlocksFinalRevalidation() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let github = GitHubService(runner: verifiedGitHubRunner(number: 129, sha: fixture.featureSHA), executable: "gh")
        let git = GitService()
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let scanner = RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let enriched = await scanner.enrichGitHub(local: local)
        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: github)
        let actualPath = try XCTUnwrap(enriched.branches.flatMap(\.worktrees).first { $0.branch == "feature" }?.path)
        let actualURL = URL(fileURLWithPath: actualPath)
        let preview = cleanup.previewRemoveWorktree(snapshot: enriched, path: actualPath)
        XCTAssertTrue(preview.items[0].allowed)

        FileManager.default.createFile(atPath: actualURL.appendingPathComponent("later.txt").path, contents: Data("later\n".utf8))
        _ = try runGit(["-C", actualPath, "add", "."])
        _ = try runGit(["-C", actualPath, "commit", "-m", "later"])

        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.flatMap(\.worktrees).contains { $0.path == actualPath })
    }

    func testGitHubFailureBlocksGitHubVerifiedWorktreeExecute() async throws {
        let fixture = try makeFeatureRepository()
        let worktreePath = fixture.root.appendingPathComponent("attached-feature")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try runGit(["-C", fixture.repository.path, "worktree", "add", worktreePath.path, "feature"])
        let goodGitHub = GitHubService(runner: verifiedGitHubRunner(number: 130, sha: fixture.featureSHA), executable: "gh")
        let failedGitHub = GitHubService(runner: RoutingRunner { _ in throw ProcessRunnerError.failed("offline") }, executable: "gh")
        let git = GitService()
        let local = RepositoryLocalScanResult(snapshot: try git.snapshot(repositoryPath: fixture.repository.path), sessionNotes: [])
        let scanner = RepositoryScanService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: goodGitHub)
        let enriched = await scanner.enrichGitHub(local: local)
        let actualPath = try XCTUnwrap(enriched.branches.flatMap(\.worktrees).first { $0.branch == "feature" }?.path)
        let preview = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: goodGitHub).previewRemoveWorktree(snapshot: enriched, path: actualPath)
        XCTAssertTrue(preview.items[0].allowed)

        let cleanup = CleanupService(git: git, sessions: SessionService(home: fixture.root.appendingPathComponent("no-sessions").path), github: failedGitHub)
        XCTAssertTrue(cleanup.execute(preview).isEmpty)
        XCTAssertTrue((try git.snapshot(repositoryPath: fixture.repository.path)).branches.flatMap(\.worktrees).contains { $0.path == actualPath })
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
        let beforeCleanup = recorder.arguments.count
        XCTAssertEqual(cleanup.execute(preview).deletedLocalBranches, ["feature"])
        XCTAssertEqual(recorder.arguments.count - beforeCleanup, 7, "standalone verified branch deletion process count")
        print("CLEANUP_GIT_SUBPROCESS standalone_github_branch=\(recorder.arguments.count - beforeCleanup)")
        XCTAssertTrue(recorder.arguments.contains { $0.suffix(4).elementsEqual(["update-ref", "-d", "refs/heads/feature", fixture.featureSHA]) })
        XCTAssertFalse(recorder.arguments.flatMap { $0 }.contains("-D"))
        XCTAssertFalse((try git.snapshot(repositoryPath: fixture.repository.path)).branches.contains { $0.name == "feature" })
    }

    private func verifiedGitHubRunner(number: Int, sha: String) -> RoutingRunner {
        let mergedAt = "2026-01-01T00:00:00Z"
        let pullRequest = "[{\"number\":\(number),\"title\":\"feature\",\"state\":\"MERGED\",\"isDraft\":false,\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(sha)\",\"mergedAt\":\"\(mergedAt)\",\"url\":\"https://github.com/example/repo/pull/\(number)\"}]"
        let exactPullRequest = "{\"number\":\(number),\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feature\",\"headRefOid\":\"\(sha)\",\"mergedAt\":\"\(mergedAt)\"}"
        return RoutingRunner { arguments in
            if arguments.starts(with: ["pr", "list"]) { return ProcessResult(status: 0, stdout: pullRequest) }
            if arguments.starts(with: ["pr", "view"]) {
                return ProcessResult(status: 0, stdout: arguments.contains("closingIssuesReferences") ? "[]" : exactPullRequest)
            }
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
