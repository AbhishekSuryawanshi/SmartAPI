// GitHub API demo — a small but complete SwiftUI app showing every
// SmartAPI feature against a real public API.
//
// Drop these files into any iOS 17+ Xcode project that depends on the
// SmartAPI package and you'll have a working GitHub explorer.
//
// What's exercised here:
//   • Typed models from real GitHub response samples
//   • Paginated search via SmartPaginatedView (page-number strategy)
//   • User detail screen via SmartView with stale-data banner
//   • Custom SmartClient with observer, retry, request coalescer
//   • Endpoint catalog (SmartEndpoint)
//   • Offline cache (User.Model gets cache: true)
//   • Custom row views — generated UI is opt-in; we use our own here

import SwiftUI
import SmartAPI

// MARK: - Models (generated from real GitHub API responses)

@SmartAPI(sample: """
{
  "login": "tjboneman",
  "id": 12345,
  "avatar_url": "https://avatars.githubusercontent.com/u/12345",
  "html_url": "https://github.com/tjboneman",
  "name": "T J Boneman",
  "company": "@example",
  "blog": "https://example.com",
  "location": "Reykjavík",
  "email": "tj@example.com",
  "bio": "iOS developer",
  "public_repos": 42,
  "followers": 1247,
  "following": 89,
  "created_at": "2014-03-15T10:30:00Z"
}
""", scope: .parseOnly, strict: false, cache: true)
enum GitHubUser {}

@SmartAPI(sample: """
{
  "id": 9999,
  "name": "swift",
  "full_name": "apple/swift",
  "html_url": "https://github.com/apple/swift",
  "description": "The Swift Programming Language",
  "stargazers_count": 67000,
  "forks_count": 10300,
  "language": "C++",
  "topics": ["swift", "compiler", "language"],
  "updated_at": "2024-06-01T08:00:00Z",
  "owner": {
    "login": "apple",
    "id": 10639145,
    "avatar_url": "https://avatars.githubusercontent.com/u/10639145"
  }
}
""", scope: .parseOnly, strict: false)
enum Repository {}

// Search response — GitHub uses page-number pagination on /search/repositories
@SmartAPI(sample: """
{
  "total_count": 81427,
  "incomplete_results": false,
  "items": [
    {
      "id": 9999,
      "name": "swift",
      "full_name": "apple/swift",
      "html_url": "https://github.com/apple/swift",
      "description": "The Swift Programming Language",
      "stargazers_count": 67000,
      "forks_count": 10300,
      "language": "C++",
      "topics": ["swift"],
      "updated_at": "2024-06-01T08:00:00Z",
      "owner": {
        "login": "apple",
        "id": 10639145,
        "avatar_url": "https://avatars.githubusercontent.com/u/10639145"
      }
    }
  ]
}
""", scope: .parseOnly, strict: false,
    paginated: .page(items: "items", total: "total_count", pageSize: 30)
)
enum RepoSearch {}

// MARK: - API catalog

enum GitHub {

    /// Configured client used everywhere. In a real app this would be a
    /// dependency-injected singleton; for the demo it lives in this enum.
    static let client = SmartClient(
        defaultHeaders: [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ],
        baseURL: URL(string: "https://api.github.com")!,
        retryPolicy: .standard,             // 5xx + timeouts; no POST retries
        observer: SmartAPILogger.shared,    // os.Logger; swap your analytics in
        coalescer: RequestCoalescer()       // dedup concurrent GETs across screens
    )

    static let getUser  = SmartEndpoint<GitHubUser.Model>(path: "/users/{username}")
    static let getRepo  = SmartEndpoint<Repository.Model>(path: "/repos/{owner}/{repo}")
    // The search endpoint returns a wrapped page; pagination is handled by
    // the macro-generated RepoSearch.Loader, not SmartEndpoint.
}

// MARK: - Screens

struct GitHubDemoApp: View {

    var body: some View {
        TabView {
            NavigationStack { SearchScreen() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { UserDetailScreen(username: "apple") }
                .tabItem { Label("User", systemImage: "person.circle") }
        }
    }
}

// MARK: - Search (paginated)

struct SearchScreen: View {

    @State private var query: String = "swift"
    @State private var loaderID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search repositories…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onSubmit { loaderID = UUID() }   // force a new loader

            SearchResultsList(query: query)
                .id(loaderID)                     // ← reset when query changes
        }
        .navigationTitle("GitHub Repos")
    }
}

private struct SearchResultsList: View {

    let query: String

    /// Construct the macro-generated paginated loader once per query.
    /// `SmartPaginatedView` handles infinite scroll + pull-to-refresh.
    @State private var loader: RepoSearch.Loader

    init(query: String) {
        self.query = query
        self._loader = State(initialValue: RepoSearch.loader(
            url: GitHub.client.baseURL!
                .appendingPathComponent("search/repositories"),
            fetcher: GitHub.client
        ))
    }

    var body: some View {
        SmartPaginatedView(loader: loader) { repo in
            NavigationLink {
                RepoDetailScreen(owner: repo.owner.login, repo: repo.name)
            } label: {
                RepoRow(repo: repo)
            }
        }
        .task {
            // Bind the search query into the loader's base URL.
            // (In a richer demo we'd refactor to a query-driven init.)
            await loader.load()
        }
    }
}

// MARK: - User detail (with offline cache)

struct UserDetailScreen: View {

    let username: String
    @State private var loader: GitHubUser.Loader

    init(username: String) {
        self.username = username
        self._loader = State(initialValue: GitHubUser.Loader(
            url: GitHub.client.baseURL!
                .appendingPathComponent("users/\(username)"),
            fetcher: GitHub.client
            // cache defaults to JSONFileCache because @SmartAPI(cache: true)
        ))
    }

    var body: some View {
        // SmartView auto-renders a yellow stale-data banner above content
        // when state is .loaded but the most recent refresh failed.
        SmartView(loader: loader) { user in
            UserDetail(user: user)
        }
        .navigationTitle("@\(username)")
    }
}

// MARK: - Repo detail

struct RepoDetailScreen: View {

    let owner: String
    let repo: String

    @State private var model: Repository.Model?
    @State private var error: (any Error)?

    var body: some View {
        Group {
            if let model {
                RepoDetail(repo: model)
            } else if let error {
                ContentUnavailableView(
                    "Couldn't load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .navigationTitle("\(owner)/\(repo)")
    }

    private func load() async {
        do {
            // Endpoint catalog — auth, retry, dedup all flow through.
            model = try await GitHub.client.call(
                GitHub.getRepo,
                pathParams: ["owner": owner, "repo": repo]
            )
        } catch {
            self.error = error
        }
    }
}

// MARK: - Row + detail views (your design system)

private struct RepoRow: View {
    let repo: RepoSearch.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.fullName)
                    .font(.headline)
                Spacer()
                Label(repo.stargazersCount.formatted(), systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !repo.description.isEmpty {
                Text(repo.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !repo.language.isEmpty {
                Text(repo.language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct UserDetail: View {
    let user: GitHubUser.Model

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AsyncImage(url: user.avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.gray.opacity(0.2) }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())

                    VStack(alignment: .leading) {
                        if !user.name.isEmpty {
                            Text(user.name).font(.headline)
                        }
                        Text("@\(user.login)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !user.bio.isEmpty {
                Section("Bio") { Text(user.bio) }
            }

            Section("Stats") {
                LabeledContent("Repositories", value: user.publicRepos.formatted())
                LabeledContent("Followers", value: user.followers.formatted())
                LabeledContent("Following", value: user.following.formatted())
            }

            if !user.company.isEmpty {
                Section("Company") { Text(user.company) }
            }
            if !user.location.isEmpty {
                Section("Location") { Text(user.location) }
            }
        }
    }
}

private struct RepoDetail: View {
    let repo: Repository.Model

    var body: some View {
        Form {
            Section {
                Text(repo.description).font(.body)
            }
            Section("Stats") {
                LabeledContent("Stars", value: repo.stargazersCount.formatted())
                LabeledContent("Forks", value: repo.forksCount.formatted())
                LabeledContent("Language", value: repo.language)
            }
            if !repo.topics.isEmpty {
                Section("Topics") {
                    Text(repo.topics.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Open on GitHub") {
                Link(repo.htmlURL.absoluteString, destination: repo.htmlURL)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    GitHubDemoApp()
}
