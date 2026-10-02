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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1")
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
            dependencies: ["PortmasterCore", .product(name: "MCP", package: "swift-sdk")],
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
