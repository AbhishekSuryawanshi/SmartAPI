// Mode 3: Custom SmartClient — the full production config
// ─────────────────────────────────────────────────────────────────────
// For real apps with real concerns: auth + refresh, retry policy
// tuning, observability, request deduplication, custom decoders,
// per-endpoint retry overrides, audit-log safety.
//
// This is what your `API.swift` looks like once SmartAPI is properly
// adopted: one configured client, a catalog of endpoints, every screen
// reads from it.

import Foundation
import SmartAPI
import os

// MARK: - Models

@SmartAPI(sample: """
{
  "id": 42,
  "name": "Post title",
  "body": "...",
  "author_id": 7,
  "created_at": "2024-01-15T10:30:00Z"
}
""", scope: .parseOnly, cache: true)
enum Post {}

@SmartAPI(sample: """
{
  "id": 7,
  "username": "ada",
  "display_name": "Ada Lovelace"
}
""", scope: .parseOnly)
enum Author {}

// MARK: - Auth provider — wired to your keychain

actor MyKeychainAuth: AuthorizationProvider {
    private var accessToken: String?
    private let refreshToken: String

    init(accessToken: String?, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func currentHeader() async throws -> String? {
        accessToken.map { "Bearer \($0)" }
    }

    func refresh() async throws -> String? {
        // Hit your refresh endpoint. Use a *separate* URLSession so this
        // refresh call doesn't loop through the SmartClient retry/auth flow.
        struct RefreshResponse: Decodable { let access_token: String }
        var request = URLRequest(url: URL(string: "https://api.example.com/auth/refresh")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(RefreshResponse.self, from: data)
        accessToken = response.access_token
        // Persist to Keychain here in real code.
        return "Bearer \(response.access_token)"
    }
}

// MARK: - Observer — wire your analytics SDK

struct ProductionObserver: SmartAPIObserver {

    private let logger = Logger(subsystem: "com.example.MyApp", category: "api")

    func loaderSucceeded(typeName: String, url: URL, latency: TimeInterval) {
        // Analytics.shared.track("api_success", ["type": typeName, "ms": latency * 1000])
        logger.info("\(typeName) loaded in \(latency * 1000, format: .fixed(precision: 1))ms")
    }

    func loaderFailed(typeName: String, url: URL, error: any Error) {
        // Analytics.shared.track("api_failure", ["type": typeName, "error": "\(error)"])
        logger.error("\(typeName) failed: \(error.localizedDescription)")
    }

    func requestRetried(url: URL, method: HTTPMethod, attempt: Int, error: any Error) {
        // Bumps Datadog "api.flakiness" counter — visibility into infra issues.
        logger.warning("retry \(attempt + 1) for \(method.rawValue) \(url)")
    }

    func authRefreshAttempted(url: URL) {
        // Track auth-refresh frequency — sudden spikes mean a token rotation issue.
        logger.info("auth refresh on \(url.path)")
    }

    func lenientDefaultUsed(typeName: String, field: String, reason: LenientReason) {
        // Production gold: see exactly which fields your server stopped
        // honoring before users complain about wrong data.
        logger.warning("\(typeName).\(field) defaulted (\(reason.rawValue))")
    }
}

// MARK: - The configured client

enum API {

    static let client = SmartClient(
        // URLSession with appropriate timeouts for your product.
        session: {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            return URLSession(configuration: config)
        }(),

        defaultHeaders: [
            "Accept": "application/json",
            "X-Client-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ],

        // ISO-8601 dates by default — override if your API uses Unix epoch / custom format.
        defaultDecoder: SmartClient.makeDefaultDecoder(),

        // Custom auth, ready for keychain integration.
        authorization: MyKeychainAuth(
            accessToken: nil,   // load from Keychain in real code
            refreshToken: ""    // load from Keychain in real code
        ),

        baseURL: URL(string: "https://api.example.com/v1")!,

        // 3 attempts on transient failures (5xx + timeouts). POST/PATCH
        // not auto-retried — flip to `.allowsUnsafeRetries` only on
        // endpoints that accept idempotency keys.
        retryPolicy: .standard,

        // Wire to your analytics SDK. Default `SmartAPILogger.shared`
        // routes everything to os.Logger.
        observer: ProductionObserver(),

        // Fold concurrent identical GETs into one network call —
        // critical for SwiftUI screens that mount two copies of the
        // same loader (tabs, splits, previews).
        coalescer: RequestCoalescer()
    )

    // MARK: - Endpoint catalog

    static let getPost     = SmartEndpoint<Post.Model>(path: "/posts/{id}")
    static let listPosts   = SmartEndpoint<[Post.Model]>(path: "/posts")
    static let getAuthor   = SmartEndpoint<Author.Model>(path: "/authors/{id}")

    // Mutations
    static let createPost  = SmartEndpoint<Post.Model>(path: "/posts", method: .post, requiresAuth: true)
    static let updatePost  = SmartEndpoint<Post.Model>(path: "/posts/{id}", method: .patch, requiresAuth: true)
    static let deletePost  = SmartEndpoint<Empty>(path: "/posts/{id}", method: .delete, requiresAuth: true)

    // Safety-critical write — never retry. The override flows to
    // `client.call(_:retryPolicy:)` without affecting the client default.
    static let auditLog    = SmartEndpoint<Empty>(path: "/audit", method: .post, requiresAuth: true)
}

// MARK: - Use them

@MainActor
func customClientModeDemo() async {
    do {
        // Typed read — auth, retry, dedup, cache, observability all flow through.
        let post = try await API.client.call(API.getPost, pathParams: ["id": "42"])
        print(post.name)

        // Typed write with idempotency key (custom header).
        let draft = Post.Model(
            id: 0,
            name: "New post",
            body: "Lorem ipsum",
            authorID: 7,
            createdAt: .now
        )
        let saved = try await API.client.call(API.createPost, body: draft)
        print("Created:", saved.id)

        // Per-call retry override — audit endpoints must NEVER duplicate.
        try await API.client.call(
            API.auditLog,
            body: ["event": "user.viewed_post", "post_id": String(saved.id)],
            retryPolicy: .none
        )

    } catch let error as SmartClientError {
        // Type-safe error handling.
        print("API error:", error)
    } catch {
        print("Unexpected error:", error)
    }
}

// MARK: - Why this mode

// • **Auth + 401 refresh**: drop-in `AuthorizationProvider`. Concurrent
//   refreshes coalesce — no double-burning refresh tokens.
//
// • **Retry safety**: POST/PATCH refused by default. Per-call override
//   for surgical "never retry" endpoints.
//
// • **Observability**: every retry, refresh, lenient default, cache
//   write failure surfaces through one observer. Analytics dashboards
//   stop being a black hole.
//
// • **Request dedup**: two screens mounting the same loader on app
//   launch → one network call. Bandwidth and battery savings.
//
// • **Backward-compatible**: drop in `.allowsUnsafeRetries`, custom
//   decoders, custom URLSession — every dial is configurable.
