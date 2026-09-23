// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NHLCoreTests",
    platforms: [.macOS(.v15)],
    products: [.library(name: "NHLCore", targets: ["NHLCore"])],
    targets: [
        .target(name: "NHLCore"),
        .testTarget(name: "NHLCoreTests", dependencies: ["NHLCore"], resources: [.copy("Fixtures")])
    ]
)
