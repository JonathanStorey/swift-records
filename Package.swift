// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-records",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwiftRecords", targets: ["SwiftRecords"]),
        .library(name: "SwiftRecordsFileSync", targets: ["SwiftRecordsFileSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
        .package(url: "https://github.com/JonathanStorey/swift-merging.git", from: "0.1.0"),
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
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
        // Syncs through a shared folder, such as iCloud Drive, using only the public `SyncProvider` API.
        .target(
            name: "SwiftRecordsFileSync",
            dependencies: ["SwiftRecords"]
        ),
        // Times the heaviest operations on a large store: `swift run -c release Benchmarks`.
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["SwiftRecords"]
        ),
        .testTarget(
            name: "SwiftRecordsTests",
            dependencies: ["SwiftRecords", "SwiftRecordsFileSync"]
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
