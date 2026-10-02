// swift-tools-version:6.0
// PortmasterCore: UI-free system-data layer (collectors, sampling, persistence).
import PackageDescription

let package = Package(
    name: "PortmasterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortmasterCore", targets: ["PortmasterCore"])
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
        )
    ]
)
