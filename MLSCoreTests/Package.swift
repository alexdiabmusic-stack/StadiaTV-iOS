// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MLSCoreTests", platforms: [.macOS(.v15)], products: [.library(name: "MLSCore", targets: ["MLSCore"])], targets: [.target(name: "MLSCore"), .testTarget(name: "MLSCoreTests", dependencies: ["MLSCore"], resources: [.copy("Fixtures")])])
