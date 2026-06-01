/// Pattern-based detectors that pick a Swift type and a render hint from
/// a JSON key + sample value. Heuristics are intentionally simple so the
/// rules are obvious from reading; refinements (e.g. URL regex, RFC 3339
/// validators) can be layered on without changing the shape.
enum Heuristics {

    // MARK: - Type-hint detection

    /// Detect URL-shaped strings via key suffix or value prefix.
    static func looksLikeURL(key: String, value: String) -> Bool {
        let lowerKey = key.lowercased()
        if urlKeySuffixes.contains(where: { lowerKey.hasSuffix($0) }) { return true }
        return value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    /// Detect date-shaped strings via key suffix or an ISO-8601-ish prefix.
    static func looksLikeDate(key: String, value: String) -> Bool {
        let lowerKey = key.lowercased()
        if dateKeySuffixes.contains(where: { lowerKey.hasSuffix($0) }) { return true }
        if exactDateKeys.contains(lowerKey) { return true }
        return startsWithISODatePrefix(value)
    }

    // MARK: - Render-hint mapping

    /// Pick the SwiftUI rendering hint for a field, given its type and the
    /// shape of its key. Resolves the "what widget?" question once so codegen
    /// can stay declarative.
    static func renderHint(forKey key: String, propertyName: String, type: InferredType) -> RenderHint {
        let lowerKey = key.lowercased()

        switch type {
        case .url:
            return imageHints.contains(where: { lowerKey.contains($0) }) ? .image : .linkable

        case .date:
            return .relativeDate

        case .bool:
            return .boolBadge

        case .string:
            return longTextHints.contains(where: { lowerKey.contains($0) }) ? .longText : .plain

        case .array(let element):
            if case .object(let typeName, _) = element {
                return .listOfObject(typeName: typeName)
            }
            return .listOfPrimitive(element)

        case .object(let typeName, _):
            return .nestedObject(typeName: typeName)

        case .int, .double, .unknown:
            return .plain
        }
    }

    // MARK: - Rule tables

    private static let urlKeySuffixes = [
        "url", "_url", "link", "_link", "href", "src", "uri", "_uri"
    ]

    private static let dateKeySuffixes = ["_at", "_date", "_time", "_on"]

    private static let exactDateKeys: Set<String> = [
        "createdat", "updatedat", "deletedat", "timestamp"
    ]

    private static let imageHints = [
        "avatar", "image", "photo", "picture", "icon",
        "banner", "cover", "thumbnail", "thumb", "logo"
    ]

    private static let longTextHints = [
        "bio", "description", "content", "body", "summary",
        "about", "details", "notes", "message"
    ]

    // MARK: - Helpers

    /// `2024-01-15T...` or `2024-01-15` — first 10 chars are digits + dashes
    /// in `YYYY-MM-DD` shape.
    private static func startsWithISODatePrefix(_ value: String) -> Bool {
        guard value.count >= 10 else { return false }
        let prefix = value.prefix(10)
        return prefix.allSatisfy { $0.isNumber || $0 == "-" } && prefix.contains("-")
    }
}
