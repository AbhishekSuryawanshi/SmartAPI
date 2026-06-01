// SmartAPI - public macro declarations.
//
// Usage:
//
//     @SmartAPI(sample: """
//     {
//       "id": 1,
//       "name": "Ada",
//       "avatar_url": "https://i.pravatar.cc/150",
//       "is_active": true,
//       "created_at": "2024-01-15T10:30:00Z"
//     }
//     """)
//     enum User {}
//
// Expands to:
//   - `User.Model` — Codable, Identifiable, Hashable, Sendable
//   - `User.View`  — a SwiftUI View rendering the model with smart per-field widgets
//   - `User.Loader` — @MainActor @Observable async loader (LoadState<Model>)
//   - sibling views for any nested object types

/// Attach to an empty `enum` (or `struct`) to generate a Codable model,
/// a SwiftUI view, and a `@MainActor @Observable` loader from a JSON sample.
///
/// Field types and view widgets are inferred from key names and value shapes:
///
///   - keys ending in `_url`, `_link`, `_href` → `URL`
///   - keys ending in `_at`, `_date`, ISO-8601 strings → `Date`
///   - `avatar`/`image`/`photo`/`thumbnail` URL fields → `AsyncImage`
///   - `bio`/`description`/`content`/`body` → multiline text
///   - bools → green checkmark / xmark
///   - arrays of objects → `NavigationLink` list
///
/// - Parameters:
///   - sample: A JSON string literal. Must parse as an object.
///   - renames: Optional map from JSON key to Swift property name. Overrides
///     the default snake_case → camelCase heuristic for the keys you list.
///     This is the seam where LLM-based naming tools plug in: an external
///     CLI calls an LLM, gets back better names, emits the dictionary
///     literal you paste here (or commits next to your source).
///
/// Example with renames:
///
///     @SmartAPI(
///         sample: "...",
///         renames: ["usr_nm": "userName", "ctr_cd": "countryCode"]
///     )
///     enum User {}
@attached(member, names: arbitrary)
public macro SmartAPI(
    sample: String,
    renames: [String: String] = [:],
    cache: Bool = false,
    scope: SmartAPIScope = .full,
    strict: Bool = true,
    paginated: PaginationConfig? = nil
) = #externalMacro(module: "SmartAPIMacros", type: "SmartAPIMacro")

// Note: A `sampleFile:` overload was deliberately *not* added here.
// Swift macro plugins run sandboxed and cannot read arbitrary files from
// disk reliably. The right pattern for "JSON sample on disk → inlined into
// source" is an external code-gen step that runs before the compiler — see
// the `smartapi-bundle` executable target, which scans your tree for
// `*.smartapi.json` files and emits the matching `*+SmartAPI.swift`
// wrappers you commit alongside.
