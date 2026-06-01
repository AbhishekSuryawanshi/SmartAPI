/// Controls which members `@SmartAPI` generates on the host type. Lets a
/// project that already has its own SwiftUI views — design system, custom
/// components, brand identity — opt out of the generated UI and use only
/// the typed parsing + fetching pieces.
///
///     // I already have UserProfileView — I just need the model + loader.
///     @SmartAPI(sample: "...", scope: .parseOnly)
///     enum User {}
///
/// | Scope          | Emits                                                |
/// |----------------|------------------------------------------------------|
/// | `.parseOnly`   | `Model`, `Loader`                                    |
/// | `.displayOnly` | `Model`, `Loader`, `View` (read-only)                |
/// | `.full`        | everything: also `Draft`, `Mutator`, `EditView`      |
public enum SmartAPIScope: Sendable {
    /// Parse + fetch only. No SwiftUI generated. Most production apps want
    /// this so they can bind the model to their existing views.
    case parseOnly

    /// Parse + fetch + read-only `View`. No mutation surface (`Draft`,
    /// `Mutator`, `EditView` aren't generated). For "I want the auto-view
    /// for browsing but I'll write my own create/edit flows."
    case displayOnly

    /// Everything: `Model`, `Loader`, `View`, `Draft`, `Mutator`, `EditView`.
    /// Default — matches the original `@SmartAPI` behavior so existing
    /// call sites stay unchanged.
    case full
}
