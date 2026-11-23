// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-records",
    // Observation and Predicate set the floors, which also clear swift-versioning's.
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftRecords", targets: ["SwiftRecords"]),
    ],
    dependencies: [
        // Tracks main so each resolve picks up the newest swift-versioning. Package.resolved is ignored for the same reason.
        .package(url: "https://github.com/JonathanStorey/swift-versioning", branch: "main"),
    ],
    targets: [
        .target(
            name: "SwiftRecords",
            dependencies: [
                .product(name: "Versioning", package: "swift-versioning"),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            exclude: ["RecordContainer/README.md"]
        ),
        // Apple platforms import SQLite3 from the SDK. Linux links the system library.
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .testTarget(
            name: "SwiftRecordsTests",
            dependencies: ["SwiftRecords"]
        ),
    ]
)
