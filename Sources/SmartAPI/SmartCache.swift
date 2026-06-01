import Foundation

// MARK: - SmartCache

/// Local persistence for cached `Loader` values. The Loader writes here
/// after every successful network fetch and reads from here on `load()`
/// before hitting the network — that's what makes "open the app offline
/// and it just works" possible.
///
/// The default implementation is `JSONFileCache`, which writes one JSON
/// blob per type into the app's Caches directory. For a SwiftData-backed
/// cache, conform `@Model` types to `SmartCache` yourself.
public protocol SmartCache<Value>: Sendable {
    associatedtype Value: Codable & Sendable

    /// Read the previously-written value, or `nil` if the cache is empty
    /// or the stored data can't be decoded against the current model shape.
    func read() async throws -> Value?

    /// Persist `value` so the next `read()` returns it.
    func write(_ value: Value) async throws

    /// Remove the cached entry. Useful on sign-out or schema migrations.
    func clear() async throws
}

// MARK: - JSONFileCache

/// One-file-per-type JSON cache living under `Library/Caches/SmartAPI/`.
/// Simple, no external dependencies, easy to inspect on-disk.
public struct JSONFileCache<Value: Codable & Sendable>: SmartCache {

    public let fileURL: URL
    public let decoder: JSONDecoder
    public let encoder: JSONEncoder

    public init(
        name: String,
        directory: URL? = nil,
        decoder: JSONDecoder? = nil,
        encoder: JSONEncoder? = nil
    ) {
        let root = directory ?? Self.defaultDirectory()
        // Best-effort directory creation. Read/write will surface real errors.
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        self.fileURL = root.appendingPathComponent("\(name).json")
        self.decoder = decoder ?? SmartClient.makeDefaultDecoder()
        self.encoder = encoder ?? SmartClient.makeDefaultEncoder()
    }

    public func read() async throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(Value.self, from: data)
    }

    public func write(_ value: Value) async throws {
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// `Library/Caches/SmartAPI/`. App-private, may be purged by the OS.
    public static func defaultDirectory() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartAPI", isDirectory: true)
    }
}
