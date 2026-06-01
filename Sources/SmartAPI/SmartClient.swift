import Foundation

// MARK: - HTTPMethod

/// HTTP verb. An open struct rather than a closed enum so callers can
/// add custom methods (`OPTIONS`, `HEAD`, `SUBSCRIBE`) without forking
/// the package, while the common verbs stay typo-safe through the
/// `static let` constants.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }

    public static let get     = HTTPMethod(rawValue: "GET")
    public static let post    = HTTPMethod(rawValue: "POST")
    public static let put     = HTTPMethod(rawValue: "PUT")
    public static let patch   = HTTPMethod(rawValue: "PATCH")
    public static let delete  = HTTPMethod(rawValue: "DELETE")
    public static let head    = HTTPMethod(rawValue: "HEAD")
    public static let options = HTTPMethod(rawValue: "OPTIONS")
}

// MARK: - SmartFetching

/// Abstraction over "something that turns a `URL` into a decoded value,
/// and can also send writes back". Lets `SmartFlow`, generated `Loader`s,
/// generated `Mutator`s, and tests work against any implementation — real
/// HTTP, mocked-in-memory, recorded fixtures — without depending on
/// `SmartClient` directly.
///
/// The two `send` variants have default implementations that throw
/// `SmartFetchingError.unsupportedOperation`, so read-only fetchers
/// (test stubs that only need `fetch`/`fetchRaw`) can skip implementing
/// them without warnings.
public protocol SmartFetching: Sendable {
    /// Decode a Decodable response from `url` (GET).
    func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value

    /// Return the raw response bytes from `url`. Used by schema-drift
    /// detection, which fingerprints the response shape without decoding.
    func fetchRaw(from url: URL) async throws -> Data

    /// Decode a response from a fully-described `SmartQuery` (verb, headers,
    /// body). This is the path generated `Loader`s take so they support POST
    /// search, GraphQL, signed query parameters, etc.
    func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        via query: SmartQuery
    ) async throws -> Value

    /// Raw bytes from a `SmartQuery`. Used by schema-drift detection so it
    /// works against POST endpoints too.
    func fetchRaw(via query: SmartQuery) async throws -> Data

    /// Send a request with an encoded body and decode the response.
    /// Used by generated `Mutator.create(_:)` and `update(_:)`.
    func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        to url: URL,
        method: HTTPMethod,
        body: Body
    ) async throws -> Response

    /// Send a request with no body and discard the response.
    /// Used by generated `Mutator.delete(_:)`.
    func send(to url: URL, method: HTTPMethod) async throws
}

public extension SmartFetching {
    /// Default for read-only mock fetchers: fall back to the URL-only API
    /// when the query is a plain GET with no body or extra headers. Anything
    /// else throws so the failure is loud rather than silent.
    func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        via query: SmartQuery
    ) async throws -> Value {
        if query.method == .get, query.body == nil, query.headers.isEmpty {
            return try await fetch(type, from: query.url)
        }
        throw SmartFetchingError.unsupportedOperation(query.method)
    }

    func fetchRaw(via query: SmartQuery) async throws -> Data {
        if query.method == .get, query.body == nil, query.headers.isEmpty {
            return try await fetchRaw(from: query.url)
        }
        throw SmartFetchingError.unsupportedOperation(query.method)
    }

    func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        to url: URL,
        method: HTTPMethod,
        body: Body
    ) async throws -> Response {
        throw SmartFetchingError.unsupportedOperation(method)
    }

    func send(to url: URL, method: HTTPMethod) async throws {
        throw SmartFetchingError.unsupportedOperation(method)
    }
}

public enum SmartFetchingError: Error, CustomStringConvertible {
    case unsupportedOperation(HTTPMethod)

    public var description: String {
        switch self {
        case .unsupportedOperation(let method):
            return "This SmartFetching implementation does not support \(method.rawValue)."
        }
    }
}

// MARK: - SmartClient

/// Minimal HTTP client used by generated `*Loader` and `*Mutator` types.
/// Value type with immutable configuration: `let` everywhere, fully
/// `Sendable`, safe to share across actors without ceremony.
///
/// Customize by constructing your own instance and passing it to the loader:
///
///     let authed = SmartClient(defaultHeaders: ["Authorization": "Bearer ..."])
///     User.Loader(url: url, fetcher: authed)
///
/// `SmartClient.shared` is the default for the zero-config path.
public struct SmartClient: SmartFetching, Sendable {

    public let session: URLSession
    public let defaultHeaders: [String: String]
    public let defaultDecoder: JSONDecoder
    public let defaultEncoder: JSONEncoder
    public let authorization: any AuthorizationProvider
    public let baseURL: URL?
    public let retryPolicy: RetryPolicy
    public let observer: any SmartAPIObserver

    /// In-flight GET deduplication. Two concurrent calls to the same URL
    /// share one network request. Disabled by default (`nil`) for
    /// backward compatibility — opt in by passing a `RequestCoalescer()`.
    public let coalescer: RequestCoalescer?

    public init(
        session: URLSession = .shared,
        defaultHeaders: [String: String] = ["Accept": "application/json"],
        defaultDecoder: JSONDecoder? = nil,
        defaultEncoder: JSONEncoder? = nil,
        authorization: any AuthorizationProvider = NoAuthProvider(),
        baseURL: URL? = nil,
        retryPolicy: RetryPolicy = .standard,
        observer: any SmartAPIObserver = SmartAPILogger.shared,
        coalescer: RequestCoalescer? = nil
    ) {
        self.session = session
        self.defaultHeaders = defaultHeaders
        self.defaultDecoder = defaultDecoder ?? Self.makeDefaultDecoder()
        self.defaultEncoder = defaultEncoder ?? Self.makeDefaultEncoder()
        self.authorization = authorization
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
        self.observer = observer
        self.coalescer = coalescer
    }

    public static let shared = SmartClient()

    /// The decoder used when callers don't supply their own. ISO-8601 dates,
    /// other defaults left at Foundation's standard.
    public static func makeDefaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The encoder used when callers don't supply their own. ISO-8601 dates
    /// to match the decoder's default.
    public static func makeDefaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: SmartFetching

    public func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value {
        let data = try await fetchRaw(from: url)
        return try defaultDecoder.decode(Value.self, from: data)
    }

    public func fetchRaw(from url: URL) async throws -> Data {
        let req = request(for: url, method: .get)
        return try await dedupedRaw(req, method: .get, url: url, body: nil)
    }

    public func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        via query: SmartQuery
    ) async throws -> Value {
        let data = try await fetchRaw(via: query)
        return try defaultDecoder.decode(Value.self, from: data)
    }

    public func fetchRaw(via query: SmartQuery) async throws -> Data {
        let urlRequest = buildURLRequest(for: query)
        return try await dedupedRaw(urlRequest, method: query.method, url: query.url, body: query.body)
    }

    private func buildURLRequest(for query: SmartQuery) -> URLRequest {
        var urlRequest = URLRequest(url: query.url)
        urlRequest.httpMethod = query.method.rawValue
        for (key, value) in defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in query.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = query.body
        return urlRequest
    }

    /// Either run the request directly or hand it to the coalescer so
    /// concurrent identical GETs share one network round-trip.
    private func dedupedRaw(
        _ request: URLRequest,
        method: HTTPMethod,
        url: URL,
        body: Data?,
        retryPolicy: RetryPolicy? = nil
    ) async throws -> Data {
        // Only GET (or other idempotent reads) are eligible for coalescing.
        // POST/PUT/DELETE always go through directly.
        guard let coalescer, method == .get else {
            let (data, _) = try await perform(request, retryPolicy: retryPolicy)
            return data
        }
        let key = RequestCoalescer.key(method: method, url: url, body: body)
        return try await coalescer.run(key: key) { [self] in
            let (data, _) = try await perform(request, retryPolicy: retryPolicy)
            return data
        }
    }

    public func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        to url: URL,
        method: HTTPMethod,
        body: Body
    ) async throws -> Response {
        var built = request(for: url, method: method)
        built.setValue("application/json", forHTTPHeaderField: "Content-Type")
        built.httpBody = try defaultEncoder.encode(body)
        let (data, _) = try await perform(built)
        return try defaultDecoder.decode(Response.self, from: data)
    }

    public func send(to url: URL, method: HTTPMethod) async throws {
        _ = try await perform(request(for: url, method: method))
    }

    // MARK: - Plumbing

    private func request(for url: URL, method: HTTPMethod) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Run `request` with the configured retry policy + 401 refresh + the
    /// `SmartAPIContext.observer` set to our `observer` for the duration —
    /// so generated lenient `init(from:)` paths can surface decode-time
    /// anomalies through the same observer used elsewhere.
    ///
    /// The retry loop respects three guards:
    ///   1. `maxAttempts` — total tries allowed
    ///   2. `maxTotalDelay` — cumulative backoff budget (defends against
    ///       a hung UI when stacking long exponential delays)
    ///   3. `shouldRetry(error, attempt, method)` — the policy's predicate,
    ///       which by default refuses to retry non-idempotent methods.
    private func perform(
        _ request: URLRequest,
        retryPolicy override: RetryPolicy? = nil
    ) async throws -> (Data, URLResponse) {
        try await SmartAPIContext.$observer.withValue(observer) {
            try await performWithRetries(request, policy: override ?? retryPolicy)
        }
    }

    private func performWithRetries(
        _ request: URLRequest,
        policy: RetryPolicy
    ) async throws -> (Data, URLResponse) {
        let method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        let url = request.url ?? URL(fileURLWithPath: "/")
        var lastError: any Error = SmartClientError.badStatus(0, data: Data())
        var totalDelayElapsed: TimeInterval = 0

        for attempt in 0..<policy.maxAttempts {
            let delay = policy.backoff.delay(for: attempt)
            if delay > 0 {
                guard totalDelayElapsed + delay <= policy.maxTotalDelay else { break }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                totalDelayElapsed += delay
            }
            do {
                return try await performOnce(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let isLastAttempt = attempt + 1 >= policy.maxAttempts
                if isLastAttempt || !policy.shouldRetry(error, attempt, method) {
                    throw error
                }
                // We're going to retry — surface the failed attempt so
                // analytics can count flakiness.
                observer.requestRetried(url: url, method: method, attempt: attempt, error: error)
            }
        }
        throw lastError
    }

    /// One attempt: attach auth, run the request, retry once on 401 refresh.
    private func performOnce(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var authedRequest = request
        if let header = try await authorization.currentHeader() {
            authedRequest.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: authedRequest)
        guard let http = response as? HTTPURLResponse else { return (data, response) }

        if http.statusCode == 401 {
            let url = request.url ?? URL(fileURLWithPath: "/")
            observer.authRefreshAttempted(url: url)
            // One-shot 401 refresh — independent of the retry-policy loop.
            if let refreshed = try await authorization.refresh() {
                var retried = request
                retried.setValue(refreshed, forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await session.data(for: retried)
                if let retryHTTP = retryResponse as? HTTPURLResponse,
                   !(200..<300).contains(retryHTTP.statusCode) {
                    throw SmartClientError.badStatus(retryHTTP.statusCode, data: retryData)
                }
                return (retryData, retryResponse)
            }
        }

        if !(200..<300).contains(http.statusCode) {
            throw SmartClientError.badStatus(http.statusCode, data: data)
        }
        return (data, response)
    }
}

// MARK: - SmartEndpoint integration

public extension SmartClient {

    /// Call an endpoint that has no request body — typically GET or DELETE.
    /// Path placeholders in the endpoint's template are substituted from
    /// `pathParams`. Query items are appended to the URL.
    ///
    /// - Parameter retryPolicy: Override the client's default retry policy
    ///   for just this call. Useful for endpoints that should *never*
    ///   retry (audit logs, legally-sensitive writes) without spinning up
    ///   a separate client.
    func call<Response>(
        _ endpoint: SmartEndpoint<Response>,
        pathParams: [String: String] = [:],
        queryParams: [URLQueryItem] = [],
        headers: [String: String] = [:],
        retryPolicy: RetryPolicy? = nil
    ) async throws -> Response {
        let url = try endpoint.buildURL(
            baseURL: baseURL,
            pathParams: pathParams,
            queryParams: queryParams
        )
        let query = SmartQuery(url: url, method: endpoint.method, headers: headers, body: nil)
        if Response.self == Empty.self {
            _ = try await fetchRaw(via: query, retryPolicy: retryPolicy)
            return Empty() as! Response
        }
        return try await fetch(Response.self, via: query, retryPolicy: retryPolicy)
    }

    /// Call an endpoint with a typed Encodable body — typically POST / PUT / PATCH.
    func call<Response, Body: Encodable & Sendable>(
        _ endpoint: SmartEndpoint<Response>,
        pathParams: [String: String] = [:],
        queryParams: [URLQueryItem] = [],
        body: Body,
        headers: [String: String] = [:],
        retryPolicy: RetryPolicy? = nil
    ) async throws -> Response {
        let url = try endpoint.buildURL(
            baseURL: baseURL,
            pathParams: pathParams,
            queryParams: queryParams
        )
        let bodyData = try defaultEncoder.encode(body)
        var mergedHeaders = headers
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json"
        }
        let query = SmartQuery(
            url: url,
            method: endpoint.method,
            headers: mergedHeaders,
            body: bodyData
        )
        if Response.self == Empty.self {
            _ = try await fetchRaw(via: query, retryPolicy: retryPolicy)
            return Empty() as! Response
        }
        return try await fetch(Response.self, via: query, retryPolicy: retryPolicy)
    }

    // MARK: - via:retryPolicy: overloads on the public via: API

    func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        via query: SmartQuery,
        retryPolicy: RetryPolicy?
    ) async throws -> Value {
        let data = try await fetchRaw(via: query, retryPolicy: retryPolicy)
        return try defaultDecoder.decode(Value.self, from: data)
    }

    func fetchRaw(via query: SmartQuery, retryPolicy: RetryPolicy?) async throws -> Data {
        let urlRequest = buildURLRequest(for: query)
        return try await dedupedRaw(
            urlRequest,
            method: query.method,
            url: query.url,
            body: query.body,
            retryPolicy: retryPolicy
        )
    }
}

// MARK: - SmartClientError

/// Error raised when `SmartClient` receives a non-2xx response.
///
/// Important: the response `data` is kept on the case payload so callers
/// who need it can decode it themselves (e.g. an API-specific error
/// envelope). The default `description` deliberately does **not** dump the
/// body — response bodies routinely contain access tokens, refresh tokens,
/// PII, and other things that should not land in unstructured logs or
/// crash reports.
///
/// If you want the body in a development build, decode `data` explicitly:
///
///     do { _ = try await client.fetch(...) } catch let error as SmartClientError {
///         #if DEBUG
///         if case .badStatus(_, let data) = error,
///            let text = String(data: data, encoding: .utf8) {
///             print(text)
///         }
///         #endif
///     }
public enum SmartClientError: Error, CustomStringConvertible {
    case badStatus(Int, data: Data)

    public var description: String {
        switch self {
        case .badStatus(let code, let data):
            return "HTTP \(code) (\(data.count) bytes)"
        }
    }
}
