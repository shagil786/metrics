// swift-tools-version:6.0
// PortmasterCore: UI-free system-data layer (collectors, sampling, persistence).
import PackageDescription

let package = Package(
    name: "PortmasterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortmasterCore", targets: ["PortmasterCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
        // Not a direct use of our own: the SDK's `Transport` protocol requires a
        // `Logging.Logger`, so conforming a transport of ours means naming the type.
        // Already pinned by swift-sdk, so this adds no new resolution.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "PMShim",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio")]
        ),
        .target(
            name: "PortmasterCore",
            dependencies: ["PMShim"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortmasterCoreTests",
            dependencies: ["PortmasterCore", "PMShim"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PortmasterMCP",
            dependencies: [
                "PortmasterCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "portmaster-mcp",
            dependencies: ["PortmasterMCP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortmasterMCPTests",
            dependencies: ["PortmasterMCP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
