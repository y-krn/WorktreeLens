import Foundation
import Security

public struct GitHubAccount: Codable, Equatable, Sendable {
    public let id: Int
    public let login: String
    public init(id: Int, login: String) { self.id = id; self.login = login }
    public var identifier: String { "github.com:\(id)" }
}

public struct GitHubCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let account: GitHubAccount
    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, refreshExpiresAt: Date?, account: GitHubAccount) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.refreshExpiresAt = refreshExpiresAt; self.account = account
    }
    public var description: String { "GitHubCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol GitHubCredentialStore: Sendable {
    func load() throws -> GitHubCredentials?
    func save(_ credentials: GitHubCredentials) throws
    func delete() throws
}

public struct KeychainGitHubCredentialStore: GitHubCredentialStore {
    private let service: String
    public init(clientID: String) { service = "com.ykrn.WorktreeLens.github.com.\(clientID)" }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "active-user", kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    public func load() throws -> GitHubCredentials? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GitHubAuthError.keychain(status) }
        do { return try JSONDecoder().decode(GitHubCredentials.self, from: data) }
        catch { throw GitHubAuthError.invalidResponse }
    }
    public func save(_ credentials: GitHubCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitHubAuthError.keychain(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubAuthError.keychain(status) }
    }
}

public enum GitHubAuthError: Error, Equatable, LocalizedError {
    case missingClientID, busy, denied, expired, reauthenticationRequired, invalidResponse, keychain(Int32), oauthUnknown
    public var errorDescription: String? {
        switch self {
        case .missingClientID: return "Configure a GitHub App client ID."
        case .busy: return "GitHub authentication is already in progress."
        case .denied: return "GitHub authorization was denied."
        case .expired: return "GitHub device code expired. Start sign-in again."
        case .reauthenticationRequired: return "Sign in to GitHub again."
        case .invalidResponse: return "Invalid GitHub authentication response."
        case .keychain(let status): return "GitHub Keychain operation failed (\(status))."
        case .oauthUnknown: return "GitHub authorization failed; the cause is unknown."
        }
    }
}

public struct GitHubDevicePrompt: Equatable, Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
}

public struct GitHubAuthState: Equatable, Sendable {
    public let account: GitHubAccount?
    /// Changes on logout, sign-in and revocation, even for the same account.
    public let revision: UUID
}

public struct GitHubAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let revision: UUID
    public init(token: String, revision: UUID) { self.token = token; self.revision = revision }
    public var description: String { "GitHubAuthorization(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol GitHubAuthenticationProviding: Sendable {
    func authorization() async throws -> GitHubAuthorization
    func invalidate(_ authorization: GitHubAuthorization) async throws
    func isCurrent(_ authorization: GitHubAuthorization) async -> Bool
}

/// Multiple refresh callers share one operation. Each waiter is independently cancellable;
/// when the last waiter leaves, cancellation reaches the operation's URLSession request.
private actor SharedGitHubOperation<Value: Sendable> {
    private var task: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var result: Result<Value, Error>?
    private let operation: @Sendable () async throws -> Value
    init(operation: @escaping @Sendable () async throws -> Value) { self.operation = operation }
    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result); return }
                waiters[id] = continuation
                if task == nil {
                    task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        finish(result)
                    }
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty && result == nil { cancelAll() }
    }
    func isFinished() -> Bool { result != nil }
    func cancelAll() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}

public actor GitHubDeviceFlowProvider: GitHubAuthenticationProviding {
    private let clientID: String
    private let http: GitHubHTTPClient
    private let clock: any GitHubClock
    private let store: any GitHubCredentialStore
    private var credentials: GitHubCredentials?
    private var restored = false
    private var revision = UUID()
    private var signIn: SharedGitHubOperation<GitHubAccount>?
    private var refresh: SharedGitHubOperation<GitHubCredentials>?
    private var observers: [UUID: AsyncStream<GitHubAuthState>.Continuation] = [:]

    public init(clientID: String, http: GitHubHTTPClient = GitHubHTTPClient(),
                clock: any GitHubClock = SystemGitHubClock(), store: (any GitHubCredentialStore)? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http; self.clock = clock
        self.store = store ?? KeychainGitHubCredentialStore(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func state() throws -> GitHubAuthState {
        try restore()
        return GitHubAuthState(account: credentials?.account, revision: revision)
    }
    public func changes() throws -> AsyncStream<GitHubAuthState> {
        try restore()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(GitHubAuthState(account: credentials?.account, revision: revision))
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() {
        let state = GitHubAuthState(account: credentials?.account, revision: revision)
        for observer in observers.values { observer.yield(state) }
    }
    private func restore() throws {
        if !restored { credentials = try store.load(); restored = true }
    }

    public func authenticate(present: @escaping @Sendable (GitHubDevicePrompt) async -> Void) async throws -> GitHubAccount {
        guard !clientID.isEmpty else { throw GitHubAuthError.missingClientID }
        guard signIn == nil, refresh == nil else { throw GitHubAuthError.busy }
        let generation = revision
        let operation = SharedGitHubOperation { try await self.performDeviceFlow(generation: generation, present: present) }
        signIn = operation
        defer { if revision == generation { signIn = nil } }
        return try await operation.value()
    }

    public func logout() async throws {
        let activeSignIn = signIn, activeRefresh = refresh
        revision = UUID(); credentials = nil; restored = true
        signIn = nil; refresh = nil
        publish()
        let deletion = Result { try store.delete() }
        // Invalidate generation before suspending so late responses cannot restore secrets.
        await activeSignIn?.cancelAll()
        await activeRefresh?.cancelAll()
        try deletion.get()
    }

    public func authorization() async throws -> GitHubAuthorization {
        try Task.checkCancellation()
        try restore()
        guard credentials != nil else { throw GitHubAuthError.reauthenticationRequired }
        let startingRevision = revision
        let now = await clock.now()
        try Task.checkCancellation()
        guard startingRevision == revision, let credentials else { throw CancellationError() }
        if let expiry = credentials.expiresAt, expiry <= now.addingTimeInterval(30) {
            guard let refreshToken = credentials.refreshToken,
                  credentials.refreshExpiresAt.map({ $0 > now }) ?? true else {
                try await logout()
                throw GitHubAuthError.reauthenticationRequired
            }
            let generation = revision
            let operation: SharedGitHubOperation<GitHubCredentials>
            if let refresh { operation = refresh }
            else {
                operation = SharedGitHubOperation { try await self.performRefresh(refreshToken, generation: generation) }
                refresh = operation
            }
            do {
                let updated = try await operation.value()
                guard revision == generation else { throw CancellationError() }
                refresh = nil
                try Task.checkCancellation()
                return GitHubAuthorization(token: updated.accessToken, revision: revision)
            } catch {
                if await operation.isFinished(), revision == generation, refresh === operation { refresh = nil }
                throw error
            }
        }
        guard self.credentials?.accessToken == credentials.accessToken else { throw CancellationError() }
        return GitHubAuthorization(token: credentials.accessToken, revision: revision)
    }

    public func isCurrent(_ authorization: GitHubAuthorization) -> Bool {
        revision == authorization.revision && credentials?.accessToken == authorization.token
    }
    public func invalidate(_ authorization: GitHubAuthorization) async throws {
        guard isCurrent(authorization) else { return }
        let now = await clock.now()
        guard isCurrent(authorization) else { return }
        // A token can expire while I/O is in flight. Preserve its usable refresh token;
        // the next authorization will refresh it instead of forcing Device Flow again.
        if let credentials, let expiry = credentials.expiresAt, expiry <= now,
           credentials.refreshToken != nil, credentials.refreshExpiresAt.map({ $0 > now }) ?? true { return }
        try await logout()
    }

    private struct DeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: URL
        let expires_in: Int
        let interval: Int
    }
    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let refresh_token_expires_in: Int?
        let error: String?
    }
    private func oauth<T: Decodable>(_ path: String, fields: [String: String], deadline: Date? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com\(path)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)
        let response = try await http.send(request, deadline: deadline)
        try GitHubHTTPClient.validate(response)
        do { return try JSONDecoder().decode(T.self, from: response.data) }
        catch { throw GitHubAuthError.invalidResponse }
    }
    private func performDeviceFlow(generation: UUID, present: @Sendable (GitHubDevicePrompt) async -> Void) async throws -> GitHubAccount {
        let device: DeviceResponse = try await oauth("/login/device/code", fields: ["client_id": clientID])
        guard device.expires_in > 0, device.expires_in <= 3600, device.interval > 0, device.interval <= 3600,
              !device.device_code.isEmpty, !device.user_code.isEmpty,
              device.verification_uri == URL(string: "https://github.com/login/device") else { throw GitHubAuthError.invalidResponse }
        let deadline = (await clock.now()).addingTimeInterval(Double(device.expires_in))
        try ensureCurrent(generation)
        await present(GitHubDevicePrompt(userCode: device.user_code, verificationURL: device.verification_uri, expiresAt: deadline))
        var interval = Double(device.interval)
        while true {
            try ensureCurrent(generation)
            let remaining = deadline.timeIntervalSince(await clock.now())
            guard remaining > interval else { throw GitHubAuthError.expired }
            try await clock.sleep(seconds: interval)
            try ensureCurrent(generation)
            guard (await clock.now()) < deadline else { throw GitHubAuthError.expired }
            let token: TokenResponse = try await oauth("/login/oauth/access_token", fields: [
                "client_id": clientID, "device_code": device.device_code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ], deadline: deadline)
            let receivedAt = await clock.now()
            try ensureCurrent(generation)
            switch token.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5; continue
            case "access_denied": throw GitHubAuthError.denied
            case "expired_token": throw GitHubAuthError.expired
            case .some: throw GitHubAuthError.oauthUnknown
            case .none: break
            }
            guard (await clock.now()) < deadline else { throw GitHubAuthError.expired }
            guard let accessToken = token.access_token, !accessToken.isEmpty else { throw GitHubAuthError.invalidResponse }
            let account = try await readAccount(token: accessToken)
            try ensureCurrent(generation)
            let saved = try makeCredentials(token, account: account, receivedAt: receivedAt)
            try ensureCurrent(generation)
            try store.save(saved)
            credentials = saved; restored = true
            signIn = nil
            revision = UUID()
            publish()
            return account
        }
    }
    private func performRefresh(_ refreshToken: String, generation: UUID) async throws -> GitHubCredentials {
        let token: TokenResponse = try await oauth("/login/oauth/access_token", fields: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ])
        try ensureCurrent(generation)
        if let error = token.error {
            if ["bad_refresh_token", "expired_token", "invalid_grant"].contains(error) {
                // Do not cancel the shared operation from within itself.
                credentials = nil; revision = UUID(); refresh = nil; publish()
                try store.delete()
                throw GitHubAuthError.reauthenticationRequired
            }
            throw GitHubAuthError.oauthUnknown
        }
        guard let account = credentials?.account else { throw CancellationError() }
        let receivedAt = await clock.now()
        let updated = try makeCredentials(token, account: account, receivedAt: receivedAt)
        try ensureCurrent(generation)
        try store.save(updated)
        credentials = updated
        return updated
    }
    private func makeCredentials(_ token: TokenResponse, account: GitHubAccount, receivedAt: Date) throws -> GitHubCredentials {
        guard let accessToken = token.access_token, !accessToken.isEmpty,
              token.expires_in.map({ $0 > 0 }) ?? true,
              token.refresh_token_expires_in.map({ $0 > 0 }) ?? true,
              token.expires_in == nil || (token.refresh_token?.isEmpty == false && token.refresh_token_expires_in != nil)
        else { throw GitHubAuthError.invalidResponse }
        return GitHubCredentials(accessToken: accessToken, refreshToken: token.refresh_token,
                                 expiresAt: token.expires_in.map { receivedAt.addingTimeInterval(Double($0)) },
                                 refreshExpiresAt: token.refresh_token_expires_in.map { receivedAt.addingTimeInterval(Double($0)) }, account: account)
    }
    private func ensureCurrent(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
    }
    private func readAccount(token: String) async throws -> GitHubAccount {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let response = try await http.send(request, retryRead: true)
        try GitHubHTTPClient.validate(response)
        do { return try JSONDecoder().decode(GitHubAccount.self, from: response.data) }
        catch { throw GitHubAuthError.invalidResponse }
    }
}
