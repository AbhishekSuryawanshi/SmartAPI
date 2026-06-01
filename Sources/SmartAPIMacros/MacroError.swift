/// Errors surfaced by the `@SmartAPI` macro at expansion time. The compiler
/// reports `description` as the diagnostic message, so phrases land in the
/// developer's build log verbatim — keep them actionable.
struct MacroError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }

    static func message(_ text: String) -> MacroError {
        MacroError(message: text)
    }
}
