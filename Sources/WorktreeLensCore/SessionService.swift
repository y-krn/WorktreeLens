import Foundation

public struct SessionDiscoveryResult: Sendable {
    public let sessions: [SessionRecord]
    public let notes: [String]

    public init(sessions: [SessionRecord], notes: [String]) {
        self.sessions = sessions
        self.notes = notes
    }
}

public protocol SessionActivityProbing: Sendable {
    func activity(for sessionID: String, provider: SessionProviderKind) -> (SessionActivity, String)
}

public struct ProcessActivityProbe: SessionActivityProbing {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = LocalProcessRunner()) { self.runner = runner }

    public func activity(for sessionID: String, provider: SessionProviderKind) -> (SessionActivity, String) {
        guard let result = try? runner.run("/bin/ps", arguments: ["-axo", "pid=,command="], currentDirectory: nil), result.succeeded else {
            return (.unknown, "process scan unavailable")
        }
        let processes = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        if processes.contains(where: { containsExactToken(sessionID, in: $0) }) {
            return (.active, "running process contains exact session ID")
        }
        let appName = provider == .codex ? "Codex" : "ChatGPT"
        let appRunning = processes.contains { line in
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
    func discover() -> SessionDiscoveryResult
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
        let statePath = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite/state_5.sqlite").path
        let catalogPath = URL(fileURLWithPath: home).appendingPathComponent(".codex/sqlite/codex-dev.db").path
        var sessions: [String: SessionRecord] = [:]
        var notes: [String] = []

        let threadQuery = "SELECT json_object('id',id,'title',title,'updated_at',updated_at,'updated_at_ms',updated_at_ms,'cwd',cwd,'branch',git_branch) FROM threads WHERE cwd IS NOT NULL;"
        if let rows = query(database: statePath, sql: threadQuery) {
            for row in rows {
                guard let id = row["id"] as? String, let cwd = row["cwd"] as? String else { continue }
                sessions[id] = makeRecord(id: id, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session", updatedAt: date(seconds: row["updated_at"] as? Double, milliseconds: row["updated_at_ms"] as? Double), cwd: cwd, branch: row["branch"] as? String, source: "threads.cwd")
            }
            notes.append("Codex: state_5.sqlite threads.cwd 読み取り")
        } else {
            notes.append("Codex: state_5.sqlite 読み取り不可")
        }

        let catalogQuery = "SELECT json_object('id',thread_id,'title',display_title,'updated_at',source_updated_at,'cwd',cwd,'branch',git_branch) FROM local_thread_catalog WHERE cwd IS NOT NULL;"
        if let rows = query(database: catalogPath, sql: catalogQuery) {
            for row in rows {
                guard let id = row["id"] as? String, let cwd = row["cwd"] as? String, sessions[id] == nil else { continue }
                sessions[id] = makeRecord(id: id, title: (row["title"] as? String) ?? "Untitled session", updatedAt: date(seconds: row["updated_at"] as? Double, milliseconds: nil), cwd: cwd, branch: row["branch"] as? String, source: "local_thread_catalog.cwd")
            }
            notes.append("Codex: codex-dev.db local_thread_catalog.cwd 読み取り")
        } else {
            notes.append("Codex: codex-dev.db 読み取り不可")
        }

        notes.append("Codex: Active=exact session ID process、Inactive=provider非稼働、他=Unknown")
        return SessionDiscoveryResult(sessions: sessions.values.sorted { $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast }, notes: notes)
    }

    private func makeRecord(id: String, title: String, updatedAt: Date?, cwd: String, branch: String?, source: String) -> SessionRecord {
        let state = activityProbe.activity(for: id, provider: .codex)
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

    public init(home: String = NSHomeDirectory(), activityProbe: any SessionActivityProbing = ProcessActivityProbe()) {
        self.home = home
        self.activityProbe = activityProbe
    }

    public func discover() -> SessionDiscoveryResult {
        let roots = [
            URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/com.openai.chat"),
            URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ChatGPT"),
            URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/com.openai.chat/Data/Library/Application Support/com.openai.chat")
        ]
        var records: [SessionRecord] = []
        var inspected = false
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            inspected = true
            records.append(contentsOf: scanJSON(root: root))
        }
        var notes = [inspected ? "ChatGPT: known local roots read-only scan" : "ChatGPT: known local roots unavailable"]
        if records.isEmpty {
            notes.append("ChatGPT: explicit session metadata未取得 → Unknown")
        } else {
            notes.append("ChatGPT: explicit path/id metadataのみ採用")
        }
        notes.append("ChatGPT: アプリ内部DB・設定書込みなし")
        var unique: [String: SessionRecord] = [:]
        records.forEach { unique[$0.id] = $0 }
        return SessionDiscoveryResult(sessions: Array(unique.values), notes: notes)
    }

    private func scanJSON(root: URL) -> [SessionRecord] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var records: [SessionRecord] = []
        for case let fileURL as URL in enumerator {
            guard ["json", "jsonl"].contains(fileURL.pathExtension.lowercased()), let values = readJSONObjects(fileURL) else { continue }
            for value in values { collect(value, records: &records, source: fileURL.path) }
        }
        return records
    }

    private func readJSONObjects(_ url: URL) -> [[String: Any]]? {
        guard let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), resource.isRegularFile == true, (resource.fileSize ?? 0) <= 10_000_000, let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "jsonl" {
            return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return [object].compactMap { $0 as? [String: Any] }
    }

    private func collect(_ object: Any, records: inout [SessionRecord], source: String) {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] { array.forEach { collect($0, records: &records, source: source) } }
            return
        }
        let id = firstString(dictionary, keys: ["id", "conversationId", "conversation_id", "threadId", "thread_id"])
        let cwd = firstString(dictionary, keys: ["cwd", "workingDirectory", "worktreePath", "repoPath", "repositoryPath"])
        if let id, let cwd {
            let state = activityProbe.activity(for: id, provider: .chatGPT)
            records.append(SessionRecord(id: "chatgpt-\(id)", provider: .chatGPT, title: firstString(dictionary, keys: ["title", "name"]) ?? "Untitled session", updatedAt: date(dictionary), cwd: cwd, branch: firstString(dictionary, keys: ["branch", "branchName"]), url: URL(string: firstString(dictionary, keys: ["url", "link"]) ?? ""), activity: state.0, evidence: "\(source); explicit path/id; \(state.1)"))
        }
        dictionary.values.forEach { collect($0, records: &records, source: source) }
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { dictionary[$0] as? String }.first
    }

    private func date(_ dictionary: [String: Any]) -> Date? {
        if let value = firstString(dictionary, keys: ["updatedAt", "updated_at", "modifiedAt", "lastUpdatedAt"]), let date = ISO8601DateFormatter().date(from: value) { return date }
        for key in ["updatedAt", "updated_at", "modifiedAt", "lastUpdatedAt"] {
            if let value = dictionary[key] as? Double { return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value) }
        }
        return nil
    }
}

public final class SessionService: @unchecked Sendable {
    private let providers: [any SessionProvider]

    public init(home: String = NSHomeDirectory(), runner: any ProcessRunning = LocalProcessRunner()) {
        let probe = ProcessActivityProbe(runner: runner)
        providers = [CodexSessionProvider(home: home, runner: runner, activityProbe: probe), ChatGPTSessionProvider(home: home, activityProbe: probe)]
    }

    public func discover() -> SessionDiscoveryResult {
        providers.reduce(into: SessionDiscoveryResult(sessions: [], notes: [])) { result, provider in
            let next = provider.discover()
            result = SessionDiscoveryResult(sessions: result.sessions + next.sessions, notes: result.notes + next.notes)
        }
    }
}
