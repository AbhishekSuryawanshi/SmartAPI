import Foundation

/// One side of every HTTP exchange SmartAPI makes: URL + verb + headers +
/// optional body, captured as a `Sendable` value.
///
/// Generated `Loader`s take a `SmartQuery` so they can describe any kind of
/// request — POST for search/login/GraphQL, custom headers per call,
/// signed query parameters, etc. — without growing a wall of init
/// parameters. The simple `init(url:)` convenience on `Loader` wraps
/// `SmartQuery.get(url)` so day-one GET usage stays one line.
///
/// Examples:
///
///     // Search via POST with a typed body
///     let query = try SmartQuery.post(
///         URL(string: "https://api.example.com/search")!,
///         body: SearchRequest(term: "ada", limit: 25)
///     )
///     let loader = SearchResults.Loader(query: query)
///
///     // Authenticated GET with extra headers
///     let query = SmartQuery.get(
///         url,
///         headers: ["X-Idempotency-Key": uuid.uuidString]
///     )
///
///     // GraphQL POST against /graphql
///     let query = try SmartQuery.post(graphqlURL, body: GraphQLBody(query: ..., variables: ...))
public struct SmartQuery: Sendable {

    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    // MARK: - Convenience constructors

    /// Plain GET request — equivalent to passing `url` alone.
    public static func get(
        _ url: URL,
        headers: [String: String] = [:]
    ) -> SmartQuery {
        SmartQuery(url: url, method: .get, headers: headers, body: nil)
    }

    /// POST with a typed Encodable body. The body is encoded eagerly so
    /// every retry uses identical bytes (consistent idempotency keys, etc).
    /// `Content-Type: application/json` is added automatically.
    public static func post<Body: Encodable & Sendable>(
        _ url: URL,
        body: Body,
        headers: [String: String] = [:],
        encoder: JSONEncoder? = nil
    ) throws -> SmartQuery {
        try makeWithJSONBody(url: url, method: .post, body: body, headers: headers, encoder: encoder)
    }

    /// PUT with a typed Encodable body.
    public static func put<Body: Encodable & Sendable>(
        _ url: URL,
        body: Body,
        headers: [String: String] = [:],
        encoder: JSONEncoder? = nil
    ) throws -> SmartQuery {
        try makeWithJSONBody(url: url, method: .put, body: body, headers: headers, encoder: encoder)
    }

    /// PATCH with a typed Encodable body.
    public static func patch<Body: Encodable & Sendable>(
        _ url: URL,
        body: Body,
        headers: [String: String] = [:],
        encoder: JSONEncoder? = nil
    ) throws -> SmartQuery {
        try makeWithJSONBody(url: url, method: .patch, body: body, headers: headers, encoder: encoder)
    }

    /// DELETE — no body.
    public static func delete(
        _ url: URL,
        headers: [String: String] = [:]
    ) -> SmartQuery {
        SmartQuery(url: url, method: .delete, headers: headers, body: nil)
    }

    // MARK: - Query-parameter helpers

    /// Append query items to `self.url`. Returns a new `SmartQuery` because
    /// `SmartQuery` is a value type.
    public func appending(queryItems: [URLQueryItem]) -> SmartQuery {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return self
        }
        var existing = components.queryItems ?? []
        existing.append(contentsOf: queryItems)
        components.queryItems = existing
        let newURL = components.url ?? url
        return SmartQuery(url: newURL, method: method, headers: headers, body: body)
    }

    // MARK: - Internals

    private static func makeWithJSONBody<Body: Encodable & Sendable>(
        url: URL,
        method: HTTPMethod,
        body: Body,
        headers: [String: String],
        encoder: JSONEncoder?
    ) throws -> SmartQuery {
        let actualEncoder = encoder ?? SmartClient.makeDefaultEncoder()
        let data = try actualEncoder.encode(body)
        var headersWithType = headers
        if headersWithType["Content-Type"] == nil {
            headersWithType["Content-Type"] = "application/json"
        }
        return SmartQuery(url: url, method: method, headers: headersWithType, body: data)
    }
}
