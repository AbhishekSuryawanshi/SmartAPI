import Foundation

/// Strategy for retrying failed requests. Applied automatically by every
/// `SmartClient` request unless the caller opts out.
///
/// The default `RetryPolicy.standard` retries transient failures (DNS,
/// timeouts, dropped connections, 5xx) up to 3 times with exponential
/// backoff. Permanent failures (404, 422, decode errors) are NOT retried
/// — the server told you the answer, retrying won't change it.
public struct RetryPolicy: Sendable {

    public let maxAttempts: Int
    public let backoff: Backoff

    /// Hard ceiling on cumulative backoff time. Without this, an exponential
    /// policy with `maxAttempts: 5` can block the caller for tens of
    /// seconds — which on iOS means a hung screen.
    public let maxTotalDelay: TimeInterval

    /// Predicate run on each error to decide whether to retry. Passed the
    /// underlying error, the attempt number (0-indexed), and the HTTP method
    /// — so the policy can refuse to retry non-idempotent methods (POST,
    /// PATCH) that risk creating duplicate side-effects.
    public let shouldRetry: @Sendable (any Error, Int, HTTPMethod) -> Bool

    public init(
        maxAttempts: Int,
        backoff: Backoff,
        maxTotalDelay: TimeInterval = 15,
        shouldRetry: @escaping @Sendable (any Error, Int, HTTPMethod) -> Bool
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff
        self.maxTotalDelay = max(0, maxTotalDelay)
        self.shouldRetry = shouldRetry
    }

    /// HTTP methods whose retries are *safe* to perform automatically.
    /// POST and PATCH typically have server-side side effects, so a
    /// well-behaved retry policy refuses them by default — let the caller
    /// opt in with idempotency keys when they want it.
    public static let idempotentMethods: Set<HTTPMethod> = [.get, .put, .delete]

    public enum Backoff: Sendable {
        case fixed(TimeInterval)
        case exponential(initial: TimeInterval, multiplier: Double, max: TimeInterval)

        /// Delay before attempt `attempt` (0-indexed). 0 means "don't wait".
        public func delay(for attempt: Int) -> TimeInterval {
            switch self {
            case .fixed(let interval):
                return attempt == 0 ? 0 : interval
            case .exponential(let initial, let multiplier, let cap):
                guard attempt > 0 else { return 0 }
                let raw = initial * pow(multiplier, Double(attempt - 1))
                return min(raw, cap)
            }
        }
    }

    // MARK: - Presets

    /// No retries — fail fast.
    public static let none = RetryPolicy(
        maxAttempts: 1,
        backoff: .fixed(0),
        shouldRetry: { _, _, _ in false }
    )

    /// 3 attempts, exponential backoff (0.5s → 1s → 2s capped at 5s),
    /// total budget 15s. Retries: URLError timeouts/connection errors and
    /// HTTP 5xx — and ONLY for idempotent methods (GET, PUT, DELETE).
    /// Does NOT retry: 4xx, decode errors, cancellation, POST, PATCH.
    public static let standard = RetryPolicy(
        maxAttempts: 3,
        backoff: .exponential(initial: 0.5, multiplier: 2.0, max: 5.0),
        maxTotalDelay: 15,
        shouldRetry: { error, _, method in
            guard idempotentMethods.contains(method) else { return false }
            return isTransient(error)
        }
    )

    /// Same backoff as `.standard` but also retries 429 rate-limit errors.
    /// Still refuses to retry non-idempotent methods — even rate-limit
    /// retries of a POST would risk duplicate writes.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        backoff: .exponential(initial: 0.5, multiplier: 2.0, max: 10.0),
        maxTotalDelay: 30,
        shouldRetry: { error, _, method in
            guard idempotentMethods.contains(method) else { return false }
            if isTransient(error) { return true }
            if case .badStatus(let code, _) = error as? SmartClientError, code == 429 {
                return true
            }
            return false
        }
    )

    /// Opt-in: retry everything including POST/PATCH. Use only when callers
    /// supply idempotency keys (e.g. via `SmartQuery.post(..., headers:
    /// ["Idempotency-Key": uuid])`). The name is intentionally explicit so
    /// it shows up in code review.
    public static let allowsUnsafeRetries = RetryPolicy(
        maxAttempts: 3,
        backoff: .exponential(initial: 0.5, multiplier: 2.0, max: 5.0),
        maxTotalDelay: 15,
        shouldRetry: { error, _, _ in isTransient(error) }
    )

    /// Default predicate for "transient failure worth retrying."
    public static func isTransient(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .cannotConnectToHost,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if case .badStatus(let code, _) = error as? SmartClientError,
           (500...599).contains(code) {
            return true
        }
        return false
    }
}
