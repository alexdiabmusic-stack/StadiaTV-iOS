// swift-tools-version:5.9
import PackageDescription

// BannerTV for macOS: a native SwiftUI/AppKit app.
//  - BannerPlayer: the mpv player (Metal, MoltenVK, VideoToolbox), ported from the iPhone player.
//  - BannerTVMac:  the app shell and screens.
// BannerCore: the Kotlin core (recommendations, Explore, row order). Built by
//   ./gradlew -Pnuvio.android.distribution=full :bannerCore:assembleBannerCoreDebugXCFramework
// and copied to Frameworks/ by Scripts/sync-core.sh.
let package = Package(
    name: "BannerTVMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BannerTVMac", targets: ["BannerTVMac"]),
        .library(name: "BannerPlayer", targets: ["BannerPlayer"]),
    ],
    dependencies: [
        // The GPL variant is the only MPVKit build that ships a macOS slice.
        .package(path: "../MPVKit"),
    ],
    targets: [
        .target(
            name: "BannerPlayer",
            dependencies: [.product(name: "MPVKit-GPL", package: "MPVKit")]
        ),
        .binaryTarget(name: "BannerCore", path: "Frameworks/BannerCore.xcframework"),
        .executableTarget(
            name: "BannerTVMac",
            dependencies: ["BannerPlayer", "BannerCore"]
        ),
    ]
)
