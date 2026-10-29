import SwiftUI

struct CompleteToolbar: ViewModifier {
    @State private var settings = false
    func body(content: Content) -> some View {
        content.toolbar {
            NavigationLink { SearchView() } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search all content")
            Button { settings = true } label: { Image(systemName: "person.crop.circle") }
                .accessibilityLabel("Settings and preferences")
        }
        .sheet(isPresented: $settings) { MoreView(showsDoneButton: true) }
    }
}

struct CompleteTelevisionView: View {
    var body: some View {
        NavigationStack {
            LiveChannelsView()
                .navigationTitle("Live TV")
                .toolbar {
                    NavigationLink { TVGuideView() } label: { Label("Guide", systemImage: "calendar") }
                }
                .modifier(CompleteToolbar())
        }
    }
}

struct CompleteSportsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    TelevisionSportsSection(level: .full)
                    NavigationLink("Scores & Game Centres") { LiveView() }
                    NavigationLink("Following & Schedules") { MatchesView() }
                    NavigationLink("News, Podcasts & Discovery") { DiscoverView() }
                    NavigationLink("Sports Home") { HomeView(switchToFollowing: {}) }
                }
                .padding(Theme.Spacing.screen)
            }
            .background(Theme.background)
            .navigationTitle("Sports")
            .modifier(CompleteToolbar())
        }
    }
}

struct CompleteHomeView: View {
    @SceneStorage("banner.navigation.completeHome.v1") private var savedPath = "[]"
    @State private var path: [String] = []
    @State private var restored = false
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var history: WatchStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
    @EnvironmentObject private var launch: StartupCoordinator
    @EnvironmentObject private var live: LiveViewModel
    @EnvironmentObject private var preferences: PreferencesStore
    @AppStorage("banner.complete.sportsVisibility.v1") private var sportsVisibility = "balanced"
    private let repository = EntertainmentRepository.shared
    @State private var continuing: [EntertainmentItem] = []
    @State private var upNext: [EntertainmentItem] = []
    @State private var movies: [EntertainmentItem] = []
    @State private var series: [EntertainmentItem] = []
    @State private var recent: [Channel] = []
    @State private var playing: Channel?

    private var sportsFirst: Bool {
        sportsVisibility == "prominent" ||
        (sportsVisibility != "minimal" && live.allLive.contains { preferences.isFavoriteMatch($0) })
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if sportsFirst { TelevisionSportsSection(level: .compact) }
                    if let featured = continuing.first ?? movies.first ?? series.first {
                        CompleteHero(item: featured)
                    }
                    if !continuing.isEmpty {
                        CompleteContentRail(title: "Continue Watching", items: continuing, showsProgress: true)
                    }
                    if !upNext.isEmpty {
                        CompleteContentRail(title: "Up Next", items: upNext, showsProgress: true)
                    }
                    CompleteOnNowSection()
                    if !recent.isEmpty {
                        TelevisionChannelSection(title: "Recently Watched Live TV", channels: recent,
                            onPlay: { playing = $0 }, allowsHistoryRemoval: true)
                    }
                    if !sportsFirst && sportsVisibility != "minimal" { TelevisionSportsSection(level: .compact) }
                    CompleteContentRail(title: "Movies for You", items: movies, showsProgress: false)
                    CompleteContentRail(title: "Series for You", items: series, showsProgress: false)
                    if repository.catalog.isEmpty {
                        ContentUnavailableView {
                            Label("Your TV. Your way.", systemImage: "play.rectangle")
                        } description: {
                            Text("Connect a source with movies or series to build your entertainment library. Browse Live TV and Sports from their tabs.")
                        } actions: {
                            NavigationLink("Manage Sources") { PlaylistsSettingsView() }
                        }
                    }
                    CompleteBrowseSection()
                }
                .padding(Theme.Spacing.screen)
            }
            .background(Theme.background)
            .navigationTitle("Banner TV")
            .navigationDestination(for: String.self) { EntertainmentDetailView(itemID: $0) }
            .onAppear {
                if !restored { restored = true; path = EntertainmentNavigationState.decode(savedPath) }
            }
            .onChange(of: path) { _, value in savedPath = EntertainmentNavigationState.encode(value) }
            .modifier(CompleteToolbar())
            .fullScreenCoverCompat(item: $playing) { PlayerView(channel: $0) }
            .task(id: playlists.channelsRevision) {
                launch.markAppShellReady()
                await repository.sync(playlists: playlists.playlists, channels: playlists.allChannels)
            }
            .task(id: "\(repository.revision)|\(repository.userStateRevision)|\(history.history.map(\.id))|\(channelPreferences.revision)") {
                let items = repository.catalog
                let episodes = repository.seasonsBySeries.values.flatMap { $0.flatMap(\.episodes) }
                let progress = repository.progress, watchlist = repository.watchlist
                let hidden = repository.hiddenContinueWatching
                let result = await Task.detached(priority: .utility) { () -> ([EntertainmentItem], [EntertainmentItem], [EntertainmentItem], [EntertainmentItem]) in
                    let continuing = Array(EntertainmentDiscovery.continuing(items: items + episodes, progress: progress).filter { !hidden.contains($0.progressID) }.prefix(10))
                    let excluded = Set(continuing.map(\.id))
                    let shows = items.filter { $0.kind == .series }
                    let episodesBySeries = Dictionary(grouping: episodes, by: { $0.seriesID ?? "" })
                    let next: [EntertainmentItem] = shows.compactMap { show -> EntertainmentItem? in
                        let availableEpisodes = episodesBySeries[show.id] ?? []
                        guard availableEpisodes.contains(where: { EntertainmentDiscovery.state($0, progress: progress) != nil }) else { return nil }
                        return EntertainmentDiscovery.nextEpisode(seriesID: show.id, episodes: availableEpisodes, progress: progress)
                    }.filter { !excluded.contains($0.id) }.sorted { $0.id < $1.id }
                    return (continuing, Array(next.prefix(10)),
                        EntertainmentDiscovery.recommendations(items: items, kind: .movie, progress: progress, watchlist: watchlist, excluding: excluded),
                        EntertainmentDiscovery.recommendations(items: items, kind: .series, progress: progress, watchlist: watchlist))
                }.value
                guard !Task.isCancelled else { return }
                continuing = result.0; upNext = result.1; movies = result.2; series = result.3
                recent = Array(history.history.compactMap { playlists.channelsByID[$0.id] }
                    .filter { !channelPreferences.hiddenChannelIDs.contains($0.id) }.prefix(4))
            }
        }
    }
}

struct CompleteHero: View {
    let item: EntertainmentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let backdrop = item.metadata.backdrop {
                CachedImage(url: backdrop) { image in image.resizable().scaledToFit() } placeholder: {
                    Rectangle().fill(Theme.surface).aspectRatio(16 / 9, contentMode: .fit)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            }
            Text(item.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            if let overview = item.metadata.overview { Text(overview).lineLimit(3).foregroundStyle(.secondary) }
            NavigationLink(value: item.seriesID ?? item.id) {
                Label("Details & Watching Options", systemImage: "play.circle")
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct CompleteContentRail: View {
    let title: LocalizedStringResource
    let items: [EntertainmentItem]
    let showsProgress: Bool
    private let repository = EntertainmentRepository.shared
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold())
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(value: item.seriesID ?? item.id) {
                                VStack(alignment: .leading, spacing: 8) {
                                    EntertainmentPosterCard(item: item)
                                    if showsProgress, let progress = repository.watchProgress(for: item),
                                       let duration = progress.duration, duration > 0 {
                                        ProgressView(value: min(1, progress.position / duration))
                                            .accessibilityLabel("Viewing progress")
                                            .accessibilityValue(Text("\(Int(min(100, progress.position / duration * 100))) percent"))
                                    }
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if showsProgress {
                                    Button("Remove from Continue Watching", role: .destructive) { repository.hideFromContinueWatching(item) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CompleteBrowseSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse Your Entertainment").font(.title2.bold())
            NavigationLink("Movies") { EntertainmentLibraryView(fixedKind: .movie) }
            NavigationLink("Series") { EntertainmentLibraryView(fixedKind: .series) }
            NavigationLink("Live TV & Guide") { CompleteTelevisionView() }
            NavigationLink("Sports") { CompleteSportsView() }
            NavigationLink("Watchlist & History") { EntertainmentCollectionsView() }
        }
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
