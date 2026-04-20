// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SimulatorPreviewKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SimulatorPreviewKit",
            targets: ["SimulatorPreviewKit"]
        ),
        .library(
            name: "SimulatorPreviewCore",
            targets: ["SimulatorPreviewCore"]
        ),
        .library(
            name: "SimulatorPreviewBridge",
            targets: ["SimulatorPreviewBridge"]
        ),
        .library(
            name: "SimulatorPreviewHTTP",
            targets: ["SimulatorPreviewHTTP"]
        ),
        .executable(
            name: "simulator-preview-demo",
            targets: ["simulator-preview-demo"]
        ),
    ],
    targets: [
        .target(
            name: "SimulatorPreviewCore"
        ),
        .target(
            name: "SimulatorPreviewBridge",
            dependencies: ["SimulatorPreviewCore"]
        ),
        .target(
            name: "SimulatorPreviewHTTP",
            dependencies: ["SimulatorPreviewCore", "SimulatorPreviewBridge"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "SimulatorPreviewKit",
            dependencies: ["SimulatorPreviewCore", "SimulatorPreviewBridge", "SimulatorPreviewHTTP"]
        ),
        .executableTarget(
            name: "simulator-preview-demo",
            dependencies: ["SimulatorPreviewKit"]
        ),
        .testTarget(
            name: "SimulatorPreviewCoreTests",
            dependencies: ["SimulatorPreviewCore", "SimulatorPreviewBridge"]
        ),
        .testTarget(
            name: "SimulatorPreviewHTTPTests",
            dependencies: ["SimulatorPreviewHTTP"]
        ),
    ]
)
