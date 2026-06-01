import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SmartAPIPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        SmartAPIMacro.self,
    ]
}
