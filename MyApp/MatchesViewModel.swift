import Foundation
import Combine

@MainActor
final class MatchesViewModel: ObservableObject {
    @Published var selectedLeague: League = League.all[0]
    @Published var matches: [Match] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var favoriteMatches: [Match] = []
    @Published var isLoadingFavorites = false
    @Published private(set) var allFollowedMatches: [Match] = []
    @Published private(set) var isLoadingFollowing = false

    private let sportsRepository = SportsRepository.shared
    private var refreshTask: Task<Void, Never>?
    private var lastFollowingArgs: (leagues: [League], favorites: [FavoriteTeam])?

    var liveMatches: [Match] { matches.filter { $0.state == .live } }
    var upcomingMatches: [Match] {
        matches.filter { $0.state == .pre }.sorted { $0.date < $1.date }
    }
    var finishedMatches: [Match] {
        matches.filter { $0.state == .final }.sorted { $0.date > $1.date }
    }

    var favoriteMatchesForSelectedLeague: [Match] {
        favoriteMatches.filter { $0.league.id == selectedLeague.id }
    }

    func load() async {
        isLoading = matches.isEmpty
        errorMessage = nil
        do {
            let result = try await sportsRepository.legacyScoreboard(for: selectedLeague)
            matches = result
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Loads the personalized Following feed. Team favorites are matched by exact
    /// participants; league-wide events are included only for explicitly followed leagues.
    func loadFollowing(leagues: [League], favorites: [FavoriteTeam]) async {
        lastFollowingArgs = (leagues, favorites)
        isLoadingFollowing = allFollowedMatches.isEmpty
        errorMessage = nil

        let favoriteLeagueIDs = Set(favorites.map(\.leaguePath))
        let followedLeagueIDs = Set(leagues.map(\.id))
        let sourceLeagues = reconcileLeagues(
            leagues + League.all.filter { favoriteLeagueIDs.contains($0.id) }
        )

        var loaded: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in sourceLeagues {
                let days = favoriteLeagueIDs.contains(league.id) ? 365 : 30
                group.addTask { [sportsRepository] in
                    (try? await sportsRepository.legacyScoreboards(for: league, starting: Date(), days: days)) ?? []
                }
            }
            for await matches in group {
                loaded.append(contentsOf: matches)
            }
        }

        let favoriteFiltered = filterForFavorites(loaded, favorites: favorites)
        let teamFavoriteLeagueIDs = Set(favorites.map(\.leaguePath))
        let competitionLeagueIDs = followedLeagueIDs.subtracting(teamFavoriteLeagueIDs)
        let explicitlyFollowedLeagueMatches = loaded.filter { competitionLeagueIDs.contains($0.league.id) }
        allFollowedMatches = reconcileFixtures(favoriteFiltered + explicitlyFollowedLeagueMatches)
            .sorted { $0.date < $1.date }
        favoriteMatches = reconcileFixtures(favoriteFiltered).sorted { $0.date < $1.date }
        isLoadingFollowing = false

        if allFollowedMatches.isEmpty && (!favorites.isEmpty || !leagues.isEmpty) {
            errorMessage = "No followed games were returned right now."
        }
    }

    /// All announced games over the next 365 days for the user's favorite teams,
    /// fetched across every league those teams belong to.
    func loadFavoriteSchedule(favorites: [FavoriteTeam]) async {
        guard !favorites.isEmpty else {
            favoriteMatches = []
            return
        }
        isLoadingFavorites = favoriteMatches.isEmpty

        let leaguePaths = Set(favorites.map(\.leaguePath))
        let leagues = League.all.filter { leaguePaths.contains($0.path) }
        var loaded: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask { [sportsRepository] in
                    (try? await sportsRepository.legacyScoreboards(for: league, starting: Date(), days: 365)) ?? []
                }
            }
            for await matches in group {
                loaded.append(contentsOf: matches)
            }
        }

        favoriteMatches = reconcileFixtures(filterForFavorites(loaded, favorites: favorites))
            .sorted { $0.date < $1.date }
        isLoadingFavorites = false
    }

    func selectLeague(_ league: League) {
        guard league != selectedLeague else { return }
        selectedLeague = league
        matches = []
        Task { await load() }
    }

    /// Refreshes live data on an interval while the view is on screen.
    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                if let args = self.lastFollowingArgs {
                    await self.loadFollowing(leagues: args.leagues, favorites: args.favorites)
                } else {
                    await self.load()
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func filterForFavorites(_ matches: [Match], favorites: [FavoriteTeam]) -> [Match] {
        guard !favorites.isEmpty else { return [] }
        let favoriteIDs = Set(favorites.map(\.id))
        let canonicalFavoriteIDs = Set(favorites.map(\.canonicalTeamID))
        let favoriteNames = Set(favorites.map { $0.displayName.lowercased() })
        return matches.filter { match in
            [match.home, match.away].contains { side in
                if let teamID = side.teamID, favoriteIDs.contains("\(match.league.path)-\(teamID)") {
                    return true
                }
                if let canonicalID = side.canonicalIDString, canonicalFavoriteIDs.contains(canonicalID) {
                    return true
                }
                return favoriteNames.contains(side.displayName.lowercased())
            }
        }
    }

    private func reconcileLeagues(_ leagues: [League]) -> [League] {
        var seen = Set<String>()
        return leagues.filter { seen.insert($0.id).inserted }
    }

    /// ESPN can return the same event through multiple windows, and some feeds
    /// expose reversed duplicate fixtures. Keep the richest/latest event per key.
    private func reconcileFixtures(_ matches: [Match]) -> [Match] {
        let byCanonicalID = reconcile(matches, key: { $0.id })
        return reconcile(byCanonicalID, key: fixtureKey(for:))
    }

    private func reconcile(_ matches: [Match], key: (Match) -> String) -> [Match] {
        var order: [String] = []
        var byKey: [String: Match] = [:]
        for match in matches.sorted(by: { $0.date < $1.date }) {
            let key = key(match)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = match
                continue
            }
            if shouldReplace(existing: byKey[key]!, with: match) {
                byKey[key] = match
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private func fixtureKey(for match: Match) -> String {
        let calendar = Calendar.current
        let day = ESPNService.dateFormatter.string(from: match.date)
        let teams = [match.home.displayName.lowercased(), match.away.displayName.lowercased()].sorted().joined(separator: "-")
        let minuteBucket = calendar.component(.hour, from: match.date) * 60 + calendar.component(.minute, from: match.date)
        return "\(match.league.id)-\(day)-\(minuteBucket)-\(teams)"
    }

    private func shouldReplace(existing: Match, with candidate: Match) -> Bool {
        if existing.state != .live && candidate.state == .live { return true }
        if existing.broadcasts.isEmpty && !candidate.broadcasts.isEmpty { return true }
        if existing.venue == nil && candidate.venue != nil { return true }
        return existing.id == candidate.id
    }
}
