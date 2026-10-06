#if os(macOS)
import SwiftUI

/// Menu bar commands for the Mac build. Reaches the live player through
/// `BannerAppEnvironment.shared` — the same app-wide singleton CarPlay already uses to
/// drive playback without a SwiftUI environment of its own (see BannerAppEnvironment.swift).
struct MacCommands: Commands {
    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                BannerAppEnvironment.shared.playbackController.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Mute") {
                let controller = BannerAppEnvironment.shared.playbackController
                controller.setMuted(!controller.isMuted)
            }
            .keyboardShortcut("m", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Home") { BannerAppEnvironment.shared.requestedTab = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button("Following") { BannerAppEnvironment.shared.requestedTab = .following }
                .keyboardShortcut("2", modifiers: .command)
            Button("Live") { BannerAppEnvironment.shared.requestedTab = .live }
                .keyboardShortcut("3", modifiers: .command)
            Button("Discover") { BannerAppEnvironment.shared.requestedTab = .discover }
                .keyboardShortcut("4", modifiers: .command)
        }
    }
}
#endif
