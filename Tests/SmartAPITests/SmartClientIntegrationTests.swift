import XCTest
@testable import SmartAPI

/// End-to-end tests that exercise the real `SmartClient` code paths —
/// retry loop, 401-refresh, request coalescer, lenient observer pipeline —
/// against a mocked `URLSession` rather than a fake `SmartFetching` stub.
///
/// These are the tests that verify the framework actually does what
/// `RetryPolicy.standard` claims to do.
@MainActor
final class SmartClientIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: - Retry

    func testStandardPolicyRetriesGETOnFifthHundred() async throws {
        let payload = Data(#"{"value":"ok"}"#.utf8)
        MockURLProtocol.script.enqueue(.success(status: 503, body: Data()))
        MockURLProtocol.script.enqueue(.success(status: 200, body: payload))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                backoff: .fixed(0),  // no sleep in tests
                maxTotalDelay: 0,
                shouldRetry: { error, _, method in
                    RetryPolicy.idempotentMethods.contains(method)
                        && RetryPolicy.isTransient(error)
                }
            ),
            observer: SilentObserver()
        )
        let data = try await client.fetchRaw(from: URL(string: "https://example.com/r")!)
        XCTAssertEqual(data, payload)
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 2,
                       "503 should be retried; second attempt should succeed")
    }

    func testStandardPolicyDoesNotRetryPOST() async {
        // Two scripted 503s. Standard policy refuses to retry POST, so
        // we expect only ONE attempt + a thrown error.
        MockURLProtocol.script.enqueue(.success(status: 503, body: Data()))
        MockURLProtocol.script.enqueue(.success(status: 200, body: Data("late".utf8)))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .standard,
            observer: SilentObserver()
        )
        let query = SmartQuery(url: URL(string: "https://example.com/post")!, method: .post, body: Data("{}".utf8))
        do {
            _ = try await client.fetchRaw(via: query)
            XCTFail("expected throw")
        } catch let error as SmartClientError {
            guard case .badStatus(503, _) = error else {
                XCTFail("expected 503, got \(error)"); return
            }
            XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 1,
                           "POST must NOT be auto-retried")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRetryStopsWhenTotalDelayExceeded() async {
        // 5 transient errors scripted, max total delay 0.01s, each backoff 0.1s.
        // Only the first attempt should run; subsequent backoff would exceed budget.
        for _ in 0..<5 {
            MockURLProtocol.script.enqueue(.success(status: 503, body: Data()))
        }
        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: RetryPolicy(
                maxAttempts: 5,
                backoff: .fixed(0.1),
                maxTotalDelay: 0.01,
                shouldRetry: { _, _, _ in true }
            ),
            observer: SilentObserver()
        )
        do {
            _ = try await client.fetchRaw(from: URL(string: "https://example.com/x")!)
            XCTFail("expected throw")
        } catch {
            // Initial attempt runs without delay; the first retry's 0.1s
            // delay exceeds the 0.01s budget, so retries stop.
            XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 1,
                           "total-delay cap should abort the retry loop early")
        }
    }

    // MARK: - 401 → refresh → retry

    func testAuthRefreshHappensOnce_then401Resolves() async throws {
        // First call returns 401. Refresh handler bumps the token.
        // Retry call returns 200. Observer should record the refresh.
        let payload = Data(#"{"ok":1}"#.utf8)
        MockURLProtocol.script.enqueue(.success(status: 401, body: Data()))
        MockURLProtocol.script.enqueue(.success(status: 200, body: payload))

        let observer = RecordingObserver()
        let provider = BearerTokenProvider(initialToken: "old") { "new" }
        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            authorization: provider,
            retryPolicy: .none,
            observer: observer
        )

        _ = try await client.fetchRaw(from: URL(string: "https://example.com/me")!)
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 2)
        XCTAssertEqual(observer.authRefreshes.value, 1)
    }

    // MARK: - Coalescer

    func testCoalescerSharesOneRequestAcrossConcurrentCallers() async throws {
        // Five concurrent GETs to the same URL. Only ONE network request
        // should reach the wire; the rest ride on the in-flight task.
        let payload = Data(#"{"value":"shared"}"#.utf8)
        MockURLProtocol.script.enqueue(.success(status: 200, body: payload))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver(),
            coalescer: RequestCoalescer()
        )

        let url = URL(string: "https://example.com/coalesce")!
        async let r1 = client.fetchRaw(from: url)
        async let r2 = client.fetchRaw(from: url)
        async let r3 = client.fetchRaw(from: url)
        async let r4 = client.fetchRaw(from: url)
        async let r5 = client.fetchRaw(from: url)
        let results = try await [r1, r2, r3, r4, r5]

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == payload })
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 1,
                       "coalescer should fold five identical GETs into one network call")
    }

    func testCoalescerDoesNotShareDistinctURLs() async throws {
        MockURLProtocol.script.enqueue(.success(status: 200, body: Data("a".utf8)))
        MockURLProtocol.script.enqueue(.success(status: 200, body: Data("b".utf8)))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver(),
            coalescer: RequestCoalescer()
        )

        async let a = client.fetchRaw(from: URL(string: "https://example.com/a")!)
        async let b = client.fetchRaw(from: URL(string: "https://example.com/b")!)
        _ = try await (a, b)
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 2)
    }

    // MARK: - Observer events fire

    func testObserverFiresRetryEventOnTransientFailure() async throws {
        let observer = RecordingObserver()
        MockURLProtocol.script.enqueue(.success(status: 503, body: Data()))
        MockURLProtocol.script.enqueue(.success(status: 200, body: Data("ok".utf8)))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                backoff: .fixed(0),
                maxTotalDelay: 0,
                shouldRetry: { _, _, _ in true }
            ),
            observer: observer
        )
        _ = try await client.fetchRaw(from: URL(string: "https://example.com/r")!)
        XCTAssertEqual(observer.retries.value, 1,
                       "observer should see the 503 → retry → 200 sequence as 1 retry")
    }

    // MARK: - Lenient observer pipeline

    func testLenientObserverSeesMissingField() throws {
        // SmartAPIContext.observer is a TaskLocal. We set it explicitly
        // here to mimic what SmartClient does for every request.
        let observer = RecordingObserver()
        let json = #"{ "id": 1 }"#.data(using: .utf8)!
        try SmartAPIContext.$observer.withValue(observer) {
            _ = try JSONDecoder().decode(TestLenient.Model.self, from: json)
        }
        XCTAssertTrue(
            observer.lenientDefaults.value.contains { _, field, reason in
                field == "name" && reason == .missing
            },
            "observer should record that `name` was missing"
        )
        XCTAssertTrue(
            observer.lenientDefaults.value.contains { _, field, reason in
                field == "score" && reason == .missing
            },
            "observer should record that `score` was missing"
        )
    }

    func testLenientObserverSeesWrongType() throws {
        let observer = RecordingObserver()
        let json = #"{ "id": 1, "name": "Ada", "score": "high", "is_active": true, "address": { "city": "x", "street": "y" } }"#.data(using: .utf8)!
        try SmartAPIContext.$observer.withValue(observer) {
            _ = try JSONDecoder().decode(TestLenient.Model.self, from: json)
        }
        XCTAssertTrue(
            observer.lenientDefaults.value.contains { _, field, reason in
                field == "score" && reason == .wrongType
            },
            "wrong-typed `score` should be reported"
        )
    }
}

// MARK: - Observer doubles

/// Drops every event so production logging doesn't muddy `xctest` output.
struct SilentObserver: SmartAPIObserver {}

/// Records the events we care to assert against.
final class RecordingObserver: SmartAPIObserver, @unchecked Sendable {
    let retries = LockIsolated(0)
    let authRefreshes = LockIsolated(0)
    let lenientDefaults = LockIsolated<[(String, String, LenientReason)]>([])
    let cacheWrites = LockIsolated(0)

    func requestRetried(url: URL, method: HTTPMethod, attempt: Int, error: any Error) {
        retries.withValue { $0 += 1 }
    }
    func authRefreshAttempted(url: URL) {
        authRefreshes.withValue { $0 += 1 }
    }
    func lenientDefaultUsed(typeName: String, field: String, reason: LenientReason) {
        lenientDefaults.withValue { $0.append((typeName, field, reason)) }
    }
    func cacheWriteFailed(typeName: String, error: any Error) {
        cacheWrites.withValue { $0 += 1 }
    }
}
