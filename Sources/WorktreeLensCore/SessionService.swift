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
}

public extension SessionDiscovering {
    func makeCleanupSafetyCache() -> SessionCleanupSafetyCache? { nil }
}

public protocol SessionCleanupSafetyChecking: Sendable {
    func cachedMetadata() -> [SessionRecord]?
    func freshSessionsForRemoval() -> [SessionRecord]?
}

public struct ProcessActivitySnapshot: Sendable {
    fileprivate let processes: [String]
    fileprivate let isAvailable: Bool

    fileprivate init(processes: [String], isAvailable: Bool) {
        self.processes = processes
        self.isAvailable = isAvailable
    }
}

public protocol SessionActivityProbing: Sendable {
    func snapshot() -> ProcessActivitySnapshot
    func activity(for sessionID: String, provider: SessionProviderKind, snapshot: ProcessActivitySnapshot) -> (SessionActivity, String)
}

public extension SessionActivityProbing {
    func activity(for sessionID: String, provider: SessionProviderKind) -> (SessionActivity, String) {
        activity(for: sessionID, provider: provider, snapshot: snapshot())
    }
}

public struct ProcessActivityProbe: SessionActivityProbing {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = LocalProcessRunner()) { self.runner = runner }

    public func snapshot() -> ProcessActivitySnapshot {
        guard let result = try? runner.run("/bin/ps", arguments: ["-axo", "pid=,command="], currentDirectory: nil), result.succeeded else {
            return ProcessActivitySnapshot(processes: [], isAvailable: false)
        }
        return ProcessActivitySnapshot(processes: result.stdout.split(whereSeparator: \.isNewline).map(String.init), isAvailable: true)
    }

    public func activity(for sessionID: String, provider: SessionProviderKind, snapshot: ProcessActivitySnapshot) -> (SessionActivity, String) {
        guard snapshot.isAvailable else {
            return (.unknown, "process scan unavailable")
        }
        if snapshot.processes.contains(where: { containsExactToken(sessionID, in: $0) }) {
            return (.active, "running process contains exact session ID")
        }
        let appName = provider == .codex ? "Codex" : "ChatGPT"
        let appRunning = snapshot.processes.contains { line in
            let lower = line.lowercased()
            return lower.contains("/\(appName.lowercased()).app/") || lower.contains("\(appName.lowercased()) desktop")
        }
        return appRunning ? (.unknown, "provider process running; session ID not exposed") : (.inactive, "provider process not running")
    }

    private func containsExactToken(_ token: String, in line: String) -> Bool {
        line.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public protocol SessionProvider: Sendable {
    var kind: SessionProviderKind { get }
    func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult
    func sourceFingerprint() -> String?
}

public extension SessionProvider {
    func sourceFingerprint() -> String? { nil }

    func discover() -> SessionDiscoveryResult {
        discover(processSnapshot: ProcessActivityProbe().snapshot())
    }
}

public struct CodexSessionProvider: SessionProvider {
    public let kind: SessionProviderKind = .codex
    private let home: String
    private let runner: any ProcessRunning
    private let activityProbe: any SessionActivityProbing

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner(), activityProbe: any SessionActivityProbing = ProcessActivityProbe()) {
        self.home = home
        self.runner = runner
        self.activityProbe = activityProbe
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

    private func makeRecord(id: String, title: String, updatedAt: Date?, cwd: String, branch: String?, source: String, processSnapshot: ProcessActivitySnapshot) -> SessionRecord {
        let state = activityProbe.activity(for: id, provider: .codex, snapshot: processSnapshot)
        return SessionRecord(id: "codex-\(id)", provider: .codex, title: title, updatedAt: updatedAt, cwd: cwd, branch: branch, url: URL(string: "codex://threads/\(id)"), activity: state.0, evidence: "\(source); \(state.1)")
    }

    private func date(seconds: Double?, milliseconds: Double?) -> Date? {
        if let milliseconds { return Date(timeIntervalSince1970: milliseconds / 1000) }
        if let seconds { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        return nil
    }

    private func query(database: String, sql: String) -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
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

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner(), activityProbe: any SessionActivityProbing = ProcessActivityProbe()) {
        self.home = home
        self.activityProbe = activityProbe
        _ = runner // Retain source compatibility; ChatGPT no longer reads SQLite.
    }

    public func discover() -> SessionDiscoveryResult {
        discover(processSnapshot: activityProbe.snapshot())
    }

    public func discover(processSnapshot: ProcessActivitySnapshot) -> SessionDiscoveryResult {
        let result = LegacyJSONAdapter(roots: legacyRoots).read()
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
        let manager = FileManager.default
        var entries: [String] = []
        for root in legacyRoots {
            let roots = [root] + ["Local Storage", "IndexedDB"].map { root.appendingPathComponent($0) }
            for directory in roots {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                    entries.append("missing:\(directory.path)")
                    continue
                }
                guard isDirectory.boolValue, let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
                entries.append("dir:\(directory.path)")
                for file in children where LegacyJSONAdapter.isCandidate(file) {
                    guard let attributes = try? manager.attributesOfItem(atPath: file.path),
                          let size = attributes[.size] as? NSNumber,
                          let modified = attributes[.modificationDate] as? Date else { return nil }
                    entries.append("file:\(file.path):\(size):\(modified.timeIntervalSince1970)")
                }
            }
        }
        return entries.sorted().joined(separator: "\n")
    }

    private var legacyRoots: [URL] {
        let base = URL(fileURLWithPath: home)
        return [
            base.appendingPathComponent("Library/Application Support/com.openai.chat"),
            base.appendingPathComponent("Library/Application Support/ChatGPT"),
            base.appendingPathComponent("Library/Containers/com.openai.chat/Data/Library/Application Support/com.openai.chat")
        ]
    }

    private func makeRecord(_ metadata: ChatGPTSessionMetadata, processSnapshot: ProcessActivitySnapshot) -> SessionRecord {
        let state = activityProbe.activity(for: metadata.id, provider: .chatGPT, snapshot: processSnapshot)
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
        var inspectedFiles = 0
        var skippedFiles = 0
        var totalBytes: Int64 = 0
        for directory in Self.candidateDirectories {
            guard inspectedFiles < Self.maxFiles, totalBytes < Self.maxTotalBytes, sessions.count < Self.maxSessions else { break }
            let directoryURL = directory.isEmpty ? root : root.appendingPathComponent(directory)
            guard let children = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for fileURL in children where Self.candidateFileNames.contains(fileURL.lastPathComponent) {
                guard inspectedFiles < Self.maxFiles, totalBytes < Self.maxTotalBytes, sessions.count < Self.maxSessions else { break }
                inspectedFiles += 1
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                guard size <= Self.maxFileBytes, totalBytes + size <= Self.maxTotalBytes, let data = try? Data(contentsOf: fileURL) else {
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

public final class SessionService: @unchecked Sendable, SessionDiscovering {
    private let providers: [any SessionProvider]
    private let processProbe: ProcessActivityProbe

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner()) {
        let probe = ProcessActivityProbe(runner: runner)
        processProbe = probe
        providers = [CodexSessionProvider(home: home, runner: runner, activityProbe: probe), ChatGPTSessionProvider(home: home, activityProbe: probe)]
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
        SessionCleanupSafetyCache(providers: providers, processProbe: processProbe)
    }

    private func rawThreadID(_ session: SessionRecord) -> String {
        let prefix = session.provider == .codex ? "codex-" : "chatgpt-"
        return session.id.hasPrefix(prefix) ? String(session.id.dropFirst(prefix.count)) : session.id
    }
}

public final class SessionCleanupSafetyCache: SessionCleanupSafetyChecking, @unchecked Sendable {
    private let providers: [any SessionProvider]
    private let processProbe: ProcessActivityProbe
    private var fingerprints: [SessionProviderKind: String] = [:]
    private var metadata: [SessionProviderKind: [SessionRecord]] = [:]
    private var initialized = false

    fileprivate init(providers: [any SessionProvider], processProbe: ProcessActivityProbe) {
        self.providers = providers
        self.processProbe = processProbe
    }

    public func cachedMetadata() -> [SessionRecord]? {
        guard initializeIfNeeded() else { return nil }
        return allMetadata.map { withActivity($0, .inactive, "cached metadata") }
    }

    public func freshSessionsForRemoval() -> [SessionRecord]? {
        guard initializeIfNeeded(), refreshChangedProviders() else { return nil }
        let processSnapshot = processProbe.snapshot()
        let sourceStamps = fingerprints
        var result: [SessionRecord] = []
        for session in allMetadata {
            let activity = processProbe.activity(for: rawID(session), provider: session.provider, snapshot: processSnapshot)
            result.append(SessionRecord(id: session.id, provider: session.provider, title: session.title, updatedAt: session.updatedAt, cwd: session.cwd, branch: session.branch, url: session.url, activity: activity.0, evidence: metadataEvidence(session) + "; " + activity.1))
        }
        // A source change during inspection invalidates this snapshot; the next attempt refreshes it.
        guard providers.allSatisfy({ $0.sourceFingerprint() == sourceStamps[$0.kind] }) else { return nil }
        return result
    }

    private var allMetadata: [SessionRecord] { providers.flatMap { metadata[$0.kind] ?? [] } }

    private func initializeIfNeeded() -> Bool {
        if initialized { return true }
        for provider in providers {
            guard let before = provider.sourceFingerprint() else { return false }
            let found = provider.discover(processSnapshot: ProcessActivitySnapshot(processes: [], isAvailable: false))
            guard let after = provider.sourceFingerprint(), before == after else { return false }
            fingerprints[provider.kind] = after
            metadata[provider.kind] = found.sessions
        }
        initialized = true
        return true
    }

    private func refreshChangedProviders() -> Bool {
        for provider in providers {
            guard let current = provider.sourceFingerprint() else { return false }
            guard current != fingerprints[provider.kind] else { continue }
            let refreshed = provider.discover(processSnapshot: ProcessActivitySnapshot(processes: [], isAvailable: false))
            guard let verified = provider.sourceFingerprint(), verified == current else { return false }
            metadata[provider.kind] = refreshed.sessions
            fingerprints[provider.kind] = verified
        }
        return true
    }

    private func rawID(_ session: SessionRecord) -> String {
        let prefix = session.provider == .codex ? "codex-" : "chatgpt-"
        return session.id.hasPrefix(prefix) ? String(session.id.dropFirst(prefix.count)) : session.id
    }

    private func metadataEvidence(_ session: SessionRecord) -> String {
        session.evidence.components(separatedBy: "; ").filter { $0 != "process scan unavailable" && $0 != "provider process not running" && $0 != "provider process running; session ID not exposed" && $0 != "running process contains exact session ID" }.joined(separator: "; ")
    }

    private func withActivity(_ session: SessionRecord, _ activity: SessionActivity, _ evidence: String) -> SessionRecord {
        SessionRecord(id: session.id, provider: session.provider, title: session.title, updatedAt: session.updatedAt, cwd: session.cwd, branch: session.branch, url: session.url, activity: activity, evidence: metadataEvidence(session) + "; " + evidence)
    }
}

private func fingerprintFiles(_ urls: [URL]) -> String? {
    let manager = FileManager.default
    var entries: [String] = []
    for url in urls {
        guard manager.fileExists(atPath: url.path) else {
            entries.append("missing:\(url.path)")
            continue
        }
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        entries.append("file:\(url.path):\(size):\(modified.timeIntervalSince1970)")
    }
    return entries.joined(separator: "\n")
}
