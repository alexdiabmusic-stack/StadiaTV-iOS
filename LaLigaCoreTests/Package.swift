// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LaLigaCoreTests", platforms: [.macOS(.v15)], products: [.library(name: "LaLigaCore", targets: ["LaLigaCore"])], targets: [.target(name: "LaLigaCore"), .testTarget(name: "LaLigaCoreTests", dependencies: ["LaLigaCore"], resources: [.copy("Fixtures")])])
