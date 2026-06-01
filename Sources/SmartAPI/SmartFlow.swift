import Foundation
#if canImport(SwiftUI)
import SwiftUI
import Observation

// MARK: - SmartFlow

/// Compose dependent fetches into one observable load.
///
///     let flow = SmartFlow<Feed> { ctx in
///         // Independent fetches run in parallel via `async let`.
///         async let user = ctx.fetch("user", from: userURL, as: User.Model.self)
///         async let stats = ctx.fetch("stats", from: statsURL, as: Stats.self)
///         let u = try await user
///         let s = try await stats
///         // Dependent fetch (needs `u`) runs after.
///         let posts = try await ctx.fetch(
///             "posts",
///             from: postsURL(for: u.id),
///             as: [Post.Model].self
///         )
///         return Feed(user: u, stats: s, posts: posts)
///     }
///
/// The flow exposes `state: LoadState<Output>` *and* per-step progress, so
/// the UI can show "user ✓, stats ⟳, posts ⌛" if you want progressive
/// loading. Conforms to `SmartLoaderProtocol`, so it slots into `SmartView`.
@MainActor
@Observable
public final class SmartFlow<Output: Sendable>: SmartLoaderProtocol {

    public var state: LoadState<Output> = .idle

    /// Per-step state, keyed by the name the user passed to `ctx.fetch(...)`
    /// or `ctx.step(...)`. Useful for showing a per-row spinner.
    public private(set) var steps: [String: SmartFlowStepState] = [:]

    private let build: @Sendable (SmartFlowContext) async throws -> Output

    public init(_ build: @escaping @Sendable (SmartFlowContext) async throws -> Output) {
        self.build = build
    }

    public func load() async {
        state = .loading
        steps = [:]
        // Capture `self` weakly once in the outer closure. The inner Task
        // closure inherits that weak binding — no second `[weak self]` needed.
        let context = SmartFlowContext(onStep: { [weak self] name, progress in
            Task { @MainActor in
                self?.steps[name] = progress
            }
        })
        do {
            let result = try await build(context)
            state = .loaded(result)
        } catch {
            state = .failed(error)
        }
    }
}

// MARK: - Context handed to the flow closure

/// Handle that the build closure uses to declare named steps. Each step's
/// progress is reported back to the owning `SmartFlow` for observation.
///
/// The context is intentionally decoupled from any concrete HTTP client:
/// `fetch(_:from:as:using:)` accepts any `SmartFetching`, so tests can pass
/// an in-memory mock and production code can pass a configured `SmartClient`.
public struct SmartFlowContext: Sendable {
    fileprivate let onStep: @Sendable (String, SmartFlowStepState) -> Void

    /// Fetch a Decodable response (GET) and report progress for it.
    public func fetch<Value: Decodable & Sendable>(
        _ name: String,
        from url: URL,
        as type: Value.Type = Value.self,
        using fetcher: any SmartFetching = SmartClient.shared
    ) async throws -> Value {
        try await step(name) {
            try await fetcher.fetch(Value.self, from: url)
        }
    }

    /// Fetch via a fully-described `SmartQuery` — supports POST search,
    /// GraphQL, signed query params, custom headers, etc.
    public func fetch<Value: Decodable & Sendable>(
        _ name: String,
        via query: SmartQuery,
        as type: Value.Type = Value.self,
        using fetcher: any SmartFetching = SmartClient.shared
    ) async throws -> Value {
        try await step(name) {
            try await fetcher.fetch(Value.self, via: query)
        }
    }

    /// Call a `SmartEndpoint` from the catalog — applies path-template
    /// substitution, auth, and retry. The recommended way to chain
    /// dependent calls inside a `SmartFlow`.
    public func call<Response>(
        _ name: String,
        endpoint: SmartEndpoint<Response>,
        pathParams: [String: String] = [:],
        queryParams: [URLQueryItem] = [],
        headers: [String: String] = [:],
        using client: SmartClient = .shared
    ) async throws -> Response {
        try await step(name) {
            try await client.call(
                endpoint,
                pathParams: pathParams,
                queryParams: queryParams,
                headers: headers
            )
        }
    }

    /// Endpoint call with a typed Encodable body.
    public func call<Response, Body: Encodable & Sendable>(
        _ name: String,
        endpoint: SmartEndpoint<Response>,
        pathParams: [String: String] = [:],
        queryParams: [URLQueryItem] = [],
        body: Body,
        headers: [String: String] = [:],
        using client: SmartClient = .shared
    ) async throws -> Response {
        try await step(name) {
            try await client.call(
                endpoint,
                pathParams: pathParams,
                queryParams: queryParams,
                body: body,
                headers: headers
            )
        }
    }

    /// General-purpose named step. Use this for non-HTTP work, mocked
    /// dependencies in tests, or anything else you want to track progress on.
    public func step<Value: Sendable>(
        _ name: String,
        _ body: () async throws -> Value
    ) async throws -> Value {
        onStep(name, .running)
        do {
            let value = try await body()
            onStep(name, .completed)
            return value
        } catch {
            onStep(name, .failed)
            throw error
        }
    }
}

public enum SmartFlowStepState: Sendable, Equatable {
    case running
    case completed
    case failed
}
#endif
