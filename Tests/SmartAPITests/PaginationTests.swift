import XCTest
@testable import SmartAPI

/// End-to-end tests for the pagination runtime against `MockURLProtocol`.
/// Each test walks through real pages, verifies `items` accumulates,
/// `hasMore` flips correctly, and `loadMore()` no-ops once exhausted.
// MARK: - Macro-generated paginated type

// Verifies the macro emits:
//   - Posts.Page          — the response wrapper, with `posts: [Posts.Model]`
//   - Posts.Model         — the item, hoisted from the array element
//   - Posts.paginationStrategy
//   - Posts.Loader (typealias)
//   - Posts.loader(url:)  and Posts.loader(query:)
@SmartAPI(
    sample: """
    {
      "posts": [{ "id": 1, "title": "Hello" }],
      "next_cursor": "abc",
      "has_more": true
    }
    """,
    scope: .parseOnly,
    paginated: .cursor(items: "posts", nextCursor: "next_cursor", hasMore: "has_more")
)
enum Posts {}

@MainActor
final class PaginationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: - Test types

    struct Page: Codable, Sendable {
        let data: [Item]
        let nextCursor: String?
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case data
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
        }
    }

    struct PagedResponse: Codable, Sendable {
        let items: [Item]
        let total: Int
    }

    struct OffsetResponse: Codable, Sendable {
        let results: [Item]
        let total: Int
    }

    struct Item: Codable, Sendable, Hashable, Identifiable {
        let id: Int
        let title: String
    }

    // MARK: - Cursor strategy

    func testCursorStrategyWalksPagesUntilCursorIsNil() async throws {
        // Three pages: cursor → another cursor → null
        let page1 = #"{"data":[{"id":1,"title":"a"},{"id":2,"title":"b"}],"next_cursor":"c2","has_more":true}"#
        let page2 = #"{"data":[{"id":3,"title":"c"},{"id":4,"title":"d"}],"next_cursor":"c3","has_more":true}"#
        let page3 = #"{"data":[{"id":5,"title":"e"}],"next_cursor":null,"has_more":false}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
            .success(status: 200, body: Data(page3.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<Page, Item>.cursor(
            items: { $0.data },
            nextCursor: { $0.nextCursor },
            hasMore: { $0.hasMore }
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )

        await loader.load()
        XCTAssertEqual(loader.items.map(\.id), [1, 2])
        XCTAssertTrue(loader.hasMore)

        await loader.loadMore()
        XCTAssertEqual(loader.items.map(\.id), [1, 2, 3, 4])
        XCTAssertTrue(loader.hasMore)

        await loader.loadMore()
        XCTAssertEqual(loader.items.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertFalse(loader.hasMore, "cursor null + has_more false → no more pages")

        // Subsequent loadMore is a no-op (no fourth network call enqueued).
        await loader.loadMore()
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 3)
    }

    func testCursorStrategySendsCursorAsQueryParam() async throws {
        let page1 = #"{"data":[{"id":1,"title":"a"}],"next_cursor":"abc","has_more":true}"#
        let page2 = #"{"data":[{"id":2,"title":"b"}],"next_cursor":null,"has_more":false}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<Page, Item>.cursor(
            items: { $0.data },
            nextCursor: { $0.nextCursor },
            hasMore: { $0.hasMore },
            cursorParam: "after"
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/feed")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        await loader.loadMore()

        let urls = MockURLProtocol.script.recordedRequests.compactMap(\.url?.absoluteString)
        XCTAssertEqual(urls.count, 2)
        XCTAssertFalse(urls[0].contains("after="), "first call has no cursor")
        XCTAssertTrue(urls[1].contains("after=abc"), "second call carries cursor")
    }

    // MARK: - Page strategy

    func testPageStrategyAdvancesPageNumber() async throws {
        let page1 = #"{"items":[{"id":1,"title":"a"},{"id":2,"title":"b"}],"total":3}"#
        let page2 = #"{"items":[{"id":3,"title":"c"}],"total":3}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<PagedResponse, Item>.page(
            items: { $0.items },
            total: { $0.total },
            pageSize: 2
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        await loader.loadMore()

        XCTAssertEqual(loader.items.map(\.id), [1, 2, 3])
        XCTAssertFalse(loader.hasMore, "accumulated 3 == total 3 → done")

        let urls = MockURLProtocol.script.recordedRequests.compactMap(\.url?.absoluteString)
        XCTAssertTrue(urls[0].contains("page=1"))
        XCTAssertTrue(urls[1].contains("page=2"))
        XCTAssertTrue(urls.allSatisfy { $0.contains("per_page=2") })
    }

    func testPageStrategyStopsWhenPartialPageReturnedWithoutTotal() async throws {
        // No `total` provided — strategy infers "done" from a short page.
        let page1 = #"{"items":[{"id":1,"title":"a"},{"id":2,"title":"b"}],"total":0}"#
        let page2 = #"{"items":[{"id":3,"title":"c"}],"total":0}"#  // 1 item, less than pageSize=2
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<PagedResponse, Item>.page(
            items: { $0.items },
            total: nil,                    // ← no total
            pageSize: 2
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        await loader.loadMore()

        XCTAssertEqual(loader.items.count, 3)
        XCTAssertFalse(loader.hasMore, "short page (1 < 2) marks the end")
    }

    // MARK: - Offset strategy

    func testOffsetStrategyAccumulatesOffset() async throws {
        let page1 = #"{"results":[{"id":1,"title":"a"},{"id":2,"title":"b"}],"total":4}"#
        let page2 = #"{"results":[{"id":3,"title":"c"},{"id":4,"title":"d"}],"total":4}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<OffsetResponse, Item>.offset(
            items: { $0.results },
            total: { $0.total },
            pageSize: 2
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/search")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        await loader.loadMore()

        XCTAssertEqual(loader.items.map(\.id), [1, 2, 3, 4])
        XCTAssertFalse(loader.hasMore)

        let urls = MockURLProtocol.script.recordedRequests.compactMap(\.url?.absoluteString)
        XCTAssertTrue(urls[0].contains("offset=0"))
        XCTAssertTrue(urls[1].contains("offset=2"))
    }

    // MARK: - Error handling

    func testErrorMidPaginationPreservesItems() async throws {
        let page1 = #"{"data":[{"id":1,"title":"a"}],"next_cursor":"c2","has_more":true}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 500, body: Data("boom".utf8)),     // second page errors
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<Page, Item>.cursor(
            items: { $0.data },
            nextCursor: { $0.nextCursor },
            hasMore: { $0.hasMore }
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        XCTAssertEqual(loader.items.count, 1)

        await loader.loadMore()
        // Existing items preserved; error observable via lastRefreshError.
        XCTAssertEqual(loader.items.count, 1, "page-1 items must survive a page-2 failure")
        XCTAssertFalse(loader.lastRefreshErrorDescription.isEmpty)
        if case .loaded = loader.state { /* ok */ } else {
            XCTFail("state should stay .loaded, not flip to .failed")
        }
    }

    func testFailureOnFirstPageMarksStateFailed() async throws {
        MockURLProtocol.script.enqueue(.success(status: 500, body: Data("boom".utf8)))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<Page, Item>.cursor(
            items: { $0.data },
            nextCursor: { $0.nextCursor }
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()

        if case .failed = loader.state { /* ok */ } else {
            XCTFail("state should be .failed when there's nothing to show")
        }
        XCTAssertTrue(loader.items.isEmpty)
    }

    // MARK: - Reset behavior

    // MARK: - Macro-generated loader end-to-end

    func testMacroGeneratedLoaderWalksRealResponses() async throws {
        let page1 = #"{"posts":[{"id":1,"title":"a"},{"id":2,"title":"b"}],"next_cursor":"c2","has_more":true}"#
        let page2 = #"{"posts":[{"id":3,"title":"c"}],"next_cursor":null,"has_more":false}"#
        MockURLProtocol.script.enqueue([
            .success(status: 200, body: Data(page1.utf8)),
            .success(status: 200, body: Data(page2.utf8)),
        ])

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        // Macro-generated factory — typed all the way through.
        let loader: Posts.Loader = Posts.loader(
            url: URL(string: "https://example.com/posts")!,
            fetcher: client
        )

        await loader.load()
        XCTAssertEqual(loader.items.map(\.id), [1, 2])
        XCTAssertTrue(loader.hasMore)

        await loader.loadMore()
        XCTAssertEqual(loader.items.map(\.id), [1, 2, 3])
        XCTAssertFalse(loader.hasMore)

        // Per-call URL inspection: second call should carry the cursor.
        let urls = MockURLProtocol.script.recordedRequests.compactMap(\.url?.absoluteString)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[1].contains("cursor=c2"))
    }

    func testResetClearsStateWithoutFetching() async throws {
        let page1 = #"{"data":[{"id":1,"title":"a"}],"next_cursor":"abc","has_more":true}"#
        MockURLProtocol.script.enqueue(.success(status: 200, body: Data(page1.utf8)))

        let client = SmartClient(
            session: MockURLProtocol.mockedSession(),
            retryPolicy: .none,
            observer: SilentObserver()
        )
        let strategy = PaginationStrategy<Page, Item>.cursor(
            items: { $0.data },
            nextCursor: { $0.nextCursor }
        )
        let loader = PaginatedLoader(
            baseQuery: SmartQuery.get(URL(string: "https://example.com/posts")!),
            strategy: strategy,
            fetcher: client
        )
        await loader.load()
        XCTAssertEqual(loader.items.count, 1)

        loader.reset()
        XCTAssertEqual(loader.items.count, 0)
        XCTAssertTrue(loader.hasMore)
        if case .idle = loader.state { /* ok */ } else {
            XCTFail("state should be .idle after reset")
        }
        XCTAssertEqual(MockURLProtocol.script.recordedRequests.count, 1,
                       "reset must not fire a network call")
    }
}
