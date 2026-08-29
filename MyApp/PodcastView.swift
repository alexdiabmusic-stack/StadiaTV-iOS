import SwiftUI
import AVFoundation
import AVKit

// MARK: - Podcast browser (full view, opened from Discover)

struct PodcastBrowserView: View {
    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var prefs: PreferencesStore

    @State private var selectedFilter: PodcastFilter = .forYou
    @State private var searchText = ""
    @State private var searchResults: [Podcast] = []
    @State private var isSearching = false
    @State private var selectedPodcast: Podcast?
    @State private var showingPlayer = false
    @State private var teamPodcastCache: [String: [Podcast]] = [:]
    @State private var loadingTeamIDs: Set<String> = []

    private var allFilters: [PodcastFilter] {
        var filters: [PodcastFilter] = [.forYou, .subscribed]
        for team in prefs.favoriteTeams.prefix(6) { filters.append(.team(team)) }
        for group in SportGroup.allCases { filters.append(.sport(group)) }
        return filters
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterStrip
                    content
                }
            }
            .navigationTitle("Sports Talk")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search podcasts")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: searchText) { if searchText.isEmpty { searchResults = [] } }
            .navigationDestination(item: $selectedPodcast) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .sheet(isPresented: $showingPlayer) {
                PodcastPlayerSheet()
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allFilters) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 10)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func filterChip(_ filter: PodcastFilter) -> some View {
        Button { withAnimation(.snappy) { selectedFilter = filter } } label: {
            Text(filter.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selectedFilter == filter ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selectedFilter == filter ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selectedFilter == filter ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !searchText.isEmpty {
            searchContent
        } else {
            browseContent
        }
    }

    private var searchContent: some View {
        Group {
            if isSearching {
                VStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
            } else if searchResults.isEmpty && !searchText.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No results", subtitle: "Try a different search term.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchResults) { podcast in
                            PodcastRow(podcast: podcast) { selectedPodcast = podcast }
                            Divider().overlay(Theme.hairline)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(20)
                }
            }
        }
    }

    @ViewBuilder
    private var browseContent: some View {
        switch selectedFilter {
        case .forYou:       forYouContent
        case .subscribed:   subscribedContent
        case .team(let t):  teamContent(t)
        case .sport(let g): sportContent(g)
        }
    }

    private var forYouContent: some View {
        let feeds = store.catalogFeedsForFollowedSports(prefs.followedLeagues)
        return Group {
            if feeds.isEmpty && prefs.favoriteTeams.isEmpty {
                emptyState(icon: "waveform", title: "Follow some leagues", subtitle: "Your podcast recommendations will appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !prefs.favoriteTeams.isEmpty {
                            PodcastSectionHeader(title: "MY TEAMS", actionTitle: nil)
                            LazyVStack(spacing: 0) {
                                ForEach(prefs.favoriteTeams.prefix(6)) { team in
                                    teamRow(team)
                                    if team.id != prefs.favoriteTeams.prefix(6).last?.id {
                                        Divider().overlay(Theme.hairline)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                        }
                        if !feeds.isEmpty {
                            PodcastSectionHeader(title: "RECOMMENDED FOR YOU", actionTitle: nil)
                            podcastGrid(feeds: feeds)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func teamRow(_ team: FavoriteTeam) -> some View {
        Button {
            withAnimation(.snappy) { selectedFilter = .team(team) }
        } label: {
            HStack(spacing: 12) {
                TeamLogo(url: team.logoURL, size: 36)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(team.leaguePath.components(separatedBy: "/").last?.uppercased() ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                let pods = teamPodcastCache[team.id] ?? []
                if loadingTeamIDs.contains(team.id) {
                    ProgressView().scaleEffect(0.7)
                } else if !pods.isEmpty {
                    Text("\(pods.count) shows")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .task(id: team.id) { await loadTeamPodcasts(for: team) }
    }

    private func loadTeamPodcasts(for team: FavoriteTeam) async {
        guard teamPodcastCache[team.id] == nil, !loadingTeamIDs.contains(team.id) else { return }
        loadingTeamIDs.insert(team.id)
        let pods = await store.resolvePodcasts(for: team)
        teamPodcastCache[team.id] = pods
        loadingTeamIDs.remove(team.id)
    }

    private func teamContent(_ team: FavoriteTeam) -> some View {
        Group {
            if loadingTeamIDs.contains(team.id) {
                VStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
            } else {
                let pods = teamPodcastCache[team.id] ?? []
                if pods.isEmpty {
                    VStack {
                        Spacer()
                        emptyState(icon: "waveform", title: "Loading \(team.displayName) podcasts",
                                   subtitle: "Searching for team-specific shows…")
                        Spacer()
                    }
                    .task { await loadTeamPodcasts(for: team) }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(pods) { podcast in
                                PodcastRow(podcast: podcast) { selectedPodcast = podcast }
                                Divider().overlay(Theme.hairline)
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                        .padding(20)
                    }
                }
            }
        }
    }

    private var subscribedContent: some View {
        let ids = store.subscribedIDs
        let shows = ids.compactMap { store.podcastMetaCache[$0] }
        return Group {
            if shows.isEmpty {
                emptyState(icon: "bookmark", title: "No subscriptions yet", subtitle: "Subscribe to a show to see it here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shows) { podcast in
                            PodcastRow(podcast: podcast) { selectedPodcast = podcast }
                            Divider().overlay(Theme.hairline)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(20)
                }
            }
        }
    }

    private func sportContent(_ sport: SportGroup) -> some View {
        let feeds = store.catalogFeeds(forSport: sport)
        return Group {
            if feeds.isEmpty {
                emptyState(icon: "waveform", title: "Coming soon", subtitle: "No curated shows for this sport yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        podcastGrid(feeds: feeds)
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: - Podcast card grid

    private func podcastGrid(feeds: [PodcastCatalog.CatalogFeed]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(feeds) { feed in
                let podcast = Podcast(id: feed.feedURL.absoluteString,
                                     title: feed.title,
                                     publisher: "",
                                     feedURL: feed.feedURL,
                                     artworkURL: nil,  // PodcastCardTile reads from cache itself
                                     podcastDescription: "",
                                     sport: feed.sport,
                                     tags: feed.tags)
                PodcastCardTile(podcast: podcast) { selectedPodcast = podcast }
            }
        }
    }

    // MARK: - Search

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        Task {
            searchResults = await store.search(query: query)
            isSearching = false
        }
    }

    // MARK: - Empty state

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary.opacity(0.45))
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Filter model

private enum PodcastFilter: Hashable, Identifiable {
    case forYou
    case subscribed
    case team(FavoriteTeam)
    case sport(SportGroup)

    var id: String { title }

    var title: String {
        switch self {
        case .forYou:         return "For You"
        case .subscribed:     return "Subscribed"
        case .team(let t):    return t.displayName
        case .sport(let g):   return g.rawValue
        }
    }
}

// MARK: - Podcast card tile (grid item)

struct PodcastCardTile: View {
    let podcast: Podcast
    let onTap: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var artworkURL: URL? {
        store.podcastMetaCache[podcast.id]?.artworkURL ?? podcast.artworkURL
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                PodcastArtwork(url: artworkURL, size: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(podcast.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !podcast.publisher.isEmpty {
                    Text(podcast.publisher)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: podcast.id) { await store.fetchArtwork(for: podcast.feedURL) }
    }
}

// MARK: - Podcast row (list item)

struct PodcastRow: View {
    let podcast: Podcast
    let onTap: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var artworkURL: URL? {
        store.podcastMetaCache[podcast.id]?.artworkURL ?? podcast.artworkURL
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PodcastArtwork(url: artworkURL, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(podcast.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !podcast.publisher.isEmpty {
                        Text(podcast.publisher)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if let sport = podcast.sport {
                        Text(sport.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .task(id: podcast.id) { await store.fetchArtwork(for: podcast.feedURL) }
    }
}

// MARK: - Podcast detail (episode list)

struct PodcastDetailView: View {
    let podcast: Podcast
    @EnvironmentObject private var store: PodcastStore
    @State private var showingPlayer = false
    @State private var mediumFilter: PodcastMedium? = nil  // nil = show all

    private var allEpisodes: [PodcastEpisode] {
        store.episodesByFeed[podcast.id] ?? []
    }
    private var hasVideoEpisodes: Bool { allEpisodes.contains { $0.isVideo } }
    private var hasAudioEpisodes: Bool { allEpisodes.contains { !$0.isVideo } }
    private var showsMediumFilter: Bool { hasVideoEpisodes && hasAudioEpisodes }

    private var episodes: [PodcastEpisode] {
        guard let filter = mediumFilter else { return allEpisodes }
        return allEpisodes.filter { $0.medium == filter }
    }

    private var isLoading: Bool { store.loadingFeedIDs.contains(podcast.id) }
    private var isSubscribed: Bool { store.isSubscribed(podcast) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                podcastHeader
                Divider().overlay(Theme.hairline)
                if showsMediumFilter {
                    mediumFilterBar
                    Divider().overlay(Theme.hairline)
                }
                if isLoading && allEpisodes.isEmpty {
                    Spacer(); ProgressView().tint(Theme.accent); Spacer()
                } else if episodes.isEmpty {
                    Spacer()
                    Image(systemName: mediumFilter == .video ? "video.slash" : "waveform")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.textSecondary.opacity(0.4))
                    Text(mediumFilter == .video ? "No video episodes" : "No episodes found")
                        .font(.headline).foregroundStyle(Theme.textPrimary).padding(.top, 12)
                    Spacer()
                } else {
                    episodeList
                }
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadEpisodes(for: podcast.feedURL) }
        .sheet(isPresented: $showingPlayer) { PodcastPlayerSheet() }
        .tint(Theme.accent)
    }

    private var mediumFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                mediumChip(label: "All", icon: "list.bullet", value: nil)
                mediumChip(label: "Listen", icon: "headphones", value: .audio)
                mediumChip(label: "Watch", icon: "video", value: .video)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    private func mediumChip(label: String, icon: String, value: PodcastMedium?) -> some View {
        let isSelected = mediumFilter == value
        return Button { mediumFilter = value } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var podcastHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            PodcastArtwork(url: podcast.artworkURL, size: 88)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(podcast.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !podcast.publisher.isEmpty {
                    Text(podcast.publisher)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Button(action: { store.toggleSubscription(podcast) }) {
                    Label(isSubscribed ? "Subscribed" : "Subscribe",
                          systemImage: isSubscribed ? "checkmark.circle.fill" : "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSubscribed ? Theme.accent : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSubscribed ? Theme.surface : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.background)
    }

    private var episodeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { episode in
                    PodcastEpisodeRow(episode: episode) {
                        store.play(episode)
                        showingPlayer = true
                    }
                    Divider().overlay(Theme.hairline)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            .padding(16)
        }
    }
}

// MARK: - Episode row

struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    let onPlay: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var progress: Double { store.progressFraction(for: episode) }
    private var isNowPlaying: Bool { store.nowPlaying?.id == episode.id }

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if isNowPlaying {
                            Image(systemName: store.isPlaying ? "waveform" : "pause.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(episode.relativeDate)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isNowPlaying ? Theme.accent : Theme.textSecondary)
                    }
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !episode.episodeDescription.isEmpty {
                        Text(episode.episodeDescription)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        // Styled as a button pill but tap is handled by the outer Button
                        Label(isNowPlaying && store.isPlaying ? "Playing" : (episode.isVideo ? "Watch" : "Play"),
                              systemImage: isNowPlaying && store.isPlaying ? "waveform" : (episode.isVideo ? "video.fill" : "play.fill"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        if !episode.formattedDuration.isEmpty {
                            Text(episode.formattedDuration)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if episode.isVideo {
                            Text("VIDEO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                        }
                        if store.isPlayed(episode) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if progress > 0 && progress < 1 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline).frame(height: 3)
                                Capsule().fill(Theme.accent).frame(width: geo.size.width * progress, height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mini player (persistent bar above tab bar)

struct PodcastMiniPlayer: View {
    @EnvironmentObject private var store: PodcastStore
    @State private var showingPlayer = false

    var body: some View {
        if let episode = store.nowPlaying {
            Button { showingPlayer = true } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        PodcastArtwork(url: episode.podcastArtworkURL, size: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        if episode.isVideo {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(episode.podcastTitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { store.togglePlayPause() } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    Button { store.skip(seconds: 30) } label: {
                        Image(systemName: "goforward.30")
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingPlayer) {
                PodcastPlayerSheet()
            }
        }
    }
}

// MARK: - Full-screen player sheet

struct PodcastPlayerSheet: View {
    @EnvironmentObject private var store: PodcastStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let episode = store.nowPlaying {
                    playerContent(episode)
                } else {
                    Text("Nothing playing").foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func playerContent(_ episode: PodcastEpisode) -> some View {
        VStack(spacing: 0) {
            Spacer()
            // Artwork or video player
            if episode.isVideo, let avPlayer = store.videoPlayer {
                VideoPlayer(player: avPlayer)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                    .padding(.horizontal, 20)
            } else {
                PodcastArtwork(url: episode.podcastArtworkURL, size: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    .scaleEffect(store.isPlaying ? 1.0 : 0.88)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: store.isPlaying)
            }
            Spacer().frame(height: 36)
            // Title
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(episode.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if episode.isVideo {
                        Text("VIDEO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(episode.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            Spacer().frame(height: 28)
            // Scrubber
            scrubber(episode)
                .padding(.horizontal, 32)
            Spacer().frame(height: 28)
            // Controls
            controls
                .padding(.horizontal, 32)
            Spacer().frame(height: 24)
            // Speed picker (only meaningful for audio)
            if !episode.isVideo {
                speedPicker
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func scrubber(_ episode: PodcastEpisode) -> some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { store.totalDuration > 0 ? store.currentTime / store.totalDuration : 0 },
                    set: { store.seek(to: $0 * max(store.totalDuration, 1)) }
                )
            )
            .tint(Theme.accent)
            HStack {
                Text(formatTime(store.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(store.totalDuration > 0 ? "-\(formatTime(store.totalDuration - store.currentTime))" : "--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { store.skip(seconds: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            Button { store.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 64, height: 64)
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            Button { store.skip(seconds: 30) } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    private var speedPicker: some View {
        HStack(spacing: 8) {
            ForEach(PodcastSpeed.allCases) { speed in
                Button { store.setSpeed(speed) } label: {
                    Text(speed.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.speed == speed ? .white : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(store.speed == speed ? Theme.accent : Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Reusable podcast artwork

struct PodcastArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Theme.surfaceElevated.overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

// MARK: - Section header (reusable in DiscoverView)

struct PodcastSectionHeader: View {
    let title: String
    let actionTitle: String?
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if let actionTitle {
                Button(action: { action?() }) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Horizontal podcast carousel (embedded in DiscoverView)

// Note: deliberately has NO @EnvironmentObject store reference.
// Holding a store ref would cause this view (and its ScrollView) to re-render
// on every currentTime tick (every 0.5s during playback) and every artwork load,
// resetting the carousel scroll position. PodcastCardTile handles store access
// internally as a leaf view so the carousel stays stable.
struct PodcastCarousel: View {
    let feeds: [PodcastCatalog.CatalogFeed]
    let onShowAll: () -> Void
    @State private var selectedPodcast: Podcast?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PodcastSectionHeader(title: "SPORTS TALK", actionTitle: "See All", action: onShowAll)
                .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(feeds) { feed in
                        let podcast = Podcast(
                            id: feed.feedURL.absoluteString,
                            title: feed.title,
                            publisher: "",
                            feedURL: feed.feedURL,
                            artworkURL: nil,  // PodcastCardTile reads from cache itself
                            podcastDescription: "",
                            sport: feed.sport,
                            tags: feed.tags
                        )
                        PodcastCardTile(podcast: podcast) { selectedPodcast = podcast }
                            .frame(width: 140)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
        }
        .navigationDestination(item: $selectedPodcast) { podcast in
            PodcastDetailView(podcast: podcast)
        }
    }
}
