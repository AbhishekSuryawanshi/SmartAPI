import Foundation

/// Thread-safe box for a single value, guarded by an `NSLock`. Lets a
/// `Sendable` type hold mutable state without falling back to
/// `@unchecked Sendable` shenanigans and without requiring an actor's
/// async hop on every access.
///
/// Use when:
///   - The value is small and operations are short (millisecond range).
///   - You need synchronous read/write from arbitrary contexts.
///   - An actor would force callers to be `async` for no real benefit.
///
/// Don't use when:
///   - You need to perform long-running work under the lock — use an actor.
///   - Multiple correlated fields need atomic update — use a struct payload.
///
///     let counter = LockIsolated(0)
///     counter.withValue { $0 += 1 }
///     let snapshot = counter.value
public final class LockIsolated<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    public init(_ initial: Value) {
        self._value = initial
    }

    /// Atomically read the current value.
    public var value: Value {
        lock.withLock { _value }
    }

    /// Atomically read and mutate. The closure runs while the lock is held —
    /// keep it short and don't call back into another `LockIsolated` from
    /// inside (potential deadlock).
    @discardableResult
    public func withValue<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try operation(&_value) }
    }

    /// Atomically replace the value, returning the previous one.
    @discardableResult
    public func swap(_ newValue: Value) -> Value {
        lock.withLock {
            let previous = _value
            _value = newValue
            return previous
        }
    }
}
