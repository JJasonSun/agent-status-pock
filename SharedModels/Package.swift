// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SharedModels",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentBridgeModels", targets: ["AgentBridgeModels"])
    ],
    targets: [
        .target(name: "AgentBridgeModels", path: "Sources/AgentBridgeModels")
    ]
)
