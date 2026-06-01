import Foundation

/// Single-pass classification of `Foundation.JSONSerialization` output.
/// Replaces the cascading `if let _ = value as? X` chain callers would
/// otherwise write, and makes the underlying JSON kinds explicit.
///
/// `NSNumber` requires special handling because it bridges to both `Bool`
/// and the integer/floating types — we use `CFGetTypeID` to detect the
/// boolean case, then check for an integer-valued double to decide
/// between `.int` and `.double`.
enum JSONValueKind {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([Any])
    case object([String: Any])
    case null

    init(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let text as String:
            self = .string(text)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            let asDouble = number.doubleValue
            self = asDouble.truncatingRemainder(dividingBy: 1) == 0
                ? .int(number.intValue)
                : .double(asDouble)
        case let items as [Any]:
            self = .array(items)
        case let dictionary as [String: Any]:
            self = .object(dictionary)
        default:
            self = .null
        }
    }
}
