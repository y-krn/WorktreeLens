// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorktreeLens",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WorktreeLensCore", targets: ["WorktreeLensCore"]),
        .executable(name: "WorktreeLensApp", targets: ["WorktreeLensApp"])
    ],
    targets: [
        .target(name: "WorktreeLensCore"),
        .executableTarget(name: "WorktreeLensApp", dependencies: ["WorktreeLensCore"]),
        .testTarget(name: "WorktreeLensCoreTests", dependencies: ["WorktreeLensCore", "WorktreeLensApp"])
    ]
)
