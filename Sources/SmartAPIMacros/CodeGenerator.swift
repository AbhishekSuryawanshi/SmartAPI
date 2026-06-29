import Foundation

/// Turns an `InferredType` tree into Swift source declarations that go
/// inside an `@SmartAPI`-attributed type. Emits:
///
///   - `struct Model: Codable, ...` (with nested object types inside)
///   - `struct View: View`
///   - sibling `<Foo>View` for each nested object type
///   - `@MainActor @Observable class Loader: SmartLoaderProtocol`
enum CodeGenerator {

    static func generate(
        root: InferredType,
        cacheEnabled: Bool = false,
        hostTypeName: String = "SmartAPIType",
        scope: ScopeKind = .full,
        strict: Bool = true,
        pagination: PaginationConfigKind? = nil
    ) -> [String] {
        guard case .object(_, let fields) = root else { return [] }

        // Paginated path forks completely — emits Page + Model (item) +
        // PaginationStrategy + Loader typealias + factory. The Model still
        // gets View/Draft/Mutator/EditView when scope requests them, but
        // those operate on individual items, not the page wrapper.
        if let pagination {
            return generatePaginated(
                wrapperFields: fields,
                pagination: pagination,
                hostTypeName: hostTypeName,
                scope: scope,
                strict: strict
            )
        }

        let fingerprint = root.fingerprint
        var sources: [String] = []

        // Always emitted — every scope needs the parsed types + the fetcher.
        sources.append(generateModel(
            typeName: "Model",
            fields: fields,
            schemaFingerprint: fingerprint,
            lenient: !strict
        ))
        sources.append(generateLoader(cacheEnabled: cacheEnabled, hostTypeName: hostTypeName))

        // Read-side UI — skipped for `.parseOnly`.
        if scope != .parseOnly {
            sources.append(generateView(typeName: "View", modelRef: "Model", fields: fields))
            // Sibling views for nested object types (referenced via `Model.<Name>`).
            for (typeName, nestedFields) in collectNestedObjects(in: fields) {
                sources.append(generateView(
                    typeName: "\(typeName)View",
                    modelRef: "Model.\(typeName)",
                    fields: nestedFields
                ))
            }
        }

        // Write-side surface (Draft + Mutator + EditView) — only `.full`.
        if scope == .full {
            sources.append(generateDraft(fields: fields))
            sources.append(generateMutator(hostTypeName: hostTypeName))
            sources.append(generateEditView(fields: fields))
        }
        return sources
    }

    // MARK: - Paginated branch

    private static func generatePaginated(
        wrapperFields: [InferredField],
        pagination: PaginationConfigKind,
        hostTypeName: String,
        scope: ScopeKind,
        strict: Bool
    ) -> [String] {
        // Find the field that carries the items array.
        guard let itemsField = wrapperFields.first(where: { $0.originalKey == pagination.itemsKey }) else {
            return ["#error(\"@SmartAPI(paginated:): items key `\(pagination.itemsKey)` not found in sample.\")"]
        }
        guard case .array(let elementType) = itemsField.type,
              case .object(_, let itemFields) = elementType else {
            return ["#error(\"@SmartAPI(paginated:): items key `\(pagination.itemsKey)` must point to an array of objects.\")"]
        }

        var sources: [String] = []

        // 1. The item type — what `Loader.items` returns.
        sources.append(generateModel(
            typeName: "Model",
            fields: itemFields,
            schemaFingerprint: nil,
            lenient: !strict
        ))

        // 2. The wrapper page — same shape as the sample, except the items
        //    field is `[Model]` (top-level reference, not a nested type)
        //    and the cursor field is *forced optional* because real APIs
        //    send `null` on the last page even if the sample doesn't show it.
        sources.append(generatePageWrapper(
            fields: wrapperFields,
            itemsKey: pagination.itemsKey,
            cursorKey: pagination.cursorKey,
            lenient: !strict
        ))

        // 3. The strategy constant + typealias + factory.
        sources.append(generatePaginationStrategy(
            pagination: pagination,
            wrapperFields: wrapperFields,
            hostTypeName: hostTypeName
        ))

        // 4. Item-level Views and CRUD when scope requests them — operate
        //    on a single `Model`, not the page.
        if scope != .parseOnly {
            sources.append(generateView(typeName: "View", modelRef: "Model", fields: itemFields))
            for (typeName, nestedFields) in collectNestedObjects(in: itemFields) {
                sources.append(generateView(
                    typeName: "\(typeName)View",
                    modelRef: "Model.\(typeName)",
                    fields: nestedFields
                ))
            }
        }
        if scope == .full {
            sources.append(generateDraft(fields: itemFields))
            sources.append(generateMutator(hostTypeName: hostTypeName))
            sources.append(generateEditView(fields: itemFields))
        }

        return sources
    }

    /// Emit the page wrapper struct. Same as `generateModel` except:
    ///   - the items-array field references the top-level `Model`
    ///   - the cursor field (if any) is force-optionalized so `null` on
    ///     the last page round-trips cleanly
    private static func generatePageWrapper(
        fields: [InferredField],
        itemsKey: String,
        cursorKey: String?,
        lenient: Bool
    ) -> String {
        func typeFor(_ field: InferredField) -> String {
            if field.originalKey == itemsKey { return "[Model]" }
            if field.originalKey == cursorKey { return "String?" }
            return pageWrapperFieldType(field.type)
        }

        var lines: [String] = []
        lines.append("public nonisolated struct Page: Codable, Hashable, Sendable {")

        // Properties.
        for field in fields {
            lines.append("    public let \(field.propertyName): \(typeFor(field))")
        }

        // Public memberwise init.
        lines.append("")
        let initParameters = fields
            .map { "\($0.propertyName): \(typeFor($0))" }
            .joined(separator: ", ")
        lines.append("    public init(\(initParameters)) {")
        for field in fields {
            lines.append("        self.\(field.propertyName) = \(field.propertyName)")
        }
        lines.append("    }")

        // CodingKeys — always needed; the items key often differs from the
        // Swift property name (e.g. `data` vs `data`, but `next_cursor` vs
        // `nextCursor` certainly does).
        lines.append("")
        lines.append("    enum CodingKeys: String, CodingKey {")
        for field in fields {
            if field.originalKey == field.propertyName {
                lines.append("        case \(field.propertyName)")
            } else {
                lines.append("        case \(field.propertyName) = \"\(field.originalKey)\"")
            }
        }
        lines.append("    }")

        // Lenient mode propagates to the page wrapper too.
        if lenient {
            lines.append("")
            lines.append(generatePageLenientInit(fields: fields, itemsKey: itemsKey, cursorKey: cursorKey))
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Like `field.type.swiftType` but for use inside the page wrapper:
    /// nested object types are not declared here (the Page only references
    /// types — it doesn't nest them), so we use the wrapper-level
    /// qualified name.
    private static func pageWrapperFieldType(_ type: InferredType) -> String {
        switch type {
        case .array(let element):
            // A non-items array — element type stays whatever inference said.
            return "[\(pageWrapperFieldType(element))]"
        case .object(let name, _):
            // Should be rare in a page wrapper, but in case the sample has
            // other nested objects alongside the items array, qualify them
            // under `Page.<Name>` so we don't collide with the item Model.
            return name
        default:
            return type.swiftType
        }
    }

    /// Lenient init(from:) for the page wrapper — fires `lenientDefaultUsed`
    /// observer events the same way the item Model does.
    private static func generatePageLenientInit(fields: [InferredField], itemsKey: String, cursorKey: String?) -> String {
        var lines: [String] = []
        lines.append("    public init(from decoder: any Decoder) throws {")
        lines.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
        for field in fields {
            let prop = field.propertyName
            let originalKey = field.originalKey
            let swiftType: String
            let fallback: String
            if field.originalKey == itemsKey {
                swiftType = "[Model]"
                fallback = "[]"
            } else if field.originalKey == cursorKey {
                swiftType = "String?"
                fallback = "nil"
            } else {
                swiftType = pageWrapperFieldType(field.type)
                fallback = lenientDefault(for: field.type)
            }
            lines.append("        if !container.contains(.\(prop)) {")
            lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"Page\", field: \"\(originalKey)\", reason: .missing)")
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        } else if (try? container.decodeNil(forKey: .\(prop))) == true {")
            // Null cursor is *expected* on the last page — don't spam the
            // observer about it. Other null fields are still surfaced.
            if field.originalKey != cursorKey {
                lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"Page\", field: \"\(originalKey)\", reason: .null)")
            }
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        } else if let value = try? container.decode(\(swiftType).self, forKey: .\(prop)) {")
            lines.append("            self.\(prop) = value")
            lines.append("        } else {")
            lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"Page\", field: \"\(originalKey)\", reason: .wrongType)")
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        }")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    /// Emit the static `PaginationStrategy<Page, Model>` + `Loader` typealias
    /// + `loader(url:)` / `loader(query:)` factories.
    ///
    /// The factories are `@MainActor` because they call `PaginatedLoader.init`,
    /// which is `@MainActor` (the loader holds observable state that
    /// SwiftUI reads). Callers must construct loaders from a MainActor
    /// context — same as `User.Loader(url:)` in the non-paginated case.
    private static func generatePaginationStrategy(
        pagination: PaginationConfigKind,
        wrapperFields: [InferredField],
        hostTypeName: String
    ) -> String {
        let strategyCall = strategyConstructorCall(pagination: pagination, wrapperFields: wrapperFields)
        return """
        public static let paginationStrategy: PaginationStrategy<Page, Model> = \(strategyCall)

        public typealias Loader = PaginatedLoader<Page, Model>

        @MainActor
        public static func loader(
            url: URL,
            fetcher: any \(RuntimeSymbols.fetcherProtocol) = \(RuntimeSymbols.defaultFetcher),
            observer: any SmartAPIObserver = SmartAPILogger.shared
        ) -> Loader {
            Loader(
                baseQuery: SmartQuery.get(url),
                strategy: paginationStrategy,
                fetcher: fetcher,
                observer: observer,
                typeName: "\(hostTypeName)"
            )
        }

        @MainActor
        public static func loader(
            query: SmartQuery,
            fetcher: any \(RuntimeSymbols.fetcherProtocol) = \(RuntimeSymbols.defaultFetcher),
            observer: any SmartAPIObserver = SmartAPILogger.shared
        ) -> Loader {
            Loader(
                baseQuery: query,
                strategy: paginationStrategy,
                fetcher: fetcher,
                observer: observer,
                typeName: "\(hostTypeName)"
            )
        }
        """
    }

    /// Build the right-hand-side expression for `PaginationStrategy.<case>(...)`
    /// with closures that read items / cursor / total from the typed `Page`.
    private static func strategyConstructorCall(
        pagination: PaginationConfigKind,
        wrapperFields: [InferredField]
    ) -> String {
        // Translate JSON keys → Swift property names on Page.
        func swiftName(forKey key: String) -> String {
            wrapperFields.first(where: { $0.originalKey == key })?.propertyName
                ?? FieldNaming.camelCase(from: key)
        }

        switch pagination {
        case .cursor(let items, let nextCursor, let hasMore, let cursorParam):
            let itemsExpr = "{ $0.\(swiftName(forKey: items)) }"
            let cursorExpr = "{ $0.\(swiftName(forKey: nextCursor)) }"
            let hasMoreLine: String
            if let hasMoreKey = hasMore {
                hasMoreLine = "hasMore: { $0.\(swiftName(forKey: hasMoreKey)) },\n            "
            } else {
                hasMoreLine = ""
            }
            return """
            PaginationStrategy<Page, Model>.cursor(
                items: \(itemsExpr),
                nextCursor: \(cursorExpr),
                \(hasMoreLine)cursorParam: \"\(cursorParam)\"
            )
            """

        case .page(let items, let total, let pageParam, let perPageParam, let pageSize, let firstPage):
            let itemsExpr = "{ $0.\(swiftName(forKey: items)) }"
            let totalLine: String
            if let totalKey = total {
                totalLine = "total: { $0.\(swiftName(forKey: totalKey)) },\n            "
            } else {
                totalLine = ""
            }
            return """
            PaginationStrategy<Page, Model>.page(
                items: \(itemsExpr),
                \(totalLine)pageParam: \"\(pageParam)\",
                perPageParam: \"\(perPageParam)\",
                pageSize: \(pageSize),
                firstPage: \(firstPage)
            )
            """

        case .offset(let items, let total, let offsetParam, let limitParam, let pageSize):
            let itemsExpr = "{ $0.\(swiftName(forKey: items)) }"
            let totalLine: String
            if let totalKey = total {
                totalLine = "total: { $0.\(swiftName(forKey: totalKey)) },\n            "
            } else {
                totalLine = ""
            }
            return """
            PaginationStrategy<Page, Model>.offset(
                items: \(itemsExpr),
                \(totalLine)offsetParam: \"\(offsetParam)\",
                limitParam: \"\(limitParam)\",
                pageSize: \(pageSize)
            )
            """
        }
    }

    // MARK: - Model

    private static func generateModel(
        typeName: String,
        fields: [InferredField],
        schemaFingerprint: String? = nil,
        lenient: Bool = false
    ) -> String {
        let needsIdentifiable = fields.contains { $0.propertyName == "id" }
        var conformances = ["Codable", "Hashable", "Sendable"]
        if needsIdentifiable { conformances.append("Identifiable") }

        var lines: [String] = []
        // `nonisolated` so the synthesized Codable/Sendable conformances stay
        // off the main actor even when the consumer compiles under Swift 6.2's
        // "main actor by default" mode (the new Xcode app-target default).
        // Without it, `PaginatedLoader<Page: Sendable>` and other generic
        // constraints reject the type's actor-isolated conformance.
        lines.append("public nonisolated struct \(typeName): \(conformances.joined(separator: ", ")) {")

        // Schema fingerprint — only emitted on the root model. Used at
        // runtime by `Loader.detectSchemaDrift()` to compare expected vs.
        // live response shape.
        if let fingerprint = schemaFingerprint {
            lines.append("    public static let schemaFingerprint: String = #\"\(fingerprint)\"#")
            lines.append("")
        }

        // Properties
        for field in fields {
            lines.append("    public let \(field.propertyName): \(field.type.swiftType)")
        }

        // Public memberwise init (synthesized one is internal).
        lines.append("")
        let initParameters = fields
            .map { "\($0.propertyName): \($0.type.swiftType)" }
            .joined(separator: ", ")
        lines.append("    public init(\(initParameters)) {")
        for field in fields {
            lines.append("        self.\(field.propertyName) = \(field.propertyName)")
        }
        lines.append("    }")

        // CodingKeys: always needed in lenient mode (custom init(from:)
        // dispatches on them); in strict mode only when JSON keys differ
        // from property names.
        let hasKeyMismatch = fields.contains { $0.originalKey != $0.propertyName }
        if lenient || hasKeyMismatch {
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey {")
            for field in fields {
                if field.originalKey == field.propertyName {
                    lines.append("        case \(field.propertyName)")
                } else {
                    lines.append("        case \(field.propertyName) = \"\(field.originalKey)\"")
                }
            }
            lines.append("    }")
        }

        // Lenient mode: emit a forgiving init(from:) + a defaultEmpty
        // static, used by parents when this type's key is missing entirely.
        if lenient {
            lines.append("")
            lines.append(generateLenientInit(typeName: typeName, fields: fields))
            lines.append("")
            lines.append(generateDefaultEmpty(typeName: typeName, fields: fields))
        }

        // Nested object types as members.
        for (nestedTypeName, nestedFields) in directNestedObjectTypes(in: fields) {
            lines.append("")
            // Nested types don't carry their own fingerprint — drift is a
            // root-level concept. They inherit `lenient` so the leniency
            // applies all the way down the tree.
            let nestedSource = generateModel(
                typeName: nestedTypeName,
                fields: nestedFields,
                schemaFingerprint: nil,
                lenient: lenient
            )
            lines.append(indentBlock(nestedSource, prefix: "    "))
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Lenient decoding

    /// Per-type fallback used when a field is missing / null. Lets the
    /// generated `Model` keep non-optional types while still surviving
    /// servers that drop or null-out fields.
    private static func lenientDefault(for type: InferredType) -> String {
        switch type {
        case .string:                return "\"\""
        case .int:                   return "0"
        case .double:                return "0.0"
        case .bool:                  return "false"
        case .url:                   return "URL(string: \"about:blank\")!"
        case .date:                  return "Date(timeIntervalSince1970: 0)"
        case .array:                 return "[]"
        case .object(let name, _):   return "\(name).defaultEmpty"
        case .unknown:               return "\"\""
        }
    }

    /// Emit a custom `init(from:)` that uses `decodeIfPresent` with the
    /// type-specific fallback for every field. Survives null / missing /
    /// wrong-shape fields without throwing — and surfaces every fallback
    /// through `SmartAPIContext.observer.lenientDefaultUsed(...)` so the
    /// developer can see exactly which keys their server is dropping.
    private static func generateLenientInit(typeName: String, fields: [InferredField]) -> String {
        var lines: [String] = []
        lines.append("    public init(from decoder: any Decoder) throws {")
        lines.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
        for field in fields {
            let prop = field.propertyName
            let originalKey = field.originalKey
            let swiftType = field.type.swiftType
            let fallback = lenientDefault(for: field.type)
            // Three failure modes to distinguish for the observer:
            //   missing  — key not in container
            //   null     — key present but JSON null
            //   wrongType — present, non-null, but wrong type for `T`
            // The fallback is the same in every case; only the reported
            // reason differs. `try?` collapses the typed decode into nil
            // so we don't throw; the observer surfaces *why*.
            lines.append("        if !container.contains(.\(prop)) {")
            lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"\(typeName)\", field: \"\(originalKey)\", reason: .missing)")
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        } else if (try? container.decodeNil(forKey: .\(prop))) == true {")
            lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"\(typeName)\", field: \"\(originalKey)\", reason: .null)")
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        } else if let value = try? container.decode(\(swiftType).self, forKey: .\(prop)) {")
            lines.append("            self.\(prop) = value")
            lines.append("        } else {")
            lines.append("            SmartAPIContext.observer?.lenientDefaultUsed(typeName: \"\(typeName)\", field: \"\(originalKey)\", reason: .wrongType)")
            lines.append("            self.\(prop) = \(fallback)")
            lines.append("        }")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    /// `Type.defaultEmpty` — used by lenient init when a nested-object field
    /// is missing entirely (the parent's `decodeIfPresent` returned nil).
    private static func generateDefaultEmpty(typeName: String, fields: [InferredField]) -> String {
        let args = fields
            .map { "\($0.propertyName): \(lenientDefault(for: $0.type))" }
            .joined(separator: ", ")
        return "    public static let defaultEmpty = \(typeName)(\(args))"
    }

    /// Direct (non-recursive into siblings) child object types of `fields`,
    /// preserving discovery order so codegen is stable.
    private static func directNestedObjectTypes(
        in fields: [InferredField]
    ) -> [(name: String, fields: [InferredField])] {
        var seenNames: Set<String> = []
        var result: [(name: String, fields: [InferredField])] = []
        for field in fields {
            collectDirect(field.type, into: &result, seen: &seenNames)
        }
        return result
    }

    private static func collectDirect(
        _ type: InferredType,
        into result: inout [(name: String, fields: [InferredField])],
        seen: inout Set<String>
    ) {
        switch type {
        case .object(let name, let fields):
            if seen.insert(name).inserted { result.append((name, fields)) }
        case .array(let element):
            collectDirect(element, into: &result, seen: &seen)
        default:
            break
        }
    }

    /// All nested object types in the entire tree (for sibling view generation).
    private static func collectNestedObjects(
        in fields: [InferredField]
    ) -> [(name: String, fields: [InferredField])] {
        var seenNames: Set<String> = []
        var result: [(name: String, fields: [InferredField])] = []
        func walk(_ type: InferredType) {
            switch type {
            case .object(let name, let nestedFields):
                if seenNames.insert(name).inserted {
                    result.append((name, nestedFields))
                }
                for field in nestedFields { walk(field.type) }
            case .array(let element):
                walk(element)
            default:
                break
            }
        }
        for field in fields { walk(field.type) }
        return result
    }

    // MARK: - View

    private static func generateView(
        typeName: String,
        modelRef: String,
        fields: [InferredField]
    ) -> String {
        var lines: [String] = []
        // Qualify the protocol so the nested type named `View` doesn't
        // self-conform. Requires the host file to `import SwiftUI`.
        lines.append("#if canImport(SwiftUI)")
        lines.append("public struct \(typeName): SwiftUI.View {")
        lines.append("    public let model: \(modelRef)")
        lines.append("    fileprivate var overrides = Overrides()")
        lines.append("")

        // Storage for per-field user overrides. AnyView erasure lets us hold
        // closures of differing concrete View types in a single value.
        lines.append("    fileprivate struct Overrides {")
        for field in fields {
            let valueType = overrideValueType(for: field)
            lines.append("        var \(field.propertyName): ((\(valueType)) -> AnyView)?")
        }
        lines.append("    }")
        lines.append("")

        lines.append("    public init(model: \(modelRef)) { self.model = model }")
        lines.append("")

        // Fluent `with<Field> { value in ... }` modifier per field.
        for field in fields {
            let valueType = overrideValueType(for: field)
            let methodName = withMethodName(for: field.propertyName)
            lines.append("    /// Override the default widget for `\(field.propertyName)`.")
            lines.append("    public func \(methodName)<Custom: SwiftUI.View>(@ViewBuilder _ build: @escaping (\(valueType)) -> Custom) -> Self {")
            lines.append("        var copy = self")
            lines.append("        copy.overrides.\(field.propertyName) = { value in AnyView(build(value)) }")
            lines.append("        return copy")
            lines.append("    }")
            lines.append("")
        }

        lines.append("    public var body: some SwiftUI.View {")
        lines.append("        Form {")

        for field in fields {
            lines.append(renderField(field, indent: "            "))
        }

        lines.append("        }")
        lines.append("        #if os(macOS)")
        lines.append("        .formStyle(.grouped)")
        lines.append("        #endif")
        lines.append("    }")
        lines.append("}")
        lines.append("#endif")
        return lines.joined(separator: "\n")
    }

    /// `"avatarURL"` → `"withAvatarURL"`. PascalCases the first character
    /// without lowering subsequent letters (so trailing acronyms survive).
    private static func withMethodName(for propertyName: String) -> String {
        "with" + propertyName.prefix(1).uppercased() + propertyName.dropFirst()
    }

    /// The Swift type the user's override closure receives for `field`.
    /// For arrays the closure gets one element at a time.
    private static func overrideValueType(for field: InferredField) -> String {
        switch field.renderHint {
        case .listOfPrimitive(let inner):
            return inner.swiftType
        case .listOfObject(let typeName):
            return "Model.\(typeName)"
        case .nestedObject(let typeName):
            return "Model.\(typeName)"
        default:
            return field.type.swiftType
        }
    }

    /// SwiftUI container that wraps a single field's row in the generated Form.
    private enum Container {
        case section(label: String)         // Section("label") { ... }
        case labeledContent(label: String)  // LabeledContent("label") { ... }

        var headExpression: String {
            switch self {
            case .section(let label):        return "Section(\"\(label)\")"
            case .labeledContent(let label): return "LabeledContent(\"\(label)\")"
            }
        }
    }

    /// Emit a container whose body conditionally falls back to `defaultBody`
    /// when the user hasn't supplied an override closure. Indents the body
    /// to sit at the right depth under the `else` branch.
    private static func renderInContainer(
        _ container: Container,
        overridePath: String,
        overrideArgument: String,
        defaultBody: String,
        indent: String
    ) -> String {
        let indentedDefaultBody = indentBlock(defaultBody, prefix: "\(indent)        ")
        return """
        \(indent)\(container.headExpression) {
        \(indent)    if let custom = \(overridePath) {
        \(indent)        custom(\(overrideArgument))
        \(indent)    } else {
        \(indentedDefaultBody)
        \(indent)    }
        \(indent)}
        """
    }

    /// Re-indent a multi-line snippet by prefixing every line.
    private static func indentBlock(_ body: String, prefix: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private static func renderField(_ field: InferredField, indent: String) -> String {
        let label = humanizeLabel(field.propertyName)
        let valuePath = "model.\(field.propertyName)"
        let overridePath = "overrides.\(field.propertyName)"

        switch field.renderHint {
        case .image:
            return renderInContainer(
                .section(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: """
                AsyncImage(url: \(valuePath)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("\(label)")
                """,
                indent: indent
            )

        case .longText:
            return renderInContainer(
                .section(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: """
                Text(\(valuePath))
                    .font(.body)
                    .multilineTextAlignment(.leading)
                """,
                indent: indent
            )

        case .relativeDate:
            return renderInContainer(
                .labeledContent(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: """
                Text(\(valuePath), format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                """,
                indent: indent
            )

        case .boolBadge:
            return renderInContainer(
                .labeledContent(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: """
                Image(systemName: \(valuePath) ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(\(valuePath) ? Color.green : Color.secondary)
                    .accessibilityLabel(\(valuePath) ? "Yes" : "No")
                """,
                indent: indent
            )

        case .linkable:
            return renderInContainer(
                .labeledContent(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: """
                Link(\(valuePath).absoluteString, destination: \(valuePath))
                    .lineLimit(1)
                    .truncationMode(.middle)
                """,
                indent: indent
            )

        case .listOfPrimitive:
            // The override gate goes inside ForEach; container is Section.
            let gateBlock = renderOverrideGate(
                overridePath: overridePath,
                overrideArgument: "item",
                defaultBody: "Text(\"\\(item)\")",
                indent: "\(indent)        "
            )
            return """
            \(indent)Section("\(label)") {
            \(indent)    ForEach(Array(\(valuePath).enumerated()), id: \\.offset) { _, item in
            \(gateBlock)
            \(indent)    }
            \(indent)}
            """

        case .listOfObject(let typeName):
            // Override replaces the row LABEL; navigation destination stays auto.
            let gateBlock = renderOverrideGate(
                overridePath: overridePath,
                overrideArgument: "item",
                defaultBody: "Text(\(RuntimeSymbols.rowLabel).preview(of: item))",
                indent: "\(indent)            "
            )
            return """
            \(indent)Section("\(label)") {
            \(indent)    ForEach(Array(\(valuePath).enumerated()), id: \\.offset) { _, item in
            \(indent)        NavigationLink {
            \(indent)            \(typeName)View(model: item)
            \(indent)        } label: {
            \(gateBlock)
            \(indent)        }
            \(indent)    }
            \(indent)}
            """

        case .nestedObject(let typeName):
            let gateBlock = renderOverrideGate(
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: "Text(\(RuntimeSymbols.rowLabel).preview(of: \(valuePath)))",
                indent: "\(indent)        "
            )
            return """
            \(indent)Section("\(label)") {
            \(indent)    NavigationLink {
            \(indent)        \(typeName)View(model: \(valuePath))
            \(indent)    } label: {
            \(gateBlock)
            \(indent)    }
            \(indent)}
            """

        case .plain:
            return renderInContainer(
                .labeledContent(label: label),
                overridePath: overridePath,
                overrideArgument: valuePath,
                defaultBody: plainDefaultBody(for: field.type, valuePath: valuePath),
                indent: indent
            )
        }
    }

    /// Just the `if let custom = ... else ...` gate without a surrounding
    /// container. Used by the list/nested cases that have their own wrapping.
    private static func renderOverrideGate(
        overridePath: String,
        overrideArgument: String,
        defaultBody: String,
        indent: String
    ) -> String {
        let indentedDefaultBody = indentBlock(defaultBody, prefix: "\(indent)    ")
        return """
        \(indent)if let custom = \(overridePath) {
        \(indent)    custom(\(overrideArgument))
        \(indent)} else {
        \(indentedDefaultBody)
        \(indent)}
        """
    }

    /// Default rendering body for `.plain` fields, varying by underlying type.
    private static func plainDefaultBody(for type: InferredType, valuePath: String) -> String {
        switch type {
        case .int, .double: return "Text(\"\\(\(valuePath))\")"
        case .string:       return "Text(\(valuePath))"
        default:            return "Text(String(describing: \(valuePath)))"
        }
    }

    /// Turn `"avatarURL"` → `"Avatar URL"`, `"createdAt"` → `"Created At"`.
    private static func humanizeLabel(_ propertyName: String) -> String {
        var result = ""
        var previousWasLowercase = false
        for character in propertyName {
            if character.isUppercase, previousWasLowercase {
                result.append(" ")
            }
            result.append(character)
            previousWasLowercase = character.isLowercase
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    // MARK: - Loader

    private static func generateLoader(cacheEnabled: Bool, hostTypeName: String) -> String {
        // When cache is enabled at the macro site, default the Loader's
        // cache parameter to a JSONFileCache namespaced by the host type
        // (e.g. `User.Model.json`, `Post.Model.json`). Without the host-name
        // prefix every cached `@SmartAPI` type would collide on a single
        // `Model.json` file.
        let defaultCache = cacheEnabled
            ? "JSONFileCache<Model>(name: \"\(hostTypeName).Model\")"
            : "nil"

        return """
        #if canImport(SwiftUI)
        @MainActor
        @Observable
        public final class Loader: \(RuntimeSymbols.loaderProtocol) {
            public var state: \(RuntimeSymbols.loadState)<Model> = .idle
            /// Description of the error from the last failed refresh, if any.
            /// Empty string means "no error / not attempted yet". Stored as
            /// non-optional `String` because stored optional `var`s in
            /// macro-emitted code trigger a missing init-expression linker
            /// error under Swift 6.3. Callers who need the typed error can
            /// install a `SmartAPIObserver`.
            public private(set) var lastRefreshErrorDescription: String = ""

            /// Full description of the request to make — verb, headers, body,
            /// and URL. For day-one GET usage just call `Loader(url:)`; for
            /// POST search / GraphQL / signed query params build a
            /// `SmartQuery` and call `Loader(query:)`.
            public let query: SmartQuery
            public let fetcher: any \(RuntimeSymbols.fetcherProtocol)
            public let cache: (any SmartCache<Model>)?

            /// Optional analytics/logging observer. Defaults to the shared
            /// `SmartAPILogger` which writes to `os.Logger`.
            public let observer: any SmartAPIObserver

            /// Convenience alias for `query.url` — kept so existing call sites
            /// that read `loader.url` keep compiling.
            public var url: URL { query.url }

            public init(
                query: SmartQuery,
                fetcher: any \(RuntimeSymbols.fetcherProtocol) = \(RuntimeSymbols.defaultFetcher),
                cache: (any SmartCache<Model>)? = \(defaultCache),
                observer: any SmartAPIObserver = SmartAPILogger.shared
            ) {
                self.query = query
                self.fetcher = fetcher
                self.cache = cache
                self.observer = observer
            }

            /// GET convenience — wraps the URL in a plain `SmartQuery.get`.
            public convenience init(
                url: URL,
                fetcher: any \(RuntimeSymbols.fetcherProtocol) = \(RuntimeSymbols.defaultFetcher),
                cache: (any SmartCache<Model>)? = \(defaultCache),
                observer: any SmartAPIObserver = SmartAPILogger.shared
            ) {
                self.init(
                    query: SmartQuery.get(url),
                    fetcher: fetcher,
                    cache: cache,
                    observer: observer
                )
            }

            /// Refresh `state` from cache (if any) and then from the network.
            ///
            /// Cancellation is delegated to the enclosing `Task`: SwiftUI's
            /// `.task` modifier cancels its child Task on view disappear,
            /// which propagates to the `await`s inside this method via
            /// `Task.isCancelled` / `CancellationError`. For non-SwiftUI
            /// callers, wrap the call in your own `Task` and cancel that.
            public func load() async {
                state = .loading
                lastRefreshErrorDescription = ""
                let startedAt = Date()
                observer.loaderStarted(typeName: "\(hostTypeName)", url: url)

                // 1. Hand the cached value to the UI immediately if we have one.
                if let cache, let cached = try? await cache.read() {
                    state = .loaded(cached)
                    observer.cacheHit(typeName: "\(hostTypeName)")
                }
                guard !Task.isCancelled else { return }

                // 2. Refresh from the network in the background. Uses the
                //    query path so POST + body + custom headers all work.
                do {
                    let fresh = try await fetcher.fetch(Model.self, via: query)
                    guard !Task.isCancelled else { return }
                    state = .loaded(fresh)
                    if let cache {
                        do {
                            try await cache.write(fresh)
                        } catch {
                            observer.cacheWriteFailed(typeName: "\(hostTypeName)", error: error)
                        }
                    }
                    observer.loaderSucceeded(
                        typeName: "\(hostTypeName)",
                        url: url,
                        latency: Date().timeIntervalSince(startedAt)
                    )
                } catch is CancellationError {
                    return
                } catch {
                    lastRefreshErrorDescription = error.localizedDescription
                    observer.loaderFailed(typeName: "\(hostTypeName)", url: url, error: error)
                    // If the cache already gave us something, keep showing it —
                    // the error is observable via `lastRefreshError`. Surface
                    // `.failed` only when there is nothing to show.
                    if case .loaded = state { return }
                    state = .failed(error)
                }
            }

            /// Fetch the live response and compare its structural shape to the
            /// fingerprint baked in at macro-expansion time. Returns `nil` if
            /// the shape matches; otherwise returns a drift report describing
            /// what changed. Recommended use: call this in DEBUG builds on
            /// app launch, log the drift, surface it to engineering.
            public func detectSchemaDrift() async throws -> \(RuntimeSymbols.schemaDrift)? {
                let data = try await fetcher.fetchRaw(via: query)
                let actual = try \(RuntimeSymbols.schema).fingerprint(of: data)
                if actual == Model.schemaFingerprint { return nil }
                return \(RuntimeSymbols.schemaDrift)(expected: Model.schemaFingerprint, actual: actual)
            }
        }
        #endif
        """
    }

    // MARK: - Draft (mutable companion to Model)

    /// Generates a mutable `Draft` mirror of `Model` plus `init(from:)` and
    /// `toModel()` so SwiftUI Forms can bind to per-field editors without
    /// the user having to define a separate edit-state type.
    private static func generateDraft(fields: [InferredField]) -> String {
        var lines: [String] = []
        lines.append("public struct Draft: Sendable {")
        for field in fields {
            lines.append("    public var \(field.propertyName): \(qualifiedSwiftType(field.type))")
        }
        lines.append("")
        lines.append("    public init(from model: Model) {")
        for field in fields {
            lines.append("        self.\(field.propertyName) = model.\(field.propertyName)")
        }
        lines.append("    }")
        lines.append("")
        let arguments = fields
            .map { "\($0.propertyName): \($0.propertyName)" }
            .joined(separator: ", ")
        lines.append("    public func toModel() -> Model {")
        lines.append("        Model(\(arguments))")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Return the Swift type spelling as seen *from outside* the Model
    /// namespace. Nested object types are qualified with `Model.` so siblings
    /// (Draft, EditView, sibling Views) can reference them correctly.
    private static func qualifiedSwiftType(_ type: InferredType) -> String {
        switch type {
        case .object(let name, _):
            return "Model.\(name)"
        case .array(let element):
            return "[\(qualifiedSwiftType(element))]"
        default:
            return type.swiftType
        }
    }

    // MARK: - Mutator

    /// Generates a `Mutator` value type that wraps the create / update /
    /// delete URLs and a `SmartFetching`. Each operation is optional —
    /// pass only the URLs the API supports; missing ones throw at call
    /// time so the type-level surface stays uniform across resources.
    private static func generateMutator(hostTypeName: String) -> String {
        return """
        public struct Mutator: Sendable {
            public let createURL: URL?
            public let updateURLBuilder: (@Sendable (Model) throws -> URL)?
            public let deleteURLBuilder: (@Sendable (Model) throws -> URL)?
            public let fetcher: any \(RuntimeSymbols.fetcherProtocol)
            public let observer: any SmartAPIObserver

            public init(
                createURL: URL? = nil,
                updateURL: (@Sendable (Model) throws -> URL)? = nil,
                deleteURL: (@Sendable (Model) throws -> URL)? = nil,
                fetcher: any \(RuntimeSymbols.fetcherProtocol) = \(RuntimeSymbols.defaultFetcher),
                observer: any SmartAPIObserver = SmartAPILogger.shared
            ) {
                self.createURL = createURL
                self.updateURLBuilder = updateURL
                self.deleteURLBuilder = deleteURL
                self.fetcher = fetcher
                self.observer = observer
            }

            public func create(_ model: Model) async throws -> Model {
                guard let url = createURL else {
                    throw \(RuntimeSymbols.mutatorError).notConfigured(operation: .create)
                }
                return try await observe(.create, url: url) {
                    try await fetcher.send(Model.self, to: url, method: .post, body: model)
                }
            }

            public func update(_ model: Model) async throws -> Model {
                guard let builder = updateURLBuilder else {
                    throw \(RuntimeSymbols.mutatorError).notConfigured(operation: .update)
                }
                let url = try builder(model)
                return try await observe(.update, url: url) {
                    try await fetcher.send(Model.self, to: url, method: .put, body: model)
                }
            }

            public func delete(_ model: Model) async throws {
                guard let builder = deleteURLBuilder else {
                    throw \(RuntimeSymbols.mutatorError).notConfigured(operation: .delete)
                }
                let url = try builder(model)
                _ = try await observe(.delete, url: url) {
                    try await fetcher.send(to: url, method: .delete)
                    return ()
                }
            }

            /// Wrap a mutation call with start/succeed/fail observer events
            /// and a latency measurement.
            private func observe<Value>(
                _ operation: \(RuntimeSymbols.mutatorError).Operation,
                url: URL,
                _ body: () async throws -> Value
            ) async throws -> Value {
                observer.mutatorStarted(typeName: "\(hostTypeName)", operation: operation, url: url)
                let startedAt = Date()
                do {
                    let value = try await body()
                    observer.mutatorSucceeded(
                        typeName: "\(hostTypeName)",
                        operation: operation,
                        url: url,
                        latency: Date().timeIntervalSince(startedAt)
                    )
                    return value
                } catch {
                    observer.mutatorFailed(
                        typeName: "\(hostTypeName)",
                        operation: operation,
                        url: url,
                        error: error
                    )
                    throw error
                }
            }
        }
        """
    }

    // MARK: - EditView

    /// Generates a SwiftUI `EditView` bound to a mutable `Draft`. Editable
    /// scalar fields (String/Int/Double/Bool/Date) get the appropriate
    /// SwiftUI input; URL / Array / Nested fields are shown read-only in
    /// v1 — keeping scope contained without sacrificing the common case.
    private static func generateEditView(fields: [InferredField]) -> String {
        var lines: [String] = []
        lines.append("#if canImport(SwiftUI)")
        lines.append("public struct EditView: SwiftUI.View {")
        lines.append("    public enum Mode: Sendable {")
        lines.append("        case creating")
        lines.append("        case updating(Model)")
        lines.append("    }")
        lines.append("")
        lines.append("    @State private var draft: Draft")
        lines.append("    @State private var isSaving = false")
        // Use non-optional String (empty = no error) to side-step the
        // Swift 6.3 macro/optional init-expression bug we hit on Loader.
        lines.append("    @State private var saveErrorDescription: String = \"\"")
        lines.append("    @Environment(\\.dismiss) private var dismiss")
        lines.append("")
        lines.append("    public let mode: Mode")
        lines.append("    public let mutator: Mutator")
        lines.append("    public let onSaved: (Model) -> Void")
        lines.append("    public let onDeleted: (@Sendable () -> Void)?")
        lines.append("")
        lines.append("    /// Create-mode initializer. Pass a starter `Draft` for the form.")
        lines.append("    public init(")
        lines.append("        creating draft: Draft,")
        lines.append("        mutator: Mutator,")
        lines.append("        onSaved: @escaping (Model) -> Void = { _ in }")
        lines.append("    ) {")
        lines.append("        self._draft = State(initialValue: draft)")
        lines.append("        self.mode = .creating")
        lines.append("        self.mutator = mutator")
        lines.append("        self.onSaved = onSaved")
        lines.append("        self.onDeleted = nil")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Update-mode initializer. Pass `onDeleted` to surface a Delete button.")
        lines.append("    public init(")
        lines.append("        editing model: Model,")
        lines.append("        mutator: Mutator,")
        lines.append("        onSaved: @escaping (Model) -> Void = { _ in },")
        lines.append("        onDeleted: (@Sendable () -> Void)? = nil")
        lines.append("    ) {")
        lines.append("        self._draft = State(initialValue: Draft(from: model))")
        lines.append("        self.mode = .updating(model)")
        lines.append("        self.mutator = mutator")
        lines.append("        self.onSaved = onSaved")
        lines.append("        self.onDeleted = onDeleted")
        lines.append("    }")
        lines.append("")
        lines.append("    public var body: some SwiftUI.View {")
        lines.append("        Form {")

        for field in fields {
            lines.append(renderEditField(field, indent: "            "))
        }

        lines.append("            if !saveErrorDescription.isEmpty {")
        lines.append("                Section {")
        lines.append("                    Text(saveErrorDescription)")
        lines.append("                        .foregroundStyle(.red)")
        lines.append("                }")
        lines.append("            }")
        lines.append("        }")
        lines.append("        #if os(macOS)")
        lines.append("        .formStyle(.grouped)")
        lines.append("        #endif")
        lines.append("        .disabled(isSaving)")
        lines.append("        .toolbar {")
        lines.append("            ToolbarItem(placement: .confirmationAction) {")
        lines.append("                Button(\"Save\") { Task { await save() } }")
        lines.append("                    .disabled(isSaving)")
        lines.append("            }")
        lines.append("            ToolbarItem(placement: .cancellationAction) {")
        lines.append("                Button(\"Cancel\") { dismiss() }")
        lines.append("                    .disabled(isSaving)")
        lines.append("            }")
        lines.append("            if case .updating = mode, onDeleted != nil {")
        lines.append("                ToolbarItem(placement: .destructiveAction) {")
        lines.append("                    Button(\"Delete\", role: .destructive) {")
        lines.append("                        Task { await delete() }")
        lines.append("                    }")
        lines.append("                    .disabled(isSaving)")
        lines.append("                }")
        lines.append("            }")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    private func save() async {")
        lines.append("        isSaving = true")
        lines.append("        saveErrorDescription = \"\"")
        lines.append("        do {")
        lines.append("            let saved: Model")
        lines.append("            switch mode {")
        lines.append("            case .creating:")
        lines.append("                saved = try await mutator.create(draft.toModel())")
        lines.append("            case .updating:")
        lines.append("                saved = try await mutator.update(draft.toModel())")
        lines.append("            }")
        lines.append("            onSaved(saved)")
        lines.append("            dismiss()")
        lines.append("        } catch {")
        lines.append("            saveErrorDescription = error.localizedDescription")
        lines.append("        }")
        lines.append("        isSaving = false")
        lines.append("    }")
        lines.append("")
        lines.append("    private func delete() async {")
        lines.append("        guard case .updating(let model) = mode else { return }")
        lines.append("        isSaving = true")
        lines.append("        saveErrorDescription = \"\"")
        lines.append("        do {")
        lines.append("            try await mutator.delete(model)")
        lines.append("            onDeleted?()")
        lines.append("            dismiss()")
        lines.append("        } catch {")
        lines.append("            saveErrorDescription = error.localizedDescription")
        lines.append("        }")
        lines.append("        isSaving = false")
        lines.append("    }")
        lines.append("}")
        lines.append("#endif")
        return lines.joined(separator: "\n")
    }

    /// Pick the SwiftUI editor for a Draft field.
    private static func renderEditField(_ field: InferredField, indent: String) -> String {
        let label = humanizeLabel(field.propertyName)
        let binding = "$draft.\(field.propertyName)"
        let valuePath = "draft.\(field.propertyName)"

        switch field.type {
        case .string:
            return "\(indent)TextField(\"\(label)\", text: \(binding))"

        case .int, .double:
            return "\(indent)TextField(\"\(label)\", value: \(binding), format: .number)"

        case .bool:
            return "\(indent)Toggle(\"\(label)\", isOn: \(binding))"

        case .date:
            return "\(indent)DatePicker(\"\(label)\", selection: \(binding))"

        case .url:
            // URLs are non-trivial to edit safely (validation, error reporting).
            // Show read-only for v1; future feature: a URLField wrapper that
            // bridges Binding<URL> ↔ Binding<String>.
            return "\(indent)LabeledContent(\"\(label)\", value: \(valuePath).absoluteString)"

        case .array(let element):
            return "\(indent)LabeledContent(\"\(label)\", value: \"\\(\(valuePath).count) \(element.swiftType.lowercased())\")"

        case .object:
            return "\(indent)LabeledContent(\"\(label)\", value: \(RuntimeSymbols.rowLabel).preview(of: \(valuePath)))"

        case .unknown:
            return "\(indent)LabeledContent(\"\(label)\", value: String(describing: \(valuePath)))"
        }
    }
}
