import XCTest
@testable import SmartAPIMacros

/// Direct unit tests for `FieldNaming` — the rules that turn JSON keys
/// into idiomatic Swift identifiers. These regression-test the sanitization
/// fixes (review fix #2) plus the heuristics they live alongside.
final class FieldNamingTests: XCTestCase {

    // MARK: - Sanitization (review fix #2)

    func testLeadingDigitGetsUnderscorePrefix() {
        // Swift identifiers can't start with a digit; the sanitizer must
        // make them legal rather than emit broken source.
        XCTAssertEqual(FieldNaming.camelCase(from: "1st_place"), "_1stPlace")
        XCTAssertEqual(FieldNaming.camelCase(from: "10_items"), "_10Items")
    }

    func testReservedWordWrappedInBackticks() {
        XCTAssertEqual(FieldNaming.camelCase(from: "class"), "`class`")
        XCTAssertEqual(FieldNaming.camelCase(from: "type"), "`type`")
    }

    func testEmptyInputFallsBack() {
        XCTAssertEqual(FieldNaming.sanitizeIdentifier(""), "value")
    }

    // MARK: - Kebab-case (review fix #2)

    func testKebabCaseSplitsLikeSnakeCase() {
        XCTAssertEqual(FieldNaming.camelCase(from: "avatar-url"), "avatarURL")
        XCTAssertEqual(FieldNaming.camelCase(from: "user-id"), "userID")
        XCTAssertEqual(FieldNaming.camelCase(from: "long-field-name"), "longFieldName")
    }

    func testMixedSnakeAndKebabSplits() {
        // Some APIs mix conventions; we tolerate both in one key.
        XCTAssertEqual(FieldNaming.camelCase(from: "user-id_v2"), "userIDV2")
    }

    // MARK: - Acronyms

    func testTrailingAcronymsUpcased() {
        XCTAssertEqual(FieldNaming.camelCase(from: "user_id"), "userID")
        XCTAssertEqual(FieldNaming.camelCase(from: "avatar_url"), "avatarURL")
        XCTAssertEqual(FieldNaming.camelCase(from: "post_uuid"), "postUUID")
    }

    func testPascalCaseDelegatesToCamelCase() {
        XCTAssertEqual(FieldNaming.pascalCase(from: "user_id"), "UserID")
        XCTAssertEqual(FieldNaming.pascalCase(from: "avatar-url"), "AvatarURL")
    }

    // MARK: - Singularization

    func testSingularizerCommonForms() {
        XCTAssertEqual(FieldNaming.singularize("posts"), "post")
        XCTAssertEqual(FieldNaming.singularize("addresses"), "address")
        XCTAssertEqual(FieldNaming.singularize("countries"), "country")
    }

    func testSingularizerLeavesMassNounsAlone() {
        XCTAssertEqual(FieldNaming.singularize("class"), "class",
                       "double-s suffix should not be stripped")
    }
}
