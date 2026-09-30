// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "v2s",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/V2SApp",
            resources: [
                .copy("Resources/AppIcon/AppIcon-512.png"),
                .copy("Resources/SileroVAD.mlpackage"),
            ]
        ),
        .testTarget(
            name: "v2sTests",
            dependencies: ["v2s"],
            path: "Tests/V2STests"
        ),
    ]
)
