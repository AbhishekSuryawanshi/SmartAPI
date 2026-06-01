import Foundation
import os

// MARK: - Observer protocol

/// Lifecycle events for SmartAPI runtime work. Generated `Loader`s,
/// `Mutator`s, and `SmartClient` itself call into the observer at every
/// meaningful step so callers can plug in analytics, structured logging,
/// or per-request tracing without modifying any macro output.
///
/// All methods have default implementations that do nothing — implementers
/// only override the events they care about.
///
///     struct DataDogObserver: SmartAPIObserver {
///         func loaderSucceeded(typeName: String, url: URL, latency: TimeInterval) {
///             Tracker.recordHTTP(typeName, url, latency)
///         }
///         func lenientDefaultUsed(typeName: String, field: String, reason: String) {
///             Tracker.recordWarning("api_drift", ["type": typeName, "field": field])
///         }
///     }
public protocol SmartAPIObserver: Sendable {

    // MARK: - Loader lifecycle
    func loaderStarted(typeName: String, url: URL)
    func loaderSucceeded(typeName: String, url: URL, latency: TimeInterval)
    func loaderFailed(typeName: String, url: URL, error: any Error)

    // MARK: - Mutator lifecycle
    func mutatorStarted(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL)
    func mutatorSucceeded(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, latency: TimeInterval)
    func mutatorFailed(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, error: any Error)

    // MARK: - HTTP lifecycle (fires for every SmartClient request)
    /// One failed attempt that the retry policy decided to retry.
    /// Visibility into flakiness — a screen that "succeeds" on attempt 3
    /// looks identical to one that worked first try without this.
    func requestRetried(url: URL, method: HTTPMethod, attempt: Int, error: any Error)

    /// A 401 caused an `AuthorizationProvider.refresh()` cycle.
    /// Fires regardless of whether the refresh succeeded.
    func authRefreshAttempted(url: URL)

    // MARK: - Cache lifecycle
    func cacheHit(typeName: String)
    func cacheWriteFailed(typeName: String, error: any Error)

    // MARK: - Decoder lifecycle (lenient mode only)
    /// A field was missing, null, or the wrong type — the lenient decoder
    /// substituted the type-specific default. Surfacing this is the
    /// difference between "lenient mode" and "silent data loss."
    func lenientDefaultUsed(typeName: String, field: String, reason: LenientReason)
}

public enum LenientReason: String, Sendable {
    case missing
    case null
    case wrongType
}

public extension SmartAPIObserver {
    func loaderStarted(typeName: String, url: URL) {}
    func loaderSucceeded(typeName: String, url: URL, latency: TimeInterval) {}
    func loaderFailed(typeName: String, url: URL, error: any Error) {}

    func mutatorStarted(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL) {}
    func mutatorSucceeded(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, latency: TimeInterval) {}
    func mutatorFailed(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, error: any Error) {}

    func requestRetried(url: URL, method: HTTPMethod, attempt: Int, error: any Error) {}
    func authRefreshAttempted(url: URL) {}

    func cacheHit(typeName: String) {}
    func cacheWriteFailed(typeName: String, error: any Error) {}

    func lenientDefaultUsed(typeName: String, field: String, reason: LenientReason) {}
}

// MARK: - SmartAPIContext

/// Per-task context for code that can't take an observer as a parameter
/// (notably `Codable`'s synthesized init paths). `SmartClient` populates
/// `observer` for the duration of each request so the generated lenient
/// init can surface decode-time anomalies through the same observer the
/// rest of the runtime uses.
public enum SmartAPIContext {
    @TaskLocal public static var observer: (any SmartAPIObserver)?
}

// MARK: - Default logger

/// Default observer used when callers don't supply their own. Routes every
/// event to a single `os.Logger`, which Console.app / structured-log
/// readers like Stream can ingest.
public struct SmartAPILogger: SmartAPIObserver {

    public static let shared = SmartAPILogger()

    public let logger: Logger

    public init(subsystem: String = "SmartAPI", category: String = "runtime") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    // Loader
    public func loaderStarted(typeName: String, url: URL) {
        logger.debug("\(typeName, privacy: .public) load started: \(url, privacy: .public)")
    }

    public func loaderSucceeded(typeName: String, url: URL, latency: TimeInterval) {
        logger.info("\(typeName, privacy: .public) loaded in \(latency * 1000, format: .fixed(precision: 1))ms")
    }

    public func loaderFailed(typeName: String, url: URL, error: any Error) {
        logger.error("\(typeName, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
    }

    // Mutator
    public func mutatorStarted(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL) {
        logger.debug("\(typeName, privacy: .public) \(operation.rawValue, privacy: .public) started: \(url, privacy: .public)")
    }

    public func mutatorSucceeded(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, latency: TimeInterval) {
        logger.info("\(typeName, privacy: .public) \(operation.rawValue, privacy: .public) ok in \(latency * 1000, format: .fixed(precision: 1))ms")
    }

    public func mutatorFailed(typeName: String, operation: SmartAPIMutatorError.Operation, url: URL, error: any Error) {
        logger.error("\(typeName, privacy: .public) \(operation.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    // HTTP
    public func requestRetried(url: URL, method: HTTPMethod, attempt: Int, error: any Error) {
        logger.warning("retry \(attempt + 1) for \(method.rawValue, privacy: .public) \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    public func authRefreshAttempted(url: URL) {
        logger.info("auth refresh triggered by 401 on \(url, privacy: .public)")
    }

    // Cache
    public func cacheHit(typeName: String) {
        logger.debug("\(typeName, privacy: .public) served from cache")
    }

    public func cacheWriteFailed(typeName: String, error: any Error) {
        logger.error("\(typeName, privacy: .public) cache write failed: \(error.localizedDescription, privacy: .public)")
    }

    // Decoder
    public func lenientDefaultUsed(typeName: String, field: String, reason: LenientReason) {
        logger.warning("\(typeName, privacy: .public).\(field, privacy: .public) defaulted (\(reason.rawValue, privacy: .public))")
    }
}
