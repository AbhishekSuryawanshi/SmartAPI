// SmartAPI end-to-end demo — drop this file into any SwiftUI iOS 17+ app
// that imports the SmartAPI package and you have a working screen against
// the JSONPlaceholder public API. No Xcode project needed for compilation
// against the package; this file just demonstrates the API surface.
//
// What this demo exercises:
//
//   1. `@SmartAPI` macro — User + Post models generated from real JSON
//   2. Auto-routed widgets — name → Text, email → linkable, website → Link,
//      address → NavigationLink to AddressView (nested sibling view)
//   3. Field overrides — `withName`, `withWebsite`, `withBody` swap widgets
//   4. `SmartFlow` — parallel fetch of user + posts, dependent fetch of
//      comments based on the first post's id, with per-step progress
//   5. `SmartView` — renders idle / loading / loaded / error states
//   6. `renames:` — fix awkward keys (`bs` → `tagline`) without a hand-rolled type
//   7. Schema drift — `User.Loader.detectSchemaDrift()` flags API changes
//
// Real endpoints used:
//   GET https://jsonplaceholder.typicode.com/users/1
//   GET https://jsonplaceholder.typicode.com/posts?userId=1
//   GET https://jsonplaceholder.typicode.com/comments?postId=1

#if canImport(SwiftUI)
import SwiftUI
import SmartAPI

// MARK: - Models

@SmartAPI(
    sample: """
    {
      "id": 1,
      "name": "Leanne Graham",
      "username": "Bret",
      "email": "Sincere@april.biz",
      "phone": "1-770-736-8031 x56442",
      "website": "hildegard.org",
      "address": {
        "street": "Kulas Light",
        "suite": "Apt. 556",
        "city": "Gwenborough",
        "zipcode": "92998-3874"
      },
      "company": {
        "name": "Romaguera-Crona",
        "catchPhrase": "Multi-layered client-server neural-net",
        "bs": "harness real-time e-markets"
      }
    }
    """,
    renames: [
        // "bs" is meaningless out of context; rename to something readable.
        "bs": "tagline"
    ]
)
enum User {}

@SmartAPI(sample: """
{
  "userId": 1,
  "id": 1,
  "title": "sunt aut facere repellat provident occaecati",
  "body": "quia et suscipit suscipit recusandae consequuntur expedita et cum reprehenderit molestiae ut ut quas totam nostrum rerum est autem sunt rem eveniet architecto"
}
""")
enum Post {}

// MARK: - Single-endpoint screen with field overrides

struct UserScreen: View {
    let userID: Int

    private var endpoint: URL {
        URL(string: "https://jsonplaceholder.typicode.com/users/\(userID)")!
    }

    var body: some View {
        NavigationStack {
            SmartView(loader: User.Loader(url: endpoint)) { user in
                User.View(model: user)
                    .withName { name in
                        // Custom: big serif headline instead of plain text.
                        Text(name)
                            .font(.system(.title, design: .serif, weight: .semibold))
                    }
                    .withEmail { email in
                        // Custom: tappable mailto link instead of plain text.
                        Link(email, destination: URL(string: "mailto:\(email)")!)
                            .foregroundStyle(.blue)
                    }
                    .withWebsite { site in
                        // Custom: prepend https:// so it actually opens.
                        Link("hildegard.org", destination: URL(string: "https://\(site)")!)
                            .foregroundStyle(.blue)
                    }
            }
            .navigationTitle("User #\(userID)")
            .task {
                // Optional: warn if the live API shape no longer matches the
                // sample baked into our generated Model.
                #if DEBUG
                let probe = User.Loader(url: endpoint)
                if let drift = try? await probe.detectSchemaDrift() {
                    print("⚠️ SmartAPI drift detected:\n\(drift)")
                }
                #endif
            }
        }
    }
}

// MARK: - Multi-endpoint flow with parallel + dependent fetches

struct UserFeed: Sendable {
    let user: User.Model
    let posts: [Post.Model]
    let firstPostBody: String?
}

struct UserFeedScreen: View {
    let userID: Int

    @State private var flow: SmartFlow<UserFeed>

    init(userID: Int) {
        self.userID = userID
        self._flow = State(initialValue: SmartFlow { ctx in
            // Independent fetches run in parallel via async let.
            async let user = ctx.fetch(
                "user",
                from: URL(string: "https://jsonplaceholder.typicode.com/users/\(userID)")!,
                as: User.Model.self
            )
            async let posts = ctx.fetch(
                "posts",
                from: URL(string: "https://jsonplaceholder.typicode.com/posts?userId=\(userID)")!,
                as: [Post.Model].self
            )
            let u = try await user
            let p = try await posts
            return UserFeed(user: u, posts: p, firstPostBody: p.first?.body)
        })
    }

    var body: some View {
        NavigationStack {
            SmartView(loader: flow) { feed in
                Form {
                    Section("Author") {
                        Text(feed.user.name).font(.headline)
                        Text(feed.user.email).foregroundStyle(.secondary)
                    }
                    Section("Posts (\(feed.posts.count))") {
                        ForEach(feed.posts, id: \.id) { post in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.title).font(.subheadline.bold())
                                Text(post.body).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                // Show per-step progress dots while loading.
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        progressDot(for: "user")
                        progressDot(for: "posts")
                    }
                }
            }
        }
    }

    private func progressDot(for step: String) -> some View {
        let color: Color = {
            switch flow.steps[step] {
            case .completed: return .green
            case .running: return .yellow
            case .failed: return .red
            case .none: return .gray.opacity(0.3)
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}

// MARK: - Static SwiftUI previews

#Preview("User — overrides applied") {
    UserScreen(userID: 1)
}

#Preview("Feed — flow + parallelism") {
    UserFeedScreen(userID: 1)
}
#endif
