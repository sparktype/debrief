// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chorus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "chorus", targets: ["ChorusCLI"])],
    targets: [
        .target(name: "ChorusCore"),
        .executableTarget(name: "ChorusCLI", dependencies: ["ChorusCore"]),
        .testTarget(
            name: "ChorusCoreTests",
            dependencies: ["ChorusCore"],
            path: "SwiftTests/ChorusCoreTests"
        ),
        .testTarget(
            name: "ChorusIntegrationTests",
            dependencies: ["ChorusCore"],
            path: "SwiftTests/ChorusIntegrationTests"
        ),
    ]
)
