// Mode 1: Inline JSON sample
// ─────────────────────────────────────────────────────────────────────
// For most teams, most of the time. Paste a real API response into the
// macro, get a typed model + loader in three seconds. Update the sample
// when the API changes; the compiler tells you what to fix.

import SwiftUI
import SmartAPI

// MARK: - Generated from a real API response

// Paste an actual response from your API. The macro infers Swift types
// from the JSON: URL from "_url" / "_link", Date from ISO-8601 / "_at",
// Bool from true/false, snake_case → camelCase, nested objects become
// nested structs, arrays of objects produce their own item types.
//
// `scope: .parseOnly` means SmartAPI generates only the Model + Loader.
// No SwiftUI Form, no EditView, no Mutator — those would distract from
// the typed-API value if you already have your own design system.
@SmartAPI(sample: """
{
  "id": 42,
  "name": "Ada Lovelace",
  "username": "ada",
  "email": "ada@example.com",
  "avatar_url": "https://i.pravatar.cc/300?u=ada",
  "bio": "Mathematician and writer, chiefly known for her work on Babbage's proposed Analytical Engine.",
  "is_verified": true,
  "follower_count": 12453,
  "created_at": "2024-01-15T10:30:00Z",
  "homepage_url": "https://en.wikipedia.org/wiki/Ada_Lovelace",
  "address": {
    "street": "10 Downing St",
    "city": "London",
    "country_code": "GB"
  }
}
""", scope: .parseOnly)
enum User {}

// MARK: - Use it

@MainActor
func jsonSampleModeDemo() async {
    let loader = User.Loader(
        url: URL(string: "https://api.example.com/users/42")!
    )
    await loader.load()

    switch loader.state {
    case .loaded(let user):
        // Typed access: every field has the right Swift type.
        print(user.name)                        // String
        print(user.email)                       // String
        print(user.avatarURL.absoluteString)    // URL
        print(user.isVerified)                  // Bool
        print(user.followerCount)               // Int
        print(user.createdAt.timeIntervalSince1970)  // Date
        print(user.homepageURL)                 // URL
        print(user.address.city)                // nested struct
        print(user.address.countryCode)         // snake_case → camelCase
    case .failed(let error):
        print("Couldn't load:", error.localizedDescription)
    case .idle, .loading:
        break
    }
}

// MARK: - Bind to your existing SwiftUI views

// `.parseOnly` means SmartAPI doesn't ship a `User.View`. That's
// intentional — your designer already gave you a profile screen.
// SmartAPI's job is the typed model + the loader; the UI is yours.

struct ProfileScreen: View {
    let loader: User.Loader

    var body: some View {
        SmartView(loader: loader) { user in
            // Your custom view, bound to the typed Model.
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: user.avatarURL)
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())

                Text(user.name)
                    .font(.title)

                Text("@\(user.username)")
                    .foregroundStyle(.secondary)

                Text(user.bio)
                    .padding(.top, 4)

                Label(user.followerCount.formatted() + " followers",
                      systemImage: "person.2")
            }
            .padding()
        }
    }
}
