import XCTest
@testable import SmartAPIImporter

/// Direct unit tests for `OpenAPIImporter` — the OpenAPI 3.0 schema walker
/// that emits `@SmartAPI`-wrapped Swift sources. Lives in its own library
/// target (`SmartAPIImporter`) so this test target can link to it directly.
final class OpenAPIImporterTests: XCTestCase {

    // MARK: - Basic import

    func testImporterEmitsOneWrapperPerSchema() throws {
        let spec = """
        {
          "openapi": "3.0.0",
          "info": { "title": "x", "version": "1" },
          "paths": {},
          "components": {
            "schemas": {
              "Pet": {
                "type": "object",
                "properties": { "id": { "type": "integer" }, "name": { "type": "string" } }
              },
              "Owner": {
                "type": "object",
                "properties": { "id": { "type": "integer" } }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let imported = try OpenAPIImporter.importSchemas(from: spec)
        XCTAssertEqual(imported.map(\.typeName), ["Owner", "Pet"])
        XCTAssertTrue(imported[1].swiftSource.contains("@SmartAPI(sample:"))
        XCTAssertTrue(imported[1].swiftSource.contains("public enum Pet {}"))
    }

    // MARK: - $ref resolution

    func testImporterResolvesRefBetweenSchemas() throws {
        let spec = """
        {
          "openapi": "3.0.0",
          "paths": {},
          "components": {
            "schemas": {
              "Pet": {
                "type": "object",
                "properties": {
                  "owner": { "$ref": "#/components/schemas/Owner" }
                }
              },
              "Owner": {
                "type": "object",
                "properties": { "name": { "type": "string" } }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let imported = try OpenAPIImporter.importSchemas(from: spec)
        let pet = try XCTUnwrap(imported.first(where: { $0.typeName == "Pet" }))
        XCTAssertTrue(pet.swiftSource.contains("\"owner\""))
        XCTAssertTrue(pet.swiftSource.contains("\"name\""),
                      "$ref'd Owner.name should expand inline in Pet's sample")
    }

    // MARK: - Format-aware sample synthesis

    func testFormatHintsProduceMatchingValues() throws {
        let spec = """
        {
          "openapi": "3.0.0",
          "paths": {},
          "components": {
            "schemas": {
              "Event": {
                "type": "object",
                "properties": {
                  "happened_at": { "type": "string", "format": "date-time" },
                  "homepage": { "type": "string", "format": "uri" },
                  "request_id": { "type": "string", "format": "uuid" },
                  "contact": { "type": "string", "format": "email" }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let imported = try OpenAPIImporter.importSchemas(from: spec)
        let source = try XCTUnwrap(imported.first?.swiftSource)
        XCTAssertTrue(source.contains("2024-01-01T00:00:00Z"))
        // JSONSerialization escapes forward slashes (`/` → `\/`), so check
        // the recognizable substring without the protocol prefix.
        XCTAssertTrue(source.contains("example.com"))
        XCTAssertTrue(source.contains("00000000-0000-0000-0000-000000000000"))
        XCTAssertTrue(source.contains("user@example.com"))
    }

    // MARK: - Enum support

    func testEnumValuesPickFirst() throws {
        let spec = """
        {
          "openapi": "3.0.0",
          "paths": {},
          "components": {
            "schemas": {
              "Pet": {
                "type": "object",
                "properties": {
                  "status": { "type": "string", "enum": ["available", "pending", "sold"] }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let imported = try OpenAPIImporter.importSchemas(from: spec)
        XCTAssertTrue(imported[0].swiftSource.contains("\"available\""))
    }

    // MARK: - Composition (allOf/oneOf/anyOf)

    func testCompositionPicksFirstBranch() {
        let firstBranch: [String: Any] = [
            "type": "object",
            "properties": [
                "branch_picked": ["type": "string"]
            ]
        ]
        let secondBranch: [String: Any] = [
            "type": "object",
            "properties": ["other": ["type": "string"]]
        ]
        let schema: [String: Any] = ["oneOf": [firstBranch, secondBranch]]
        let sample = OpenAPIImporter.synthesizeSample(for: schema, allSchemas: [:], depth: 0)
        let dict = sample as? [String: Any]
        XCTAssertNotNil(dict?["branch_picked"], "oneOf should pick the first branch")
        XCTAssertNil(dict?["other"])
    }

    // MARK: - Recursion limit

    func testRecursionLimitBreaksCycles() {
        // Self-referential Tree schema would loop forever without the depth cap.
        let tree: [String: Any] = [
            "type": "object",
            "properties": [
                "child": ["$ref": "#/components/schemas/Tree"]
            ]
        ]
        let sample = OpenAPIImporter.synthesizeSample(
            for: tree,
            allSchemas: ["Tree": tree],
            depth: 0
        )
        // It should complete (not infinite-loop) and produce a dict.
        XCTAssertNotNil(sample as? [String: Any])
    }

    // MARK: - Error cases

    func testRejectsNonObjectSpec() {
        let bogus = "[1, 2, 3]".data(using: .utf8)!
        XCTAssertThrowsError(try OpenAPIImporter.importSchemas(from: bogus)) { error in
            guard case OpenAPIImporter.ImporterError.missingComponentsSchemas = error else {
                XCTFail("expected missingComponentsSchemas, got \(error)"); return
            }
        }
    }

    func testRejectsMalformedJSON() {
        let bogus = "{not json".data(using: .utf8)!
        XCTAssertThrowsError(try OpenAPIImporter.importSchemas(from: bogus)) { error in
            guard case OpenAPIImporter.ImporterError.invalidJSON = error else {
                XCTFail("expected invalidJSON, got \(error)"); return
            }
        }
    }

    func testRejectsSpecWithoutComponentsSchemas() {
        let spec = """
        { "openapi": "3.0.0", "paths": {} }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try OpenAPIImporter.importSchemas(from: spec)) { error in
            guard case OpenAPIImporter.ImporterError.missingComponentsSchemas = error else {
                XCTFail("expected missingComponentsSchemas, got \(error)"); return
            }
        }
    }
}
