import Foundation

/// Error messages returned by GitHub may contain submitted query text. Keep them out of diagnostics.
public struct GitHubGraphQLError: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let type: String?
    public let path: [PathComponent]?
    public enum PathComponent: Decodable, Equatable, Sendable {
        case field(String), index(Int)
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) { self = .field(text) }
            else { self = .index(try value.decode(Int.self)) }
        }
    }
    public var description: String { "GitHub GraphQL error" }
    public var debugDescription: String { description }
}
public struct GitHubGraphQLResult<Value: Decodable & Sendable>: Decodable, Sendable {
    public let data: Value?
    public let errors: [GitHubGraphQLError]?
    public var hasErrors: Bool { !(errors?.isEmpty ?? true) }
    public func hasErrors(at alias: String) -> Bool {
        errors?.contains { error in
            guard let first = error.path?.first else { return true }
            return first == .field(alias)
        } ?? false
    }
}

public struct GitHubRequestContext: Hashable, Sendable {
    public let accountIdentifier: String
    public let revision: UUID
    public init(accountIdentifier: String, revision: UUID) {
        self.accountIdentifier = accountIdentifier; self.revision = revision
    }
}

public struct GitHubAPIClient: Sendable {
    private struct Payload<V: Encodable>: Encodable { let query: String; let variables: V }
    private let authentication: any GitHubAuthenticationProviding
    private let http: GitHubHTTPClient
    public let stateStore: GitHubStateStore
    public init(authentication: any GitHubAuthenticationProviding, http: GitHubHTTPClient = GitHubHTTPClient(),
                stateStore: GitHubStateStore = .shared) {
        self.authentication = authentication; self.http = http; self.stateStore = stateStore
    }
    public func accountIdentifier() async throws -> String {
        try await requestContext().accountIdentifier
    }
    public func requestContext() async throws -> GitHubRequestContext {
        let authorization = try await authentication.authorization()
        return GitHubRequestContext(accountIdentifier: identifier(for: authorization), revision: authorization.revision)
    }
    public func currentUser() async throws -> GitHubAccount { try await get(path: "/user") }
    public func get<Value: Decodable & Sendable>(path: String, deadline: Date? = nil,
                                                 context: GitHubRequestContext? = nil) async throws -> Value {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: "https://api.github.com" + path), url.host == "api.github.com" else {
            throw GitHubAPIError.unsupportedURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        let response = try await send(request, retryRead: true, deadline: deadline, context: context)
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw GitHubAPIError.invalidResponse }
    }
    public func graphQL<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        query: String, variables: Variables, deadline: Date? = nil, context: GitHubRequestContext? = nil,
        shareInFlight: Bool = true
    ) async throws -> GitHubGraphQLResult<Value> {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(query: query, variables: variables))
        let response = try await send(request, retryRead: false, deadline: deadline, context: context,
                                      shareInFlight: shareInFlight)
        do {
            let result = try JSONDecoder().decode(GitHubGraphQLResult<Value>.self, from: response.data)
            guard result.data != nil || result.hasErrors else { throw GitHubAPIError.invalidResponse }
            return result
        } catch { throw GitHubAPIError.invalidResponse }
    }
    private func send(_ input: URLRequest, retryRead: Bool, deadline: Date?, context: GitHubRequestContext?,
                      shareInFlight: Bool = true) async throws -> GitHubHTTPResponse {
        let initial = try await authentication.authorization()
        let accountIdentifier = identifier(for: initial)
        if let context {
            guard context.accountIdentifier == accountIdentifier, context.revision == initial.revision else { throw CancellationError() }
        }
        var request = input
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let response = try await stateStore.send(request, accountIdentifier: context?.accountIdentifier ?? accountIdentifier,
                                                 sessionRevision: context?.revision ?? initial.revision,
                                                 shareInFlight: shareInFlight) { outbound in
            let (response, authorization) = try await http.sendAuthenticated(outbound, retryRead: retryRead,
                                                                              authentication: authentication, revision: initial.revision, deadline: deadline)
            try Task.checkCancellation()
            guard await authentication.isCurrent(authorization) else { throw CancellationError() }
            if response.status == 401 { try await authentication.invalidate(authorization) }
            return response
        }
        if response.status == 401 { await stateStore.invalidateAccount(accountIdentifier: accountIdentifier) }
        try GitHubHTTPClient.validate(response)
        return response
    }
    private func identifier(for authorization: GitHubAuthorization) -> String {
        authorization.accountIdentifier ?? "session:\(authorization.revision.uuidString)"
    }
}
