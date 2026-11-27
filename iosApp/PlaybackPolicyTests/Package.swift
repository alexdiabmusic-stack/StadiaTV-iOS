// swift-tools-version: 6.0
import PackageDescription

// Runs the hybrid player's selection and fallback rules (iosApp/iosApp/Player/PlaybackBackendPolicy.swift) and their tests
// (iosApp/iosAppTests/PlaybackBackendPolicyTests.swift) without launching the app: `swift test` in this folder.
// Both files are symlinks to the real sources, so there is one copy of each.
let package = Package(
    name: "PlaybackPolicyTests",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(name: "PlaybackPolicy"),
        .testTarget(name: "PlaybackPolicyTests", dependencies: ["PlaybackPolicy"]),
    ]
)
