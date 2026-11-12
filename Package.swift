// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v13)],
    targets: [
        // Logic that doesn't need the app around it: Figma links, the MCP
        // client, region math, rich text and video writing. Unit tested.
        .target(
            name: "MarginKit",
            path: "Sources/MarginKit"
        ),
        .executableTarget(
            name: "Margin",
            dependencies: ["MarginKit"],
            path: "Sources/Margin"
        ),
        .testTarget(
            name: "MarginKitTests",
            dependencies: ["MarginKit"],
            path: "Tests/MarginKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MarginAppTests",
            dependencies: ["Margin", "MarginKit"],
            path: "Tests/MarginAppTests"
        ),
    ]
)
