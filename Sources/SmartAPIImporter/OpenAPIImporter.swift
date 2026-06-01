import Foundation

/// Imports an OpenAPI 3.0 JSON spec by walking `components.schemas` and
/// synthesizing a JSON sample for each one. The samples are wrapped in
/// `@SmartAPI(sample: ...)` and written as `*+SmartAPI.swift` files — at
/// which point the macro takes over and the user has a typed Model + View
/// + Loader + Mutator for every resource defined in the API.
///
/// Scope for the prototype:
///   ✓ `components.schemas` with `type`, `properties`, `items`, `$ref`, `format`, `enum`
///   ✓ Primitive types (string, integer, number, boolean), arrays, nested objects
///   ✓ Format-aware samples for `uri`, `date-time`, `uuid`
///   ✗ Composition (`allOf`, `oneOf`, `anyOf`) — picks the first branch where present
///   ✗ Schema-level paths, operations, security — schemas-only for v1
public enum OpenAPIImporter {

    public struct ImportedSchema: Equatable, Sendable {
        public let typeName: String   // PascalCase Swift type name
        public let swiftSource: String

        public init(typeName: String, swiftSource: String) {
            self.typeName = typeName
            self.swiftSource = swiftSource
        }
    }

    public enum ImporterError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case missingComponentsSchemas

        public var description: String {
            switch self {
            case .invalidJSON(let reason):
                return "OpenAPI spec is not valid JSON: \(reason)"
            case .missingComponentsSchemas:
                return "OpenAPI spec has no `components.schemas` — nothing to import."
            }
        }
    }

    /// Parse the spec and return one `ImportedSchema` per top-level schema.
    public static func importSchemas(from specData: Data) throws -> [ImportedSchema] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: specData)
        } catch {
            throw ImporterError.invalidJSON(error.localizedDescription)
        }
        guard
            let spec = parsed as? [String: Any],
            let components = spec["components"] as? [String: Any],
            let schemas = components["schemas"] as? [String: Any]
        else {
            throw ImporterError.missingComponentsSchemas
        }

        return try schemas
            .sorted { $0.key < $1.key }
            .compactMap { name, value in
                guard let schema = value as? [String: Any] else { return nil }
                return try renderSchema(name: name, schema: schema, allSchemas: schemas)
            }
    }

    // MARK: - Per-schema rendering

    private static func renderSchema(
        name: String,
        schema: [String: Any],
        allSchemas: [String: Any]
    ) throws -> ImportedSchema {
        let sample = synthesizeSample(for: schema, allSchemas: allSchemas, depth: 0)
        // Top-level samples must be objects for `@SmartAPI`; if the schema
        // is a non-object (rare for components.schemas), wrap it.
        let rootObject: Any = (sample is [String: Any]) ? sample : ["value": sample]
        let json = try jsonString(rootObject)
        let typeName = WrapperRenderer.pascalCase(name)
        let source = WrapperRenderer.renderSwiftWrapper(
            typeName: typeName,
            sourceFile: "openapi:\(name)",
            json: json
        )
        return ImportedSchema(typeName: typeName, swiftSource: source)
    }

    // MARK: - Sample synthesis

    private static let maxRecursionDepth = 5

    /// Build a placeholder JSON value matching the schema shape.
    /// Cycles between $refs are broken by depth-limiting.
    public static func synthesizeSample(
        for schema: [String: Any],
        allSchemas: [String: Any],
        depth: Int
    ) -> Any {
        guard depth < maxRecursionDepth else { return NSNull() }

        // Composition: take the first branch as the sample. Better than
        // bailing out, less right than unification — good enough for v1.
        for composition in ["allOf", "oneOf", "anyOf"] {
            if let arr = schema[composition] as? [[String: Any]], let first = arr.first {
                return synthesizeSample(for: first, allSchemas: allSchemas, depth: depth + 1)
            }
        }

        if let ref = schema["$ref"] as? String {
            let name = ref.split(separator: "/").last.map(String.init) ?? ""
            if let target = allSchemas[name] as? [String: Any] {
                return synthesizeSample(for: target, allSchemas: allSchemas, depth: depth + 1)
            }
            return NSNull()
        }

        if let enumValues = schema["enum"] as? [Any], let first = enumValues.first {
            return first
        }

        let type = (schema["type"] as? String) ?? "object"
        let format = schema["format"] as? String

        switch type {
        case "string":
            return samplePrimitive(stringFormat: format)
        case "integer":
            return 1
        case "number":
            return 1.5
        case "boolean":
            return true
        case "array":
            if let items = schema["items"] as? [String: Any] {
                return [synthesizeSample(for: items, allSchemas: allSchemas, depth: depth + 1)]
            }
            return [] as [Any]
        case "object":
            return synthesizeObject(schema: schema, allSchemas: allSchemas, depth: depth)
        default:
            return NSNull()
        }
    }

    private static func samplePrimitive(stringFormat: String?) -> String {
        switch stringFormat {
        case "date-time": return "2024-01-01T00:00:00Z"
        case "date":      return "2024-01-01"
        case "uri", "url": return "https://example.com"
        case "uuid":      return "00000000-0000-0000-0000-000000000000"
        case "email":     return "user@example.com"
        default:          return "example"
        }
    }

    private static func synthesizeObject(
        schema: [String: Any],
        allSchemas: [String: Any],
        depth: Int
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        if let properties = schema["properties"] as? [String: Any] {
            for (key, value) in properties {
                guard let propertySchema = value as? [String: Any] else { continue }
                result[key] = synthesizeSample(
                    for: propertySchema,
                    allSchemas: allSchemas,
                    depth: depth + 1
                )
            }
        }
        return result
    }

    // MARK: - JSON formatting

    private static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
