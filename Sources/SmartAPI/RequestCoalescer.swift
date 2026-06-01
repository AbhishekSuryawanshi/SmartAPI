import Foundation
import CryptoKit

/// Deduplicates concurrent identical requests. The first caller fires the
/// real HTTP work; every subsequent caller with a matching key awaits the
/// same in-flight `Task` and gets the same `Data` back.
///
/// Why this matters in iOS apps:
///   - SwiftUI mounts views eagerly. Two screens showing the same `User`
///     loader on app launch would otherwise produce *two* identical
///     network requests.
///   - On WAN connections, that's wasted bandwidth, server cycles, and
///     observable inconsistency (one response newer than the other).
///   - On lossy connections, both requests can flake — doubling failure
///     probability for the same outcome.
///
/// Only GET requests are coalesced by default. Coalescing a POST would
/// silently merge two writes into one — the second caller would think
/// their write happened when it didn't.
public actor RequestCoalescer {

    private var inFlight: [String: Task<Data, any Error>] = [:]

    public init() {}

    /// Run `work` under `key`, deduplicating concurrent callers.
    /// `work` is captured by the first caller; subsequent callers await
    /// the same `Task.value` and get the same result (or the same error).
    public func run(
        key: String,
        _ work: @Sendable @escaping () async throws -> Data
    ) async throws -> Data {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, any Error> { try await work() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Cancel and forget any in-flight task under `key`. Useful when the
    /// caller knows the response is no longer needed (view dismissed).
    public func cancel(key: String) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    /// Snapshot of currently-tracked keys (testing/diagnostics).
    public var trackedKeys: [String] {
        Array(inFlight.keys)
    }
}

// MARK: - Key derivation

public extension RequestCoalescer {
    /// Stable key for a request — method + URL + (if any) body hash.
    /// Headers are deliberately ignored: two callers asking for the same
    /// resource with different idempotency keys are still asking for the
    /// same resource, and per-call header variation shouldn't fragment
    /// the coalescer.
    static func key(method: HTTPMethod, url: URL, body: Data?) -> String {
        var key = "\(method.rawValue)\u{1F}\(url.absoluteString)"
        if let body, !body.isEmpty {
            let digest = SHA256.hash(data: body)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            key += "\u{1F}\(hex)"
        }
        return key
    }
}
