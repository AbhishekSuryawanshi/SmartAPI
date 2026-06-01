import Foundation

/// Error raised when a generated `Mutator` is asked to perform an operation
/// it wasn't given a URL for at construction time.
public enum SmartAPIMutatorError: Error, CustomStringConvertible {
    case notConfigured(operation: Operation)

    /// Which CRUD verb the caller tried to invoke without configuring.
    public enum Operation: String, Sendable {
        case create, update, delete
    }

    public var description: String {
        switch self {
        case .notConfigured(let operation):
            return """
            SmartAPI: \(operation.rawValue.uppercased()) operation has no URL configured.
            Pass the matching URL when constructing the Mutator.
            """
        }
    }
}
