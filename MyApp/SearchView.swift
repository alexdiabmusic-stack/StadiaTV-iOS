import SwiftUI
import Combine

struct SearchView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var podcastStore: PodcastStore
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SearchViewModel()
    @State private var query = ""
    @State private var playingChannel: Channel?
    @State private var presentedArticle: ESPNArticle?
    @State private var presentedPodcast: Podcast?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var playerSearchKey: String {
        "\(trimmedQuery.searchNormalized)|\(prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","))"
    }

    private var shouldLoadPlayers: Bool {
        guard !prefs.favoriteTeams.isEmpty else { return false }
        let normalized = trimmedQuery.searchNormalized
        guard normalized.count >= 3 else { return false }
        let playerIntentWords = ["player", "players", "roster", "stats", "injury", "injured"]
        return normalized.split(separator: " ").count >= 2
            || playerIntentWords.contains { normalized.contains($0) }
    }

    /// All channels with hidden ones removed and custom names applied.
    private var searchChannels: [Channel] {
        playlists.allChannels
            .filter { !channelPrefs.isHidden($0.id) }
            .map { ch in
                guard let custom = channelPrefs.customName(for: ch.id) else { return ch }
                return Channel(id: ch.id, name: custom, streamURL: ch.streamURL,
                               logoURL: ch.logoURL, group: ch.group,
                               playlistID: ch.playlistID, playlistName: ch.playlistName)
            }
    }

    private var results: [UniversalSearchResult] {
        SearchIndex.results(
            for: trimmedQuery,
            leagues: League.all,
            teams: viewModel.teams,
            matches: viewModel.matches,
            channels: searchChannels,
            players: viewModel.players,
            articles: viewModel.articles,
            podcasts: podcastStore.catalog,
            settings: SearchSettingDestination.allCases
        )
    }

    private var sections: [SearchSection] {
        var teams: [UniversalSearchResult] = []
        var liveGames: [UniversalSearchResult] = []
        var games: [UniversalSearchResult] = []
        var news: [UniversalSearchResult] = []
        var highlights: [UniversalSearchResult] = []
        var channels: [UniversalSearchResult] = []
        var podcasts: [UniversalSearchResult] = []
        var players: [UniversalSearchResult] = []
        var settings: [UniversalSearchResult] = []

        for result in results {
            switch result.payload {
            case .team, .league:
                teams.append(result)
            case .match(let match):
                if match.state == .live { liveGames.append(result) } else { games.append(result) }
            case .article(let article):
                if article.isSearchHighlight { highlights.append(result) } else { news.append(result) }
            case .channel:
                channels.append(result)
            case .podcast:
                podcasts.append(result)
            case .player:
                players.append(result)
            case .setting:
                settings.append(result)
            }
        }

        var out: [SearchSection] = []
        func add(_ title: String, _ list: [UniversalSearchResult], limit: Int = 4) {
            guard !list.isEmpty else { return }
            out.append(SearchSection(title: title, results: Array(list.prefix(limit))))
        }
        add("Teams & Leagues", teams)
        add("Live Now", liveGames, limit: 5)
        add("Upcoming Games", games, limit: 5)
        add("News", news, limit: 5)
        add("Highlights", highlights, limit: 3)
        add("Channels", channels, limit: 5)
        add("Podcasts", podcasts, limit: 4)
        add("Players", players, limit: 4)
        add("Settings", settings, limit: 3)
        return out
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Search")
            .navigationDestination(for: Match.self) { match in
                MatchDetailView(match: match)
            }
            .navigationDestination(for: SearchTeamResult.self) { result in
                TeamRosterView(league: result.league, teamID: result.team.id, teamName: result.team.displayName)
            }
            .navigationDestination(for: SearchPlayerResult.self) { result in
                PlayerDetailView(league: result.league, athlete: result.athlete)
            }
            .navigationDestination(for: SearchSettingDestination.self) { destination in
                destination.view
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Teams, leagues, games, channels, players")
            .fullScreenCover(item: $playingChannel) { channel in
                PlayerView(channel: channel)
            }
            .navigationDestination(item: $presentedArticle) { article in
                ArticleReaderView(article: article)
            }
            .sheet(item: $presentedPodcast) { podcast in
                PodcastDetailView(podcast: podcast)
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined(separator: ",") + "|" + prefs.favoriteTeams.map(\.id).joined(separator: ",")) {
            await viewModel.loadBase(leagues: prefs.followedLeagues, favoriteTeams: prefs.favoriteTeams)
        }
        .task(id: playerSearchKey) {
            guard shouldLoadPlayers else { return }
            await viewModel.loadFavoritePlayers(favoriteTeams: prefs.favoriteTeams)
        }
    }

    @ViewBuilder private var content: some View {
        if trimmedQuery.isEmpty {
            idleState
        } else if sections.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "command.circle.fill")
                .font(.system(size: Theme.scaled(42)))
                .foregroundStyle(Theme.accent)
            Text("Search teams, leagues, games, channels, players, news, highlights, and settings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            FlowLayout(spacing: 8) {
                ForEach(["Senators", "NBA", "TSN", "Highlights", "Notifications", "Injury report"], id: \.self) { suggestion in
                    Button(suggestion) { query = suggestion }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.scaled(42)))
                .foregroundStyle(Theme.textSecondary)
            Text("No results for \"\(trimmedQuery)\"")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                    if index > 0 {
                        Divider()
                            .overlay(Theme.hairline)
                            .padding(.vertical, 4)
                    }
                    SearchSectionTitle(title: section.title, count: section.results.count)
                    ForEach(section.results) { result in
                        row(for: result)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func row(for result: UniversalSearchResult) -> some View {
        switch result.payload {
        case .team(let team):
            NavigationLink(value: team) {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .league(let league):
            NavigationLink(value: SearchSettingDestination.teamsLeagues) {
                UniversalSearchRow(result: result, accessoryText: league.group.rawValue)
            }
            .buttonStyle(.plain)
        case .match(let match):
            NavigationLink(value: match) {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .channel(let channel):
            Button { playingChannel = channel } label: {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .player(let player):
            NavigationLink(value: player) {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .article(let article):
            Button {
                presentedArticle = article
            } label: {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .podcast(let podcast):
            Button {
                presentedPodcast = podcast
            } label: {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        case .setting(let setting):
            NavigationLink(value: setting) {
                UniversalSearchRow(result: result)
            }
            .buttonStyle(.plain)
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var matches: [Match] = []
    @Published private(set) var articles: [ESPNArticle] = []
    @Published private(set) var teams: [SearchTeamResult] = []
    @Published private(set) var players: [SearchPlayerResult] = []

    private let service = ESPNService()

    private var loadedFavoritePlayerTeamIDs: Set<String> = []

    func loadBase(leagues: [League], favoriteTeams: [FavoriteTeam]) async {
        var loadedMatches: [Match] = []
        var loadedArticles: [ESPNArticle] = []
        var loadedTeams: [SearchTeamResult] = []
        let favoriteIDs = Set(favoriteTeams.map(\.id))
        players.removeAll { !favoriteIDs.contains("\($0.league.path)-\($0.teamID)") }
        loadedFavoritePlayerTeamIDs.formIntersection(favoriteIDs)

        await withTaskGroup(of: SearchLoadResult.self) { group in
            for league in leagues {
                group.addTask {
                    async let matches = self.service.scoreboards(for: league, starting: Date(), days: 14)
                    async let articles = self.service.news(for: league, limit: 12)
                    async let teams = self.service.teams(for: league)

                    let loadedTeams = (try? await teams) ?? []
                    return SearchLoadResult(
                        matches: (try? await matches) ?? [],
                        articles: (try? await articles) ?? [],
                        teams: loadedTeams.map { SearchTeamResult(league: league, team: $0) },
                        players: []
                    )
                }
            }
            for await result in group {
                loadedMatches.append(contentsOf: result.matches)
                loadedArticles.append(contentsOf: result.articles)
                loadedTeams.append(contentsOf: result.teams)
            }
        }

        matches = Dictionary(grouping: loadedMatches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
        articles = Dictionary(grouping: loadedArticles, by: \.id)
            .compactMap { $0.value.first }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        teams = Dictionary(grouping: loadedTeams, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.team.displayName.localizedCaseInsensitiveCompare($1.team.displayName) == .orderedAscending }
    }

    func loadFavoritePlayers(favoriteTeams: [FavoriteTeam]) async {
        let teamsToLoad = favoriteTeams.filter { !loadedFavoritePlayerTeamIDs.contains($0.id) }
        guard !teamsToLoad.isEmpty else { return }
        teamsToLoad.forEach { loadedFavoritePlayerTeamIDs.insert($0.id) }

        var loadedPlayers: [SearchPlayerResult] = []
        await withTaskGroup(of: [SearchPlayerResult].self) { group in
            for favorite in teamsToLoad {
                guard let league = League.all.first(where: { $0.path == favorite.leaguePath }) else { continue }
                group.addTask {
                    let rosterGroups = (try? await self.service.roster(for: league, teamID: favorite.teamID)) ?? []
                    return rosterGroups.flatMap(\.athletes).map { athlete in
                        SearchPlayerResult(league: league, teamID: favorite.teamID, teamName: favorite.displayName, athlete: athlete)
                    }
                }
            }
            for await result in group {
                loadedPlayers.append(contentsOf: result)
            }
        }

        players = Dictionary(grouping: players + loadedPlayers, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.athlete.displayName.localizedCaseInsensitiveCompare($1.athlete.displayName) == .orderedAscending }
    }
}

private struct SearchLoadResult {
    let matches: [Match]
    let articles: [ESPNArticle]
    let teams: [SearchTeamResult]
    let players: [SearchPlayerResult]
}

private struct SearchSection {
    let title: String
    let results: [UniversalSearchResult]
}

struct SearchTeamResult: Identifiable, Hashable {
    let league: League
    let team: Team

    var id: String { "team-\(league.id)-\(team.id)" }
}

struct SearchPlayerResult: Identifiable, Hashable {
    let league: League
    let teamID: String
    let teamName: String
    let athlete: RosterAthlete

    var id: String { "player-\(league.id)-\(teamID)-\(athlete.id)" }
}

private enum SearchResultPayload: Hashable {
    case team(SearchTeamResult)
    case league(League)
    case match(Match)
    case channel(Channel)
    case player(SearchPlayerResult)
    case article(ESPNArticle)
    case setting(SearchSettingDestination)
    case podcast(Podcast)
}

private struct UniversalSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let imageURL: URL?
    let rank: Int
    let payload: SearchResultPayload
}

enum SearchSettingDestination: String, CaseIterable, Identifiable, Hashable {
    case playlists
    case teamsLeagues
    case appearancePlayback
    case notificationsCalendar
    case privacySync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .teamsLeagues: "Teams & Leagues"
        case .appearancePlayback: "Appearance & Playback"
        case .notificationsCalendar: "Notifications & Calendar"
        case .privacySync: "Privacy & iCloud Sync"
        }
    }

    var subtitle: String {
        switch self {
        case .playlists: "Settings"
        case .teamsLeagues: "Settings"
        case .appearancePlayback: "Settings"
        case .notificationsCalendar: "Settings"
        case .privacySync: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: "list.and.film"
        case .teamsLeagues: "star.circle.fill"
        case .appearancePlayback: "paintpalette.fill"
        case .notificationsCalendar: "bell.badge.fill"
        case .privacySync: "lock.icloud.fill"
        }
    }

    var keywords: [String] {
        switch self {
        case .playlists:
            ["settings", "channels", "m3u", "stream login", "live tv", "playlist", "source"]
        case .teamsLeagues:
            ["settings", "teams", "leagues", "following", "favorites", "sports", "setup"]
        case .appearancePlayback:
            ["settings", "appearance", "theme", "playback", "language", "player", "spoiler", "scores"]
        case .notificationsCalendar:
            ["settings", "notifications", "alerts", "calendar", "reminders", "digest", "game starting"]
        case .privacySync:
            ["settings", "privacy", "icloud", "sync", "data", "watch history", "reset"]
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .playlists:
            PlaylistsSettingsView()
        case .teamsLeagues:
            TeamEditorView()
        case .appearancePlayback:
            AppearancePlaybackSettingsView()
        case .notificationsCalendar:
            NotificationsCalendarSettingsView()
        case .privacySync:
            PrivacySyncSettingsView()
        }
    }
}

private enum SearchIndex {
    static func results(
        for query: String,
        leagues: [League],
        teams: [SearchTeamResult],
        matches: [Match],
        channels: [Channel],
        players: [SearchPlayerResult],
        articles: [ESPNArticle],
        podcasts: [PodcastCatalog.CatalogFeed],
        settings: [SearchSettingDestination]
    ) -> [UniversalSearchResult] {
        let query = SearchQuery(query)
        guard !query.isEmpty else { return [] }

        var results: [UniversalSearchResult] = []
        results.append(contentsOf: teams.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: leagues.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: matches.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: channels.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: players.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: articles.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: podcasts.compactMap { result(for: $0, query: query) })
        results.append(contentsOf: settings.compactMap { result(for: $0, query: query) })

        return results.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func result(for team: SearchTeamResult, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [
            team.team.displayName,
            team.team.shortDisplayName,
            team.team.abbreviation,
            team.league.name,
            team.league.shortName,
            team.league.group.rawValue,
            "team teams club favorite following"
        ]
        guard let rank = score(query: query, title: team.team.displayName, fields: fields, categoryBoost: 24) else { return nil }
        return UniversalSearchResult(
            id: team.id,
            title: team.team.displayName,
            subtitle: "Team · \(team.league.shortName)",
            systemImage: "shield.fill",
            imageURL: team.team.logoURL,
            rank: rank,
            payload: .team(team)
        )
    }

    private static func result(for league: League, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [league.name, league.shortName, league.group.rawValue, league.keywords.joined(separator: " "), "league leagues sport settings"]
        guard let rank = score(query: query, title: league.name, fields: fields, categoryBoost: 18) else { return nil }
        return UniversalSearchResult(
            id: "league-\(league.id)",
            title: league.name,
            subtitle: "League",
            systemImage: league.group.systemImage,
            imageURL: nil,
            rank: rank,
            payload: .league(league)
        )
    }

    private static func result(for match: Match, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [
            match.name,
            match.shortName,
            match.league.name,
            match.league.shortName,
            match.home.displayName,
            match.home.shortName,
            match.home.abbreviation,
            match.away.displayName,
            match.away.shortName,
            match.away.abbreviation,
            match.broadcasts.joined(separator: " "),
            match.venue ?? "",
            "game games match matches schedule upcoming live final"
        ]
        guard let rank = score(query: query, title: match.name, fields: fields, categoryBoost: match.state == .live ? 24 : 16) else { return nil }
        return UniversalSearchResult(
            id: "match-\(match.id)",
            title: match.name,
            subtitle: "\(match.state.label) game · \(match.searchDateText)",
            systemImage: match.state == .live ? "dot.radiowaves.left.and.right" : "calendar",
            imageURL: match.away.logoURL ?? match.home.logoURL,
            rank: rank,
            payload: .match(match)
        )
    }

    private static func result(for channel: Channel, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [channel.name, channel.group ?? "", channel.playlistName, "channel channels stream live tv watch"]
        guard let rank = score(query: query, title: channel.name, fields: fields, categoryBoost: 14) else { return nil }
        return UniversalSearchResult(
            id: "channel-\(channel.id)",
            title: channel.name,
            subtitle: "Channel",
            systemImage: "play.tv.fill",
            imageURL: channel.logoURL,
            rank: rank,
            payload: .channel(channel)
        )
    }

    private static func result(for player: SearchPlayerResult, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [
            player.athlete.displayName,
            player.athlete.position ?? "",
            player.athlete.positionName ?? "",
            player.teamName,
            player.league.name,
            player.league.shortName,
            "player players athlete roster stats injury injured"
        ]
        guard let rank = score(query: query, title: player.athlete.displayName, fields: fields, categoryBoost: 20) else { return nil }
        return UniversalSearchResult(
            id: player.id,
            title: player.athlete.displayName,
            subtitle: "Player · \(player.teamName)",
            systemImage: player.athlete.isInjured ? "cross.case.fill" : "person.fill",
            imageURL: player.athlete.headshotURL,
            rank: rank,
            payload: .player(player)
        )
    }

    private static func result(for article: ESPNArticle, query: SearchQuery) -> UniversalSearchResult? {
        let isHighlight = article.isSearchHighlight
        let fields = [
            article.headline,
            article.description,
            article.league.name,
            article.league.shortName,
            article.byline ?? "",
            article.type ?? "",
            article.categories.joined(separator: " "),
            isHighlight ? "highlight highlights video clips replay media" : "news story article report injury trade analysis"
        ]
        guard let rank = score(query: query, title: article.headline, fields: fields, categoryBoost: isHighlight ? 18 : 12) else { return nil }
        return UniversalSearchResult(
            id: "article-\(article.id)",
            title: article.headline,
            subtitle: isHighlight ? "Highlight" : "News",
            systemImage: isHighlight ? "play.rectangle.fill" : "newspaper.fill",
            imageURL: article.imageURL,
            rank: rank,
            payload: .article(article)
        )
    }

    private static func result(for feed: PodcastCatalog.CatalogFeed, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [
            feed.title,
            feed.sport,
            feed.tags.joined(separator: " "),
            "podcast podcasts talk show audio sports radio"
        ]
        guard let rank = score(query: query, title: feed.title, fields: fields, categoryBoost: 16) else { return nil }
        let sportLabel = feed.sport.capitalized
        return UniversalSearchResult(
            id: "podcast-\(feed.id)",
            title: feed.title,
            subtitle: "Podcast · \(sportLabel)",
            systemImage: "waveform",
            imageURL: feed.imageURL,
            rank: rank,
            payload: .podcast(feed.asPodcast)
        )
    }

    private static func result(for setting: SearchSettingDestination, query: SearchQuery) -> UniversalSearchResult? {
        let fields = [setting.title, setting.subtitle, setting.keywords.joined(separator: " ")]
        guard let rank = score(query: query, title: setting.title, fields: fields, categoryBoost: 10) else { return nil }
        return UniversalSearchResult(
            id: "setting-\(setting.id)",
            title: setting.title,
            subtitle: setting.subtitle,
            systemImage: setting.systemImage,
            imageURL: nil,
            rank: rank,
            payload: .setting(setting)
        )
    }

    private static func score(query: SearchQuery, title: String, fields: [String], categoryBoost: Int) -> Int? {
        let normalizedTitle = title.searchNormalized
        let normalizedFields = fields.map(\.searchNormalized)
        let combined = normalizedFields.joined(separator: " ")

        guard combined.contains(query.normalized) || query.tokens.allSatisfy({ token in combined.contains(token) }) else {
            return nil
        }

        var score = categoryBoost
        if normalizedTitle == query.normalized { score += 140 }
        if normalizedTitle.hasPrefix(query.normalized) { score += 110 }
        if normalizedTitle.contains(query.normalized) { score += 80 }
        for token in query.tokens {
            if normalizedTitle.hasPrefix(token) { score += 24 }
            if normalizedTitle.contains(token) { score += 18 }
            if normalizedFields.contains(where: { $0.hasPrefix(token) }) { score += 12 }
            if normalizedFields.contains(where: { $0.contains(token) }) { score += 8 }
        }
        if query.tokens.count > 1 && combined.contains(query.normalized) { score += 32 }
        return score
    }
}

private struct SearchQuery {
    let normalized: String
    let tokens: [String]

    init(_ rawValue: String) {
        normalized = rawValue.searchNormalized
        tokens = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 }
    }

    var isEmpty: Bool {
        normalized.isEmpty || tokens.isEmpty
    }
}

private struct SearchSectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.vertical, 6)
    }
}

private struct UniversalSearchRow: View {
    let result: UniversalSearchResult
    var accessoryText: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SearchResultArtwork(result: result)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            if let accessoryText {
                Text(accessoryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: result.accessorySystemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct SearchResultArtwork: View {
    let result: UniversalSearchResult

    var body: some View {
        ZStack {
            Theme.surfaceElevated
            if let imageURL = result.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(5)
                    } else {
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fallbackIcon: some View {
        Image(systemName: result.systemImage)
            .font(.headline)
            .foregroundStyle(Theme.accent)
    }
}

private extension UniversalSearchResult {
    var accessorySystemImage: String {
        switch payload {
        case .channel:
            "play.fill"
        case .article, .podcast:
            "arrow.up.right"
        default:
            "chevron.right"
        }
    }
}

private extension Match {
    var searchDateText: String {
        let text: String

        switch state {
        case .live:
            text = statusDetail
        case .final:
            text = "Final"
        case .pre:
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                text = "Today"
            } else if calendar.isDateInTomorrow(date) {
                text = "Tomorrow"
            } else {
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("EEEE")
                text = formatter.string(from: date)
            }
        }

        return text
    }
}

private extension ESPNArticle {
    var isSearchHighlight: Bool {
        let text = "\(type ?? "") \(headline) \(categories.joined(separator: " "))".searchNormalized
        return text.contains("highlight") || text.contains("video") || text.contains("media") || text.contains("play")
    }
}

private extension PodcastCatalog.CatalogFeed {
    var asPodcast: Podcast {
        Podcast(
            id: feedURL.absoluteString,
            title: title,
            publisher: "",
            feedURL: feedURL,
            artworkURL: imageURL,
            podcastDescription: "",
            sport: sport,
            tags: tags
        )
    }
}

private extension String {
    var searchNormalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
