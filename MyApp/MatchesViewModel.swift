import Foundation
import Combine

@MainActor
final class MatchesViewModel: ObservableObject {
    @Published var selectedLeague: League = League.all[0]
    @Published var matches: [Match] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = ESPNService()
    private var refreshTask: Task<Void, Never>?

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
            let result = try await service.scoreboard(for: selectedLeague)
            matches = result
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// All announced games over the next 365 days for the user's favorite teams,
    /// fetched across every league those teams belong to.
    @Published var favoriteMatches: [Match] = []
    @Published var isLoadingFavorites = false

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
                group.addTask { [service] in
                    (try? await service.scoreboards(for: league, starting: Date(), days: 365)) ?? []
                }
            }
            for await matches in group {
                loaded.append(contentsOf: matches)
            }
        }

        let favoriteIDs = Set(favorites.map(\.id))
        let favoriteNames = Set(favorites.map { $0.displayName.lowercased() })
        favoriteMatches = loaded.filter { match in
            let sides = [match.home, match.away]
            return sides.contains { side in
                if let teamID = side.teamID, favoriteIDs.contains("\(match.league.path)-\(teamID)") {
                    return true
                }
                return favoriteNames.contains(side.displayName.lowercased())
            }
        }
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
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30s
                guard !Task.isCancelled else { break }
                await self?.load()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
