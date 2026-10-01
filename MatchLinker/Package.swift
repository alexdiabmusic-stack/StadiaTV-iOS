// swift-tools-version: 6.2
import PackageDescription

// Local harness for StreamLinker.
//   swift test                                        runs the golden tests
//   swift run -c release linker-cli DIR guide.json events.json out.json
//
// The build settings mirror the app target (Swift 5 language mode, default MainActor isolation),
// so an isolation problem shows up here and not in Xcode.
let app: [SwiftSetting] = [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]

let package = Package(
    name: "MatchLinker",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BannerTV", targets: ["BannerTV"])],
    targets: [
        .target(name: "BannerTV", path: "Sources/BannerTV", swiftSettings: app),
        .executableTarget(name: "linker-cli", dependencies: ["BannerTV"], path: "Sources/linker-cli", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BannerTVTests", dependencies: ["BannerTV"], path: "Tests/BannerTVTests", swiftSettings: app),
    ]
)
