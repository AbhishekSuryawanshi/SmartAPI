#if canImport(SwiftUI)
import SwiftUI

/// State-aware wrapper that turns a generated loader into a screen with
/// idle / loading / loaded / error states handled for you. Optionally
/// surfaces a stale-data banner above the content when a background
/// refresh failed but the cache served the screen.
///
///     SmartView(loader: User.Loader(url: url)) { user in
///         User.View(model: user)
///     }
///
/// The banner reads `loader.lastRefreshErrorDescription` automatically.
/// To customize, pass a closure to `staleBanner:` — return any view to
/// replace the default; return `EmptyView()` to disable.
public struct SmartView<Value, Content: View, Banner: View, Loader: SmartLoaderProtocol>: View
where Loader.Value == Value {

    @State private var loader: Loader
    private let content: (Value) -> Content
    private let staleBanner: (String) -> Banner

    public init(
        loader: Loader,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder staleBanner: @escaping (String) -> Banner
    ) {
        self._loader = State(initialValue: loader)
        self.content = content
        self.staleBanner = staleBanner
    }

    public var body: some View {
        Group {
            switch loader.state {
            case .idle:
                Color.clear.task { await loader.load() }
            case .loading:
                ProgressView().controlSize(.large)
            case .loaded(let value):
                VStack(spacing: 0) {
                    if !loader.lastRefreshErrorDescription.isEmpty {
                        staleBanner(loader.lastRefreshErrorDescription)
                    }
                    content(value)
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Couldn't load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
    }
}

// MARK: - Convenience: default stale banner

public extension SmartView where Banner == DefaultStaleBanner {
    /// Construct a `SmartView` with the built-in stale-data banner —
    /// a yellow strip with the failure reason. For zero-config consumers.
    init(
        loader: Loader,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.init(
            loader: loader,
            content: content,
            staleBanner: { reason in DefaultStaleBanner(reason: reason) }
        )
    }
}

/// Built-in stale-data banner. Replace by passing your own `staleBanner:`
/// to `SmartView`. The string passed in is `loader.lastRefreshErrorDescription`.
public struct DefaultStaleBanner: View {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing offline data")
                    .font(.footnote.weight(.medium))
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.yellow.opacity(0.4)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Protocol the macro-generated loaders conform to. Lets `SmartView`
/// be generic over any concrete loader type.
///
/// Main-actor-isolated so `SmartView` can call `load()` from `.task`
/// without data-race warnings under Swift 6 strict concurrency.
@MainActor
public protocol SmartLoaderProtocol: AnyObject {
    associatedtype Value: Sendable
    var state: LoadState<Value> { get }

    /// Empty when no error since the last refresh. Non-empty when the
    /// network call failed but cache served the screen — used by
    /// `SmartView` to surface the stale-data banner.
    var lastRefreshErrorDescription: String { get }

    func load() async
}

public extension SmartLoaderProtocol {
    /// Default for loaders without a cache layer — they go straight to
    /// `.failed` rather than displaying stale data, so the banner never
    /// applies to them.
    var lastRefreshErrorDescription: String { "" }
}

/// Best-effort one-line preview of any value, used by generated views
/// for nested-object navigation rows. Lives in the runtime so multiple
/// `@SmartAPI` invocations in the same module don't duplicate it.
///
/// Resolution order:
/// 1. A child property named `title`, `name`, `label`, `headline`, or
///    `summary` whose value is a non-empty `String`.
/// 2. The first `String`-typed child.
/// 3. The first 60 characters of `String(describing:)`.
public enum SmartAPIRowLabel {
    private static let preferredLabelKeys = ["title", "name", "label", "headline", "summary"]

    public static func preview<Value>(of value: Value) -> String {
        let mirror = Mirror(reflecting: value)

        for key in preferredLabelKeys {
            if let child = mirror.children.first(where: { $0.label == key }),
               let text = child.value as? String, !text.isEmpty {
                return text
            }
        }
        if let firstString = mirror.children.first(where: { $0.value is String }),
           let text = firstString.value as? String {
            return text
        }
        return String(String(describing: value).prefix(60))
    }
}
#endif
