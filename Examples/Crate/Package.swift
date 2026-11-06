// swift-tools-version: 6.0

import PackageDescription

// Crate, a record collection that exercises SwiftRecords end to end: every kind of relationship, every
// property wrapper, merging and CloudKit sync. The models build and test on Linux, the views on Apple
// platforms, and `App/Crate.xcodeproj` wraps them in an app for a Mac and an iPhone.
let package = Package(
    name: "Crate",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CrateModels", targets: ["CrateModels"]),
        .library(name: "CrateUI", targets: ["CrateUI"]),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/JonathanStorey/swift-identification.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(
            name: "CrateModels",
            dependencies: [
                .product(name: "SwiftRecords", package: "swift-records"),
                .product(name: "Identification", package: "swift-identification"),
            ]
        ),
        .target(name: "CrateUI", dependencies: ["CrateModels"]),
        .testTarget(name: "CrateModelsTests", dependencies: ["CrateModels"]),
    ]
)
