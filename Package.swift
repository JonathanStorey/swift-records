// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-records",
    // Floors match swift-versioning, which cannot be undercut by a package that depends on it.
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
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
            dependencies: [.product(name: "Versioning", package: "swift-versioning")]
        ),
        .testTarget(
            name: "SwiftRecordsTests",
            dependencies: ["SwiftRecords"]
        ),
    ]
)
