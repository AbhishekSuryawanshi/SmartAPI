import SwiftSyntax

/// Parsed form of the `@SmartAPI(...)` attribute. Produced by
/// `MacroArguments.parse(_:)`, consumed by the macro entry point.
struct MacroArguments {
    /// The JSON sample inlined into source.
    let sample: String

    /// Optional map from JSON key to property name; takes precedence over
    /// the default snake_case → camelCase heuristic.
    let renames: [String: String]

    /// When `true`, the generated `Loader` defaults to using a JSON-file
    /// cache so the app shows the last-seen response immediately on launch
    /// (before the network call completes).
    let cacheEnabled: Bool

    /// Which members the macro should generate (parse-only / display-only
    /// / full). Default `.full`.
    let scope: ScopeKind

    /// When `false`, the generated `Model` decodes missing or null fields
    /// by falling back to type-specific defaults rather than throwing.
    /// Use for APIs you don't fully trust to send the agreed shape.
    let strict: Bool

    /// When non-nil, the macro emits `Page` + `Model` (item) + a
    /// `PaginationStrategy` + `Loader` typealias instead of the default
    /// single-shot Loader. Default: nil (non-paginated).
    let pagination: PaginationConfigKind?
}

/// Mirror of `SmartAPIScope` for use inside the macro plugin. We can't
/// import the runtime module from a macro plugin target, so the cases
/// are duplicated here. Order and spelling must match `SmartAPIScope`.
enum ScopeKind: String {
    case parseOnly
    case displayOnly
    case full
}

/// Plugin-side mirror of `PaginationConfig`. Carries the values the user
/// wrote in `@SmartAPI(paginated: .cursor(...))` so codegen can emit the
/// matching `PaginationStrategy<Page, Item>` constant.
enum PaginationConfigKind {
    case cursor(items: String, nextCursor: String, hasMore: String?, cursorParam: String)
    case page(items: String, total: String?, pageParam: String, perPageParam: String, pageSize: Int, firstPage: Int)
    case offset(items: String, total: String?, offsetParam: String, limitParam: String, pageSize: Int)

    /// JSON key for the items array — common to all three strategies.
    /// Codegen looks this up in the sample to find the item type.
    var itemsKey: String {
        switch self {
        case .cursor(let items, _, _, _): return items
        case .page(let items, _, _, _, _, _): return items
        case .offset(let items, _, _, _, _): return items
        }
    }

    /// JSON key for the cursor field — only present in `.cursor` strategy.
    /// Codegen force-optionalizes this field on the `Page` wrapper so
    /// `"next_cursor": null` decodes cleanly on the last page.
    var cursorKey: String? {
        if case .cursor(_, let cursor, _, _) = self { return cursor }
        return nil
    }
}

extension MacroArguments {

    /// Parse and validate the labeled-argument list attached to an
    /// `@SmartAPI(...)` invocation. Throws a `MacroError` whose message
    /// surfaces directly in the developer's compile diagnostics.
    static func parse(_ node: AttributeSyntax) throws -> MacroArguments {
        guard let argList = node.arguments?.as(LabeledExprListSyntax.self) else {
            throw MacroError.message("@SmartAPI requires a `sample:` argument.")
        }

        var sample: String?
        var renames: [String: String] = [:]
        var cacheEnabled = false
        var scope: ScopeKind = .full
        var strict = true
        var pagination: PaginationConfigKind?
        for argument in argList {
            switch argument.label?.text {
            case "sample":
                sample = try StringLiteralExtractor.extract(argument.expression, argName: "sample")
            case "renames":
                renames = try StringDictionaryExtractor.extract(argument.expression, argName: "renames")
            case "cache":
                cacheEnabled = try BoolLiteralExtractor.extract(argument.expression, argName: "cache")
            case "scope":
                scope = try ScopeExtractor.extract(argument.expression, argName: "scope")
            case "strict":
                strict = try BoolLiteralExtractor.extract(argument.expression, argName: "strict")
            case "paginated":
                pagination = try PaginationConfigExtractor.extract(argument.expression, argName: "paginated")
            default:
                break
            }
        }

        guard let sample, !sample.isEmpty else {
            throw MacroError.message(
                "@SmartAPI requires a `sample:` argument with a JSON string literal. " +
                "(For samples stored as .json files, use the `smartapi-bundle` CLI to generate wrappers.)"
            )
        }
        return MacroArguments(
            sample: sample,
            renames: renames,
            cacheEnabled: cacheEnabled,
            scope: scope,
            strict: strict,
            pagination: pagination
        )
    }
}

/// Extracts `.parseOnly` / `.displayOnly` / `.full` from a member-access
/// expression. Rejects anything else so a typo surfaces at the call site
/// rather than silently falling back to a default.
enum ScopeExtractor {
    static func extract(_ expression: ExprSyntax, argName: String) throws -> ScopeKind {
        guard let memberAccess = expression.as(MemberAccessExprSyntax.self) else {
            throw MacroError.message(
                "@SmartAPI: `\(argName):` must be a `SmartAPIScope` case literal — " +
                "`.parseOnly`, `.displayOnly`, or `.full`."
            )
        }
        let caseName = memberAccess.declName.baseName.text
        guard let kind = ScopeKind(rawValue: caseName) else {
            throw MacroError.message(
                "@SmartAPI: unknown `\(argName):` value `.\(caseName)`. " +
                "Valid: `.parseOnly`, `.displayOnly`, `.full`."
            )
        }
        return kind
    }
}

/// Parses `.cursor(items:nextCursor:...)` / `.page(...)` / `.offset(...)`.
/// The user-facing expression is a `FunctionCallExpr` whose callee is a
/// `MemberAccessExpr` (the `.cursor` part); the argument list carries the
/// labeled values. Each value must be a string or integer literal — no
/// dynamic expressions.
enum PaginationConfigExtractor {
    static func extract(_ expression: ExprSyntax, argName: String) throws -> PaginationConfigKind {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self)
        else {
            throw MacroError.message(
                "@SmartAPI: `\(argName):` must be a `PaginationConfig` case — " +
                "`.cursor(items:, nextCursor:)`, `.page(items:)`, or `.offset(items:)`."
            )
        }
        let caseName = memberAccess.declName.baseName.text
        let args = call.arguments

        switch caseName {
        case "cursor":
            return .cursor(
                items: try requireString(args, label: "items", argName: argName),
                nextCursor: try requireString(args, label: "nextCursor", argName: argName),
                hasMore: try optionalString(args, label: "hasMore"),
                cursorParam: try optionalString(args, label: "cursorParam") ?? "cursor"
            )
        case "page":
            return .page(
                items: try requireString(args, label: "items", argName: argName),
                total: try optionalString(args, label: "total"),
                pageParam: try optionalString(args, label: "pageParam") ?? "page",
                perPageParam: try optionalString(args, label: "perPageParam") ?? "per_page",
                pageSize: try optionalInt(args, label: "pageSize") ?? 20,
                firstPage: try optionalInt(args, label: "firstPage") ?? 1
            )
        case "offset":
            return .offset(
                items: try requireString(args, label: "items", argName: argName),
                total: try optionalString(args, label: "total"),
                offsetParam: try optionalString(args, label: "offsetParam") ?? "offset",
                limitParam: try optionalString(args, label: "limitParam") ?? "limit",
                pageSize: try optionalInt(args, label: "pageSize") ?? 20
            )
        default:
            throw MacroError.message(
                "@SmartAPI: unknown pagination case `.\(caseName)`. " +
                "Valid: `.cursor`, `.page`, `.offset`."
            )
        }
    }

    // MARK: - Argument lookup helpers

    private static func argument(_ args: LabeledExprListSyntax, label: String) -> LabeledExprSyntax? {
        args.first { $0.label?.text == label }
    }

    private static func requireString(_ args: LabeledExprListSyntax, label: String, argName: String) throws -> String {
        guard let value = try optionalString(args, label: label) else {
            throw MacroError.message(
                "@SmartAPI: `\(argName)` requires `\(label):` as a string literal."
            )
        }
        return value
    }

    private static func optionalString(_ args: LabeledExprListSyntax, label: String) throws -> String? {
        guard let arg = argument(args, label: label) else { return nil }
        // `nil` literal → return Swift nil (the field stays unset).
        if arg.expression.is(NilLiteralExprSyntax.self) { return nil }
        return try StringLiteralExtractor.extract(arg.expression, argName: label)
    }

    private static func optionalInt(_ args: LabeledExprListSyntax, label: String) throws -> Int? {
        guard let arg = argument(args, label: label) else { return nil }
        guard let lit = arg.expression.as(IntegerLiteralExprSyntax.self),
              let value = Int(lit.literal.text) else {
            throw MacroError.message("@SmartAPI: `\(label):` must be an integer literal.")
        }
        return value
    }
}

// MARK: - Argument extractors

/// Extracts a Swift `String` from a `"..."` literal expression — the value
/// the macro sees at expansion time. Rejects interpolation so the JSON the
/// inference walks is exactly what the developer typed.
enum StringLiteralExtractor {
    static func extract(_ expression: ExprSyntax, argName: String) throws -> String {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            throw MacroError.message("@SmartAPI: `\(argName):` must be a string literal.")
        }
        var text = ""
        for segment in literal.segments {
            guard let staticSegment = segment.as(StringSegmentSyntax.self) else {
                throw MacroError.message(
                    "@SmartAPI: `\(argName):` cannot contain string interpolation. " +
                    "Use a literal JSON string."
                )
            }
            text += staticSegment.content.text
        }
        return text
    }
}

/// Extracts a `Bool` value from a `true` / `false` literal expression.
enum BoolLiteralExtractor {
    static func extract(_ expression: ExprSyntax, argName: String) throws -> Bool {
        guard let literal = expression.as(BooleanLiteralExprSyntax.self) else {
            throw MacroError.message("@SmartAPI: `\(argName):` must be a boolean literal (true or false).")
        }
        return literal.literal.text == "true"
    }
}

/// Extracts a `[String: String]` dictionary from a literal expression like
/// `["k": "v", ...]` or `[:]`. Used for the `renames:` parameter.
enum StringDictionaryExtractor {
    static func extract(_ expression: ExprSyntax, argName: String) throws -> [String: String] {
        guard let dictionary = expression.as(DictionaryExprSyntax.self) else {
            throw MacroError.message("@SmartAPI: `\(argName):` must be a `[String: String]` literal.")
        }
        var result: [String: String] = [:]
        if case .elements(let elements) = dictionary.content {
            for element in elements {
                let key = try StringLiteralExtractor.extract(element.key, argName: "\(argName) key")
                let value = try StringLiteralExtractor.extract(element.value, argName: "\(argName) value")
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - Attachment validation

/// Validates that the `@SmartAPI` macro is attached to a host type that can
/// usefully namespace generated members (an empty enum or struct).
enum AttachmentValidator {
    static func validate(_ declaration: some DeclGroupSyntax) throws {
        guard declaration.is(EnumDeclSyntax.self) || declaration.is(StructDeclSyntax.self) else {
            throw MacroError.message(
                "@SmartAPI must be attached to an empty `enum` or `struct` that acts as a namespace."
            )
        }
    }
}
