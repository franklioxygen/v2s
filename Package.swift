// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "V2SApp",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/V2SApp",
            resources: [
                .copy("Resources/silero_vad.onnx"),
            ]
        ),
    ]
)
