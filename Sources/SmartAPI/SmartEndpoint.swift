import Foundation

// MARK: - SmartEndpoint

/// Typed description of one API endpoint: path template, HTTP method, and
/// whether it needs auth. Lets a project keep every endpoint in one
/// catalog and call any of them through `SmartClient.call(...)` without
/// rewriting URL plumbing per call site.
///
///     enum API {
///         static let base = URL(string: "https://api.example.com")!
///
///         static let listPosts  = SmartEndpoint<[Post.Model]>(path: "/posts")
///         static let getPost    = SmartEndpoint<Post.Model>(path: "/posts/{id}")
///         static let createPost = SmartEndpoint<Post.Model>(
///             path: "/posts", method: .post, requiresAuth: true
///         )
///         static let deletePost = SmartEndpoint<Empty>(
///             path: "/posts/{id}", method: .delete, requiresAuth: true
///         )
///     }
///
///     let posts = try await client.call(API.listPosts)
///     let post  = try await client.call(API.getPost, pathParams: ["id": "42"])
///     let new   = try await client.call(API.createPost, body: draft)
///     try await client.call(API.deletePost, pathParams: ["id": "42"])
public struct SmartEndpoint<Response: Decodable & Sendable>: Sendable {

    /// Path template — `{name}` segments get substituted at call time.
    public let path: String

    public let method: HTTPMethod

    /// When `true`, `SmartClient.call(...)` adds the `Authorization` header
    /// from the client's `AuthorizationProvider` and treats a 401 as a
    /// refresh-and-retry candidate.
    public let requiresAuth: Bool

    /// Optional base URL override for this endpoint. When nil, the client's
    /// `baseURL` is used. Useful for "most of my API is at example.com but
    /// these few hit a different host."
    public let baseURL: URL?

    public init(
        path: String,
        method: HTTPMethod = .get,
        requiresAuth: Bool = false,
        baseURL: URL? = nil
    ) {
        self.path = path
        self.method = method
        self.requiresAuth = requiresAuth
        self.baseURL = baseURL
    }
}

// MARK: - Empty (response placeholder for endpoints with no body)

/// Stand-in for endpoints that return no useful body (`DELETE`, 204).
/// Conforms to `Decodable` so it can flow through the generic call API
/// without a separate code path.
public struct Empty: Codable, Sendable, Equatable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        // Accept any body — we ignore it.
        _ = decoder
    }

    public func encode(to encoder: any Encoder) throws {
        // No-op.
        _ = encoder
    }
}

// MARK: - Endpoint errors

public enum SmartEndpointError: Error, CustomStringConvertible {
    case missingBaseURL
    case missingPathParameter(String)
    case invalidURL(String)

    public var description: String {
        switch self {
        case .missingBaseURL:
            return "SmartEndpoint: no base URL configured. Set `SmartClient.baseURL` or pass `baseURL:` on the endpoint."
        case .missingPathParameter(let name):
            return "SmartEndpoint: path template references `{\(name)}` but no value was supplied in `pathParams:`."
        case .invalidURL(let path):
            return "SmartEndpoint: could not build a URL from path `\(path)`."
        }
    }
}

// MARK: - Path-template substitution

public extension SmartEndpoint {
    /// Substitute `{name}` placeholders in `path` and join with `baseURL`.
    /// Throws if any placeholder is unfilled or if the result isn't a valid URL.
    /// Exposed publicly so callers can inspect the resolved URL — useful
    /// for debug logging and verifying expectations in tests.
    func buildURL(
        baseURL clientBaseURL: URL?,
        pathParams: [String: String],
        queryParams: [URLQueryItem]
    ) throws -> URL {
        guard let base = self.baseURL ?? clientBaseURL else {
            throw SmartEndpointError.missingBaseURL
        }
        let substituted = try substitutePathParams(path, with: pathParams)
        let appended = base.appendingPathComponent(substituted)

        guard var components = URLComponents(url: appended, resolvingAgainstBaseURL: false) else {
            throw SmartEndpointError.invalidURL(substituted)
        }
        if !queryParams.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: queryParams)
            components.queryItems = items
        }
        guard let url = components.url else {
            throw SmartEndpointError.invalidURL(substituted)
        }
        return url
    }

    private func substitutePathParams(
        _ template: String,
        with values: [String: String]
    ) throws -> String {
        var result = template
        // Match `{name}` segments. Iterating with String operations avoids a
        // regex dependency and keeps the rule readable. Values are inserted
        // as-is — `URL.appendingPathComponent` percent-encodes them, so
        // double-encoding (e.g. " " → "%2520") doesn't happen.
        while let openRange = result.range(of: "{"),
              let closeRange = result.range(of: "}", range: openRange.upperBound..<result.endIndex) {
            let nameStart = openRange.upperBound
            let nameEnd = closeRange.lowerBound
            let name = String(result[nameStart..<nameEnd])
            guard let value = values[name] else {
                throw SmartEndpointError.missingPathParameter(name)
            }
            result.replaceSubrange(openRange.lowerBound...closeRange.lowerBound, with: value)
        }
        return result
    }
}
