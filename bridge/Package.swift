// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentBridge",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .target(
            name: "AgentBridgeCore",
            dependencies: [
                .product(name: "AgentBridgeModels", package: "SharedModels")
            ],
            path: "Sources/AgentBridgeCore"
        ),
        .executableTarget(
            name: "AgentBridge",
            dependencies: [
                "AgentBridgeCore",
                .product(name: "AgentBridgeModels", package: "SharedModels")
            ],
            path: "Sources/AgentBridge"
        ),
        .testTarget(
            name: "AgentBridgeTests",
            dependencies: [
                "AgentBridgeCore",
                .product(name: "AgentBridgeModels", package: "SharedModels")
            ],
            path: "Tests/AgentBridgeTests"
        )
    ]
)
