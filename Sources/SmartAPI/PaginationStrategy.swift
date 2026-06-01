import Foundation

// MARK: - PaginationStrategy

/// Captures the rules for advancing through a paginated endpoint:
/// what query parameters to send, how to read items out of a response,
/// and how to tell when there's nothing left to fetch.
///
/// The strategy is a *pure value* — no actor, no state, no side effects.
/// All mutable state lives on the `PaginatedLoader` that consumes the
/// strategy. That makes strategies cheap to construct, easy to share
/// across loaders, and trivially `Sendable`.
///
/// Three blessed factory methods cover ~95% of real-world REST APIs:
///   - `.cursor(...)` — Stripe / Slack / Twitter / Firebase style
///   - `.page(...)`   — GitHub REST / Rails / generic page-number APIs
///   - `.offset(...)` — Algolia / many internal APIs
public struct PaginationStrategy<Page: Decodable & Sendable, Item: Sendable>: Sendable {

    /// Per-loader pagination state. Different strategies use different
    /// fields; unused fields are left at their default.
    public struct State: Sendable {
        public var cursor: String?
        public var pageIndex: Int
        public var offset: Int
        public var hasMore: Bool

        public init(
            cursor: String? = nil,
            pageIndex: Int = 1,
            offset: Int = 0,
            hasMore: Bool = true
        ) {
            self.cursor = cursor
            self.pageIndex = pageIndex
            self.offset = offset
            self.hasMore = hasMore
        }
    }

    /// Outcome of consuming one `Page`: items to append + the new state.
    public struct Outcome: Sendable {
        public let items: [Item]
        public let newState: State

        public init(items: [Item], newState: State) {
            self.items = items
            self.newState = newState
        }
    }

    public let initialState: State
    public let queryItems: @Sendable (State) -> [URLQueryItem]
    public let advance: @Sendable (Page, State) -> Outcome

    public init(
        initialState: State,
        queryItems: @escaping @Sendable (State) -> [URLQueryItem],
        advance: @escaping @Sendable (Page, State) -> Outcome
    ) {
        self.initialState = initialState
        self.queryItems = queryItems
        self.advance = advance
    }
}

// MARK: - Cursor strategy

public extension PaginationStrategy {

    /// Cursor-based pagination. The server returns an opaque cursor for
    /// the next page; the client sends it back as a query parameter.
    /// Used by Stripe, Slack, Twitter v2, Firebase.
    ///
    /// - Parameters:
    ///   - items: Extract the items array from the page response.
    ///   - nextCursor: Extract the cursor for the next page (`nil` when done).
    ///   - hasMore: Optional explicit "more available" flag. When omitted,
    ///     `hasMore` is derived from `nextCursor != nil && items.isEmpty == false`.
    ///   - cursorParam: Query-parameter name for the cursor (default `"cursor"`).
    static func cursor(
        items: @escaping @Sendable (Page) -> [Item],
        nextCursor: @escaping @Sendable (Page) -> String?,
        hasMore: (@Sendable (Page) -> Bool)? = nil,
        cursorParam: String = "cursor"
    ) -> PaginationStrategy {
        PaginationStrategy(
            initialState: State(cursor: nil, hasMore: true),
            queryItems: { state in
                state.cursor.map { [URLQueryItem(name: cursorParam, value: $0)] } ?? []
            },
            advance: { page, _ in
                let pageItems = items(page)
                let newCursor = nextCursor(page)
                let explicitHasMore = hasMore?(page) ?? true
                let derivedHasMore = explicitHasMore && newCursor != nil && !pageItems.isEmpty
                return Outcome(
                    items: pageItems,
                    newState: State(cursor: newCursor, hasMore: derivedHasMore)
                )
            }
        )
    }
}

// MARK: - Page-number strategy

public extension PaginationStrategy {

    /// Page-number pagination. Client tracks `page=N&per_page=M`; server
    /// returns items and (optionally) the total count for "are we done?"
    /// detection. Used by GitHub REST, Rails, most generic admin APIs.
    ///
    /// - Parameters:
    ///   - items: Extract the items array from the page response.
    ///   - total: Optional extractor for the total item count. When provided,
    ///     `hasMore` is computed from `accumulated < total`. When `nil`,
    ///     pagination ends as soon as a page comes back with fewer than
    ///     `pageSize` items.
    ///   - pageParam: Query-parameter name for the page number (default `"page"`).
    ///   - perPageParam: Query-parameter name for the page size (default `"per_page"`).
    ///   - pageSize: Items per page (default `20`).
    ///   - firstPage: Page numbering origin (`1` for most APIs, `0` for some).
    static func page(
        items: @escaping @Sendable (Page) -> [Item],
        total: (@Sendable (Page) -> Int)? = nil,
        pageParam: String = "page",
        perPageParam: String = "per_page",
        pageSize: Int = 20,
        firstPage: Int = 1
    ) -> PaginationStrategy {
        PaginationStrategy(
            initialState: State(pageIndex: firstPage, hasMore: true),
            queryItems: { state in
                [
                    URLQueryItem(name: pageParam, value: String(state.pageIndex)),
                    URLQueryItem(name: perPageParam, value: String(pageSize)),
                ]
            },
            advance: { page, state in
                let pageItems = items(page)
                let hasMore: Bool
                if let totalExtractor = total {
                    let accumulated = (state.pageIndex - firstPage + 1) * pageSize
                    hasMore = accumulated < totalExtractor(page)
                } else {
                    hasMore = pageItems.count >= pageSize
                }
                return Outcome(
                    items: pageItems,
                    newState: State(pageIndex: state.pageIndex + 1, hasMore: hasMore)
                )
            }
        )
    }
}

// MARK: - Offset/limit strategy

public extension PaginationStrategy {

    /// Offset/limit pagination. Client tracks `offset=N&limit=M`.
    /// Used by Algolia search, many internal APIs.
    ///
    /// - Parameters:
    ///   - items: Extract the items array from the page response.
    ///   - total: Optional extractor for the total item count.
    ///   - offsetParam: Query-parameter name for the offset (default `"offset"`).
    ///   - limitParam: Query-parameter name for the limit (default `"limit"`).
    ///   - pageSize: Items per page (default `20`).
    static func offset(
        items: @escaping @Sendable (Page) -> [Item],
        total: (@Sendable (Page) -> Int)? = nil,
        offsetParam: String = "offset",
        limitParam: String = "limit",
        pageSize: Int = 20
    ) -> PaginationStrategy {
        PaginationStrategy(
            initialState: State(offset: 0, hasMore: true),
            queryItems: { state in
                [
                    URLQueryItem(name: offsetParam, value: String(state.offset)),
                    URLQueryItem(name: limitParam, value: String(pageSize)),
                ]
            },
            advance: { page, state in
                let pageItems = items(page)
                let newOffset = state.offset + pageItems.count
                let hasMore: Bool
                if let totalExtractor = total {
                    hasMore = newOffset < totalExtractor(page)
                } else {
                    hasMore = pageItems.count >= pageSize
                }
                return Outcome(
                    items: pageItems,
                    newState: State(offset: newOffset, hasMore: hasMore)
                )
            }
        )
    }
}
