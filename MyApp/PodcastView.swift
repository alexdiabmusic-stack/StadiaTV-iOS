import SwiftUI
import AVFoundation
import AVKit

// MARK: - Podcast Topic Model

enum PodcastBrowseMode: String, CaseIterable, Identifiable {
    case forYou = "For You"
    case following = "Following"
    var id: String { rawValue }
}

enum PodcastTopic: Hashable, Identifiable {
    case league(League)
    case team(FavoriteTeam)
    case all

    var id: String {
        switch self {
        case .all: return "all"
        case .league(let l): return "league-\(l.id)"
        case .team(let t): return "team-\(t.id)"
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .league(let l): return l.shortName
        case .team(let t): return t.displayName
        }
    }
}

enum PodcastSortOption: String, CaseIterable, Identifiable {
    case recommended = "Recommended"
    case alphabetical = "A to Z"
    var id: String { rawValue }
}

// MARK: - Podcast Browser View (Sports Talk)

struct PodcastBrowserView: View {
    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var browseMode: PodcastBrowseMode = .forYou
    @State private var selectedTopic: PodcastTopic?
    @State private var searchText = ""
    @State private var searchResults: [Podcast] = []
    @State private var isSearching = false
    @State private var selectedPodcast: Podcast?
    @State private var sortOption: PodcastSortOption = .recommended
    @State private var teamPodcastCache: [String: [Podcast]] = [:]
    @State private var loadingTeamIDs: Set<String> = []

    // MARK: - Topics assembly
    private var availableTopics: [PodcastTopic] {
        var topics: [PodcastTopic] = []

        let majorLeagues: [League] = [
            League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey),
            League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football),
            League(name: "NBA", shortName: "NBA", path: "basketball/nba", group: .basketball),
            League(name: "MLB", shortName: "MLB", path: "baseball/mlb", group: .baseball),
            League(name: "MLS", shortName: "MLS", path: "soccer/usa.1", group: .soccer)
        ]

        // Group favorite teams near their leagues or first in the strip
        for league in majorLeagues {
            topics.append(.league(league))
            for team in prefs.favoriteTeams where team.leaguePath == league.path {
                topics.append(.team(team))
            }
        }
        for team in prefs.favoriteTeams {
            if !topics.contains(where: {
                if case .team(let t) = $0 { return t.id == team.id }
                return false
            }) {
                topics.append(.team(team))
            }
        }
        return topics
    }

    private var activeTopic: PodcastTopic {
        selectedTopic ?? availableTopics.first ?? .league(League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey))
    }

    // MARK: - Feeds / Podcasts resolution
    private var rawTopicPodcasts: [Podcast] {
        switch activeTopic {
        case .team(let team):
            if let cached = teamPodcastCache[team.id], !cached.isEmpty {
                return cached
            }
            let catalogMatches = store.catalog.filter { feed in
                let name = team.displayName.lowercased()
                return feed.tags.contains(name) || feed.title.localizedCaseInsensitiveContains(name)
            }.map { $0.toPodcast(cachedMeta: store.podcastMetaCache[$0.feedURL.absoluteString]) }
            return catalogMatches

        case .league(let league):
            let feeds = store.catalogFeeds(forSport: league.group)
            return feeds.map { $0.toPodcast(cachedMeta: store.podcastMetaCache[$0.feedURL.absoluteString]) }

        case .all:
            let feeds = store.catalogFeedsForFollowedSports(prefs.followedLeagues)
            let targetFeeds = feeds.isEmpty ? Array(store.catalog.prefix(30)) : feeds
            return targetFeeds.map { $0.toPodcast(cachedMeta: store.podcastMetaCache[$0.feedURL.absoluteString]) }
        }
    }

    private var followedPodcasts: [Podcast] {
        let ids = store.subscribedIDs
        let shows = ids.compactMap { id -> Podcast? in
            if let cached = store.podcastMetaCache[id] { return cached }
            if let feed = store.catalog.first(where: { $0.feedURL.absoluteString == id || $0.id == id }) {
                return feed.toPodcast(cachedMeta: store.podcastMetaCache[feed.feedURL.absoluteString])
            }
            return nil
        }
        switch activeTopic {
        case .team(let team):
            let name = team.displayName.lowercased()
            let filtered = shows.filter { $0.title.localizedCaseInsensitiveContains(name) || $0.tags.contains(name) }
            return filtered.isEmpty ? shows : filtered
        case .league(let league):
            let filtered = shows.filter { $0.sport?.lowercased() == league.group.rawValue.lowercased() }
            return filtered.isEmpty ? shows : filtered
        case .all:
            return shows
        }
    }

    private var currentPodcasts: [Podcast] {
        if !searchText.isEmpty {
            return searchResults
        }
        switch browseMode {
        case .forYou:
            return rawTopicPodcasts
        case .following:
            return followedPodcasts
        }
    }

    private var displayedPodcasts: [Podcast] {
        switch sortOption {
        case .recommended:
            return currentPodcasts
        case .alphabetical:
            return currentPodcasts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Featured Podcasts
    private var featuredPodcasts: [Podcast] {
        guard browseMode == .forYou && searchText.isEmpty else { return [] }
        var list: [Podcast] = []
        var seenIDs = Set<String>()

        for p in rawTopicPodcasts.prefix(4) {
            if seenIDs.insert(p.id).inserted {
                list.append(p)
            }
        }

        if list.count < 3 {
            let topFeeds = store.catalog.filter { feed in
                let t = feed.title.lowercased()
                return t.contains("32 thoughts") || t.contains("spittin' chiclets") || t.contains("bill simmons") || t.contains("athletic")
            }.map { $0.toPodcast(cachedMeta: store.podcastMetaCache[$0.feedURL.absoluteString]) }

            for p in topFeeds {
                if seenIDs.insert(p.id).inserted {
                    list.append(p)
                }
                if list.count >= 3 { break }
            }
        }

        return Array(list.prefix(3))
    }

    private var resultsSectionTitle: String {
        if !searchText.isEmpty {
            return "Search Results"
        }
        switch browseMode {
        case .forYou:
            return activeTopic.title
        case .following:
            return "Following"
        }
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                customNavigationBar

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            headerSection
                            searchSection
                            modeSelectorSection
                            topicScrollSection

                            if !featuredPodcasts.isEmpty {
                                featuredSection(scrollProxy: scrollProxy)
                            }

                            resultsHeaderSection
                                .id("resultsHeader")

                            if isSearching {
                                skeletonResultsList
                            } else if displayedPodcasts.isEmpty {
                                emptyStateView
                            } else {
                                resultsListView
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, store.nowPlaying != nil ? 96 : 36)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .enableSwipeBack()
        .navigationDestination(item: $selectedPodcast) { podcast in
            PodcastDetailView(podcast: podcast)
        }
        .task(id: activeTopic.id) {
            if case .team(let team) = activeTopic {
                await loadTeamPodcasts(for: team)
            }
        }
        .task(id: searchText) {
            await performSearch(query: searchText)
        }
        .onAppear {
            if selectedTopic == nil {
                if let fav = availableTopics.first(where: { if case .team = $0 { return true }; return false }) {
                    selectedTopic = fav
                } else {
                    selectedTopic = availableTopics.first
                }
            }
        }
    }

    // MARK: - Custom Navigation Bar
    private var customNavigationBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Discover")
                        .font(.system(size: 17, weight: .regular))
                }
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Discover")

            Spacer()

            Menu {
                Button {
                    Task {
                        if case .team(let team) = activeTopic {
                            teamPodcastCache.removeValue(forKey: team.id)
                            await loadTeamPodcasts(for: team)
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated.opacity(0.85), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Page Header
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sports Talk")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text("Podcasts, analysis and conversations from across the sports world.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Search Field
    private var searchSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            TextField("Search podcasts, teams, hosts", text: $searchText)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if isSearching {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(Theme.accent)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Primary Mode Selector
    private var modeSelectorSection: some View {
        HStack(spacing: 10) {
            ForEach(PodcastBrowseMode.allCases) { mode in
                let isSelected = browseMode == mode
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        browseMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Theme.surfaceElevated : Theme.surfaceElevated.opacity(0.35),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? Color.white.opacity(0.22) : Theme.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue), \(isSelected ? "selected" : "")")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Topic Filters Scroller
    private var topicScrollSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(availableTopics) { topic in
                    let isSelected = activeTopic.id == topic.id
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedTopic = topic
                        }
                    } label: {
                        Text(topic.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(
                                isSelected ? Theme.accent : Theme.surfaceElevated,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(topic.title), \(isSelected ? "selected" : "")")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Featured Section
    private func featuredSection(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Featured for You")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo("resultsHeader", anchor: .top)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(featuredPodcasts) { podcast in
                        FeaturedPodcastCard(podcast: podcast) {
                            selectedPodcast = podcast
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Results Header
    private var resultsHeaderSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(resultsSectionTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("\(displayedPodcasts.count) podcasts")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Menu {
                ForEach(PodcastSortOption.allCases) { opt in
                    Button {
                        withAnimation { sortOption = opt }
                    } label: {
                        HStack {
                            Text(opt.rawValue)
                            if sortOption == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortOption == .recommended ? "Sort" : sortOption.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort podcasts, currently \(sortOption.rawValue)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Results List View (Unbordered)
    private var resultsListView: some View {
        LazyVStack(spacing: 0) {
            ForEach(displayedPodcasts) { podcast in
                PodcastRow(podcast: podcast) {
                    selectedPodcast = podcast
                }
                Divider()
                    .overlay(Theme.hairline)
                    .padding(.leading, 16 + 72 + 14)
            }
        }
    }

    // MARK: - Skeleton Results List
    private var skeletonResultsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surfaceElevated)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surfaceElevated)
                            .frame(height: 18)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surfaceElevated)
                            .frame(width: 140, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surfaceElevated)
                            .frame(width: 90, height: 12)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                    .overlay(Theme.hairline)
                    .padding(.leading, 16 + 72 + 14)
            }
        }
        .opacity(0.6)
    }

    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 28)
            Image(systemName: emptyStateIcon)
                .font(.system(size: 42))
                .foregroundStyle(Theme.textSecondary.opacity(0.45))
            Text(emptyStateTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(emptyStateSubtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyStateIcon: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        if browseMode == .following { return "bookmark" }
        return "waveform"
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty { return "No results found" }
        if browseMode == .following { return "You're not following any podcasts yet" }
        return "No podcasts available"
    }

    private var emptyStateSubtitle: String {
        if !searchText.isEmpty { return "Try searching for a different podcast title, sport, or host." }
        if browseMode == .following { return "Find a show you like and tap Follow." }
        return "No podcasts found for \(activeTopic.title)."
    }

    // MARK: - Helpers & Data Loading
    private func loadTeamPodcasts(for team: FavoriteTeam) async {
        guard teamPodcastCache[team.id] == nil, !loadingTeamIDs.contains(team.id) else { return }
        loadingTeamIDs.insert(team.id)
        let pods = await store.resolvePodcasts(for: team)
        teamPodcastCache[team.id] = pods
        loadingTeamIDs.remove(team.id)
    }

    private func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        let localMatches = store.catalog.filter { feed in
            feed.title.localizedCaseInsensitiveContains(trimmed) ||
            feed.sport.localizedCaseInsensitiveContains(trimmed) ||
            feed.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }.map { $0.toPodcast(cachedMeta: store.podcastMetaCache[$0.feedURL.absoluteString]) }

        let remoteMatches = await store.search(query: trimmed)
        guard !Task.isCancelled else { return }

        var seen = Set<String>()
        var combined: [Podcast] = []
        for p in localMatches + remoteMatches {
            if seen.insert(p.id).inserted {
                combined.append(p)
            }
        }
        searchResults = combined
        isSearching = false
    }
}

// MARK: - Featured Podcast Card (Carousel Item)

struct FeaturedPodcastCard: View {
    let podcast: Podcast
    let onTap: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var artworkURL: URL? {
        podcast.artworkURL ?? store.podcastMetaCache[podcast.id]?.artworkURL
    }

    private var subtitleText: String {
        var parts: [String] = []
        let pub = !podcast.publisher.isEmpty
            ? podcast.publisher
            : (store.podcastMetaCache[podcast.id]?.publisher ?? "")
        if !pub.isEmpty { parts.append(pub) }
        if let sport = podcast.sport, !sport.isEmpty {
            parts.append(sport.capitalized)
        } else if let firstTag = podcast.tags.first, !firstTag.isEmpty {
            parts.append(firstTag.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                PodcastArtwork(url: artworkURL, size: 140, cornerRadius: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)

                Text(podcast.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
        .task(id: podcast.id) {
            await store.fetchArtwork(for: podcast.feedURL)
        }
    }
}

// MARK: - Podcast Row (Unbordered List Item)

struct PodcastRow: View {
    let podcast: Podcast
    let onTap: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var artworkURL: URL? {
        podcast.artworkURL ?? store.podcastMetaCache[podcast.id]?.artworkURL
    }

    private var publisherText: String {
        let pub = !podcast.publisher.isEmpty
            ? podcast.publisher
            : (store.podcastMetaCache[podcast.id]?.publisher ?? "")
        return pub
    }

    private var categoryText: String {
        var parts: [String] = []
        if let sport = podcast.sport, !sport.isEmpty {
            parts.append(sport.capitalized)
        } else if let firstTag = podcast.tags.first, !firstTag.isEmpty {
            parts.append(firstTag.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                PodcastArtwork(url: artworkURL, size: 72, cornerRadius: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(podcast.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !publisherText.isEmpty {
                        Text(publisherText)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    if !categoryText.isEmpty {
                        Text(categoryText)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: podcast.id) {
            await store.fetchArtwork(for: podcast.feedURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(podcast.title), \(publisherText), \(categoryText)")
        .accessibilityHint("Opens podcast details")
    }
}

// MARK: - Podcast detail (episode list)

enum EpisodeSortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest First"
    case oldest = "Oldest First"
    var id: String { rawValue }
}

struct PodcastDetailView: View {
    let podcast: Podcast
    @EnvironmentObject private var store: PodcastStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPlayer = false
    @State private var mediumFilter: PodcastMedium? = nil  // nil = show all
    @State private var sortOrder: EpisodeSortOrder = .newest
    @State private var isDescriptionExpanded = false
    @State private var filterUnplayedOnly = false

    private var allEpisodes: [PodcastEpisode] {
        store.episodes(for: podcast)
    }
    private var hasVideoEpisodes: Bool { allEpisodes.contains { $0.isVideo } }
    private var hasAudioEpisodes: Bool { allEpisodes.contains { !$0.isVideo } }
    private var showsMediumFilter: Bool { hasVideoEpisodes && hasAudioEpisodes }

    private var filteredEpisodes: [PodcastEpisode] {
        var list = allEpisodes
        if let filter = mediumFilter {
            list = list.filter { $0.medium == filter }
        }
        if filterUnplayedOnly {
            list = list.filter { !store.isPlayed($0) }
        }
        return list
    }

    private var sortedEpisodes: [PodcastEpisode] {
        switch sortOrder {
        case .newest:
            return filteredEpisodes.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:
            return filteredEpisodes.sorted { $0.publishedAt < $1.publishedAt }
        }
    }

    private var latestEpisode: PodcastEpisode? {
        sortedEpisodes.first
    }

    private var listEpisodes: [PodcastEpisode] {
        if sortedEpisodes.count > 1, let latest = latestEpisode {
            return sortedEpisodes.filter { $0.id != latest.id }
        }
        return sortedEpisodes
    }

    private var isLoading: Bool {
        store.loadingFeedIDs.contains(podcast.feedURL.absoluteString) ||
        store.loadingFeedIDs.contains(podcast.id)
    }
    private var isSubscribed: Bool { store.isSubscribed(podcast) }

    private var headerArtworkURL: URL? {
        podcast.artworkURL
            ?? store.podcastMetaCache[podcast.id]?.artworkURL
            ?? allEpisodes.first(where: { $0.podcastArtworkURL != nil })?.podcastArtworkURL
    }

    private var categorySubtitle: String {
        var parts: [String] = []
        let publisher = !podcast.publisher.isEmpty
            ? podcast.publisher
            : (store.podcastMetaCache[podcast.id]?.publisher ?? "")
        if !publisher.isEmpty {
            parts.append(publisher)
        }
        if let sport = podcast.sport, !sport.isEmpty {
            parts.append(sport.capitalized)
        } else if let firstTag = podcast.tags.first, !firstTag.isEmpty {
            parts.append(firstTag.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    private var sanitizedPodcastDescription: String {
        let desc = podcast.podcastDescription.isEmpty
            ? (store.podcastMetaCache[podcast.id]?.podcastDescription ?? "")
            : podcast.podcastDescription
        return desc.strippingHTML
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                customNavigationBar

                if isLoading && allEpisodes.isEmpty {
                    ScrollView {
                        PodcastDetailSkeletonView()
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }
                } else if allEpisodes.isEmpty {
                    emptyView
                } else {
                    mainScrollView
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .enableSwipeBack()
        .task {
            await store.fetchArtwork(for: podcast.feedURL)
            await store.loadEpisodes(for: podcast.feedURL)
        }
        .sheet(isPresented: $showingPlayer) {
            PodcastPlayerSheet()
        }
        .tint(Theme.accent)
    }

    // MARK: - Custom Navigation Bar
    private var customNavigationBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated.opacity(0.85), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Spacer()

            Menu {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.toggleSubscription(podcast)
                    }
                } label: {
                    Label(isSubscribed ? "Unfollow Show" : "Follow Show",
                          systemImage: isSubscribed ? "checkmark" : "plus")
                }

                #if !os(tvOS)
ShareLink(item: podcast.feedURL) {
                    Label("Share Show", systemImage: "square.and.arrow.up")
                }
                    #endif

                Button {
                    Task {
                        await store.loadEpisodes(for: podcast.feedURL)
                    }
                } label: {
                    Label("Refresh Episodes", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated.opacity(0.85), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Main Scroll Content
    private var mainScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                heroSection

                if showsMediumFilter {
                    mediumFilterBar
                }

                if let latest = latestEpisode {
                    featuredLatestCard(latest)
                }

                episodesHeader

                if listEpisodes.isEmpty && filterUnplayedOnly {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(Theme.accent)
                        Text("All Caught Up!")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("You've listened to all episodes of this show.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(listEpisodes) { episode in
                            PodcastEpisodeRow(
                                episode: episode,
                                podcastArtworkURL: headerArtworkURL
                            ) {
                                if store.nowPlaying?.id == episode.id {
                                    store.togglePlayPause()
                                } else {
                                    store.play(episode)
                                }
                            }
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, store.nowPlaying != nil ? 140 : 60)
        }
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                PodcastArtwork(url: headerArtworkURL, size: 128, cornerRadius: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text(podcast.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if !categorySubtitle.isEmpty {
                        Text(categorySubtitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    if !sanitizedPodcastDescription.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sanitizedPodcastDescription)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(isDescriptionExpanded ? nil : 3)
                                .lineSpacing(2.5)

                            if !isDescriptionExpanded && sanitizedPodcastDescription.count > 100 {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        isDescriptionExpanded = true
                                    }
                                } label: {
                                    Text("more")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }

            // Primary Action Pills: [+ Follow] [▶ Play Latest Episode]
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.toggleSubscription(podcast)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSubscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text(isSubscribed ? "Following" : "Follow")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(isSubscribed ? Theme.surfaceElevated : Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSubscribed ? "Unfollow \(podcast.title)" : "Follow \(podcast.title)")

                if let latest = latestEpisode {
                    let isCurrentPlaying = store.nowPlaying?.id == latest.id && store.isPlaying
                    let isCurrentPaused = store.nowPlaying?.id == latest.id && !store.isPlaying

                    Button {
                        if store.nowPlaying?.id == latest.id {
                            store.togglePlayPause()
                        } else {
                            store.play(latest)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isCurrentPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(isCurrentPlaying ? "Pause" : (isCurrentPaused ? "Resume" : "Play Latest Episode"))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.35), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play latest episode, \(latest.title)")
                }

                Spacer()
            }
        }
    }

    // MARK: - Medium Filter Bar
    private var mediumFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                mediumChip(label: "All", icon: "list.bullet", value: nil)
                mediumChip(label: "Listen", icon: "headphones", value: .audio)
                mediumChip(label: "Watch", icon: "video", value: .video)
            }
        }
        .padding(.vertical, 4)
    }

    private func mediumChip(label: String, icon: String, value: PodcastMedium?) -> some View {
        let isSelected = mediumFilter == value
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { mediumFilter = value }
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Featured Latest Episode Card
    private func featuredLatestCard(_ episode: PodcastEpisode) -> some View {
        let isCurrent = store.nowPlaying?.id == episode.id
        let isPlaying = isCurrent && store.isPlaying
        let progress = isCurrent
            ? (store.totalDuration > 0 ? store.currentTime / store.totalDuration : 0)
            : store.progressFraction(for: episode)
        let isPlayed = store.isPlayed(episode)
        let remainingFormatted = store.remainingTimeFormatted(for: episode)

        return VStack(alignment: .leading, spacing: 10) {
            Text("LATEST EPISODE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accent)
                .tracking(0.6)

            Text(episode.title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !episode.cleanDescription.isEmpty {
                Text(episode.cleanDescription)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(2.5)
                    .multilineTextAlignment(.leading)
            }

            HStack(alignment: .center) {
                Text("\(episode.relativeDate) · \(episode.formattedDuration)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button {
                    if isCurrent {
                        store.togglePlayPause()
                    } else {
                        store.play(episode)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 50, height: 50)
                            .shadow(color: Theme.accent.opacity(0.35), radius: 8, x: 0, y: 3)

                        if isCurrent && store.isBuffering {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 1.5)
                        }
                    }
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause \(episode.title)" : "Play \(episode.title)")
            }

            if progress > 0 || isPlayed {
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 4)
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))), height: 4)
                        }
                    }
                    .frame(height: 4)

                    if let rem = remainingFormatted {
                        Text(rem)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        )
    }

    // MARK: - Episodes Section Header
    private var episodesHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(filterUnplayedOnly ? "Unplayed Episodes" : "All Episodes")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            // Unplayed filter toggle button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    filterUnplayedOnly.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: filterUnplayedOnly ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .bold))
                    Text("Unplayed")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(filterUnplayedOnly ? .white : Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(
                    filterUnplayedOnly ? Theme.accent : Theme.surfaceElevated,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(filterUnplayedOnly ? Theme.accent : Theme.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filterUnplayedOnly ? "Show all episodes" : "Filter unplayed episodes only")

            Menu {
                ForEach(EpisodeSortOrder.allCases) { order in
                    Button {
                        withAnimation { sortOrder = order }
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortOrder == .newest ? "Sort" : sortOrder.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort episodes, currently \(sortOrder.rawValue)")
        }
        .padding(.top, 6)
    }

    // MARK: - Empty / Error View
    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
            Text("No episodes available")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Episodes could not be loaded for this podcast.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task {
                    await store.loadEpisodes(for: podcast.feedURL)
                }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - Episode row

struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    let podcastArtworkURL: URL?
    let onPlay: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var isCurrent: Bool { store.nowPlaying?.id == episode.id }
    private var isPlaying: Bool { isCurrent && store.isPlaying }
    private var isPlayed: Bool { store.isPlayed(episode) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left thumbnail
            PodcastArtwork(url: episode.podcastArtworkURL ?? podcastArtworkURL, size: 64, cornerRadius: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )

            // Middle info
            VStack(alignment: .leading, spacing: 5) {
                Text(episode.formattedPublishedDate)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textTertiary)

                Text(episode.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !episode.cleanDescription.isEmpty {
                    Text(episode.cleanDescription)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 8) {
                    if !episode.formattedDuration.isEmpty {
                        Text(episode.formattedDuration)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if isPlayed {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                            Text("Played")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.textTertiary)
                    } else if let rem = store.remainingTimeFormatted(for: episode) {
                        Text("· \(rem)")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }

                    if episode.isVideo {
                        Text("VIDEO")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.top, 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            Spacer(minLength: 4)

            // Right controls
            HStack(spacing: 8) {
                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .fill(isCurrent ? Theme.accent : Theme.surfaceElevated)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle()
                                    .strokeBorder(isCurrent ? Color.clear : Theme.hairline, lineWidth: 1)
                            )
                        if isCurrent && store.isBuffering {
                            ProgressView().tint(isCurrent ? .white : Theme.accent)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(isCurrent ? .white : Theme.textPrimary)
                                .offset(x: isPlaying ? 0 : 1)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause \(episode.title)" : "Play \(episode.title)")

                Menu {
                    if isPlayed {
                        Button {
                            store.markUnplayed(episode)
                        } label: {
                            Label("Mark as Unplayed", systemImage: "arrow.uturn.backward.circle")
                        }
                    } else {
                        Button {
                            store.markPlayed(episode)
                        } label: {
                            Label("Mark as Played", systemImage: "checkmark.circle")
                        }
                    }

                    #if !os(tvOS)
ShareLink(item: episode.audioURL) {
                        Label("Share Episode", systemImage: "square.and.arrow.up")
                    }
                    #endif
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options for \(episode.title)")
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Podcast Detail Skeleton Loader

struct PodcastDetailSkeletonView: View {
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .frame(width: 128, height: 128)

                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceElevated)
                        .frame(height: 24)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceElevated)
                        .frame(width: 120, height: 14)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceElevated)
                        .frame(height: 40)
                }
            }

            HStack(spacing: 12) {
                Capsule().fill(Theme.surfaceElevated).frame(width: 90, height: 40)
                Capsule().fill(Theme.surfaceElevated).frame(width: 160, height: 40)
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surfaceElevated)
                .frame(height: 150)

            VStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(alignment: .top, spacing: 14) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surfaceElevated)
                            .frame(width: 58, height: 58)

                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.surfaceElevated)
                                .frame(width: 80, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.surfaceElevated)
                                .frame(height: 16)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.surfaceElevated)
                                .frame(height: 12)
                        }
                        Spacer()
                    }
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .opacity(isPulsing ? 0.45 : 0.85)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Mini player (floating bar above tab bar)

struct PodcastMiniPlayer: View {
    @EnvironmentObject private var store: PodcastStore
    @State private var showingPlayer = false

    var body: some View {
        if let episode = store.nowPlaying {
            let progress = store.totalDuration > 0 ? max(0, min(1, store.currentTime / store.totalDuration)) : 0

            Button { showingPlayer = true } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            PodcastArtwork(url: episode.podcastArtworkURL, size: 48, cornerRadius: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                                )
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
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)

                            Text(episode.podcastTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button {
                            store.togglePlayPause()
                        } label: {
                            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(store.isPlaying ? "Pause" : "Play")

                        Button {
                            store.skip(seconds: 30)
                        } label: {
                            Image(systemName: "goforward.30")
                                .font(.system(size: 21, weight: .regular))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip forward 30 seconds")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 2.5)
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: geo.size.width * CGFloat(progress), height: 2.5)
                        }
                    }
                    .frame(height: 2.5)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.4), radius: 14, x: 0, y: 6)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
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
            .inlineNavigationTitle()
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
            #if os(tvOS)
            ProgressView(value: store.currentTime, total: max(store.totalDuration, 1))
            #else
            Slider(
                value: Binding(
                    get: { store.totalDuration > 0 ? store.currentTime / store.totalDuration : 0 },
                    set: { store.seek(to: $0 * max(store.totalDuration, 1)) }
                )
            )
            .tint(Theme.accent)
            #endif
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
    var cornerRadius: CGFloat = 8

    @State private var cachedImage: Image?

    var body: some View {
        ZStack {
            if let cachedImage {
                cachedImage
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.surfaceElevated.overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(Theme.textSecondary.opacity(0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            guard let url else {
                cachedImage = nil
                return
            }
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let uiImage = UIImage(data: data) else { return }
            cachedImage = Image(uiImage: uiImage)
        }
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

// MARK: - Podcast Card Tile (used in Discover carousel)

struct PodcastCardTile: View {
    let podcast: Podcast
    let onTap: () -> Void
    @EnvironmentObject private var store: PodcastStore

    private var artworkURL: URL? {
        store.podcastMetaCache[podcast.id]?.artworkURL ?? podcast.artworkURL
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                PodcastArtwork(url: artworkURL, size: 140, cornerRadius: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
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
                            artworkURL: feed.imageURL,
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


// MARK: - Interactive Pop Gesture (Swipe to Dismiss)

extension View {
    func enableSwipeBack() -> some View {
        background(EnableSwipeBackHelper())
    }
}

private struct EnableSwipeBackHelper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackViewController {
        SwipeBackViewController()
    }
    func updateUIViewController(_ uiViewController: SwipeBackViewController, context: Context) {}
}

private class SwipeBackViewController: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if !os(tvOS)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        nav.interactivePopGestureRecognizer?.delegate = self
        #endif
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return (navigationController?.viewControllers.count ?? 0) > 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
