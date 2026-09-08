import Foundation
import SwiftUI

/// Holds all onboarding selections in progress.
/// Call `commit(to:)` to persist everything once the user finishes.
@MainActor
@Observable
final class OnboardingStore {

    var selectedSportIDs: Set<String> = []
    var selectedLeagueIDs: Set<String> = []          // catalog league IDs
    var favoriteCatalogTeamIDs: Set<String> = []     // catalog team IDs

    private let catalog = SportsCatalogRepository.shared

    // MARK: - Sport

    func isSportSelected(_ sport: CatalogSport) -> Bool {
        selectedSportIDs.contains(sport.id)
    }

    /// Removes a sport and all its descendant leagues + favorites.
    func deselectSport(_ sport: CatalogSport) {
        selectedSportIDs.remove(sport.id)
        selectedLeagueIDs.subtract(sport.leagues.map(\.id))
        favoriteCatalogTeamIDs.subtract(sport.leagues.flatMap(\.teams).map(\.id))
    }

    func selectSport(_ sport: CatalogSport) {
        selectedSportIDs.insert(sport.id)
    }

    var hasAtLeastOneSport: Bool { !selectedSportIDs.isEmpty }

    // MARK: - League

    func isLeagueSelected(_ league: CatalogLeague) -> Bool {
        selectedLeagueIDs.contains(league.id)
    }

    func toggleLeague(_ league: CatalogLeague, inSport sport: CatalogSport) {
        if selectedLeagueIDs.contains(league.id) {
            selectedLeagueIDs.remove(league.id)
            favoriteCatalogTeamIDs.subtract(league.teams.map(\.id))
        } else {
            selectedLeagueIDs.insert(league.id)
            selectedSportIDs.insert(sport.id)
        }
    }

    // MARK: - Favorite teams

    func isFavorite(teamID: String) -> Bool {
        favoriteCatalogTeamIDs.contains(teamID)
    }

    func toggleFavorite(teamID: String) {
        if favoriteCatalogTeamIDs.contains(teamID) {
            favoriteCatalogTeamIDs.remove(teamID)
        } else {
            favoriteCatalogTeamIDs.insert(teamID)
        }
    }

    // MARK: - Favorite screen content

    /// (league, sport, teams) triples for leagues that have bundled team selection.
    var leaguesWithSelectableTeams: [(league: CatalogLeague, sport: CatalogSport, teams: [CatalogTeam])] {
        var result: [(CatalogLeague, CatalogSport, [CatalogTeam])] = []
        for sport in catalog.sports where selectedSportIDs.contains(sport.id) {
            for league in catalog.leagues(for: sport) where selectedLeagueIDs.contains(league.id) {
                let teams = catalog.teams(for: league)
                if league.supportsTeamSelection && !teams.isEmpty {
                    result.append((league, sport, teams))
                }
            }
        }
        return result
    }

    var hasFavoriteScreenContent: Bool { !leaguesWithSelectableTeams.isEmpty }

    // MARK: - Commit to PreferencesStore

    func commit(to prefs: PreferencesStore) {
        // Map catalog leagues → legacy League objects for ESPN-backed views
        var legacyLeagues = Set<League>()
        for id in selectedLeagueIDs {
            if let league = catalog.legacyLeague(for: id) { legacyLeagues.insert(league) }
        }
        if !legacyLeagues.isEmpty { prefs.setLeagues(legacyLeagues) }

        // Persist catalog IDs for catalog-aware views
        prefs.setSelectedCatalogLeagueIDs(selectedLeagueIDs)
        prefs.setSelectedCatalogSportIDs(selectedSportIDs)

        // Commit favorite teams
        for teamID in favoriteCatalogTeamIDs {
            guard
                let catalogTeam = catalog.team(id: teamID),
                let leagueID = SportsCatalogRepository.leagueID(fromTeamID: teamID),
                let league = catalog.legacyLeague(for: leagueID)
            else { continue }
            let team = catalog.makeTeam(from: catalogTeam, leagueID: leagueID)
            if !prefs.isFavorite(team, in: league) {
                prefs.toggleFavorite(team, in: league)
            }
        }

        prefs.completeOnboarding()
    }
}
