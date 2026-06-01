// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SmartAPI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SmartAPI", targets: ["SmartAPI"]),
        .executable(name: "smartapi-bundle", targets: ["SmartAPIBundle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .macro(
            name: "SmartAPIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            swiftSettings: swift6Settings
        ),
        .target(
            name: "SmartAPI",
            dependencies: ["SmartAPIMacros"],
            swiftSettings: swift6Settings
        ),
        .target(
            name: "SmartAPIImporter",
            // Pure logic: OpenAPI 3.0 → Swift wrappers, no I/O. Lives in its
            // own library target so the CLI and the test suite can both
            // depend on it.
            swiftSettings: swift6Settings
        ),
        .executableTarget(
            name: "SmartAPIBundle",
            dependencies: ["SmartAPIImporter"],
            // Run with: `swift run smartapi-bundle <dir1> [<dir2> ...]`
            path: "Sources/smartapi-bundle",
            swiftSettings: swift6Settings
        ),
        .testTarget(
            name: "SmartAPITests",
            dependencies: [
                "SmartAPI",
                "SmartAPIMacros",
                "SmartAPIImporter",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            // Resources/ holds JSON samples the macro plugin reads at
            // build time via FileManager — they're not Swift resources, so
            // exclude them from SPM's resource processing.
            exclude: ["Resources"],
            swiftSettings: swift6Settings
        ),
    ]
)

// Lock every owned target to Swift 6 language mode + the upcoming
// features we want enforced. Centralizing keeps target definitions tidy
// and makes opting into a new upcoming feature a one-line change.
var swift6Settings: [SwiftSetting] {
    [
        .swiftLanguageMode(.v6),
        // `ExistentialAny` requires `any` on protocol existentials — catches
        // accidental boxing and reads better. Cheap to satisfy in this code.
        .enableUpcomingFeature("ExistentialAny"),
    ]
}
