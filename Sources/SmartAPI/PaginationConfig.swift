/// Macro-level configuration for `@SmartAPI(paginated:)`. The user picks
/// a strategy + tells SmartAPI which keys carry the items, the cursor /
/// total, and (where the API requires it) custom query-parameter names.
///
/// This enum is the **public surface** the developer writes:
///
///     @SmartAPI(
///         sample: "...",
///         paginated: .cursor(items: "data", nextCursor: "next_cursor")
///     )
///     enum Posts {}
///
/// At macro-expansion time the `SmartAPIMacros` plugin parses these
/// values out of the syntax tree and generates the matching
/// `PaginationStrategy<Page, Item>` constant on the host type.
///
/// The runtime values are only used if you construct a strategy
/// manually outside the macro — most callers never touch them.
public enum PaginationConfig: Sendable {

    /// Cursor-based pagination (Stripe / Slack / Twitter / Firebase).
    ///
    /// - Parameters:
    ///   - items: JSON key where the items array lives (e.g. `"data"`).
    ///   - nextCursor: JSON key carrying the next-page cursor (`null` when exhausted).
    ///   - hasMore: Optional JSON key with an explicit "more available" boolean.
    ///   - cursorParam: Query-parameter name to send the cursor under.
    case cursor(
        items: String,
        nextCursor: String,
        hasMore: String? = nil,
        cursorParam: String = "cursor"
    )

    /// Page-number pagination (GitHub REST / Rails / generic admin APIs).
    ///
    /// - Parameters:
    ///   - items: JSON key where the items array lives (e.g. `"items"`).
    ///   - total: Optional JSON key for the total item count.
    ///   - pageParam: Query-parameter name for the page number.
    ///   - perPageParam: Query-parameter name for the page size.
    ///   - pageSize: Items per page (default 20; override on the call site if needed).
    ///   - firstPage: Page numbering origin (`1` for most APIs, `0` for some).
    case page(
        items: String,
        total: String? = nil,
        pageParam: String = "page",
        perPageParam: String = "per_page",
        pageSize: Int = 20,
        firstPage: Int = 1
    )

    /// Offset/limit pagination (Algolia / many internal APIs).
    ///
    /// - Parameters:
    ///   - items: JSON key where the items array lives.
    ///   - total: Optional JSON key for the total item count.
    ///   - offsetParam: Query-parameter name for the offset.
    ///   - limitParam: Query-parameter name for the limit.
    ///   - pageSize: Items per page (default 20).
    case offset(
        items: String,
        total: String? = nil,
        offsetParam: String = "offset",
        limitParam: String = "limit",
        pageSize: Int = 20
    )
}
