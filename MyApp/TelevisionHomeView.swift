import SwiftUI

struct TelevisionHomeView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var history: WatchStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var epg: EPGRepository
    @EnvironmentObject private var launch: StartupCoordinator
    @State private var recent: [Channel] = []
    @State private var favourites: [Channel] = []
    @State private var onNow: [Channel] = []
    @State private var playing: Channel?
    @State private var query = ""

    private var inputKey: String {
        "\(playlists.channelsRevision)|\(channelPreferences.revision)|\(history.history.map(\.id).joined())"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if playlists.playlists.isEmpty {
                        ContentUnavailableView {
                            Label("Your television, together", systemImage: "tv")
                        } description: {
                            Text("Connect your own media source to browse channels, programmes, movies and series.")
                        } actions: {
                            NavigationLink("Add a source") { PlaylistsSettingsView() }
                        }
                    }
                    if !recent.isEmpty {
                        TelevisionChannelSection(title: "Continue Watching", channels: recent, onPlay: { playing = $0 }, allowsHistoryRemoval: true)
                    }
                    if !onNow.isEmpty {
                        TelevisionChannelSection(title: "On Now", channels: onNow, onPlay: { playing = $0 })
                    }
                    if !favourites.isEmpty {
                        TelevisionChannelSection(title: "Favourite Channels", channels: favourites, onPlay: { playing = $0 })
                    }
                    if preferences.sportsIntegration != .hidden {
                        TelevisionSportsSection(level: preferences.sportsIntegration)
                    }
                    TelevisionUpcomingSection(channels: favourites, onPlay: { playing = $0 })
                    NavigationLink {
                        LiveChannelsView().navigationTitle("Channels")
                    } label: {
                        Label("Browse Categories", systemImage: "square.grid.2x2")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    NavigationLink { EntertainmentLibraryView() } label: {
                        Label("Your Movies & Series", systemImage: "film")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(Theme.Spacing.screen)
            }
            .background(Theme.background)
            .navigationTitle("Banner TV")
            .toolbar {
                NavigationLink { TelevisionSearchView() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search")
            }
            .fullScreenCoverCompat(item: $playing) { PlayerView(channel: $0) }
            .task(id: inputKey) {
                let hidden = channelPreferences.hiddenChannelIDs
                recent = history.history.compactMap { playlists.channelsByID[$0.id] }.filter { !hidden.contains($0.id) }
                favourites = channelPreferences.favoriteChannelIDs.compactMap { playlists.channelsByID[$0] }.filter { !hidden.contains($0.id) }
                var seen = Set<String>()
                let candidates = favourites + recent + Array(playlists.allChannels.prefix(100))
                onNow = Array(candidates.filter { !hidden.contains($0.id) && seen.insert($0.id).inserted }.prefix(12))
                epg.prefetchProgrammes(for: onNow.compactMap { epg.canonicalChannel(forProviderChannelID: $0.id, playlistID: $0.playlistID) })
                launch.markAppShellReady()
            }
        }
    }
}

private struct TelevisionChannelSection: View {
    let title: LocalizedStringResource
    let channels: [Channel]
    let onPlay: (Channel) -> Void
    var allowsHistoryRemoval = false
    @EnvironmentObject private var history: WatchStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            ForEach(channels.prefix(6)) { channel in
                TelevisionChannelRow(channel: channel, onPlay: { onPlay(channel) })
                    .contextMenu {
                        Button(channelPreferences.isFavorite(channel.id) ? "Remove Favourite" : "Add Favourite") {
                            channelPreferences.toggleFavorite(channelID: channel.id)
                        }
                        if allowsHistoryRemoval {
                            Button("Remove from history", role: .destructive) {
                                if let entry = history.history.first(where: { $0.id == channel.id }) { history.removeFromHistory(entry) }
                            }
                        }
                    }
            }
        }
    }
}

struct TelevisionChannelRow: View {
    let channel: Channel
    let onPlay: () -> Void
    @EnvironmentObject private var epg: EPGRepository

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let canonical = epg.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID)
            let programme = canonical.flatMap { epg.currentProgramme(for: $0.id, at: context.date) }
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    CachedImage(url: channel.logoURL) { image in image.resizable().scaledToFit() } placeholder: {
                        Image(systemName: "tv").font(.title2).foregroundStyle(Theme.accent)
                    }
                    .frame(width: 52, height: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(channel.name).font(.headline)
                        if let programme {
                            Text(programme.title).font(.subheadline).foregroundStyle(.secondary)
                            if programme.end > programme.start {
                                ProgressView(value: min(1, max(0, context.date.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start))))
                                    .tint(Theme.accent)
                            }
                            Text("\(programme.start, format: .dateTime.hour().minute()) – \(programme.end, format: .dateTime.hour().minute())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Watch the current broadcast")
        }
    }
}

private struct TelevisionUpcomingSection: View {
    let channels: [Channel]
    let onPlay: (Channel) -> Void
    @EnvironmentObject private var epg: EPGRepository
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(channels.prefix(6)) { channel in
                if let canonical = epg.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID),
                   let programme = epg.nextProgramme(for: canonical.id) {
                    NavigationLink {
                        ProgrammeDetailSheet(programme: programme, channel: canonical, onPlayLive: { onPlay(channel) })
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Coming Up on TV").font(.caption).foregroundStyle(.secondary)
                            Text(programme.title).font(.headline)
                            Text(channel.name).font(.subheadline)
                            Text(programme.start, format: .dateTime.weekday().month().day().hour().minute()).font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TelevisionSportsSection: View {
    let level: SportsIntegrationLevel
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var live: LiveViewModel
    @State private var matches: [Match] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !matches.isEmpty {
                Text("Your Sports").font(.title2.bold())
                ForEach(matches) { match in
                    NavigationLink {
                        MatchDetailView(match: match)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(match.away.displayName) · \(match.home.displayName)").font(.headline)
                            Text(match.date, format: .dateTime.weekday().hour().minute()).font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            if level == .full {
                NavigationLink("Live Sports") { LiveView() }
                NavigationLink("Following") { MatchesView() }
            }
        }
        .task(id: "\(level.rawValue)|\(preferences.favoriteTeams.map(\.id).joined())") {
            guard !preferences.favoriteTeams.isEmpty || level == .full else { matches = []; return }
            let snapshot = await SportsRepository.shared.liveMatchSnapshot(leagues: preferences.followedLeagues,
                startingSoonWindow: 24 * 3600, nextLimit: 30)
            guard !Task.isCancelled else { return }
            let candidates = snapshot.live + snapshot.startingSoon + snapshot.next
            var seen = Set<String>()
            matches = Array(candidates.filter {
                (level == .full || preferences.isFavoriteMatch($0)) && seen.insert($0.id).inserted
            }.prefix(level == .compact ? 2 : 6))
        }
    }
}

struct TelevisionSearchView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
    @State private var query = ""
    @State private var channels: [Channel] = []
    @State private var titles: [EntertainmentItem] = []
    @State private var playing: Channel?
    private let library = EntertainmentRepository.shared

    var body: some View {
        List {
            Section("Channels") {
                ForEach(channels) { channel in
                    Button(channel.name) { playing = channel }
                }
            }
            Section("Movies & Series") {
                ForEach(titles) { item in
                    NavigationLink { EntertainmentDetailView(itemID: item.id) } label: {
                        Label(item.title, systemImage: item.kind == .movie ? "film" : "tv")
                    }
                }
            }
            Section {
                NavigationLink("Search the programme guide") { TVGuideView() }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query)
        .task { await library.load() }
        .task(id: "\(query)|\(playlists.channelsRevision)|\(library.revision)|\(channelPreferences.revision)") {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let inventory = playlists.allChannels
            let items = library.catalog
            let hidden = channelPreferences.hiddenChannelIDs
            let text = query
            let result = await Task.detached(priority: .userInitiated) {
                let key = EntertainmentMatching.normalized(text)
                guard !key.isEmpty else { return ([Channel](), [EntertainmentItem]()) }
                let channels = inventory.lazy.filter {
                    !hidden.contains($0.id) && EntertainmentMatching.normalized($0.name + " " + ($0.group ?? "")).contains(key)
                }.prefix(100)
                let titles = items.lazy.filter { EntertainmentMatching.normalized($0.title).contains(key) }.prefix(100)
                return (Array(channels), Array(titles))
            }.value
            guard !Task.isCancelled else { return }
            channels = result.0; titles = result.1
        }
        .fullScreenCoverCompat(item: $playing) { PlayerView(channel: $0) }
    }
}
