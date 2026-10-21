// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-records",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwiftRecords", targets: ["SwiftRecords"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
    ],
    targets: [
        // Apple platforms ship SQLite3 in the SDK. Linux links the system library (for CI and local tests).
        .systemLibrary(
            name: "CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .macro(
            name: "SwiftRecordsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftRecords",
            dependencies: [
                "SwiftRecordsMacros",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "SwiftRecordsTests",
            dependencies: ["SwiftRecords"]
        ),
        .testTarget(
            name: "SwiftRecordsMacrosTests",
            dependencies: [
                "SwiftRecordsMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
