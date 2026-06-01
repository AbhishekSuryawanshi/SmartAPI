import Foundation

/// `URLProtocol` subclass that intercepts every request a configured
/// `URLSession` makes and returns canned responses scripted by the test.
/// This lets us exercise the real `SmartClient` code paths — retry loops,
/// 401 refresh, coalescer — without standing up an HTTP server.
///
/// Usage:
///
///     let config = URLSessionConfiguration.ephemeral
///     config.protocolClasses = [MockURLProtocol.self]
///     let session = URLSession(configuration: config)
///     MockURLProtocol.script.enqueue(.success(status: 200, body: payload))
///     let client = SmartClient(session: session, ...)
///     defer { MockURLProtocol.reset() }
final class MockURLProtocol: URLProtocol {

    // MARK: - Script

    enum Response: Sendable {
        case success(status: Int, body: Data, headers: [String: String] = [:])
        case failure(URLError)
    }

    /// FIFO queue of scripted responses. Each network call consumes one.
    /// If the queue is empty, the test fails (no canned response).
    static let script = ResponseScript()

    final class ResponseScript: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Response] = []
        private var seenRequests: [URLRequest] = []

        func enqueue(_ response: Response) {
            lock.withLock { queue.append(response) }
        }

        func enqueue(_ responses: [Response]) {
            lock.withLock { queue.append(contentsOf: responses) }
        }

        func nextResponse() -> Response? {
            lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        }

        func record(_ request: URLRequest) {
            lock.withLock { seenRequests.append(request) }
        }

        var recordedRequests: [URLRequest] {
            lock.withLock { seenRequests }
        }

        func reset() {
            lock.withLock {
                queue.removeAll()
                seenRequests.removeAll()
            }
        }
    }

    static func reset() { script.reset() }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.script.record(request)
        guard let response = Self.script.nextResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch response {
        case .success(let status, let body, let headers):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let urlError):
            client?.urlProtocol(self, didFailWithError: urlError)
        }
    }

    override func stopLoading() {}
}

extension MockURLProtocol {
    /// Build a `URLSession` configured to route through this mock.
    static func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
