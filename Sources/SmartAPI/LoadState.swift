import Foundation

/// Four-state container for async loads. Generated `*Loader` types expose
/// a `state: LoadState<Model>` that `SmartView` knows how to render.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(any Error)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    public var error: (any Error)? {
        if case .failed(let e) = self { return e }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
