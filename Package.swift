// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-records",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftRecords", targets: ["SwiftRecords"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
        .package(url: "https://github.com/JonathanStorey/swift-merging.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/JonathanStorey/swift-identification.git", .upToNextMinor(from: "0.2.0")),
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
                .product(name: "Merging", package: "swift-merging"),
                .product(name: "Identification", package: "swift-identification"),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
        // A sync engine over an in-memory server, for the tests and benchmarks. Not a product.
        .target(
            name: "SyncTestSupport",
            dependencies: ["SwiftRecords"]
        ),
        // Times the heaviest operations on a large store: `swift run -c release Benchmarks`.
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["SwiftRecords", "SyncTestSupport", .product(name: "Identification", package: "swift-identification")]
        ),
        .testTarget(
            name: "SwiftRecordsTests",
            dependencies: [
                "SwiftRecords", "SyncTestSupport",
                .product(name: "Identification", package: "swift-identification"),
            ]
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
