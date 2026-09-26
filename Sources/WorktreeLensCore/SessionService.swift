import Foundation

public struct SessionDiscoveryResult: Sendable {
    public let sessions: [SessionRecord]
    public let notes: [String]

    public init(sessions: [SessionRecord], notes: [String]) {
        self.sessions = sessions
        self.notes = notes
    }
}

public protocol SessionDiscovering: Sendable {
    func discover() -> SessionDiscoveryResult
    func makeCleanupSafetyCache() -> SessionCleanupSafetyCache?
    /// Current working directory of every readable process, or nil when it cannot be determined.
    func processWorkingDirectories() -> [String]?
}

public extension SessionDiscovering {
    func makeCleanupSafetyCache() -> SessionCleanupSafetyCache? { nil }
    func processWorkingDirectories() -> [String]? { nil }
}

public protocol SessionCleanupSafetyChecking: Sendable {
    func cachedMetadata() -> [SessionRecord]?
    func freshSessionsForRemoval() -> [SessionRecord]?
}

public struct SessionDiscoveryMetricSnapshot: Equatable, Sendable {
    public let processScans: Int
    public let codexSQLiteQueries: Int
    public let chatGPTMetadataScans: Int
    public let chatGPTDirectoryEnumerations: Int
    public let chatGPTFileReads: Int
    public let claudeFileReads: Int
    public let fileAttributeChecks: Int
    public let providerFingerprintCalls: Int

    public var totalOperations: Int {
        processScans + codexSQLiteQueries + chatGPTMetadataScans + chatGPTDirectoryEnumerations + chatGPTFileReads + claudeFileReads + fileAttributeChecks + providerFingerprintCalls
    }
}

public final class SessionDiscoveryMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var processScans = 0
    private var codexSQLiteQueries = 0
    private var chatGPTMetadataScans = 0
    private var chatGPTDirectoryEnumerations = 0
    private var chatGPTFileReads = 0
    private var claudeFileReads = 0
    private var fileAttributeChecks = 0
    private var providerFingerprintCalls = 0

    public init() {}

    public func snapshot() -> SessionDiscoveryMetricSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SessionDiscoveryMetricSnapshot(processScans: processScans, codexSQLiteQueries: codexSQLiteQueries, chatGPTMetadataScans: chatGPTMetadataScans, chatGPTDirectoryEnumerations: chatGPTDirectoryEnumerations, chatGPTFileReads: chatGPTFileReads, claudeFileReads: claudeFileReads, fileAttributeChecks: fileAttributeChecks, providerFingerprintCalls: providerFingerprintCalls)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        processScans = 0; codexSQLiteQueries = 0; chatGPTMetadataScans = 0; chatGPTDirectoryEnumerations = 0; chatGPTFileReads = 0; claudeFileReads = 0; fileAttributeChecks = 0; providerFingerprintCalls = 0
    }

    fileprivate func recordProcessScan() { lock.lock(); processScans += 1; lock.unlock() }
    fileprivate func recordSQLiteQuery() { lock.lock(); codexSQLiteQueries += 1; lock.unlock() }
    fileprivate func recordMetadataScan() { lock.lock(); chatGPTMetadataScans += 1; lock.unlock() }
    fileprivate func recordDirectoryEnumeration() { lock.lock(); chatGPTDirectoryEnumerations += 1; lock.unlock() }
    fileprivate func recordFileRead() { lock.lock(); chatGPTFileReads += 1; lock.unlock() }
    fileprivate func recordClaudeFileRead() { lock.lock(); claudeFileReads += 1; lock.unlock() }
    fileprivate func recordAttributeCheck() { lock.lock(); fileAttributeChecks += 1; lock.unlock() }
    fileprivate func recordProviderFingerprint() { lock.lock(); providerFingerprintCalls += 1; lock.unlock() }
}

public final class SessionSourceFingerprintCache: @unchecked Sendable {
    private struct DirectoryEntry {
        let stamp: String
        let candidates: [String]
    }
    private var directories: [String: DirectoryEntry] = [:]

    fileprivate init() {}

    fileprivate func chatGPTFingerprint(directories paths: [URL], metrics: SessionDiscoveryMetrics) -> String? {
        let manager = FileManager.default
        var fingerprints: [String] = []
        for directory in paths {
            metrics.recordAttributeCheck()
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try manager.attributesOfItem(atPath: directory.path)
            } catch where isMissingFileError(error) {
                directories.removeValue(forKey: directory.path)
                fingerprints.append("missing:\(directory.path)")
                continue
            } catch {
                return nil
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { return nil }
            let stamp = "\(size):\(modified.timeIntervalSince1970):\(attributes[.systemFileNumber] ?? "")"
            let candidates: [String]
            if let cached = directories[directory.path], cached.stamp == stamp {
                candidates = cached.candidates
            } else {
                metrics.recordDirectoryEnumeration()
                guard let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
                candidates = children.filter(LegacyJSONAdapter.isCandidate).map(\.path).sorted()
                directories[directory.path] = DirectoryEntry(stamp: stamp, candidates: candidates)
            }
            fingerprints.append("dir:\(directory.path):\(stamp)")
            for candidate in candidates {
                metrics.recordAttributeCheck()
                guard let fileAttributes = try? manager.attributesOfItem(atPath: candidate),
                      let fileSize = fileAttributes[.size] as? NSNumber,
                      let fileModified = fileAttributes[.modificationDate] as? Date else { return nil }
                fingerprints.append("file:\(candidate):\(fileSize):\(fileModified.timeIntervalSince1970):\(fileAttributes[.systemFileNumber] ?? "")")
            }
        }
        return fingerprints.sorted().joined(separator: "\n")
    }

    fileprivate func claudeFingerprint(history: URL, projects: URL, metrics: SessionDiscoveryMetrics) -> String? {
        var entries: [String] = []
        guard appendFingerprint(history, to: &entries, metrics: metrics) else { return nil }
        metrics.recordAttributeCheck()
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: projects.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
            entries.append("dir:\(projects.path):\(attrs[.modificationDate] as? Date ?? .distantPast):\(attrs[.systemFileNumber] ?? "")")
        } catch where isMissingFileError(error) {
            entries.append("missing:\(projects.path)")
            return entries.joined(separator: "\n")
        } catch { return nil }
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for project in projectDirs.sorted(by: { $0.path < $1.path }).prefix(128) {
            metrics.recordAttributeCheck()
            let attrs: [FileAttributeKey: Any]
            do { attrs = try FileManager.default.attributesOfItem(atPath: project.path) }
            catch where isMissingFileError(error) { continue }
            catch { return nil }
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { continue }
            entries.append("dir:\(project.path):\(attrs[.modificationDate] as? Date ?? .distantPast):\(attrs[.systemFileNumber] ?? "")")
            guard let files = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.path < $1.path }).prefix(256 - min(entries.count, 255)) {
                guard appendFingerprint(file, to: &entries, metrics: metrics) else { return nil }
            }
            if entries.count >= 257 { break }
        }
        return entries.sorted().joined(separator: "\n")
    }

    private func appendFingerprint(_ url: URL, to entries: inout [String], metrics: SessionDiscoveryMetrics) -> Bool {
        metrics.recordAttributeCheck()
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date else { return false }
            entries.append("file:\(url.path):\(size):\(modified.timeIntervalSince1970):\(attrs[.systemFileNumber] ?? "")")
            return true
        } catch where isMissingFileError(error) {
            entries.append("missing:\(url.path)")
            return true
        } catch { return false }
    }
}

public struct ProcessActivitySnapshot: Sendable {
    fileprivate let processes: [String]
    fileprivate let isAvailable: Bool
    /// Lowercased process lines joined by newlines, so each session needs one search instead of one per line.
    fileprivate let loweredProcessBytes: [UInt8]
    /// Exact arguments of each `claude` process line.
    fileprivate let claudeArguments: [Set<String>]
    fileprivate let claudePIDs: [Int?]
    fileprivate let claudeArgumentUnion: Set<String>
    fileprivate let providerAppRunning: Set<SessionProviderKind>
    /// Working directory per PID, or nil when the cwd scan failed.
    fileprivate let processCwds: [Int: String]?

    fileprivate init(processes: [String], isAvailable: Bool, processCwds: [Int: String]? = nil) {
        self.processes = processes
        self.isAvailable = isAvailable
        self.processCwds = processCwds
        let lowered = processes.map { $0.lowercased() }
        loweredProcessBytes = Array(lowered.joined(separator: "\n").utf8)
        let claudeLines = processes.filter(ProcessActivityProbe.isClaudeProcess)
        claudeArguments = claudeLines.map(ProcessActivityProbe.exactArguments)
        claudePIDs = claudeLines.map { $0.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) } }
        claudeArgumentUnion = claudeArguments.reduce(into: Set<String>()) { $0.formUnion($1) }
        var running = Set<SessionProviderKind>()
        for (kind, appName) in [(SessionProviderKind.codex, "codex"), (.chatGPT, "chatgpt")] where lowered.contains(where: { $0.contains("/\(appName).app/") || $0.contains("\(appName) desktop") }) {
            running.insert(kind)
        }
        if !claudeArguments.isEmpty { running.insert(.claude) }
        providerAppRunning = running
    }
}

public protocol SessionActivityProbing: Sendable {
    func snapshot() -> ProcessActivitySnapshot
    func activity(for sessionID: String, provider: SessionProviderKind, cwd: String?, updatedAt: Date?, snapshot: ProcessActivitySnapshot) -> (SessionActivity, String)
}

public extension SessionActivityProbing {
    func activity(for sessionID: String, provider: SessionProviderKind) -> (SessionActivity, String) {
        activity(for: sessionID, provider: provider, snapshot: snapshot())
    }

    func activity(for sessionID: String, provider: SessionProviderKind, snapshot: ProcessActivitySnapshot) -> (SessionActivity, String) {
        activity(for: sessionID, provider: provider, cwd: nil, updatedAt: nil, snapshot: snapshot)
    }
}

enum SessionActivityEvidence {
    static let scanUnavailable = "process scan unavailable"
    static let providerNotRunning = "provider process not running"
    static let sessionIDNotExposed = "provider process running; session ID not exposed"
    static let exactSessionID = "running process contains exact session ID"
    static let noClaudeProcessInDirectory = "provider process running; no claude process in session directory"
    static let idleWithoutProcess = "provider process running; no process in session directory and idle 24h+"

    static let all = [scanUnavailable, providerNotRunning, sessionIDNotExposed, exactSessionID, noClaudeProcessInDirectory, idleWithoutProcess]
}

public struct ProcessActivityProbe: SessionActivityProbing {
    private let runner: any ProcessRunning
    private let metrics: SessionDiscoveryMetrics

    /// A session whose provider app is running but exposes no session ID counts as idle only after this long.
    public static let idleSessionInterval: TimeInterval = 86_400

    private let now: @Sendable () -> Date

    public init(runner: any ProcessRunning = LocalProcessRunner(), metrics: SessionDiscoveryMetrics = SessionDiscoveryMetrics(), now: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.metrics = metrics
        self.now = now
    }

    public func snapshot() -> ProcessActivitySnapshot {
        metrics.recordProcessScan()
        guard let result = try? runner.run("/bin/ps", arguments: ["-axo", "pid=,command="], currentDirectory: nil), result.succeeded else {
            return ProcessActivitySnapshot(processes: [], isAvailable: false)
        }
        return ProcessActivitySnapshot(processes: result.stdout.split(whereSeparator: \.isNewline).map(String.init), isAvailable: true, processCwds: processCwds())
    }

    public func activity(for sessionID: String, provider: SessionProviderKind, cwd: String?, updatedAt: Date?, snapshot: ProcessActivitySnapshot) -> (SessionActivity, String) {
        guard snapshot.isAvailable else {
            return (.unknown, SessionActivityEvidence.scanUnavailable)
        }
        let hasSessionEvidence = provider == .claude ? snapshot.claudeArgumentUnion.contains(sessionID) : containsSessionID(sessionID, in: snapshot)
        if hasSessionEvidence {
            return (.active, SessionActivityEvidence.exactSessionID)
        }
        guard snapshot.providerAppRunning.contains(provider) else { return (.inactive, SessionActivityEvidence.providerNotRunning) }
        if let cwd, let idle = idleEvidence(provider: provider, cwd: cwd, updatedAt: updatedAt, snapshot: snapshot) {
            return (.inactive, idle)
        }
        return (.unknown, SessionActivityEvidence.sessionIDNotExposed)
    }

    /// Resolves "provider running, session ID not exposed" to inactive only on positive cwd evidence; any gap stays unknown.
    private func idleEvidence(provider: SessionProviderKind, cwd: String, updatedAt: Date?, snapshot: ProcessActivitySnapshot) -> String? {
        guard let processCwds = snapshot.processCwds else { return nil }
        let sessionPath = resolvedPath(cwd)
        if provider == .claude {
            // A claude CLI process keeps the directory it was launched in, which is the session's recorded project.
            for pid in snapshot.claudePIDs {
                guard let pid, let processCwd = processCwds[pid] else { return nil }
                if resolvedPath(processCwd) == sessionPath { return nil }
            }
            return SessionActivityEvidence.noClaudeProcessInDirectory
        }
        guard let updatedAt, now().timeIntervalSince(updatedAt) >= Self.idleSessionInterval else { return nil }
        let busy = processCwds.values.contains { processCwd in
            let path = resolvedPath(processCwd)
            return path == sessionPath || path.hasPrefix(sessionPath.hasSuffix("/") ? sessionPath : sessionPath + "/")
        }
        return busy ? nil : SessionActivityEvidence.idleWithoutProcess
    }

    public func workingDirectories() -> [String]? {
        processCwds().map { Array($0.values) }
    }

    private func processCwds() -> [Int: String]? {
        guard let result = try? runner.run("/usr/sbin/lsof", arguments: ["-a", "-d", "cwd", "-Fpn", "-w"], currentDirectory: nil), result.succeeded else { return nil }
        var cwds: [Int: String] = [:]
        var pid: Int?
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p": pid = Int(line.dropFirst())
            case "n": if let pid { cwds[pid] = String(line.dropFirst()) }
            default: break
            }
        }
        return cwds
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    fileprivate func hasUnresolvedClaudeProcess(snapshot: ProcessActivitySnapshot, knownSessionIDs: Set<String>) -> Bool {
        guard snapshot.isAvailable else { return true }
        return snapshot.claudeArguments.contains { knownSessionIDs.isDisjoint(with: $0) }
    }

    private func containsSessionID(_ token: String, in snapshot: ProcessActivitySnapshot) -> Bool {
        guard !token.isEmpty else { return false }
        // Lowercasing matches the case-insensitive search for ASCII IDs; a newline-free token cannot span lines.
        if token.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            let needle = Array(token.lowercased().utf8)
            return snapshot.loweredProcessBytes.withUnsafeBufferPointer { haystack in
                needle.withUnsafeBufferPointer { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
            }
        }
        return snapshot.processes.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    fileprivate static func exactArguments(_ line: String) -> Set<String> {
        var arguments = Set<String>()
        for token in line.split(whereSeparator: \.isWhitespace).dropFirst(2) {
            let argument = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]"))
            arguments.insert(argument)
            // `--resume=<id>` carries the session ID after the equals sign.
            if argument.hasPrefix("-"), let value = argument.split(separator: "=", maxSplits: 1).dropFirst().first {
                arguments.insert(String(value))
            }
        }
        return arguments
    }

    fileprivate static func isClaudeProcess(_ line: String) -> Bool {
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { return false }
        let command = fields[1]
        let firstToken = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        // The executable path may contain spaces (e.g. "Application Support"), so also read up to the first option.
        let beforeOptions = command.components(separatedBy: " -").first ?? ""
        return [firstToken, beforeOptions].contains { candidate in
            let token = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return !token.isEmpty && URL(fileURLWithPath: token).lastPathComponent == "claude"
        }
    }
}

public protocol SessionProvider: Sendable {
    var kind: SessionProviderKind { get }
    func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult
    func sourceFingerprint() -> String?
    func sourceFingerprint(using cache: SessionSourceFingerprintCache, metrics: SessionDiscoveryMetrics) -> String?
}

public extension SessionProvider {
    func sourceFingerprint() -> String? { nil }
    func sourceFingerprint(using cache: SessionSourceFingerprintCache, metrics: SessionDiscoveryMetrics) -> String? { sourceFingerprint() }

    func discover() -> SessionDiscoveryResult {
        discover(processSnapshot: ProcessActivityProbe().snapshot())
    }
}

public struct CodexSessionProvider: SessionProvider {
    public let kind: SessionProviderKind = .codex
    private let home: String
    private let runner: any ProcessRunning
    private let activityProbe: any SessionActivityProbing
    private let metrics: SessionDiscoveryMetrics

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner(), activityProbe: any SessionActivityProbing = ProcessActivityProbe(), metrics: SessionDiscoveryMetrics = SessionDiscoveryMetrics()) {
        self.home = home
        self.runner = runner
        self.activityProbe = activityProbe
        self.metrics = metrics
    }

    public func discover() -> SessionDiscoveryResult {
        discover(processSnapshot: activityProbe.snapshot())
    }

    public func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult {
        let statePath = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite/state_5.sqlite").path
        let catalogPath = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite/codex-dev.db").path
        var sessions: [String: SessionRecord] = [:]
        var notes: [String] = []
        let threadQuery = "SELECT json_object('id',id,'title',title,'updated_at',updated_at,'updated_at_ms',updated_at_ms,'cwd',cwd,'branch',git_branch) FROM threads WHERE cwd IS NOT NULL;"
        if let rows = query(database: statePath, sql: threadQuery) {
            for row in rows {
                guard let id = row["id"] as? String, let cwd = row["cwd"] as? String else { continue }
                sessions[id] = makeRecord(id: id, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session", updatedAt: date(seconds: row["updated_at"] as? Double, milliseconds: row["updated_at_ms"] as? Double), cwd: cwd, branch: row["branch"] as? String, source: "threads.cwd", processSnapshot: processSnapshot)
            }
            notes.append("Codex: state_5.sqlite threads.cwd 読み取り")
        } else {
            notes.append("Codex: state_5.sqlite 読み取り不可")
        }

        let catalogQuery = "SELECT json_object('id',thread_id,'title',display_title,'updated_at',source_updated_at,'cwd',cwd,'branch',git_branch) FROM local_thread_catalog WHERE cwd IS NOT NULL;"
        if let rows = query(database: catalogPath, sql: catalogQuery) {
            for row in rows {
                guard let id = row["id"] as? String, let cwd = row["cwd"] as? String, sessions[id] == nil else { continue }
                sessions[id] = makeRecord(id: id, title: (row["title"] as? String) ?? "Untitled session", updatedAt: date(seconds: row["updated_at"] as? Double, milliseconds: nil), cwd: cwd, branch: row["branch"] as? String, source: "local_thread_catalog.cwd", processSnapshot: processSnapshot)
            }
            notes.append("Codex: codex-dev.db local_thread_catalog.cwd 読み取り")
        } else {
            notes.append("Codex: codex-dev.db 読み取り不可")
        }

        notes.append("Codex: Active=exact session ID process、Inactive=provider非稼働、他=Unknown")
        return SessionDiscoveryResult(sessions: sessions.values.sorted { $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast }, notes: notes)
    }

    public func sourceFingerprint() -> String? {
        let base = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite")
        return fingerprintFiles([
            base.appendingPathComponent("state_5.sqlite"),
            base.appendingPathComponent("state_5.sqlite-wal"),
            base.appendingPathComponent("codex-dev.db"),
            base.appendingPathComponent("codex-dev.db-wal")
        ])
    }

    public func sourceFingerprint(using cache: SessionSourceFingerprintCache, metrics: SessionDiscoveryMetrics) -> String? {
        let base = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite")
        return fingerprintFiles([
            base.appendingPathComponent("state_5.sqlite"),
            base.appendingPathComponent("state_5.sqlite-wal"),
            base.appendingPathComponent("codex-dev.db"),
            base.appendingPathComponent("codex-dev.db-wal")
        ], metrics: metrics)
    }

    private func makeRecord(id: String, title: String, updatedAt: Date?, cwd: String, branch: String?, source: String, processSnapshot: ProcessActivitySnapshot) -> SessionRecord {
        let state = activityProbe.activity(for: id, provider: .codex, cwd: cwd, updatedAt: updatedAt, snapshot: processSnapshot)
        return SessionRecord(id: "codex-\(id)", provider: .codex, title: title, updatedAt: updatedAt, cwd: cwd, branch: branch, url: URL(string: "codex://threads/\(id)"), activity: state.0, evidence: "\(source); \(state.1)")
    }

    private func date(seconds: Double?, milliseconds: Double?) -> Date? {
        if let milliseconds { return Date(timeIntervalSince1970: milliseconds / 1000) }
        if let seconds { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        return nil
    }

    private func query(database: String, sql: String) -> [[String: Any]]? {
        metrics.recordAttributeCheck()
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        metrics.recordSQLiteQuery()
        guard let result = try? runner.run("/usr/bin/sqlite3", arguments: ["-batch", "-noheader", "file:\(database)?mode=ro", sql], currentDirectory: nil), result.succeeded else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else { return nil }
            return dict
        }
    }
}

public struct ChatGPTSessionProvider: SessionProvider {
    public let kind: SessionProviderKind = .chatGPT
    private let home: String
    private let activityProbe: any SessionActivityProbing
    private let metrics: SessionDiscoveryMetrics

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner(), activityProbe: any SessionActivityProbing = ProcessActivityProbe(), metrics: SessionDiscoveryMetrics = SessionDiscoveryMetrics()) {
        self.home = home
        self.activityProbe = activityProbe
        self.metrics = metrics
        _ = runner // Retain source compatibility; ChatGPT no longer reads SQLite.
    }

    public func discover() -> SessionDiscoveryResult {
        discover(processSnapshot: activityProbe.snapshot())
    }

    public func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult {
        let result = LegacyJSONAdapter(roots: legacyRoots, metrics: metrics).read()
        let records = result.sessions.map { makeRecord($0, processSnapshot: processSnapshot) }
        var notes = result.notes
        if records.isEmpty {
            notes.append("ChatGPT: explicit cwd + session ID metadataなし。ChatGPT由来 session未検出。worktree紐付け不能 → Unknown")
        } else {
            notes.append("ChatGPT: absolute cwd + session ID metadataのみ採用。推測紐付けなし")
        }
        notes.append("ChatGPT: \(URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite/codex-dev.db").path) local_thread_catalog未採用。実機でChatGPT由来を識別するschema/value証拠なし")
        notes.append("ChatGPT: SQLite/IndexedDB/LevelDB未採用。JSON/JSONLのみread-only候補scan。書込み・DB migrationなし")
        var unique: [String: SessionRecord] = [:]
        records.forEach { unique[$0.id] = $0 }
        return SessionDiscoveryResult(sessions: unique.values.sorted { $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast }, notes: notes)
    }

    public func sourceFingerprint() -> String? {
        SessionSourceFingerprintCache().chatGPTFingerprint(directories: legacyDirectories, metrics: metrics)
    }

    public func sourceFingerprint(using cache: SessionSourceFingerprintCache, metrics: SessionDiscoveryMetrics) -> String? {
        cache.chatGPTFingerprint(directories: legacyDirectories, metrics: metrics)
    }

    private var legacyRoots: [URL] {
        let base = URL(fileURLWithPath: home)
        return [
            base.appendingPathComponent("Library/Application Support/com.openai.chat"),
            base.appendingPathComponent("Library/Application Support/ChatGPT"),
            base.appendingPathComponent("Library/Containers/com.openai.chat/Data/Library/Application Support/com.openai.chat")
        ]
    }

    private var legacyDirectories: [URL] {
        legacyRoots.flatMap { root in [root] + ["Local Storage", "IndexedDB"].map { root.appendingPathComponent($0) } }
    }

    private func makeRecord(_ metadata: ChatGPTSessionMetadata, processSnapshot: ProcessActivitySnapshot) -> SessionRecord {
        let state = activityProbe.activity(for: metadata.id, provider: .chatGPT, cwd: metadata.cwd, updatedAt: metadata.updatedAt, snapshot: processSnapshot)
        var evidence = "\(metadata.source); explicit cwd/id"
        if let branch = metadata.branch, !branch.isEmpty { evidence += "; git_branch=\(branch)" }
        evidence += "; \(state.1)"
        return SessionRecord(
            id: "chatgpt-\(metadata.id)",
            provider: .chatGPT,
            title: metadata.title.isEmpty ? "Untitled session" : metadata.title,
            updatedAt: metadata.updatedAt,
            cwd: metadata.cwd,
            branch: metadata.branch,
            url: metadata.url,
            activity: state.0,
            evidence: evidence
        )
    }
}

private struct ChatGPTSessionMetadata: Sendable {
    let id: String
    let title: String
    let updatedAt: Date?
    let cwd: String
    let branch: String?
    let url: URL?
    let source: String
}

private struct ChatGPTAdapterResult: Sendable {
    let sessions: [ChatGPTSessionMetadata]
    let notes: [String]
}

private struct LegacyJSONAdapter {
    let roots: [URL]
    let metrics: SessionDiscoveryMetrics

    private static let candidateDirectories = ["", "Local Storage", "IndexedDB"]
    private static let candidateFileNames: Set<String> = ["session.json", "sessions.json", "conversations.json", "conversations.jsonl", "state.json", "metadata.json"]
    private static let maxFiles = 64
    private static let maxTotalBytes: Int64 = 50_000_000
    private static let maxFileBytes: Int64 = 2_000_000
    private static let maxSessions = 500
    private static let maxDepth = 32

    static func isCandidate(_ url: URL) -> Bool { candidateFileNames.contains(url.lastPathComponent) }

    func read() -> ChatGPTAdapterResult {
        var sessions: [ChatGPTSessionMetadata] = []
        var notes: [String] = []
        for root in roots {
            metrics.recordAttributeCheck()
            guard FileManager.default.fileExists(atPath: root.path) else {
                notes.append("ChatGPT: \(root.path) unavailable")
                continue
            }
            let (inspectedFiles, skippedFiles) = scan(root: root, sessions: &sessions)
            notes.append("ChatGPT: \(root.path) JSON/JSONL candidate scan read-only; files=\(inspectedFiles), skipped=\(skippedFiles)")
        }
        return ChatGPTAdapterResult(sessions: sessions, notes: notes)
    }

    private func scan(root: URL, sessions: inout [ChatGPTSessionMetadata]) -> (Int, Int) {
        metrics.recordMetadataScan()
        var inspectedFiles = 0
        var skippedFiles = 0
        var totalBytes: Int64 = 0
        for directory in Self.candidateDirectories {
            guard inspectedFiles < Self.maxFiles, totalBytes < Self.maxTotalBytes, sessions.count < Self.maxSessions else { break }
            let directoryURL = directory.isEmpty ? root : root.appendingPathComponent(directory)
            metrics.recordDirectoryEnumeration()
            guard let children = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for fileURL in children where Self.candidateFileNames.contains(fileURL.lastPathComponent) {
                guard inspectedFiles < Self.maxFiles, totalBytes < Self.maxTotalBytes, sessions.count < Self.maxSessions else { break }
                inspectedFiles += 1
                metrics.recordAttributeCheck()
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                guard size <= Self.maxFileBytes, totalBytes + size <= Self.maxTotalBytes else {
                    skippedFiles += 1
                    continue
                }
                metrics.recordFileRead()
                guard let data = try? Data(contentsOf: fileURL) else {
                    skippedFiles += 1
                    continue
                }
                totalBytes += size
                guard let object = parseJSON(data, url: fileURL) else {
                    skippedFiles += 1
                    continue
                }
                collect(object, source: fileURL.path, depth: 0, sessions: &sessions)
            }
        }
        return (inspectedFiles, skippedFiles)
    }

    private func parseJSON(_ data: Data, url: URL) -> Any? {
        if url.pathExtension.lowercased() == "jsonl" {
            return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) }
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func collect(_ object: Any, source: String, depth: Int, sessions: inout [ChatGPTSessionMetadata]) {
        guard depth <= Self.maxDepth, sessions.count < Self.maxSessions else { return }
        if let dictionary = object as? [String: Any] {
            let id = firstString(dictionary, keys: ["id", "conversationId", "conversation_id", "threadId", "thread_id"])
            let cwd = firstString(dictionary, keys: ["cwd", "workingDirectory", "worktreePath", "repoPath", "repositoryPath"])
            if let id, let cwd = explicitAbsolutePath(cwd), !id.isEmpty {
                sessions.append(ChatGPTSessionMetadata(id: id, title: firstString(dictionary, keys: ["title", "name"]) ?? "Untitled session", updatedAt: date(dictionary), cwd: cwd, branch: firstString(dictionary, keys: ["branch", "branchName"]), url: URL(string: firstString(dictionary, keys: ["url", "link"]) ?? ""), source: source))
            }
            for value in dictionary.values { collect(value, source: source, depth: depth + 1, sessions: &sessions) }
        } else if let array = object as? [Any] {
            for value in array { collect(value, source: source, depth: depth + 1, sessions: &sessions) }
        }
    }

    private func explicitAbsolutePath(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.first == "/" else { return nil }
        return value
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { dictionary[$0] as? String }.first
    }

    private func date(_ dictionary: [String: Any]) -> Date? {
        for key in ["updatedAt", "updated_at", "modifiedAt", "lastUpdatedAt"] {
            if let value = dictionary[key] as? Double { return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value) }
            if let value = dictionary[key] as? String, let number = Double(value) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
            if let value = dictionary[key] as? String, let date = ISO8601DateFormatter().date(from: value) { return date }
        }
        return nil
    }
}

public struct ClaudeSessionProvider: SessionProvider {
    public let kind: SessionProviderKind = .claude
    private let home: String
    private let activityProbe: any SessionActivityProbing
    private let metrics: SessionDiscoveryMetrics

    public init(home: String = NSHomeDirectory(), activityProbe: any SessionActivityProbing = ProcessActivityProbe(), metrics: SessionDiscoveryMetrics = SessionDiscoveryMetrics()) {
        self.home = home
        self.activityProbe = activityProbe
        self.metrics = metrics
    }

    public func discover() -> SessionDiscoveryResult { discover(processSnapshot: activityProbe.snapshot()) }

    public func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult {
        let history = historyURL
        var historyIDs = Set<String>()
        var records: [String: ClaudeMetadata] = [:]
        var notes: [String] = []
        if let data = boundedData(at: history, limit: 4_000_000, fromEnd: true) {
            metrics.recordClaudeFileRead()
            for row in jsonLines(data) {
                guard let id = row["sessionId"] as? String, !id.isEmpty else { continue }
                guard let cwd = absolutePath(row["project"] as? String) else { continue }
                historyIDs.insert(id)
                let metadata = ClaudeMetadata(id: id, title: (row["display"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session", updatedAt: claudeDate(row["timestamp"]), cwd: cwd, branch: nil, source: "~/.claude/history.jsonl explicit project/sessionId")
                if records[id] == nil || (records[id]?.updatedAt ?? .distantPast) <= (metadata.updatedAt ?? .distantPast) { records[id] = metadata }
            }
            notes.append("Claude: history.jsonl bounded read-only scan")
        } else {
            notes.append("Claude: history.jsonl missing/unreadable")
        }

        let projects = projectsURL
        var inspected = 0
        var bytesRead = 0
        if let projectDirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for project in projectDirs.sorted(by: { $0.path < $1.path }).prefix(128) {
                guard let files = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.path < $1.path }) {
                    guard inspected < 64, bytesRead < 2_000_000 else { break }
                    inspected += 1
                    let limit = min(128_000, 2_000_000 - bytesRead)
                    guard let data = boundedData(at: file, limit: limit, fromEnd: false) else { continue }
                    bytesRead += data.count
                    metrics.recordClaudeFileRead()
                    for row in jsonLines(data) {
                        guard let id = row["sessionId"] as? String, !id.isEmpty, !historyIDs.contains(id), records[id] == nil,
                              let cwd = absolutePath(row["cwd"] as? String) else { continue }
                        records[id] = ClaudeMetadata(id: id, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session", updatedAt: claudeDate(row["timestamp"]), cwd: cwd, branch: row["gitBranch"] as? String, source: "~/.claude/projects/*.jsonl explicit cwd/sessionId")
                    }
                }
                if inspected >= 64 || bytesRead >= 2_000_000 { break }
            }
        }
        notes.append("Claude: projects fallback bounded; files=\(inspected), bytes=\(bytesRead), history-missing sessions only")

        let sessions = records.values.map { metadata -> SessionRecord in
            let state = activityProbe.activity(for: metadata.id, provider: .claude, cwd: metadata.cwd, updatedAt: metadata.updatedAt, snapshot: processSnapshot)
            var evidence = metadata.source
            if let branch = metadata.branch, !branch.isEmpty { evidence += "; explicit gitBranch=\(branch)" }
            return SessionRecord(id: "claude-\(metadata.id)", provider: .claude, title: metadata.title, updatedAt: metadata.updatedAt, cwd: metadata.cwd, branch: metadata.branch, url: nil, activity: state.0, evidence: evidence + "; " + state.1)
        }.sorted { $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast }
        return SessionDiscoveryResult(sessions: sessions, notes: notes + ["Claude: no inferred cwd/branch/time association; no URL scheme"])
    }

    public func sourceFingerprint() -> String? {
        SessionSourceFingerprintCache().claudeFingerprint(history: historyURL, projects: projectsURL, metrics: metrics)
    }

    public func sourceFingerprint(using cache: SessionSourceFingerprintCache, metrics: SessionDiscoveryMetrics) -> String? {
        cache.claudeFingerprint(history: historyURL, projects: projectsURL, metrics: metrics)
    }

    private var historyURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".claude/history.jsonl") }
    private var projectsURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".claude/projects") }

    private func boundedData(at url: URL, limit: Int, fromEnd: Bool) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if fromEnd, let size = try? handle.seekToEnd() {
            try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        }
        return try? handle.read(upToCount: limit)
    }

    private func jsonLines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    private func absolutePath(_ value: String?) -> String? {
        guard let value, value.first == "/" else { return nil }
        return value
    }

    private func claudeDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        if let string = value as? String {
            if let number = Double(string) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}

private struct ClaudeMetadata {
    let id: String
    let title: String
    let updatedAt: Date?
    let cwd: String
    let branch: String?
    let source: String
}

public final class SessionService: @unchecked Sendable, SessionDiscovering {
    private let providers: [any SessionProvider]
    private let processProbe: ProcessActivityProbe
    public let metrics: SessionDiscoveryMetrics

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner(), metrics: SessionDiscoveryMetrics = SessionDiscoveryMetrics()) {
        self.metrics = metrics
        let probe = ProcessActivityProbe(runner: runner, metrics: metrics)
        processProbe = probe
        providers = [CodexSessionProvider(home: home, runner: runner, activityProbe: probe, metrics: metrics), ChatGPTSessionProvider(home: home, activityProbe: probe, metrics: metrics), ClaudeSessionProvider(home: home, activityProbe: probe, metrics: metrics)]
    }

    public func discover() -> SessionDiscoveryResult {
        let processSnapshot = processProbe.snapshot()
        var seenThreadIDs = Set<String>()
        return providers.reduce(into: SessionDiscoveryResult(sessions: [], notes: [])) { result, provider in
            let next = provider.discover(processSnapshot: processSnapshot)
            let unique = next.sessions.filter { seenThreadIDs.insert(rawThreadID($0)).inserted }
            result = SessionDiscoveryResult(sessions: result.sessions + unique, notes: result.notes + next.notes)
        }
    }

    public func makeCleanupSafetyCache() -> SessionCleanupSafetyCache? {
        SessionCleanupSafetyCache(providers: providers, processProbe: processProbe, metrics: metrics)
    }

    public func processWorkingDirectories() -> [String]? {
        processProbe.workingDirectories()
    }

    private func rawThreadID(_ session: SessionRecord) -> String {
        let prefix = providerPrefix(session.provider)
        return session.id.hasPrefix(prefix) ? String(session.id.dropFirst(prefix.count)) : session.id
    }
}

public final class SessionCleanupSafetyCache: SessionCleanupSafetyChecking, @unchecked Sendable {
    private let providers: [any SessionProvider]
    private let processProbe: ProcessActivityProbe
    private var fingerprints: [SessionProviderKind: String] = [:]
    private var metadata: [SessionProviderKind: [SessionRecord]] = [:]
    private var initialized = false
    private let metrics: SessionDiscoveryMetrics
    private let fingerprintCache = SessionSourceFingerprintCache()

    fileprivate init(providers: [any SessionProvider], processProbe: ProcessActivityProbe, metrics: SessionDiscoveryMetrics) {
        self.providers = providers
        self.processProbe = processProbe
        self.metrics = metrics
    }

    public func cachedMetadata() -> [SessionRecord]? {
        guard initializeIfNeeded() else { return nil }
        return allMetadata.map { withActivity($0, .inactive, "cached metadata") }
    }

    public func freshSessionsForRemoval() -> [SessionRecord]? {
        guard initializeIfNeeded(), refreshChangedProviders() else { return nil }
        let processSnapshot = processProbe.snapshot()
        let knownClaudeSessionIDs = Set((metadata[.claude] ?? []).map(rawID))
        guard !processProbe.hasUnresolvedClaudeProcess(snapshot: processSnapshot, knownSessionIDs: knownClaudeSessionIDs) else { return nil }
        let sourceStamps = fingerprints
        var result: [SessionRecord] = []
        for session in allMetadata {
            let activity = processProbe.activity(for: rawID(session), provider: session.provider, cwd: session.cwd, updatedAt: session.updatedAt, snapshot: processSnapshot)
            result.append(SessionRecord(id: session.id, provider: session.provider, title: session.title, updatedAt: session.updatedAt, cwd: session.cwd, branch: session.branch, url: session.url, activity: activity.0, evidence: metadataEvidence(session) + "; " + activity.1))
        }
        // A source change during inspection invalidates this snapshot; the next attempt refreshes it.
        guard providers.allSatisfy({ sourceFingerprint($0) == sourceStamps[$0.kind] }) else { return nil }
        return result
    }

    private var allMetadata: [SessionRecord] { providers.flatMap { metadata[$0.kind] ?? [] } }

    private func initializeIfNeeded() -> Bool {
        if initialized { return true }
        for provider in providers {
            guard let before = sourceFingerprint(provider) else { return false }
            let found = provider.discover(processSnapshot: ProcessActivitySnapshot(processes: [], isAvailable: false))
            guard let after = sourceFingerprint(provider), before == after else { return false }
            fingerprints[provider.kind] = after
            metadata[provider.kind] = found.sessions
        }
        initialized = true
        return true
    }

    private func refreshChangedProviders() -> Bool {
        for provider in providers {
            guard let current = sourceFingerprint(provider) else { return false }
            guard current != fingerprints[provider.kind] else { continue }
            let refreshed = provider.discover(processSnapshot: ProcessActivitySnapshot(processes: [], isAvailable: false))
            guard let verified = sourceFingerprint(provider), verified == current else { return false }
            metadata[provider.kind] = refreshed.sessions
            fingerprints[provider.kind] = verified
        }
        return true
    }

    private func rawID(_ session: SessionRecord) -> String {
        let prefix = providerPrefix(session.provider)
        return session.id.hasPrefix(prefix) ? String(session.id.dropFirst(prefix.count)) : session.id
    }

    private func sourceFingerprint(_ provider: any SessionProvider) -> String? {
        metrics.recordProviderFingerprint()
        return provider.sourceFingerprint(using: fingerprintCache, metrics: metrics)
    }

    private func metadataEvidence(_ session: SessionRecord) -> String {
        session.evidence.components(separatedBy: "; ").filter { !SessionActivityEvidence.all.contains($0) }.joined(separator: "; ")
    }

    private func withActivity(_ session: SessionRecord, _ activity: SessionActivity, _ evidence: String) -> SessionRecord {
        SessionRecord(id: session.id, provider: session.provider, title: session.title, updatedAt: session.updatedAt, cwd: session.cwd, branch: session.branch, url: session.url, activity: activity, evidence: metadataEvidence(session) + "; " + evidence)
    }
}

private func providerPrefix(_ provider: SessionProviderKind) -> String {
    switch provider {
    case .codex: return "codex-"
    case .chatGPT: return "chatgpt-"
    case .claude: return "claude-"
    }
}

private func fingerprintFiles(_ urls: [URL], metrics: SessionDiscoveryMetrics? = nil) -> String? {
    let manager = FileManager.default
    var entries: [String] = []
    for url in urls {
        metrics?.recordAttributeCheck()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch where isMissingFileError(error) {
            entries.append("missing:\(url.path)")
            continue
        } catch {
            return nil
        }
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        entries.append("file:\(url.path):\(size):\(modified.timeIntervalSince1970):\(attributes[.systemFileNumber] ?? "")")
    }
    return entries.joined(separator: "\n")
}

private func isMissingFileError(_ error: Error) -> Bool {
    let code = (error as NSError).code
    return code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError
}
