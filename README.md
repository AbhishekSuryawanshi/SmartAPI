# SmartAPI

[![CI](https://github.com/AbhishekSuryawanshi/SmartAPI/actions/workflows/ci.yml/badge.svg)](https://github.com/AbhishekSuryawanshi/SmartAPI/actions/workflows/ci.yml)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg?logo=swift)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://developer.apple.com/ios)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos)
[![SPM](https://img.shields.io/badge/SwiftPM-supported-DE5C43.svg?logo=swift)](https://www.swift.org/documentation/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Turn JSON or OpenAPI into a production-ready Swift API client.**
Typed models, auth, retry, caching, observability, and pagination — built in.

<!-- Demo GIF: record Examples/Demo/ProductsDemo.swift, save it as
     docs/demo.gif, then UNCOMMENT the line below to show it here.
     Recommended: 30 sec max, 800px wide, 24 fps.
![SmartAPI demo](docs/demo.gif)
-->

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
    .package(url: "https://github.com/AbhishekSuryawanshi/SmartAPI.git", from: "0.1.0")
]
```

Then in your target:

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "SmartAPI", package: "SmartAPI")]
)
```

Requires **Swift 6.0+ · Xcode 16+ · iOS 17+ · macOS 14+**. Fully supports
Swift 6.2's "main actor by default" mode (the modern Xcode app-target default).

> **First build:** Xcode shows a one-time *"SmartAPIMacros — package needs to
> enable a macro"* prompt. Click **Trust & Enable**. This is Swift's standard
> security gate for package macros, not specific to SmartAPI. The first build
> also compiles `swift-syntax` once (~60–90s); subsequent builds are instant.

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

## Why not just OpenAPI Generator?

The obvious comparison is [`swift-openapi-generator`](https://github.com/apple/swift-openapi-generator) (Apple's official) or generic [OpenAPI Generator](https://openapi-generator.tech). Honest take on when each tool fits:

| | SmartAPI | swift-openapi-generator |
|---|---|---|
| Works without a published OpenAPI spec | ✅ inline JSON sample or `.smartapi.json` file | ❌ requires a full spec |
| `snake_case` → `camelCase` automatic | ✅ heuristic-driven | ⚠️ relies on `x-swift-name` hints |
| `URL` / `Date` / `Bool` inferred from sample | ✅ from values + key suffixes | ⚠️ relies on `format` annotations |
| Auth + token-refresh + 401 retry | ✅ shipped (`AuthorizationProvider`) | ❌ bring your own |
| Retry policy with idempotency safety | ✅ shipped (`RetryPolicy.standard`) | ❌ bring your own |
| Offline cache + stale-data banner | ✅ shipped (`SmartCache`, `SmartView`) | ❌ bring your own |
| Request deduplication on concurrent GETs | ✅ shipped (`RequestCoalescer`) | ❌ bring your own |
| Pagination strategies (cursor / page / offset) | ✅ shipped + macro-typed | ❌ bring your own |
| Lenient decoding with observer-visible defaults | ✅ `strict: false` | ❌ bring your own |
| Observability protocol | ✅ shipped (`SmartAPIObserver`) | ❌ bring your own |
| Optional SwiftUI views (off by default) | ✅ `scope: .full` opts in | ❌ models only |
| Full OpenAPI 3.x feature coverage | ⚠️ pragmatic subset (see [Known limitations](#known-limitations)) | ✅ comprehensive |
| Apple backing / official status | ❌ | ✅ |

**Use SmartAPI when** you want one SPM that gives you the entire iOS networking layer — typed models + a production HTTP runtime — without composing 4–5 separate libraries. Especially valuable for projects that don't have an OpenAPI spec at all (most internal APIs).

**Use swift-openapi-generator when** you need exact OpenAPI 3.x semantics across a polyglot team where Swift is one consumer of a shared contract, *and* you already have a separate solution for auth/retry/caching/observability.

The two tools are not mutually exclusive — SmartAPI's OpenAPI ingestion mode treats `components.schemas` as the source of truth, so an OpenAPI-first team can use SmartAPI for the iOS client surface while keeping the spec as the contract.

---

## Known limitations

Honest about what's not yet shipped — most of these are on the [roadmap](#roadmap), some are deliberate design choices.

- **Pagination + cache don't combine.** Caching a `PaginatedLoader`'s accumulated items requires invalidation decisions (refresh first page only? whole list? per-page entries with TTL?) that need design work before shipping safely. For now, `cache: true` is supported on single-resource `@SmartAPI` types — not on `paginated:` ones. Tracking issue: #2 (planned).
- **Link-header pagination is not yet supported.** The three shipped strategies (cursor, page-number, offset) cover the vast majority of modern REST APIs. GitHub's legacy `Link: <url>; rel="next"` style is the most common omission. Planned as a fourth strategy.
- **OpenAPI 3.x subset.** The CLI handles `components.schemas` with `$ref`, format hints, composition (`allOf` / `oneOf` / `anyOf`), enum values, and recursive schemas via depth-limited unrolling. Discriminators, complex polymorphism, security schemes, and `paths` operations are *not* yet ingested — only schemas become models.
- **`CodeGenerator` is string-based.** The macro emits Swift source as raw strings rather than `SwiftSyntaxBuilder` AST nodes. It works reliably and is heavily tested, but means a typo in generated code surfaces as a compile error in *your* project rather than at macro-expansion time. Migration to `SwiftSyntaxBuilder` is on the roadmap.
- **`Examples/Demo/` is a copy-paste-into-your-own-project file**, not a self-contained Xcode project. Drop it into any iOS 17+ app, and it runs against the public GitHub API. A standalone runnable Xcode project demo is a near-term wishlist item.
- **No built-in mocking / record-replay infrastructure** for consumer tests. `SmartFetching` is protocol-based so you can inject a mock, and a `MockURLProtocol` pattern is documented above, but there's no opinionated `SmartAPITesting` module yet.
- **Lenient mode reports `wrongType` without saying *which* type.** The observer event includes the field name and a `.wrongType` reason; the actual received type isn't surfaced. Worth adding.

If any of these are blockers for your project, file an issue and I'll prioritize accordingly.

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
