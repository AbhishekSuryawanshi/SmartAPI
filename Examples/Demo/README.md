# GitHub Demo

A small but complete SwiftUI iOS app built entirely on SmartAPI, against the public GitHub API (no authentication required for the endpoints used here).

## What it shows

| Feature | Where |
|---|---|
| Typed models from real GitHub responses | `GitHubUser`, `Repository`, `RepoSearch` |
| Paginated search (page-number strategy) | `SearchScreen` → `SmartPaginatedView` |
| Infinite scroll + pull-to-refresh | Free with `SmartPaginatedView` |
| Endpoint catalog | `GitHub.client`, `GitHub.getUser`, `GitHub.getRepo` |
| Custom HTTP client | `SmartClient(retryPolicy:, observer:, coalescer:)` |
| Offline cache | `@SmartAPI(cache: true)` on `GitHubUser` |
| Stale-data banner | Built into `SmartView` automatically |
| Request deduplication | `RequestCoalescer` shared on the client |
| Custom row + detail views | "Generated UI is optional" — these are yours |

## How to run

1. Create a new iOS App project in Xcode (iOS 17+).
2. File → Add Package Dependencies → Add SmartAPI package.
3. Drop `GitHubDemo.swift` into the project.
4. Replace your `App` body with `GitHubDemoApp()`:

   ```swift
   @main
   struct MyApp: App {
       var body: some Scene {
           WindowGroup {
               GitHubDemoApp()
           }
       }
   }
   ```

5. ⌘R.

## What you'll see

- **Search tab**: type a query → paginated list of GitHub repos → scroll to load more → tap any repo for detail.
- **User tab**: pre-loaded with `@apple` → shows profile from API → close Wi-Fi and re-launch to see the **offline cache** serve the cached profile + a stale-data banner.

## What's NOT in the demo on purpose

- **Generated SwiftUI views**: every model is `scope: .parseOnly`. The demo uses *your* row/detail/form views — the whole point of `.parseOnly` is to keep your design system. Generated UI is an opt-in convenience, not the framework's value.
- **Auth**: the public GitHub API doesn't require it for the endpoints shown. For private data, see `Examples/CustomClientMode.swift` for the auth + refresh pattern.
- **Mutations**: GitHub's write APIs require auth + scopes. See `Examples/CustomClientMode.swift` for the `Mutator` + `EditView` story.
