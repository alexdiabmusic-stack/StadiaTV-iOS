// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MLBCoreTests", platforms: [.macOS(.v15)], products: [.library(name: "MLBCore", targets: ["MLBCore"])], targets: [.target(name: "MLBCore"), .testTarget(name: "MLBCoreTests", dependencies: ["MLBCore"], resources: [.copy("Fixtures")])])
