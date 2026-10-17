// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LLMBar",
            path: "Sources/LLMBar",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LLMBarTests",
            dependencies: ["LLMBar"],
            path: "Tests/LLMBarTests"
        )
    ]
)
