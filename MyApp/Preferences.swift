import Foundation
import SwiftUI
import Combine

// MARK: - Team model

struct Team: Identifiable, Hashable {
    let id: String
    let displayName: String
    let shortDisplayName: String
    let abbreviation: String
    let logoURL: URL?
}

/// A favorited team, stored with enough context to rebuild it without a network call.
struct FavoriteTeam: Codable, Hashable, Identifiable {
    var leaguePath: String
    var teamID: String
    var displayName: String
    var abbreviation: String
    var logoURLString: String?

    var id: String { "\(leaguePath)-\(teamID)" }
    var logoURL: URL? { logoURLString.flatMap(URL.init(string:)) }

    init(team: Team, league: League) {
        self.leaguePath = league.path
        self.teamID = team.id
        self.displayName = team.displayName
        self.abbreviation = team.abbreviation
        self.logoURLString = team.logoURL?.absoluteString
    }
}

// MARK: - Persisted preferences

struct UserPreferences: Codable {
    var hasCompletedOnboarding = false
    var selectedLeagueIDs: Set<String> = []   // League.path values
    var favoriteTeams: [FavoriteTeam] = []
}

/// Owns the user's onboarding selections (sports/leagues/favorite teams) and
/// persists them to `UserDefaults` so the app remembers settings between launches.
@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var prefs: UserPreferences

    private let defaultsKey = "stadiatv.preferences.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            prefs = decoded
        } else {
            prefs = UserPreferences()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Onboarding

    var hasCompletedOnboarding: Bool { prefs.hasCompletedOnboarding }

    func completeOnboarding() {
        prefs.hasCompletedOnboarding = true
        persist()
    }

    func resetOnboarding() {
        prefs.hasCompletedOnboarding = false
        persist()
    }

    // MARK: Leagues

    /// The leagues the user follows, in the catalog's canonical order.
    /// Falls back to the full catalog when nothing has been chosen yet.
    var followedLeagues: [League] {
        let selected = League.all.filter { prefs.selectedLeagueIDs.contains($0.path) }
        return selected.isEmpty ? League.all : selected
    }

    func isLeagueSelected(_ league: League) -> Bool {
        prefs.selectedLeagueIDs.contains(league.path)
    }

    func toggleLeague(_ league: League) {
        if prefs.selectedLeagueIDs.contains(league.path) {
            prefs.selectedLeagueIDs.remove(league.path)
        } else {
            prefs.selectedLeagueIDs.insert(league.path)
        }
        persist()
    }

    func setLeagues(_ leagues: Set<League>) {
        prefs.selectedLeagueIDs = Set(leagues.map(\.path))
        persist()
    }

    // MARK: Favorite teams

    func isFavorite(_ team: Team, in league: League) -> Bool {
        prefs.favoriteTeams.contains { $0.leaguePath == league.path && $0.teamID == team.id }
    }

    func toggleFavorite(_ team: Team, in league: League) {
        if let index = prefs.favoriteTeams.firstIndex(where: { $0.leaguePath == league.path && $0.teamID == team.id }) {
            prefs.favoriteTeams.remove(at: index)
        } else {
            prefs.favoriteTeams.append(FavoriteTeam(team: team, league: league))
        }
        persist()
    }

    var favoriteTeams: [FavoriteTeam] { prefs.favoriteTeams }

    var favoriteTeamNames: Set<String> {
        Set(prefs.favoriteTeams.map { $0.displayName.lowercased() })
    }

    /// True when a match involves one of the user's favorite teams.
    func isFavoriteMatch(_ match: Match) -> Bool {
        let names = favoriteTeamNames
        guard !names.isEmpty else { return false }
        return names.contains(match.home.displayName.lowercased())
            || names.contains(match.away.displayName.lowercased())
    }
}
