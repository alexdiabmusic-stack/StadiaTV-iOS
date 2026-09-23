// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NBACoreTests", platforms: [.macOS(.v15)], products: [.library(name: "NBACore", targets: ["NBACore"])], targets: [.target(name: "NBACore"), .testTarget(name: "NBACoreTests", dependencies: ["NBACore"], resources: [.copy("Fixtures")])])
