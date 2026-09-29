// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "debrief",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "debrief", targets: ["ChorusCLI"])],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            exact: "1.24.2"
        ),
    ],
    targets: [
        .target(
            name: "ChorusCore",
            dependencies: [
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                ),
            ]
        ),
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
