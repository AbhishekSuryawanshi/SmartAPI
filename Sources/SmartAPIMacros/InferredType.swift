// Types describing what `JSONInference` learns from a JSON sample. Kept
// in their own file so the inference engine, naming utilities, and
// heuristics can evolve independently.

// MARK: - InferredType

/// A Swift type inferred from a JSON sample value.
indirect enum InferredType: Equatable {
    case string
    case url
    case date
    case int
    case double
    case bool
    case array(InferredType)
    /// An object that becomes a nested Codable struct.
    case object(typeName: String, fields: [InferredField])
    /// Sample had `null` at this position — we can't infer a concrete type.
    case unknown

    /// The Swift type spelling for this node, used in generated source.
    var swiftType: String {
        switch self {
        case .string: return "String"
        case .url: return "URL"
        case .date: return "Date"
        case .int: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        case .array(let element): return "[\(element.swiftType)]"
        case .object(let name, _): return name
        case .unknown: return "String"   // pragmatic default
        }
    }

    /// Structural fingerprint used for schema-drift detection. Collapses our
    /// inferred-Swift types back to underlying JSON kinds (URL/Date both
    /// ride `string`) so it matches what we can re-compute from a raw
    /// response at runtime via `SmartAPISchema.fingerprint(of:)`.
    var fingerprint: String {
        switch self {
        case .string, .url, .date: return "string"
        case .int: return "int"
        case .double: return "double"
        case .bool: return "bool"
        case .array(let element): return "[\(element.fingerprint)]"
        case .object(_, let fields):
            // Original (snake_case) keys, sorted for stability.
            let parts = fields
                .sorted { $0.originalKey < $1.originalKey }
                .map { "\"\($0.originalKey)\":\($0.type.fingerprint)" }
            return "{\(parts.joined(separator: ","))}"
        case .unknown: return "null"
        }
    }
}

// MARK: - InferredField

/// A single key/value pair within an inferred object.
struct InferredField: Equatable {
    /// Key as it appears in JSON, e.g. `"avatar_url"`.
    let originalKey: String

    /// Idiomatic Swift property name, e.g. `"avatarURL"`.
    let propertyName: String

    let type: InferredType
    let renderHint: RenderHint
}

// MARK: - RenderHint

/// How the generated view should render a field. The hint is determined
/// from the field's key and inferred type by `Heuristics`.
enum RenderHint: Equatable {
    case plain                            // Text("\(value)")
    case image                            // AsyncImage for URL fields with image-ish names
    case longText                         // Multi-line text (bio, description, ...)
    case relativeDate                     // Date with .relative formatter
    case boolBadge                        // Checkmark icon
    case linkable                         // Tappable URL (non-image)
    case listOfPrimitive(InferredType)
    case listOfObject(typeName: String)
    case nestedObject(typeName: String)
}
