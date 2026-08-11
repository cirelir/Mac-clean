// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanCore", targets: ["CleanCore"]),
        .library(name: "MacCleanUI", targets: ["MacCleanUI"]),
        .executable(name: "MacCleanApp", targets: ["MacCleanApp"])
    ],
    targets: [
        .target(name: "CleanCore"),
        .target(name: "MacCleanUI", dependencies: ["CleanCore"]),
        .executableTarget(name: "MacCleanApp", dependencies: ["MacCleanUI", "CleanCore"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "MacCleanUITests", dependencies: ["MacCleanUI", "CleanCore"])
    ],
    swiftLanguageModes: [.v6]
)
