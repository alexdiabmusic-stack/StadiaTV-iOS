// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EPLCoreTests", platforms: [.macOS(.v15)], products: [.library(name: "EPLCore", targets: ["EPLCore"])], targets: [.target(name: "EPLCore"), .testTarget(name: "EPLCoreTests", dependencies: ["EPLCore"], resources: [.copy("Fixtures")])])
