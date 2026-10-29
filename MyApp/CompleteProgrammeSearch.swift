import SwiftUI

/// Searches the already-loaded guide, without starting provider requests for keystrokes.
struct CompleteProgrammeSearch: View {
    let query: String
    @EnvironmentObject private var epg: EPGRepository
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
    @State private var matches: [ProgrammeSearchEntry] = []
    @State private var playing: Channel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !matches.isEmpty {
                Text("On TV Now").font(.title2.bold())
                ForEach(matches) { entry in
                    Button { playing = playlists.channelsByID[entry.channelID] } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline)
                            Text(entry.channelName).font(.subheadline).foregroundStyle(.secondary)
                            Label("Watch Live", systemImage: "dot.radiowaves.left.and.right").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            NavigationLink("Search the full programme guide") { TVGuideView() }
        }
        .task(id: "\(query)|\(playlists.channelsRevision)|\(epg.lastUpdated?.timeIntervalSince1970 ?? 0)") {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let key = EntertainmentMatching.normalized(query)
            guard !key.isEmpty else { matches = []; return }
            let titles = epg.cachedCurrentTitles()
            let inventory = playlists.allChannels
            let hidden = channelPreferences.hiddenChannelIDs
            var entries: [ProgrammeSearchEntry] = []
            var seen = Set<String>()
            for channel in inventory where !hidden.contains(channel.id) {
                guard let canonical = epg.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID),
                      let title = titles[canonical.id], seen.insert(canonical.id).inserted else { continue }
                entries.append(ProgrammeSearchEntry(id: canonical.id, title: title, channelID: channel.id, channelName: channel.name))
            }
            let snapshot = entries
            let result = await Task.detached(priority: .userInitiated) {
                Array(snapshot.filter { EntertainmentMatching.normalized($0.title).contains(key) }.sorted {
                    let a = EntertainmentMatching.normalized($0.title) == key
                    let b = EntertainmentMatching.normalized($1.title) == key
                    return a == b ? $0.id < $1.id : a
                }.prefix(12))
            }.value
            guard !Task.isCancelled else { return }
            matches = result
        }
        .fullScreenCoverCompat(item: $playing) { PlayerView(channel: $0) }
    }
}

nonisolated private struct ProgrammeSearchEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let channelID: String
    let channelName: String
}
