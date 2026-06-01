import Foundation

/// Runtime helpers for schema-drift detection. Generated `Model` types carry
/// a `schemaFingerprint` computed at macro-expansion time; this enum re-derives
/// the same fingerprint from a live JSON response so they can be compared.
public enum SmartAPISchema {

    /// Compute the structural fingerprint of arbitrary JSON. Stable: same
    /// shape → same string, regardless of value content.
    public static func fingerprint(of jsonData: Data) throws -> String {
        let value = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        return fingerprint(of: value)
    }

    static func fingerprint(of value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case is String:
            return "string"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            _ = number
            return "bool"
        case let number as NSNumber:
            return number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 ? "int" : "double"
        case let items as [Any]:
            guard let first = items.first else { return "[null]" }
            return "[\(fingerprint(of: first))]"
        case let dictionary as [String: Any]:
            let parts = dictionary.keys.sorted().map { key in
                "\"\(key)\":\(fingerprint(of: dictionary[key] ?? NSNull()))"
            }
            return "{\(parts.joined(separator: ","))}"
        default:
            return "unknown"
        }
    }
}

/// Drift report returned by `Loader.detectSchemaDrift()`.
public struct SmartAPISchemaDrift: Error, Sendable, CustomStringConvertible {
    public let expected: String
    public let actual: String

    public init(expected: String, actual: String) {
        self.expected = expected
        self.actual = actual
    }

    public var description: String {
        """
        SmartAPI schema drift:
          expected: \(expected)
          actual:   \(actual)

        The remote API has changed shape relative to the JSON sample used to
        generate this Model. Update the @SmartAPI sample and rebuild.
        """
    }
}
