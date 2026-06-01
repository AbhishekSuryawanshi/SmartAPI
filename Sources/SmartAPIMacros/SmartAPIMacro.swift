import SwiftSyntax
import SwiftSyntaxMacros

/// `@attached(member, names: arbitrary)` macro that injects a Codable model,
/// a SwiftUI view, and an `@Observable` loader into the attached host type
/// (typically an empty `enum`).
///
/// This file holds the macro entry point only. Argument parsing lives in
/// `MacroArguments.swift`, codegen in `CodeGenerator.swift`, type inference
/// in `JSONInference.swift`, and runtime-name constants in
/// `RuntimeSymbols.swift`. Each file has one job.
public struct SmartAPIMacro: MemberMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try AttachmentValidator.validate(declaration)
        let arguments = try MacroArguments.parse(node)
        let hostTypeName = extractHostTypeName(declaration) ?? "SmartAPIType"

        let root: InferredType
        do {
            root = try JSONInference.infer(
                rootName: "Model",
                sample: arguments.sample,
                renames: arguments.renames
            )
        } catch {
            throw MacroError.message("@SmartAPI: \(error)")
        }

        return CodeGenerator
            .generate(
                root: root,
                cacheEnabled: arguments.cacheEnabled,
                hostTypeName: hostTypeName,
                scope: arguments.scope,
                strict: arguments.strict,
                pagination: arguments.pagination
            )
            .map { DeclSyntax(stringLiteral: $0) }
    }

    /// Pull the host type's name (`User` in `@SmartAPI enum User {}`) out of
    /// the attached declaration. Used by codegen to namespace per-type
    /// resources like the default cache file so multiple `@SmartAPI` types
    /// in the same module don't clobber each other on disk.
    private static func extractHostTypeName(
        _ declaration: some DeclGroupSyntax
    ) -> String? {
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            return enumDecl.name.text
        }
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            return structDecl.name.text
        }
        return nil
    }
}
