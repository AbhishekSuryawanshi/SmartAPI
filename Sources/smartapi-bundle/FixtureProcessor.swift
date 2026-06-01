import Foundation
import SmartAPIImporter

/// Walks a directory tree for `*.smartapi.json` fixtures, runs each one
/// through `WrapperRenderer`, and writes the resulting `*+SmartAPI.swift`
/// next to the source file. Skips writes when the target is already
/// up-to-date so re-running in CI is cheap.
struct FixtureProcessor {

    struct Counts: Equatable {
        var written = 0
        var skipped = 0
    }

    enum ProcessorError: Error, CustomStringConvertible {
        case cannotEnumerate(path: String)

        var description: String {
            switch self {
            case .cannotEnumerate(let path):
                return "cannot enumerate directory: \(path)"
            }
        }
    }

    let fileManager: FileManager
    let logger: (String) -> Void

    init(
        fileManager: FileManager = .default,
        logger: @escaping (String) -> Void = { print($0) }
    ) {
        self.fileManager = fileManager
        self.logger = logger
    }

    /// Process one root directory; recurse into subdirectories.
    func processRoot(_ rootPath: String) throws -> Counts {
        guard let enumerator = fileManager.enumerator(atPath: rootPath) else {
            throw ProcessorError.cannotEnumerate(path: rootPath)
        }

        var counts = Counts()
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".smartapi.json") else { continue }
            try processFixture(rootPath: rootPath, relativePath: relativePath, counts: &counts)
        }
        return counts
    }

    // MARK: - Single fixture

    private func processFixture(
        rootPath: String,
        relativePath: String,
        counts: inout Counts
    ) throws {
        let jsonPath = (rootPath as NSString).appendingPathComponent(relativePath)
        let outputPath = WrapperRenderer.derivedSwiftPath(forJSONAt: jsonPath)
        let typeName = WrapperRenderer.derivedTypeName(forJSONAt: jsonPath)
        let json = try String(contentsOfFile: jsonPath, encoding: .utf8)
        let rendered = WrapperRenderer.renderSwiftWrapper(
            typeName: typeName,
            sourceFile: relativePath,
            json: json
        )

        if isUpToDate(rendered, at: outputPath) {
            counts.skipped += 1
            return
        }

        try rendered.write(toFile: outputPath, atomically: true, encoding: .utf8)
        counts.written += 1
        logger("generated \(outputPath)")
    }

    private func isUpToDate(_ rendered: String, at path: String) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let existing = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return false
        }
        return existing == rendered
    }
}
