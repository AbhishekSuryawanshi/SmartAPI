/// String constants for runtime types that codegen emits.
///
/// The macro plugin can't directly import the runtime `SmartAPI` library
/// (it's a different target with no dependency edge), so generated code
/// references runtime types as strings. Centralizing those strings here
/// means a runtime rename is a one-line update — and missing-symbol
/// failures surface at the consumer's compile step, not silently as
/// wrong-name runtime crashes.
///
/// Whenever you rename or add a runtime type that codegen references,
/// update this file *and* the `CodeGenerator` call site in the same change.
enum RuntimeSymbols {
    static let loaderProtocol  = "SmartLoaderProtocol"
    static let fetcherProtocol = "SmartFetching"
    static let defaultFetcher  = "SmartClient.shared"
    static let loadState       = "LoadState"
    static let schema          = "SmartAPISchema"
    static let schemaDrift     = "SmartAPISchemaDrift"
    static let rowLabel        = "SmartAPIRowLabel"
    static let httpMethod      = "HTTPMethod"
    static let mutatorError    = "SmartAPIMutatorError"
}
