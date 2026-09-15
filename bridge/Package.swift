// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentBridge",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../SharedModels")
    ],
    targets: [
        .executableTarget(
            name: "AgentBridge",
            dependencies: [
                .product(name: "AgentBridgeModels", package: "SharedModels")
            ],
            path: "Sources/AgentBridge"
        )
    ]
)
