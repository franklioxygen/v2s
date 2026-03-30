// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "v2s",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/V2SApp",
            resources: [
                .copy("Resources/AppIcon/AppIcon-512.png"),
                .copy("Resources/silero_vad.onnx"),
            ]
        ),
    ]
)
