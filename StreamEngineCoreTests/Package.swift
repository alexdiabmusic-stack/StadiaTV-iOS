// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamEngineCoreTests",
    platforms: [.macOS(.v15)],
    products: [.library(name: "StreamEngineCore", targets: ["StreamEngineCore"])],
    targets: [
        .target(name: "StreamEngineCore"),
        .testTarget(name: "StreamEngineCoreTests", dependencies: ["StreamEngineCore"])
    ]
)
