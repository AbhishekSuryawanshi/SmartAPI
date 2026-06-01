// smartapi-bundle — turn either:
//   - `*.smartapi.json` fixtures into committed Swift wrappers, *or*
//   - an OpenAPI 3.0 spec into committed Swift wrappers for every schema.
//
// In both modes the output is `*+SmartAPI.swift` files that contain a
// `@SmartAPI(sample: ...)` call. The macro then takes over and gives you
// `Model`, `View`, `Loader`, `Mutator`, etc. for free.
//
// Modes:
//
//     # Fixture mode — walk dirs for *.smartapi.json
//     swift run smartapi-bundle Sources/MyApp Sources/MyApp/Models
//
//     # OpenAPI mode — import every schema from a spec
//     swift run smartapi-bundle openapi <spec.json> <output-dir>
//
// This sidesteps the Swift macro sandbox (which blocks file/network access
// at expansion time) by doing the file-to-source step before the compiler
// runs. Wire it into a build phase, a pre-commit hook, or a Makefile target.
//
// Architecture:
//   - SmartAPIBundle.swift   — @main entry, CLI argument dispatch
//   - FixtureProcessor.swift — walks dirs for *.smartapi.json
//   - OpenAPIImporter.swift  — parses OpenAPI 3.0, synthesizes samples
//   - WrapperRenderer.swift  — pure JSON→Swift rendering (shared)

import Foundation
import SmartAPIImporter

@main
struct SmartAPIBundle {

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "openapi" {
            exit(runOpenAPI(arguments: Array(arguments.dropFirst())))
        }
        guard !arguments.isEmpty else {
            printUsage()
            exit(64)  // EX_USAGE
        }
        exit(runFixtureWalk(directories: arguments))
    }

    // MARK: - Fixture mode

    /// Walk directories for `*.smartapi.json` fixtures and write wrappers.
    static func runFixtureWalk(directories: [String]) -> Int32 {
        let processor = FixtureProcessor()
        var totals = FixtureProcessor.Counts()
        var failed = 0

        for root in directories {
            do {
                let counts = try processor.processRoot(root)
                totals.written += counts.written
                totals.skipped += counts.skipped
            } catch {
                FileHandle.standardError.write(Data("error: \(root): \(error)\n".utf8))
                failed += 1
            }
        }

        print("smartapi-bundle: \(totals.written) generated, \(totals.skipped) up-to-date, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    // MARK: - OpenAPI mode

    /// Import every schema from an OpenAPI 3.0 spec into `<output-dir>`.
    /// Idempotent: skips files whose contents already match, so re-running
    /// in CI doesn't churn the git history.
    static func runOpenAPI(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            printUsage()
            return 64
        }
        let specPath = arguments[0]
        let outputDirectory = arguments[1]
        let fileManager = FileManager.default

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: specPath))
            let imported = try OpenAPIImporter.importSchemas(from: data)
            try fileManager.createDirectory(
                atPath: outputDirectory,
                withIntermediateDirectories: true
            )

            var written = 0
            var skipped = 0
            for schema in imported {
                let outputPath = (outputDirectory as NSString)
                    .appendingPathComponent("\(schema.typeName)+SmartAPI.swift")

                if fileManager.fileExists(atPath: outputPath),
                   let existing = try? String(contentsOfFile: outputPath, encoding: .utf8),
                   existing == schema.swiftSource {
                    skipped += 1
                    continue
                }

                try schema.swiftSource.write(
                    toFile: outputPath,
                    atomically: true,
                    encoding: .utf8
                )
                written += 1
                print("generated \(outputPath)")
            }
            print("smartapi-bundle openapi: \(written) generated, \(skipped) up-to-date, total \(imported.count) schemas")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Usage

    private static func printUsage() {
        FileHandle.standardError.write(Data("""
        Usage:
          smartapi-bundle <directory> [<directory> ...]
              Walk directories for *.smartapi.json fixtures and write
              the corresponding *+SmartAPI.swift wrappers next to them.

          smartapi-bundle openapi <spec.json> <output-dir>
              Import every schema from an OpenAPI 3.0 JSON spec and
              write *+SmartAPI.swift wrappers into <output-dir>.

        """.utf8))
    }
}
