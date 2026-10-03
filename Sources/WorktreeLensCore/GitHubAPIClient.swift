import Foundation

/// Error messages returned by GitHub may contain submitted query text. Keep them out of diagnostics.
public struct GitHubGraphQLError: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let type: String?
    public var description: String { "GitHub GraphQL error" }
    public var debugDescription: String { description }
}
public struct GitHubGraphQLResult<Value: Decodable & Sendable>: Decodable, Sendable {
    public let data: Value?
    public let errors: [GitHubGraphQLError]?
    public var hasErrors: Bool { !(errors?.isEmpty ?? true) }
}

public struct GitHubAPIClient: Sendable {
    private struct Payload<V: Encodable>: Encodable { let query: String; let variables: V }
    private let authentication: any GitHubAuthenticationProviding
    private let http: GitHubHTTPClient
    public init(authentication: any GitHubAuthenticationProviding, http: GitHubHTTPClient = GitHubHTTPClient()) {
        self.authentication = authentication; self.http = http
    }
    public func currentUser() async throws -> GitHubAccount { try await get(path: "/user") }
    public func get<Value: Decodable & Sendable>(path: String) async throws -> Value {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: "https://api.github.com" + path), url.host == "api.github.com" else {
            throw GitHubAPIError.unsupportedURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        let response = try await send(request, retryRead: true)
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw GitHubAPIError.invalidResponse }
    }
    public func graphQL<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        query: String, variables: Variables
    ) async throws -> GitHubGraphQLResult<Value> {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(query: query, variables: variables))
        let response = try await send(request, retryRead: false)
        do {
            let result = try JSONDecoder().decode(GitHubGraphQLResult<Value>.self, from: response.data)
            guard result.data != nil || result.hasErrors else { throw GitHubAPIError.invalidResponse }
            return result
        } catch { throw GitHubAPIError.invalidResponse }
    }
    private func send(_ input: URLRequest, retryRead: Bool) async throws -> GitHubHTTPResponse {
        let authorization = try await authentication.authorization()
        var request = input
        request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let response = try await http.send(request, retryRead: retryRead)
        try Task.checkCancellation()
        guard await authentication.isCurrent(authorization) else { throw CancellationError() }
        if response.status == 401 { try await authentication.invalidate(authorization) }
        try GitHubHTTPClient.validate(response)
        return response
    }
}
