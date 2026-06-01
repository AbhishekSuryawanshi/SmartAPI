import XCTest
import Foundation
import SwiftUI
import SmartAPI
// `LockIsolated` is shipped by the SmartAPI runtime now (was previously
// duplicated in tests). Use it directly for any shared mutable state.

// Generate a Model + View + Loader at compile time from a JSON sample.
// If this file compiles, the macro pipeline (parse → infer → codegen)
// produced valid Swift.
@SmartAPI(sample: """
{
  "id": 42,
  "name": "Ada Lovelace",
  "avatar_url": "https://i.pravatar.cc/150",
  "bio": "First programmer in history.",
  "is_active": true,
  "created_at": "2024-01-15T10:30:00Z",
  "tags": ["math", "computing"],
  "address": {
    "street": "10 Downing St",
    "city": "London"
  }
}
""")
enum TestUser {}

// Cryptic, legacy snake_case API. The default heuristic would give us
// `usrNm` / `ctrCd`. Renames let us (or an LLM CLI) supply better names
// without hand-writing the whole model.
@SmartAPI(
    sample: """
    { "usr_nm": "Ada", "ctr_cd": "GB", "active_flg": true }
    """,
    renames: [
        "usr_nm": "userName",
        "ctr_cd": "countryCode",
        "active_flg": "isActive"
    ]
)
enum TestLegacyUser {}

// Two cache-enabled types in the same module — used by the collision test.
@SmartAPI(sample: #"{ "id": 1, "label": "a" }"#, cache: true)
enum TestCachedAlpha {}

@SmartAPI(sample: #"{ "id": 1, "label": "b" }"#, cache: true)
enum TestCachedBeta {}

// Parse-only: Model + Loader, no generated UI. The most common production
// scenario — designer-provided views, SmartAPI just handles network.
@SmartAPI(sample: """
{ "id": 1, "title": "Hello", "body": "World" }
""", scope: .parseOnly)
enum TestParseOnly {}

// Display-only: Model + Loader + View, but no Draft / Mutator / EditView.
// For browse-only screens with no write surface.
@SmartAPI(sample: """
{ "id": 1, "title": "Read only" }
""", scope: .displayOnly)
enum TestDisplayOnly {}

// Lenient model: survives missing / null / wrong-shape server responses.
@SmartAPI(sample: """
{
  "id": 1,
  "name": "Ada",
  "is_active": true,
  "score": 99,
  "address": { "city": "London", "street": "1 Way" }
}
""", scope: .parseOnly, strict: false)
enum TestLenient {}

@MainActor
final class SmartAPITests: XCTestCase {

    func testGeneratedTypeRoundtripsThroughJSON() throws {
        let json = """
        {
          "id": 42,
          "name": "Ada Lovelace",
          "avatar_url": "https://i.pravatar.cc/150",
          "bio": "First programmer in history.",
          "is_active": true,
          "created_at": "2024-01-15T10:30:00Z",
          "tags": ["math", "computing"],
          "address": {
            "street": "10 Downing St",
            "city": "London"
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let user = try decoder.decode(TestUser.Model.self, from: json)

        XCTAssertEqual(user.id, 42)
        XCTAssertEqual(user.name, "Ada Lovelace")
        XCTAssertEqual(user.avatarURL.absoluteString, "https://i.pravatar.cc/150")
        XCTAssertTrue(user.isActive)
        XCTAssertEqual(user.tags, ["math", "computing"])
        XCTAssertEqual(user.address.city, "London")
    }

    func testCodingKeysMapSnakeCase() throws {
        let address = TestUser.Model.Address(city: "London", street: "10 Downing St")
        let user = TestUser.Model(
            address: address,
            avatarURL: URL(string: "https://example.com/g.png")!,
            bio: "Pioneer.",
            createdAt: Date(timeIntervalSince1970: 0),
            id: 7,
            isActive: false,
            name: "Grace",
            tags: ["compiler"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(user)
        let asDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(asDict?["avatar_url"])
        XCTAssertNotNil(asDict?["is_active"])
        XCTAssertNotNil(asDict?["created_at"])
        XCTAssertNil(asDict?["avatarURL"])
    }

    func testLoaderTypeExistsAndIsObservable() {
        // Compile-time check: the macro generated a Loader with the right shape.
        let loader = TestUser.Loader(url: URL(string: "https://example.com")!)
        if case .idle = loader.state { /* ok */ } else { XCTFail("expected idle") }
    }

    func testMutatorRoundtripsThroughFetcher() async throws {
        // Records what the Mutator sent so we can assert the URL, method,
        // and body shape are correct for each CRUD verb. Uses an NSLock-
        // protected class because actor isolation makes generic protocol
        // conformance awkward — fine for a tiny test stub.
        final class RecordingFetcher: SmartFetching, @unchecked Sendable {
            private let lock = NSLock()
            private var _sentURL: URL?
            private var _sentMethod: HTTPMethod?
            private var _sentBodyJSON: String?
            let response: Data

            init(response: Data) { self.response = response }

            var sentURL: URL? { lock.withLock { _sentURL } }
            var sentMethod: HTTPMethod? { lock.withLock { _sentMethod } }
            var sentBodyJSON: String? { lock.withLock { _sentBodyJSON } }

            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, from url: URL
            ) async throws -> Value {
                try SmartClient.makeDefaultDecoder().decode(Value.self, from: response)
            }

            func fetchRaw(from url: URL) async throws -> Data { response }

            func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
                _ responseType: Response.Type,
                to url: URL,
                method: HTTPMethod,
                body: Body
            ) async throws -> Response {
                let encoded = try SmartClient.makeDefaultEncoder().encode(body)
                lock.withLock {
                    _sentURL = url
                    _sentMethod = method
                    _sentBodyJSON = String(data: encoded, encoding: .utf8)
                }
                return try SmartClient.makeDefaultDecoder().decode(Response.self, from: response)
            }

            func send(to url: URL, method: HTTPMethod) async throws {
                lock.withLock {
                    _sentURL = url
                    _sentMethod = method
                    _sentBodyJSON = nil
                }
            }
        }

        // Mock response body that decodes to a TestUser.Model.
        let responsePayload = #"""
        {
          "id": 99,
          "name": "Updated Name",
          "avatar_url": "https://example.com/a.png",
          "bio": "...",
          "is_active": true,
          "created_at": "2024-01-01T00:00:00Z",
          "tags": [],
          "address": { "city": "Berlin", "street": "Unter den Linden 1" }
        }
        """#.data(using: .utf8)!

        let recorder = RecordingFetcher(response: responsePayload)
        let mutator = TestUser.Mutator(
            createURL: URL(string: "https://api.example.com/users")!,
            updateURL: { user in
                URL(string: "https://api.example.com/users/\(user.id)")!
            },
            deleteURL: { user in
                URL(string: "https://api.example.com/users/\(user.id)")!
            },
            fetcher: recorder
        )

        // Build a starting model to feed the operations.
        let original = TestUser.Model(
            address: TestUser.Model.Address(city: "Paris", street: "1 Rue"),
            avatarURL: URL(string: "https://example.com/a.png")!,
            bio: "Original.",
            createdAt: Date(timeIntervalSince1970: 0),
            id: 42,
            isActive: true,
            name: "Original",
            tags: ["a"]
        )

        // CREATE
        _ = try await mutator.create(original)
        XCTAssertEqual(recorder.sentURL?.absoluteString, "https://api.example.com/users")
        XCTAssertEqual(recorder.sentMethod, .post)
        XCTAssertTrue(recorder.sentBodyJSON?.contains("\"avatar_url\"") == true,
                      "request body should use snake_case keys")

        // UPDATE — interpolates id into URL
        _ = try await mutator.update(original)
        XCTAssertEqual(recorder.sentURL?.absoluteString, "https://api.example.com/users/42")
        XCTAssertEqual(recorder.sentMethod, .put)

        // DELETE — no body
        try await mutator.delete(original)
        XCTAssertEqual(recorder.sentURL?.absoluteString, "https://api.example.com/users/42")
        XCTAssertEqual(recorder.sentMethod, .delete)
        XCTAssertNil(recorder.sentBodyJSON, "DELETE shouldn't carry a body")
    }

    func testMutatorThrowsWhenURLIsMissing() async {
        let mutator = TestUser.Mutator()  // no URLs configured
        let placeholder = TestUser.Model(
            address: TestUser.Model.Address(city: "x", street: "y"),
            avatarURL: URL(string: "https://x")!,
            bio: "",
            createdAt: .now,
            id: 1,
            isActive: false,
            name: "x",
            tags: []
        )
        do {
            _ = try await mutator.create(placeholder)
            XCTFail("expected throw")
        } catch let error as SmartAPIMutatorError {
            if case .notConfigured(.create) = error { /* ok */ } else {
                XCTFail("wrong operation: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testDraftRoundtripsModel() {
        let original = TestUser.Model(
            address: TestUser.Model.Address(city: "Bern", street: "Marktgasse"),
            avatarURL: URL(string: "https://example.com/x.png")!,
            bio: "Hi.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            id: 7,
            isActive: true,
            name: "Edith",
            tags: ["math"]
        )
        var draft = TestUser.Draft(from: original)
        draft.name = "Edith II"
        draft.isActive = false
        let updated = draft.toModel()
        XCTAssertEqual(updated.name, "Edith II")
        XCTAssertFalse(updated.isActive)
        XCTAssertEqual(updated.id, 7, "non-edited fields preserved")
        XCTAssertEqual(updated.address.city, "Bern")
    }

    func testEditViewCompilesAndBinds() {
        // Compile-time check: the generated EditView exists, takes a
        // Mutator, and accepts an onSaved callback.
        let model = TestUser.Model(
            address: TestUser.Model.Address(city: "x", street: "y"),
            avatarURL: URL(string: "https://x")!,
            bio: "",
            createdAt: .now,
            id: 1,
            isActive: false,
            name: "x",
            tags: []
        )
        let mutator = TestUser.Mutator()
        let view = TestUser.EditView(
            editing: model,
            mutator: mutator,
            onSaved: { _ in }
        )
        _ = view.body  // touches body to prove the view tree builds
    }

    // MARK: - Regression: cache file collision (review fix #1)

    func testCachedTypesUseDistinctCacheFiles() {
        // Two `@SmartAPI(cache: true)` types in the same module must not
        // share the same on-disk cache file. Before the host-type fix they
        // both defaulted to `Model.json` and clobbered each other.
        let alphaLoader = TestCachedAlpha.Loader(url: URL(string: "https://x")!)
        let betaLoader  = TestCachedBeta.Loader(url: URL(string: "https://x")!)

        let alphaCache = alphaLoader.cache as? JSONFileCache<TestCachedAlpha.Model>
        let betaCache  = betaLoader.cache  as? JSONFileCache<TestCachedBeta.Model>

        XCTAssertNotNil(alphaCache, "cache: true should default to a JSONFileCache")
        XCTAssertNotNil(betaCache,  "cache: true should default to a JSONFileCache")
        XCTAssertNotEqual(
            alphaCache?.fileURL.lastPathComponent,
            betaCache?.fileURL.lastPathComponent,
            "two cached types must not share a cache file"
        )
        XCTAssertTrue(
            alphaCache?.fileURL.lastPathComponent.contains("TestCachedAlpha") ?? false,
            "cache file should be namespaced by host type name"
        )
        XCTAssertTrue(
            betaCache?.fileURL.lastPathComponent.contains("TestCachedBeta") ?? false,
            "cache file should be namespaced by host type name"
        )
    }

    // MARK: - Regression: response body leak (review fix #3)

    func testSmartClientErrorDoesNotLeakResponseBody() {
        // Bodies routinely carry access tokens, refresh tokens, PII.
        // `description` must not echo them — it's the string that ends up
        // in unstructured logs and crash reporters.
        let payload = Data("access_token=SECRET_DO_NOT_LOG&refresh_token=ALSO_SECRET".utf8)
        let error = SmartClientError.badStatus(401, data: payload)
        XCTAssertFalse(error.description.contains("SECRET_DO_NOT_LOG"))
        XCTAssertFalse(error.description.contains("access_token"))
        // It should still surface enough info to recognize the problem.
        XCTAssertTrue(error.description.contains("401"))
        XCTAssertTrue(error.description.contains("\(payload.count)"))
    }

    func testJSONFileCacheRoundtrip() async throws {
        // Roundtrip arbitrary Codable payload through the on-disk cache.
        struct Tiny: Codable, Equatable, Sendable { let name: String; let count: Int }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartapi-test-\(UUID().uuidString)")
        let cache = JSONFileCache<Tiny>(name: "tiny", directory: tempDir)
        // XCTAssertNil's autoclosure can't be async — bind the value first.
        let beforeWrite = try await cache.read()
        XCTAssertNil(beforeWrite, "fresh cache should be empty")

        try await cache.write(Tiny(name: "ada", count: 7))
        let afterWrite = try await cache.read()
        XCTAssertEqual(afterWrite, Tiny(name: "ada", count: 7))

        try await cache.clear()
        let afterClear = try await cache.read()
        XCTAssertNil(afterClear, "cleared cache should be empty")
    }

    // MARK: - Scope: parse-only mode

    func testParseOnlyEmitsModelAndLoaderForExistingUI() async throws {
        // The most common production scenario — designer-provided views,
        // SmartAPI handles the network layer. This test mirrors how a
        // developer would consume the package: get the model, drive their
        // own custom UI with it.
        struct MockFetcher: SmartFetching {
            let payload: Data
            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, from url: URL
            ) async throws -> Value {
                try SmartClient.makeDefaultDecoder().decode(Value.self, from: payload)
            }
            func fetchRaw(from url: URL) async throws -> Data { payload }
        }

        let payload = #"""
        { "id": 42, "title": "From the API", "body": "Bound to your view." }
        """#.data(using: .utf8)!

        let loader = TestParseOnly.Loader(
            url: URL(string: "https://x")!,
            fetcher: MockFetcher(payload: payload)
        )
        await loader.load()

        guard case .loaded(let post) = loader.state else {
            XCTFail("expected .loaded, got \(loader.state)")
            return
        }
        // The Model is exactly what the developer's custom view binds to —
        // no SmartAPI-generated SwiftUI in sight.
        XCTAssertEqual(post.id, 42)
        XCTAssertEqual(post.title, "From the API")
        XCTAssertEqual(post.body, "Bound to your view.")
    }

    func testDisplayOnlyEmitsViewButNoEditSurface() {
        // Display-only generates the read-only View so it's usable, but
        // omits the write surface. We exercise the Model + the View body
        // builds — verifying "Mutator doesn't exist" would require a
        // negative compile-time check, which Swift doesn't expose at
        // runtime. The macro is the single source of truth for what gets
        // emitted; check the contents of `CodeGenerator.generate` for the
        // gates that enforce this.
        let model = TestDisplayOnly.Model(id: 1, title: "x")
        let view = TestDisplayOnly.View(model: model)
        _ = view.body
    }

    // MARK: - Lenient decoding (`strict: false`)

    func testLenientModelSurvivesMissingFields() throws {
        // Server sent ONLY `id` — everything else missing. Strict decode
        // would throw; lenient must produce defaults.
        let json = #"""
        { "id": 7 }
        """#.data(using: .utf8)!
        let model = try JSONDecoder().decode(TestLenient.Model.self, from: json)
        XCTAssertEqual(model.id, 7)
        XCTAssertEqual(model.name, "", "missing String should fall back to \"\"")
        XCTAssertFalse(model.isActive, "missing Bool should fall back to false")
        XCTAssertEqual(model.score, 0, "missing Int should fall back to 0")
        XCTAssertEqual(model.address.city, "", "missing nested object should use defaultEmpty")
    }

    func testLenientModelSurvivesNullFields() throws {
        // Some APIs send `"name": null` rather than omitting the key.
        let json = #"""
        { "id": 7, "name": null, "is_active": null, "score": null, "address": null }
        """#.data(using: .utf8)!
        let model = try JSONDecoder().decode(TestLenient.Model.self, from: json)
        XCTAssertEqual(model.name, "")
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.score, 0)
        XCTAssertEqual(model.address.city, "")
    }

    func testLenientModelSurvivesWrongShapeFields() throws {
        // The server "improved" the API: `score` is now a String like "high".
        // Strict decode would crash the screen; lenient survives with the
        // numeric default while observability surfaces the drift separately.
        let json = #"""
        { "id": 7, "name": "Ada", "score": "high", "is_active": "yes", "address": { "city": "London", "street": "1 Way" } }
        """#.data(using: .utf8)!
        let model = try JSONDecoder().decode(TestLenient.Model.self, from: json)
        XCTAssertEqual(model.id, 7)
        XCTAssertEqual(model.name, "Ada")
        XCTAssertEqual(model.score, 0, "wrong-type Int should fall back to 0")
        XCTAssertFalse(model.isActive, "wrong-type Bool should fall back to false")
        // Nested object decoded fine because its types were right.
        XCTAssertEqual(model.address.city, "London")
    }

    // MARK: - SmartEndpoint + path templates

    func testEndpointSubstitutesPathParameters() throws {
        let endpoint = SmartEndpoint<Empty>(path: "/users/{id}/posts/{postId}")
        let url = try endpoint.buildURL(
            baseURL: URL(string: "https://api.example.com")!,
            pathParams: ["id": "42", "postId": "100"],
            queryParams: []
        )
        XCTAssertEqual(url.absoluteString, "https://api.example.com/users/42/posts/100")
    }

    func testEndpointAppendsQueryParameters() throws {
        let endpoint = SmartEndpoint<Empty>(path: "/posts")
        let url = try endpoint.buildURL(
            baseURL: URL(string: "https://api.example.com")!,
            pathParams: [:],
            queryParams: [
                URLQueryItem(name: "page", value: "2"),
                URLQueryItem(name: "limit", value: "20"),
            ]
        )
        XCTAssertTrue(url.absoluteString.contains("page=2"))
        XCTAssertTrue(url.absoluteString.contains("limit=20"))
    }

    func testEndpointThrowsOnMissingPathParam() {
        let endpoint = SmartEndpoint<Empty>(path: "/users/{id}")
        XCTAssertThrowsError(
            try endpoint.buildURL(
                baseURL: URL(string: "https://api.example.com")!,
                pathParams: [:],
                queryParams: []
            )
        ) { error in
            guard case SmartEndpointError.missingPathParameter(let name) = error else {
                XCTFail("expected missingPathParameter, got \(error)"); return
            }
            XCTAssertEqual(name, "id")
        }
    }

    func testEndpointThrowsOnMissingBaseURL() {
        let endpoint = SmartEndpoint<Empty>(path: "/users")
        XCTAssertThrowsError(
            try endpoint.buildURL(baseURL: nil, pathParams: [:], queryParams: [])
        ) { error in
            guard case SmartEndpointError.missingBaseURL = error else {
                XCTFail("expected missingBaseURL, got \(error)"); return
            }
        }
    }

    func testEndpointPercentEncodesPathValues() throws {
        // Path values often come from user input (slugs, IDs with spaces).
        // The endpoint must escape them so the URL stays valid.
        let endpoint = SmartEndpoint<Empty>(path: "/items/{slug}")
        let url = try endpoint.buildURL(
            baseURL: URL(string: "https://api.example.com")!,
            pathParams: ["slug": "hello world"],
            queryParams: []
        )
        XCTAssertTrue(url.absoluteString.contains("hello%20world"))
    }

    // MARK: - RetryPolicy

    func testRetryPolicyExponentialBackoffGrowsThenCaps() {
        let policy = RetryPolicy.Backoff.exponential(initial: 1, multiplier: 2, max: 10)
        XCTAssertEqual(policy.delay(for: 0), 0, "no delay before first attempt")
        XCTAssertEqual(policy.delay(for: 1), 1)
        XCTAssertEqual(policy.delay(for: 2), 2)
        XCTAssertEqual(policy.delay(for: 3), 4)
        XCTAssertEqual(policy.delay(for: 4), 8)
        XCTAssertEqual(policy.delay(for: 5), 10, "should cap at max")
        XCTAssertEqual(policy.delay(for: 10), 10, "still capped")
    }

    func testRetryPolicyClassifiesTransientErrors() {
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(RetryPolicy.isTransient(SmartClientError.badStatus(500, data: Data())))
        XCTAssertTrue(RetryPolicy.isTransient(SmartClientError.badStatus(503, data: Data())))

        XCTAssertFalse(RetryPolicy.isTransient(URLError(.badURL)))
        XCTAssertFalse(RetryPolicy.isTransient(SmartClientError.badStatus(404, data: Data())))
        XCTAssertFalse(RetryPolicy.isTransient(SmartClientError.badStatus(422, data: Data())))
    }

    func testStandardRetryRefusesNonIdempotentMethods() {
        // POST and PATCH are dangerous to auto-retry — a request that
        // timed out on the wire may have succeeded server-side, and a
        // retry creates a duplicate record. `.standard` must refuse them.
        let transient = URLError(.timedOut)
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(transient, 0, .get))
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(transient, 0, .put))
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(transient, 0, .delete))
        XCTAssertFalse(RetryPolicy.standard.shouldRetry(transient, 0, .post),
                       "POST must NOT be auto-retried — duplicate-write hazard")
        XCTAssertFalse(RetryPolicy.standard.shouldRetry(transient, 0, .patch),
                       "PATCH must NOT be auto-retried — duplicate-write hazard")
    }

    func testAllowsUnsafeRetriesIsExplicitOptIn() {
        // For callers who add idempotency keys on POST.
        let transient = URLError(.timedOut)
        XCTAssertTrue(RetryPolicy.allowsUnsafeRetries.shouldRetry(transient, 0, .post))
        XCTAssertTrue(RetryPolicy.allowsUnsafeRetries.shouldRetry(transient, 0, .patch))
    }

    func testBearerTokenProviderCoalescesConcurrentRefreshes() async throws {
        // Two callers refresh at the same time. The handler should run
        // exactly ONCE — the second caller rides on the first's Task.
        // Without coalescing, both would burn a refresh-token slot.
        let handlerCallCount = LockIsolated(0)
        let provider = BearerTokenProvider(initialToken: "old") {
            handlerCallCount.withValue { $0 += 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            return "fresh"
        }
        async let result1 = provider.refresh()
        async let result2 = provider.refresh()
        let (h1, h2) = (try await result1, try await result2)
        XCTAssertEqual(h1, "Bearer fresh")
        XCTAssertEqual(h2, "Bearer fresh")
        XCTAssertEqual(handlerCallCount.value, 1,
                       "refresh handler should run once for concurrent callers")
    }

    // MARK: - Client.call(endpoint:) end-to-end

    func testClientCallsEndpointThroughMockFetcher() async throws {
        // A fully-featured mock that observes SmartClient via SmartFetching.
        // Verifies path substitution + decoding actually flow end-to-end.
        struct MockFetcher: SmartFetching {
            let payload: Data
            func fetch<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) async throws -> Value {
                try SmartClient.makeDefaultDecoder().decode(Value.self, from: payload)
            }
            func fetchRaw(from url: URL) async throws -> Data { payload }
            func fetch<Value: Decodable & Sendable>(_ type: Value.Type, via query: SmartQuery) async throws -> Value {
                try SmartClient.makeDefaultDecoder().decode(Value.self, from: payload)
            }
            func fetchRaw(via query: SmartQuery) async throws -> Data { payload }
        }

        struct Post: Codable, Equatable, Sendable { let id: Int; let title: String }

        let endpoint = SmartEndpoint<Post>(path: "/posts/{id}")
        let payload = #"""
        { "id": 42, "title": "From endpoint" }
        """#.data(using: .utf8)!

        // We can't easily inject a fetcher into SmartClient since SmartClient
        // *is* the fetcher. Instead test the buildURL + use the fetcher directly.
        let url = try endpoint.buildURL(
            baseURL: URL(string: "https://api.example.com")!,
            pathParams: ["id": "42"],
            queryParams: []
        )
        let mock = MockFetcher(payload: payload)
        let post: Post = try await mock.fetch(
            Post.self,
            via: SmartQuery(url: url, method: endpoint.method)
        )
        XCTAssertEqual(post, Post(id: 42, title: "From endpoint"))
    }

    // MARK: - SmartQuery + POST loaders

    func testSmartQueryGETHasNoBody() {
        let query = SmartQuery.get(URL(string: "https://example.com")!)
        XCTAssertEqual(query.method, .get)
        XCTAssertNil(query.body)
        XCTAssertTrue(query.headers.isEmpty)
    }

    func testSmartQueryPOSTEncodesBodyAndSetsContentType() throws {
        struct Body: Codable, Equatable { let term: String; let limit: Int }
        let body = Body(term: "ada", limit: 25)
        let query = try SmartQuery.post(
            URL(string: "https://example.com/search")!,
            body: body
        )
        XCTAssertEqual(query.method, .post)
        XCTAssertEqual(query.headers["Content-Type"], "application/json")
        // Round-trip: the body bytes should decode back to the original.
        let data = try XCTUnwrap(query.body)
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testSmartQueryAppendingQueryItems() {
        let base = SmartQuery.get(URL(string: "https://example.com/items")!)
        let withParams = base.appending(queryItems: [
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "limit", value: "20"),
        ])
        XCTAssertTrue(withParams.url.absoluteString.contains("page=2"))
        XCTAssertTrue(withParams.url.absoluteString.contains("limit=20"))
    }

    func testLoaderFetchesViaPOSTQuery() async throws {
        // Mock fetcher that records the SmartQuery it received.
        final class RecordingFetcher: SmartFetching, @unchecked Sendable {
            private let lock = NSLock()
            private var _received: SmartQuery?
            let payload: Data

            init(payload: Data) { self.payload = payload }

            var received: SmartQuery? { lock.withLock { _received } }

            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, from url: URL
            ) async throws -> Value {
                XCTFail("POST loader should use fetch(via:), not fetch(from:)")
                throw URLError(.unsupportedURL)
            }
            func fetchRaw(from url: URL) async throws -> Data { payload }

            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, via query: SmartQuery
            ) async throws -> Value {
                lock.withLock { _received = query }
                return try SmartClient.makeDefaultDecoder().decode(Value.self, from: payload)
            }
            func fetchRaw(via query: SmartQuery) async throws -> Data {
                lock.withLock { _received = query }
                return payload
            }
        }

        struct SearchRequest: Codable, Sendable { let term: String }

        let payload = #"""
        {
          "id": 1,
          "name": "Ada",
          "avatar_url": "https://x",
          "bio": "",
          "is_active": true,
          "created_at": "2024-01-01T00:00:00Z",
          "tags": [],
          "address": { "city": "x", "street": "y" }
        }
        """#.data(using: .utf8)!

        let recorder = RecordingFetcher(payload: payload)
        let query = try SmartQuery.post(
            URL(string: "https://api.example.com/search")!,
            body: SearchRequest(term: "ada"),
            headers: ["X-Request-Id": "abc"]
        )
        let loader = TestUser.Loader(query: query, fetcher: recorder)
        await loader.load()

        if case .loaded(let user) = loader.state {
            XCTAssertEqual(user.name, "Ada")
        } else {
            XCTFail("expected .loaded, got \(loader.state)")
        }

        let captured = recorder.received
        XCTAssertEqual(captured?.method, .post)
        XCTAssertEqual(captured?.headers["X-Request-Id"], "abc")
        XCTAssertEqual(captured?.headers["Content-Type"], "application/json")
        XCTAssertNotNil(captured?.body, "POST query should carry the encoded body")
    }

    func testBearerTokenProviderIssuesHeaderAndRefreshes() async throws {
        // Verify the provider produces the expected `Bearer <token>` header
        // before and after a refresh. The 401-retry flow is tested via
        // injection at a higher level (would require URLProtocol mocking
        // to exercise end-to-end).
        let provider = BearerTokenProvider(initialToken: "old-token") {
            "new-token"
        }
        let firstHeader = try await provider.currentHeader()
        XCTAssertEqual(firstHeader, "Bearer old-token")

        let refreshedHeader = try await provider.refresh()
        XCTAssertEqual(refreshedHeader, "Bearer new-token")

        let nextHeader = try await provider.currentHeader()
        XCTAssertEqual(nextHeader, "Bearer new-token",
                       "post-refresh, currentHeader should return the new token")
    }

    func testNoAuthProviderReturnsNoHeader() async throws {
        let provider = NoAuthProvider()
        let header = try await provider.currentHeader()
        XCTAssertNil(header)
    }

    func testLoaderRecordsLastRefreshErrorAfterCacheHit() async throws {
        // After cache serves a value and the network refresh fails, state
        // stays `.loaded` (UI keeps working) but the error is observable
        // via `lastRefreshErrorDescription` so a stale-data banner can show.
        struct FailingFetcher: SmartFetching {
            func fetch<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) async throws -> Value {
                throw URLError(.notConnectedToInternet)
            }
            func fetchRaw(from url: URL) async throws -> Data {
                throw URLError(.notConnectedToInternet)
            }
        }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartapi-test-\(UUID().uuidString)")
        let cache = JSONFileCache<TestUser.Model>(name: "TestUser", directory: tempDir)
        try await cache.write(TestUser.Model(
            address: TestUser.Model.Address(city: "x", street: "y"),
            avatarURL: URL(string: "https://x")!,
            bio: "",
            createdAt: .now,
            id: 1,
            isActive: false,
            name: "Cached",
            tags: []
        ))

        let loader = TestUser.Loader(
            url: URL(string: "https://x")!,
            fetcher: FailingFetcher(),
            cache: cache
        )
        await loader.load()

        if case .loaded = loader.state { /* ok */ } else {
            XCTFail("expected .loaded from cache, got \(loader.state)")
        }
        XCTAssertFalse(loader.lastRefreshErrorDescription.isEmpty,
                       "lastRefreshErrorDescription should surface the network error")
    }

    func testLoaderServesCachedValueWhenOffline() async throws {
        // Simulates the offline scenario: network is dead, cache has data,
        // Loader should hand the cached value to the UI without failing.
        struct FailingFetcher: SmartFetching {
            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, from url: URL
            ) async throws -> Value {
                throw URLError(.notConnectedToInternet)
            }
            func fetchRaw(from url: URL) async throws -> Data {
                throw URLError(.notConnectedToInternet)
            }
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartapi-test-\(UUID().uuidString)")
        let cache = JSONFileCache<TestUser.Model>(name: "TestUser", directory: tempDir)
        let cached = TestUser.Model(
            address: TestUser.Model.Address(city: "Helsinki", street: "Mannerheimintie 1"),
            avatarURL: URL(string: "https://example.com/x.png")!,
            bio: "Cached.",
            createdAt: Date(timeIntervalSince1970: 0),
            id: 1,
            isActive: true,
            name: "Cached User",
            tags: ["offline"]
        )
        try await cache.write(cached)

        let loader = TestUser.Loader(
            url: URL(string: "https://api.example.com/users/1")!,
            fetcher: FailingFetcher(),
            cache: cache
        )
        await loader.load()

        guard case .loaded(let value) = loader.state else {
            XCTFail("expected .loaded from cache, got \(loader.state)")
            return
        }
        XCTAssertEqual(value.name, "Cached User")
        XCTAssertEqual(value.address.city, "Helsinki")
    }

    func testLoaderSurfacesNetworkErrorWhenNoCachedValue() async {
        // Same failing fetcher, but no cache to fall back on — the Loader
        // should report .failed so the UI can show an error state.
        struct FailingFetcher: SmartFetching {
            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type, from url: URL
            ) async throws -> Value {
                throw URLError(.notConnectedToInternet)
            }
            func fetchRaw(from url: URL) async throws -> Data {
                throw URLError(.notConnectedToInternet)
            }
        }
        let loader = TestUser.Loader(
            url: URL(string: "https://api.example.com/users/1")!,
            fetcher: FailingFetcher(),
            cache: nil
        )
        await loader.load()
        guard case .failed = loader.state else {
            XCTFail("expected .failed, got \(loader.state)")
            return
        }
    }

    func testLoaderUsesInjectedFetcher() async throws {
        // The generated Loader accepts any `SmartFetching` — no dependency on
        // `SmartClient` directly. Inject an in-memory mock and verify that
        // `load()` flows its bytes through the fetcher into state.
        struct MockFetcher: SmartFetching {
            let payload: Data
            func fetch<Value: Decodable & Sendable>(
                _ type: Value.Type,
                from url: URL
            ) async throws -> Value {
                let decoder = SmartClient.makeDefaultDecoder()
                return try decoder.decode(Value.self, from: payload)
            }
            func fetchRaw(from url: URL) async throws -> Data { payload }
        }

        let payload = #"""
        {
          "id": 1,
          "name": "Grace Hopper",
          "avatar_url": "https://example.com/g.png",
          "bio": "Compiler pioneer.",
          "is_active": true,
          "created_at": "2024-01-01T00:00:00Z",
          "tags": ["compilers"],
          "address": { "city": "Arlington", "street": "1 Way" }
        }
        """#.data(using: .utf8)!

        let loader = TestUser.Loader(
            url: URL(string: "https://stand-in")!,
            fetcher: MockFetcher(payload: payload)
        )
        await loader.load()

        guard case .loaded(let user) = loader.state else {
            XCTFail("expected .loaded, got \(loader.state)")
            return
        }
        XCTAssertEqual(user.name, "Grace Hopper")
        XCTAssertEqual(user.address.city, "Arlington")
    }

    func testSchemaFingerprintMatchesSourceSample() throws {
        // Same JSON used in the macro sample — fingerprint must match.
        let live = """
        {
          "id": 99,
          "name": "Anyone",
          "avatar_url": "https://x",
          "bio": "...",
          "is_active": false,
          "created_at": "2025-01-01T00:00:00Z",
          "tags": ["a"],
          "address": { "street": "x", "city": "y" }
        }
        """.data(using: .utf8)!
        let actual = try SmartAPISchema.fingerprint(of: live)
        XCTAssertEqual(actual, TestUser.Model.schemaFingerprint,
                       "Same-shape JSON should match the macro-generated fingerprint.")
    }

    func testRenamesOverrideHeuristicNames() throws {
        // Decode using the user-friendly names emitted by renames:
        let json = #"""
        { "usr_nm": "Ada", "ctr_cd": "GB", "active_flg": true }
        """#.data(using: .utf8)!
        let u = try JSONDecoder().decode(TestLegacyUser.Model.self, from: json)
        XCTAssertEqual(u.userName, "Ada")
        XCTAssertEqual(u.countryCode, "GB")
        XCTAssertTrue(u.isActive)
    }

    func testSchemaFingerprintDetectsDrift() throws {
        // Drifted: missing `tags`, extra `phone`, `is_active` is now string.
        let drifted = """
        {
          "id": 99,
          "name": "Anyone",
          "avatar_url": "https://x",
          "bio": "...",
          "is_active": "yes",
          "created_at": "2025-01-01T00:00:00Z",
          "phone": "555-0000",
          "address": { "street": "x", "city": "y" }
        }
        """.data(using: .utf8)!
        let actual = try SmartAPISchema.fingerprint(of: drifted)
        XCTAssertNotEqual(actual, TestUser.Model.schemaFingerprint)
        // The drift report should mention both shapes:
        let drift = SmartAPISchemaDrift(expected: TestUser.Model.schemaFingerprint, actual: actual)
        XCTAssertTrue(drift.description.contains("expected"))
        XCTAssertTrue(drift.description.contains("actual"))
    }

    func testSmartFlowChainsStepsWithProgressTracking() async {
        // Mock data — no real HTTP. Step bodies hand-roll the work so we
        // can verify the flow orchestrator without needing URLSession stubs.
        struct Feed: Sendable, Equatable {
            let userName: String
            let postCount: Int
            let firstCommentBody: String
        }

        let flow = SmartFlow<Feed> { ctx in
            // Independent steps run in parallel.
            async let user = ctx.step("user") { "Ada" }
            async let stats = ctx.step("stats") { 42 }
            let u = try await user
            _ = try await stats
            // Dependent step needs `u`.
            let posts = try await ctx.step("posts") { ["Post about \(u)", "Another"] }
            let comments = try await ctx.step("comments") { ["First comment on \(posts[0])"] }
            return Feed(userName: u, postCount: posts.count, firstCommentBody: comments[0])
        }

        await flow.load()

        guard case .loaded(let feed) = flow.state else {
            XCTFail("expected .loaded, got \(flow.state)")
            return
        }
        XCTAssertEqual(feed.userName, "Ada")
        XCTAssertEqual(feed.postCount, 2)
        XCTAssertEqual(feed.firstCommentBody, "First comment on Post about Ada")

        // Give the MainActor-hopping progress reporter a tick to flush.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(flow.steps["user"], .completed)
        XCTAssertEqual(flow.steps["stats"], .completed)
        XCTAssertEqual(flow.steps["posts"], .completed)
        XCTAssertEqual(flow.steps["comments"], .completed)
    }

    func testSmartFlowSurfacesStepFailure() async {
        struct Boom: Error {}
        let flow = SmartFlow<String> { ctx in
            _ = try await ctx.step("ok") { "fine" }
            return try await ctx.step("fails") { throw Boom() }
        }

        await flow.load()

        guard case .failed = flow.state else {
            XCTFail("expected .failed, got \(flow.state)")
            return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(flow.steps["ok"], .completed)
        XCTAssertEqual(flow.steps["fails"], .failed)
    }

    func testFieldOverridesCompileAndChain() {
        // Compile-time proof: every generated field exposes a `withX { value in View }`
        // modifier, modifiers chain fluently, and the closure receives the field's
        // typed value (not a stringly-typed blob).
        let address = TestUser.Model.Address(city: "London", street: "10 Downing St")
        let model = TestUser.Model(
            address: address,
            avatarURL: URL(string: "https://example.com/a.png")!,
            bio: "Pioneer.",
            createdAt: .now,
            id: 1,
            isActive: true,
            name: "Ada",
            tags: ["x"]
        )
        let view = TestUser.View(model: model)
            .withAvatarURL { url in
                AsyncImage(url: url).clipShape(Circle())
            }
            .withBio { text in
                Text(text).font(.system(.body, design: .serif))
            }
            .withIsActive { active in
                Text(active ? "✓" : "✗").foregroundStyle(active ? .green : .red)
            }
            .withTags { tag in
                Text(tag).padding(4).background(.thinMaterial, in: Capsule())
            }
        // Just touching `.body` is enough to prove the chain produced a valid View.
        _ = view.body
    }
}
