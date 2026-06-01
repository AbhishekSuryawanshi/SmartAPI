import Foundation

/// Parses a JSON sample and builds the inferred type tree (`InferredType`).
///
/// Single-purpose: no naming, no render hints, no code generation —
/// just "JSON shape → typed shape". Naming lives in `FieldNaming`,
/// render hints in `Heuristics`, JSON classification in `JSONValueKind`.
enum JSONInference {

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case notAnObject
        case invalidJSON(reason: String)

        var description: String {
            switch self {
            case .notAnObject:
                return "SmartAPI sample must be a JSON object (`{...}`)."
            case .invalidJSON(let reason):
                return "SmartAPI sample is not valid JSON: \(reason)"
            }
        }
    }

    // MARK: - Entry point

    /// Parse `sample` and return the inferred root object type.
    ///
    /// - Parameters:
    ///   - rootName: Type name for the root object node.
    ///   - sample: JSON string. Must parse as an object.
    ///   - renames: Optional explicit map from JSON key (at the root level
    ///     only) to desired Swift property name. Applied before the default
    ///     heuristic. This is the integration seam for LLM-driven naming —
    ///     an external tool emits the dict, the macro consumes it.
    static func infer(
        rootName: String,
        sample: String,
        renames: [String: String] = [:]
    ) throws -> InferredType {
        guard let data = sample.data(using: .utf8) else {
            throw Error.invalidJSON(reason: "sample is not UTF-8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw Error.invalidJSON(reason: error.localizedDescription)
        }
        guard let rootObject = parsed as? [String: Any] else {
            throw Error.notAnObject
        }
        return inferObject(typeName: rootName, dictionary: rootObject, renames: renames)
    }

    // MARK: - Recursive descent

    private static func inferObject(
        typeName: String,
        dictionary: [String: Any],
        renames: [String: String] = [:]
    ) -> InferredType {
        // Sort keys for stable codegen across runs.
        let fields: [InferredField] = dictionary.keys.sorted().map { key in
            let value = dictionary[key] as Any
            // Renames take precedence over the heuristic, when present.
            let propertyName = renames[key] ?? FieldNaming.camelCase(from: key)
            let type = inferValue(
                key: key,
                propertyName: propertyName,
                value: value,
                parentTypeName: typeName
            )
            let renderHint = Heuristics.renderHint(
                forKey: key,
                propertyName: propertyName,
                type: type
            )
            return InferredField(
                originalKey: key,
                propertyName: propertyName,
                type: type,
                renderHint: renderHint
            )
        }
        return .object(typeName: typeName, fields: fields)
    }

    private static func inferValue(
        key: String,
        propertyName: String,
        value: Any,
        parentTypeName: String
    ) -> InferredType {
        switch JSONValueKind(value) {
        case .string(let text):
            if Heuristics.looksLikeURL(key: key, value: text) { return .url }
            if Heuristics.looksLikeDate(key: key, value: text) { return .date }
            return .string

        case .bool:    return .bool
        case .int:     return .int
        case .double:  return .double

        case .array(let items):
            guard let first = items.first else { return .array(.unknown) }
            // First element wins. A real implementation would unify across
            // all elements; for the prototype this is acceptable.
            let elementName = FieldNaming.singularize(FieldNaming.pascalCase(from: propertyName))
            return .array(inferValue(
                key: key,
                propertyName: propertyName,
                value: first,
                parentTypeName: elementName
            ))

        case .object(let dictionary):
            return inferObject(
                typeName: FieldNaming.pascalCase(from: propertyName),
                dictionary: dictionary
            )

        case .null:
            return .unknown
        }
    }
}
