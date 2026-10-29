import SwiftUI

/// Resolves current programme at display time; history remains channel history.
struct CompleteOnNowSection: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var preferences: ChannelPreferencesStore
    @EnvironmentObject private var epg: EPGRepository
    @State private var channels: [Channel] = []
    @State private var playing: Channel?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let airing = channels.filter { channel in
                guard let canonical = epg.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID) else { return false }
                return epg.currentProgramme(for: canonical.id, at: context.date) != nil
            }
            if !airing.isEmpty {
                TelevisionChannelSection(title: "Live on TV", channels: Array(airing.prefix(4)), onPlay: { playing = $0 })
            }
        }
        .task(id: "\(playlists.channelsRevision)|\(preferences.revision)") {
            let favourites = preferences.favoriteChannelIDs.sorted().compactMap { playlists.channelsByID[$0] }
            var seen = Set<String>()
            channels = Array((favourites + Array(playlists.allChannels.prefix(100))).filter {
                !preferences.hiddenChannelIDs.contains($0.id) && seen.insert($0.id).inserted
            }.prefix(20))
            epg.prefetchProgrammes(for: channels.compactMap {
                epg.canonicalChannel(forProviderChannelID: $0.id, playlistID: $0.playlistID)
            })
        }
        .fullScreenCoverCompat(item: $playing) { PlayerView(channel: $0) }
    }
}
