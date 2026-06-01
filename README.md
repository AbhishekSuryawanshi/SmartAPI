# SmartAPI

**Turn JSON or OpenAPI into a production-ready Swift API client.**
Typed models, auth, retry, caching, observability, and pagination — built in.

```swift
@SmartAPI(sample: """
{ "items": [{"id": 1, "title": "Hello"}], "total_count": 1247 }
""", paginated: .page(items: "items", total: "total_count"))
enum Posts {}
```

That's it. You now have:

- `Posts.Model` — typed `Codable + Sendable + Hashable + Identifiable` struct
- `Posts.loader(url:)` — `@Observable` paginated loader with retry, cache, auth, dedup
- `SmartPaginatedView(loader:)` — SwiftUI infinite-scroll list, pull-to-refresh, in one line

```swift
SmartPaginatedView(loader: Posts.loader(url: postsURL, fetcher: client)) { post in
    PostRowView(post: post)   // ← your view, your design system
}
```

**No `Codable` conformances written by hand. No `CodingKeys`. No `init(from:)`. No retry plumbing. No URL string-mangling. No pagination state machine.**

→ [Quick start](#quick-start) — [The three modes](#the-three-modes) — [Production features](#production-features) — [Demo](Examples/Demo/)

---

## Why SmartAPI

Every iOS app builds the same networking layer: typed models, an HTTP client, auth refresh, retry policies, observability, pagination. Each one slightly different, each one a maintenance burden.

**SmartAPI generates the typed API layer from a JSON sample (or an OpenAPI spec) and gives you a production-grade runtime to call it.** Auto-generated SwiftUI views are *optional* — most teams keep their own design system and use SmartAPI purely for parsing and fetching.

```swift
// What you write
@SmartAPI(sample: realResponseFromYourAPI, scope: .parseOnly)
enum User {}

// What SmartAPI gives you
User.Model       // typed, Codable, snake_case → camelCase, Date/URL inferred
User.Loader      // @Observable, cache-aware, observable, retryable
                 // (and View / EditView / Draft / Mutator if you opt in via scope:)
```

---

## Installation

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourname/SmartAPI.git", from: "1.0.0")
]
```

Then in your target:

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "SmartAPI", package: "SmartAPI")]
)
```

Requires Swift 6.0+, iOS 17+, macOS 14+.

---

## Quick start

### 1. Generate a model from a real API response

```swift
import SmartAPI

@SmartAPI(sample: """
{
  "id": 42,
  "name": "Ada Lovelace",
  "avatar_url": "https://example.com/ada.jpg",
  "is_active": true,
  "created_at": "2024-01-15T10:30:00Z",
  "tags": ["math", "computing"]
}
""", scope: .parseOnly)
enum User {}
```

You get a typed `User.Model` with:

| JSON | Swift |
|---|---|
| `id: 42` | `let id: Int` (→ `Identifiable`) |
| `avatar_url: "..."` | `let avatarURL: URL` (URL inferred from `_url` suffix) |
| `is_active: true` | `let isActive: Bool` (snake_case → camelCase) |
| `created_at: "2024-..."` | `let createdAt: Date` (ISO-8601 inferred) |
| `tags: ["math", "computing"]` | `let tags: [String]` |

Plus `CodingKeys`, `Codable + Sendable + Hashable + Identifiable` conformances, public `init`. **Zero hand-written code.**

### 2. Catalog your endpoints

```swift
enum API {
    static let client = SmartClient(
        baseURL: URL(string: "https://api.example.com")!,
        authorization: BearerTokenProvider(initialToken: token) {
            try await refreshAPI()
        },
        retryPolicy: .standard,                    // safe by default — no POST auto-retry
        observer: SmartAPILogger.shared,           // os.Logger; swap in your analytics
        coalescer: RequestCoalescer()              // dedup concurrent GETs
    )

    static let getUser    = SmartEndpoint<User.Model>(path: "/users/{id}")
    static let listUsers  = SmartEndpoint<[User.Model]>(path: "/users")
    static let createUser = SmartEndpoint<User.Model>(path: "/users", method: .post, requiresAuth: true)
    static let deleteUser = SmartEndpoint<Empty>(path: "/users/{id}", method: .delete, requiresAuth: true)
}
```

### 3. Call them from anywhere

```swift
let user  = try await API.client.call(API.getUser, pathParams: ["id": "42"])
let users = try await API.client.call(API.listUsers)
let saved = try await API.client.call(API.createUser, body: draft)
try await API.client.call(API.deleteUser, pathParams: ["id": "42"])
```

Path-template substitution, query parameters, custom headers, auth, 401 refresh, retry on 5xx, request deduplication — all automatic.

### 4. Add pagination when you need it

```swift
@SmartAPI(
    sample: """
    { "data": [{"id": 1}], "next_cursor": "abc", "has_more": true }
    """,
    paginated: .cursor(items: "data", nextCursor: "next_cursor", hasMore: "has_more")
)
enum Feed {}

let loader = Feed.loader(url: feedURL, fetcher: API.client)
await loader.load()              // first page
await loader.loadMore()          // append next
loader.items                     // [Feed.Model]
loader.hasMore                   // false when exhausted
```

Three strategies supported: `.cursor`, `.page`, `.offset`. All three behave identically for the caller — only the configuration differs.

### 5. Drop into SwiftUI

```swift
struct FeedScreen: View {
    var body: some View {
        SmartPaginatedView(loader: Feed.loader(url: feedURL, fetcher: API.client)) { post in
            MyCustomPostRowView(post: post)
        }
        .navigationTitle("Feed")
    }
}
```

Infinite scroll, pull-to-refresh, empty state, stale-data banner when the cache served while the network was down — all built in.

---

## The three modes

SmartAPI scales from "I just want typed parsing" to "generate the whole screen." Pick what you need; everything is opt-in.

### Mode 1: Inline JSON sample

```swift
@SmartAPI(sample: """
{ "id": 1, "title": "Hello" }
""")
enum Post {}
```

For most cases. The sample is right there in source — easy to read, easy to update, easy to diff.

### Mode 2: JSON file via CLI

```
Sources/MyApp/Models/post.smartapi.json   ← you commit this
```

Then run:

```bash
swift run smartapi-bundle Sources/MyApp/Models
# generated Sources/MyApp/Models/post+SmartAPI.swift
```

The generated `.swift` is a one-line `@SmartAPI` wrapper. Commit both. Re-run when the JSON changes; it's idempotent.

### Mode 3: OpenAPI spec → entire API

```bash
swift run smartapi-bundle openapi github-spec.json Sources/MyApp/Generated/
# generated Sources/MyApp/Generated/Repository+SmartAPI.swift
# generated Sources/MyApp/Generated/User+SmartAPI.swift
# generated Sources/MyApp/Generated/Issue+SmartAPI.swift
# ... 200+ more
# smartapi-bundle openapi: 203 schemas imported
```

**Every schema in `components.schemas` becomes a typed Swift model.** Handles `$ref`, format hints (`uri`, `date-time`, `uuid`, `email`), composition (`allOf`/`oneOf`/`anyOf`), enum values, recursive schemas.

---

## Production features

Not just demoware. Every feature below is verified by URLProtocol-based integration tests against a real `URLSession`.

| Feature | What you get |
|---|---|
| **Auth + refresh** | `AuthorizationProvider` protocol; ships `BearerTokenProvider` with **concurrent-refresh deduplication** (no double-burning refresh tokens) |
| **Retry policy** | `.standard` / `.aggressive` / `.allowsUnsafeRetries`; exponential backoff with `maxTotalDelay` cap; **refuses POST/PATCH by default** (no duplicate-write hazard) |
| **Per-call override** | `client.call(endpoint, retryPolicy: .none)` for audit logs / legal writes |
| **Offline cache** | `JSONFileCache` per type; loader reads cache → emits state → refreshes in background |
| **Stale-data banner** | `SmartView` shows when refresh failed but cache served — built in |
| **Request deduplication** | `RequestCoalescer` folds N concurrent identical GETs into 1 network call |
| **Schema drift detection** | Fingerprint baked at compile time; `loader.detectSchemaDrift()` compares against live |
| **Lenient parsing** | `strict: false` survives missing/null/wrong-type fields; observer reports every default |
| **Observability** | `SmartAPIObserver` fires on loader/mutator lifecycle, retries, auth refresh, cache, lenient defaults |
| **Pagination** | Cursor / page-number / offset — all three; auto-null cursor on last page; SwiftUI infinite scroll |
| **POST / GraphQL** | `SmartQuery.post(url, body: typed)` — eager body encoding so retries use identical bytes |
| **Cancellation** | `Task.isCancelled` checkpoints throughout; SwiftUI `.task` auto-cancellation propagates |

---

## Architecture

Four SPM targets, ~5,000 lines total:

```
SmartAPI              (library)    — Runtime: client, cache, observer, query, flow, view
SmartAPIMacros        (plugin)     — @SmartAPI macro: JSON inference + Swift codegen
SmartAPIImporter      (library)    — OpenAPI 3.0 parser
SmartAPIBundle        (CLI)        — swift run smartapi-bundle ...
```

The compiler plugin and runtime library can't import each other (different target types). Runtime type names referenced by codegen are centralized in one `RuntimeSymbols` file — rename surfaces as a build error, not a silent runtime crash.

---

## Production-readiness checklist

Verified by 78 tests, including 17 URLProtocol-based integration tests:

- ✅ Swift 6 strict mode + `ExistentialAny` upcoming feature enforced via `Package.swift`
- ✅ `-warnings-as-errors` clean across all targets
- ✅ Zero `@unchecked Sendable` in production runtime
- ✅ POST/PATCH refused by default retry policy (no duplicate writes)
- ✅ Concurrent refresh tokens coalesced (no double-burning)
- ✅ Cumulative backoff cap (no hung UI)
- ✅ Mid-pagination errors preserve existing items
- ✅ Null cursor handled correctly on last page
- ✅ Concurrent `loadMore()` guarded (no thundering herd)
- ✅ Cache write failures surface to observer
- ✅ Lenient mode defaults surface to observer with field + reason
- ✅ Auth 401 refresh + retry verified end-to-end

---

## Examples

See [`Examples/`](Examples/):

- [`JSONSampleMode.swift`](Examples/JSONSampleMode.swift) — inline sample, one type, three minutes
- [`OpenAPIMode.swift`](Examples/OpenAPIMode.swift) — CLI workflow for entire APIs
- [`CustomClientMode.swift`](Examples/CustomClientMode.swift) — full production config: auth, retry, observer, coalescer
- [`Demo/`](Examples/Demo/) — runnable GitHub API demo: search, paginated list, user detail, offline cache

---

## Testing your own code

SmartAPI ships a `MockURLProtocol` pattern in the test target. Use it (or your own) to script HTTP responses without standing up a server:

```swift
import XCTest
@testable import SmartAPI

let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let client = SmartClient(session: URLSession(configuration: config), ...)
MockURLProtocol.script.enqueue(.success(status: 200, body: payload))
let user = try await client.call(API.getUser, pathParams: ["id": "42"])
```

For your loaders, inject a mock `SmartFetching` directly — protocol-based, no URLSession required.

---

## Roadmap

Shipped:

- ✅ Macro-based model generation from JSON
- ✅ OpenAPI 3.0 ingestion
- ✅ Full HTTP client with auth + retry + dedup
- ✅ Cursor / page / offset pagination
- ✅ SwiftUI integration with infinite scroll
- ✅ Schema drift + lenient parsing
- ✅ Observability protocol
- ✅ URLProtocol-based test infra

Considered for next:

- [ ] Link-header pagination (GitHub legacy)
- [ ] Pagination + cache integration (currently independent)
- [ ] `SwiftSyntaxBuilder`-based codegen (currently string composition)
- [ ] Backend Swift companion (Vapor/Hummingbird models)

---

## License

MIT.

---

## Contributing

Issues and PRs welcome. Run the tests with:

```bash
swift test
```

All PRs must build clean under `-Xswiftc -warnings-as-errors` in Swift 6 strict mode.
