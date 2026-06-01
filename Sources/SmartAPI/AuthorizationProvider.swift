import Foundation

// MARK: - AuthorizationProvider

/// Pluggable authentication for `SmartClient`. Returns the value to inject
/// into the `Authorization` request header (e.g. `"Bearer <jwt>"`) and
/// handles refresh when the server says the current credential expired.
///
/// `SmartClient` consults the provider on every request. If a request fails
/// with HTTP 401, the client calls `refresh()` once and retries; if the
/// retry also 401s, the original error is surfaced.
///
/// Default: `NoAuthProvider` (no header added). Ship `BearerTokenProvider`
/// for simple Bearer flows, or implement your own for OAuth2 / OIDC.
public protocol AuthorizationProvider: Sendable {
    /// Current header value, or `nil` if no credential is available.
    func currentHeader() async throws -> String?

    /// Refresh the credential (e.g. exchange the refresh token for a new
    /// access token). Return the new header value to use on the retry, or
    /// `nil` if refresh isn't possible — in which case the 401 propagates.
    func refresh() async throws -> String?
}

// MARK: - Defaults

/// No-op provider — the default. SmartClient sends requests without an
/// `Authorization` header.
public struct NoAuthProvider: AuthorizationProvider {
    public init() {}
    public func currentHeader() async throws -> String? { nil }
    public func refresh() async throws -> String? { nil }
}

/// Bearer-token provider. Holds an in-memory token plus a closure to refresh
/// it. Production apps with persistent tokens should implement their own
/// provider that reads from Keychain.
///
///     let provider = BearerTokenProvider(initialToken: "...") { /* refresh */
///         try await api.refreshToken()
///     }
///     let client = SmartClient(authorization: provider)
///
/// Concurrent `refresh()` calls are *coalesced*: when two requests both
/// hit 401 at once, only one refresh handler executes; the second caller
/// awaits the same Task. Without this, every burst of expired-token
/// failures would burn a fresh refresh — wasteful for the server and
/// dangerous for refresh tokens with strict reuse policies.
public actor BearerTokenProvider: AuthorizationProvider {

    private var token: String?
    private var inFlightRefresh: Task<String?, any Error>?
    private let refreshHandler: @Sendable () async throws -> String?

    public init(
        initialToken: String? = nil,
        refresh: @escaping @Sendable () async throws -> String?
    ) {
        self.token = initialToken
        self.refreshHandler = refresh
    }

    public func currentHeader() async throws -> String? {
        guard let token else { return nil }
        return "Bearer \(token)"
    }

    public func refresh() async throws -> String? {
        // If a refresh is already running, ride on it rather than
        // launching a second handler call.
        if let existing = inFlightRefresh {
            let newToken = try await existing.value
            return newToken.map { "Bearer \($0)" }
        }

        let handler = refreshHandler
        let task = Task<String?, any Error> { try await handler() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }

        do {
            let newToken = try await task.value
            token = newToken
            return newToken.map { "Bearer \($0)" }
        } catch {
            // On failure, drop the (possibly stale) token so subsequent
            // requests don't pretend they're authenticated.
            token = nil
            throw error
        }
    }
}
