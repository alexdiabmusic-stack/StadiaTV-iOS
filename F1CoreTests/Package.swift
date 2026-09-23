// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "F1CoreTests", platforms: [.macOS(.v15)], targets: [.target(name: "F1Core", linkerSettings: [.linkedLibrary("z")]), .testTarget(name: "F1CoreTests", dependencies: ["F1Core"], resources: [.copy("Fixtures")])])
