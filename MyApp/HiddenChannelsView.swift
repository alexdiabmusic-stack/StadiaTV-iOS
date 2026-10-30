import SwiftUI

struct HiddenChannelsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var preferences: ChannelPreferencesStore
    @State private var channels: [Channel] = []
    var body: some View {
        List {
            if channels.isEmpty {
                ContentUnavailableView("No hidden channels", systemImage: "eye")
            }
            ForEach(channels) { channel in
                HStack {
                    Text(channel.name)
                    Spacer()
                    Button("Restore") { preferences.setHidden(false, for: channel.id) }
                }
            }
        }
        .navigationTitle("Hidden Channels")
        .task(id: "\(playlists.channelsRevision)|\(preferences.revision)") {
            channels = preferences.hiddenChannelIDs.compactMap { playlists.channelsByID[$0] }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
