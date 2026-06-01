/// Pure-string utilities for turning JSON keys into idiomatic Swift names.
///
/// Has no dependency on Foundation or on any other inference machinery —
/// just `String`. That keeps the rules easy to read, easy to unit-test,
/// and easy to swap out wholesale if the project ever needs a different
/// naming policy.
enum FieldNaming {

    /// Acronyms that should be fully uppercased when they end a part of
    /// a snake_case identifier. Adding `"ABI"` here makes `"abi_version"`
    /// become `"ABIVersion"` after the next build.
    static let trailingAcronyms: Set<String> = [
        "URL", "ID", "API", "HTTP", "HTTPS", "JSON", "UUID", "GUID", "IP", "SSL"
    ]

    /// Convert `"avatar_url"` → `"avatarURL"`, `"user_id"` → `"userID"`.
    /// Splits on underscores **and** dashes (kebab-case keys like
    /// `"avatar-url"` are common in some specs).
    static func camelCase(from snake: String) -> String {
        let rawParts = snake.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(String.init)
        let parts = rawParts.isEmpty ? splitCamel(snake) : rawParts
        guard !parts.isEmpty else { return snake }

        var lowercasedParts = parts.map { $0.lowercased() }
        var result = lowercasedParts.removeFirst()
        for part in lowercasedParts {
            let upper = part.uppercased()
            if trailingAcronyms.contains(upper) {
                result += upper
            } else {
                result += part.prefix(1).uppercased() + part.dropFirst()
            }
        }
        return sanitizeIdentifier(result)
    }

    /// Convert `"avatar_url"` → `"AvatarURL"`, `"posts"` → `"Posts"`.
    static func pascalCase(from snakeOrCamel: String) -> String {
        let camel = camelCase(from: snakeOrCamel)
        guard let first = camel.first else { return camel }
        return String(first).uppercased() + camel.dropFirst()
    }

    /// Rough singularizer for nested-type names:
    /// `"posts"` → `"Post"`, `"addresses"` → `"Address"`, `"countries"` → `"country"`.
    static func singularize(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ses"), word.count > 3 { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), word.count > 1, !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// Make `identifier` a legal Swift identifier:
    ///   - empty input → `"value"` (cannot be empty)
    ///   - starts with a digit → prefixed with `_` (Swift identifiers can't
    ///     start with a number)
    ///   - reserved keyword → wrapped in backticks
    static func sanitizeIdentifier(_ identifier: String) -> String {
        guard let first = identifier.first else { return "value" }
        if first.isNumber { return "_\(identifier)" }
        if swiftReservedWords.contains(identifier) { return "`\(identifier)`" }
        return identifier
    }

    /// Swift keywords + a handful of common-method-name collisions
    /// (`description`, `type`) that would otherwise shadow synthesized
    /// `CustomStringConvertible` or metatype accessors.
    private static let swiftReservedWords: Set<String> = [
        "class", "struct", "enum", "func", "var", "let", "in", "for", "while",
        "if", "else", "return", "self", "Self", "true", "false", "nil",
        "case", "switch", "default", "where", "operator", "as", "is", "do",
        "throw", "throws", "try", "catch", "init", "deinit", "protocol",
        "extension", "import", "typealias", "associatedtype", "guard", "defer",
        "repeat", "static", "public", "private", "internal", "fileprivate",
        "open", "final", "lazy", "weak", "unowned", "rethrows", "type",
        "description"
    ]

    /// Split a camelCase or PascalCase string at uppercase boundaries:
    /// `"AvatarURL"` → `["Avatar", "URL"]`, `"isActive"` → `["is", "Active"]`.
    private static func splitCamel(_ identifier: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for (index, character) in identifier.enumerated() {
            if character.isUppercase, index != 0 {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
