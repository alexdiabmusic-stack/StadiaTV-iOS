import SwiftUI

/// Embeds a player's Metal surface in SwiftUI.
public struct MPVVideoSurface: NSViewRepresentable {
    public let player: MPVPlayer

    public init(player: MPVPlayer) { self.player = player }

    public func makeNSView(context: Context) -> MPVVideoView { player.view }
    public func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}
