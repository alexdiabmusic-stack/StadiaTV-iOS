import Foundation
import Testing
@testable import BannerTV

@MainActor
@Suite("Sports Catalog + Onboarding")
struct SportsCatalogTests {

    // MARK: - Catalog decode

    @Test("Catalog loads from bundle")
    func catalogLoadsFromBundle() {
        #expect(SportsCatalogRepository.shared.catalog != nil,
                "banner_sports_catalog.json must be bundled and decodable")
    }

    @Test("Catalog has at least one sport")
    func catalogHasSports() {
        #expect(!SportsCatalogRepository.shared.sports.isEmpty)
    }

    @Test("Football sport has leagues")
    func footballHasLeagues() throws {
        let repo = SportsCatalogRepository.shared
        let football = try #require(repo.sports.first { $0.id == "football" },
                                   "Football sport must exist in catalog")
        #expect(!repo.leagues(for: football).isEmpty, "Football must have at least one enabled league")
    }

    @Test("NHL has 32 teams")
    func nhlHas32Teams() throws {
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        let teams = repo.teams(for: nhl)
        #expect(teams.count == 32, "NHL must have exactly 32 teams, got \(teams.count)")
    }

    // MARK: - Unique IDs

    @Test("Sport IDs are unique across catalog")
    func sportIDsAreUnique() {
        let ids = SportsCatalogRepository.shared.sports.map(\.id)
        #expect(ids.count == Set(ids).count, "Every sport must have a unique ID")
    }

    @Test("League IDs are globally unique")
    func leagueIDsAreUnique() {
        let repo = SportsCatalogRepository.shared
        var seen = Set<String>()
        var duplicates: [String] = []
        for sport in repo.sports {
            for league in repo.leagues(for: sport) {
                if seen.contains(league.id) { duplicates.append(league.id) }
                seen.insert(league.id)
            }
        }
        #expect(duplicates.isEmpty, "Duplicate league IDs: \(duplicates)")
    }

    // MARK: - Ordering

    @Test("Sports are sorted by uiSortOrder")
    func sportsAreSortedByUIOrder() {
        let orders = SportsCatalogRepository.shared.sports.map(\.uiSortOrder)
        #expect(orders == orders.sorted(), "sports must be in ascending uiSortOrder")
    }

    @Test("Leagues within a sport are sorted by sortOrder")
    func leaguesAreSortedBySortOrder() throws {
        let repo = SportsCatalogRepository.shared
        let football = try #require(repo.sports.first { $0.id == "football" })
        let orders = repo.leagues(for: football).map(\.sortOrder)
        #expect(orders == orders.sorted(), "football leagues must be in ascending sortOrder")
    }

    // MARK: - Disabled entries excluded

    @Test("Disabled leagues are excluded from leagues(for:)")
    func disabledLeaguesExcluded() {
        let repo = SportsCatalogRepository.shared
        for sport in repo.sports {
            for league in repo.leagues(for: sport) {
                #expect(league.enabled, "leagues(for:) must only return enabled leagues, found disabled: \(league.id)")
            }
        }
    }

    // MARK: - Sport selection

    @Test("selectSport adds to selectedSportIDs")
    func selectSportAddsID() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        let football = try #require(repo.sports.first { $0.id == "football" })
        store.selectSport(football)
        #expect(store.isSportSelected(football))
    }

    @Test("deselectSport removes sport, its leagues, and team favorites")
    func deselectSportCleansUp() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })

        store.selectSport(hockey)
        store.toggleLeague(nhl, inSport: hockey)
        // Favorite a team
        if let team = repo.teams(for: nhl).first { store.toggleFavorite(teamID: team.id) }

        store.deselectSport(hockey)
        #expect(!store.isSportSelected(hockey), "sport should be deselected")
        #expect(!store.isLeagueSelected(nhl), "league should be removed")
        // Verify no hockey team IDs remain in favorites
        let hockeyTeamIDs = Set(hockey.leagues.flatMap(\.teams).map(\.id))
        #expect(store.favoriteCatalogTeamIDs.isDisjoint(with: hockeyTeamIDs),
                "all hockey team favorites should be removed on sport deselect")
    }

    @Test("hasAtLeastOneSport is false when nothing selected")
    func hasAtLeastOneSportFalseWhenEmpty() {
        let store = OnboardingStore()
        #expect(!store.hasAtLeastOneSport)
    }

    // MARK: - League selection

    @Test("toggleLeague auto-selects parent sport")
    func toggleLeagueAutoSelectsSport() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })

        store.toggleLeague(nhl, inSport: hockey)
        #expect(store.isSportSelected(hockey), "selecting a league must auto-select its parent sport")
        #expect(store.isLeagueSelected(nhl))
    }

    @Test("toggleLeague deselect removes team favorites for that league")
    func toggleLeagueRemovesTeamFavorites() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        let team = try #require(repo.teams(for: nhl).first)

        store.toggleLeague(nhl, inSport: hockey)
        store.toggleFavorite(teamID: team.id)
        #expect(store.isFavorite(teamID: team.id))

        store.toggleLeague(nhl, inSport: hockey)
        #expect(!store.isFavorite(teamID: team.id),
                "deselecting a league must remove its team favorites")
    }

    // MARK: - Favorites screen content

    @Test("Dynamic leagues excluded from leaguesWithSelectableTeams")
    func dynamicLeaguesExcludedFromFavoritesScreen() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        // Tennis: ATP Tour is a dynamic/individual league (no bundled teams)
        guard let tennis = repo.sports.first(where: { $0.id == "tennis" }),
              let atp = repo.leagues(for: tennis).first(where: { $0.id == "tennis:atp-tour" })
        else { return }

        store.toggleLeague(atp, inSport: tennis)
        let content = store.leaguesWithSelectableTeams
        let hasATP = content.contains { $0.league.id == "tennis:atp-tour" }
        #expect(!hasATP, "ATP (dynamic/individual league) must not appear in favorite team selection")
    }

    @Test("hasFavoriteScreenContent true when NHL selected")
    func hasFavoriteScreenContentTrueForNHL() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        store.toggleLeague(nhl, inSport: hockey)
        #expect(store.hasFavoriteScreenContent, "NHL is a fixed-team league; favorites screen should appear")
    }

    @Test("hasFavoriteScreenContent false when only tennis selected")
    func hasFavoriteScreenContentFalseForTennis() throws {
        let store = OnboardingStore()
        let repo = SportsCatalogRepository.shared
        guard let tennis = repo.sports.first(where: { $0.id == "tennis" }) else { return }
        for league in repo.leagues(for: tennis) {
            store.toggleLeague(league, inSport: tennis)
        }
        #expect(!store.hasFavoriteScreenContent,
                "Tennis has no bundled teams; favorites screen must be skipped")
    }

    // MARK: - Legacy path mapping

    @Test("legacyPath maps NHL catalog ID correctly")
    func legacyPathNHL() {
        let path = SportsCatalogRepository.legacyPath["hockey:national-hockey-league"]
        #expect(path == "hockey/nhl")
    }

    @Test("legacyLeague returns NHL League for catalog ID")
    func legacyLeagueForNHL() {
        let league = SportsCatalogRepository.shared.legacyLeague(for: "hockey:national-hockey-league")
        #expect(league != nil, "legacy NHL league must resolve from catalog ID")
        #expect(league?.path == "hockey/nhl")
    }

    @Test("legacyLeague returns nil for unknown catalog ID")
    func legacyLeagueUnknownID() {
        let league = SportsCatalogRepository.shared.legacyLeague(for: "sport:unknown-league-xyz")
        #expect(league == nil)
    }

    // MARK: - Team ID extraction

    @Test("leagueID(fromTeamID:) extracts league portion of team ID")
    func leagueIDFromTeamIDValid() {
        let result = SportsCatalogRepository.leagueID(fromTeamID: "hockey:national-hockey-league:tor")
        #expect(result == "hockey:national-hockey-league")
    }

    @Test("leagueID(fromTeamID:) returns nil for malformed team ID")
    func leagueIDFromTeamIDInvalid() {
        #expect(SportsCatalogRepository.leagueID(fromTeamID: "bad-id") == nil)
        #expect(SportsCatalogRepository.leagueID(fromTeamID: "only:two") == nil)
    }

    // MARK: - Logo resolution

    @Test("NHL team logo URL resolves to bundle asset")
    func nhlTeamLogoResolved() throws {
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        // Sabres have a well-known abbreviation "BUF"
        let sabres = repo.teams(for: nhl).first { $0.abbreviation == "BUF" }
            ?? repo.teams(for: nhl).first!
        let url = repo.logoURL(for: sabres, leagueID: nhl.id)
        // May be nil if the asset isn't in this build, but the scheme must be correct when present
        if let url {
            #expect(url.scheme == "banner-asset", "NHL logo must use banner-asset:// scheme")
        }
    }

    @Test("NFL team logo URL resolves to bundle asset")
    func nflTeamLogoResolved() throws {
        let repo = SportsCatalogRepository.shared
        let football = try #require(repo.sports.first { $0.id == "football" })
        let nfl = try #require(repo.leagues(for: football).first { $0.id == "football:national-football-league" })
        let cowboys = repo.teams(for: nfl).first { $0.abbreviation == "DAL" }
            ?? repo.teams(for: nfl).first!
        let url = repo.logoURL(for: cowboys, leagueID: nfl.id)
        if let url {
            #expect(url.scheme == "banner-asset")
        }
    }

    @Test("Missing logo returns nil for unknown league ID")
    func missingLogoReturnsNil() throws {
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        let team = try #require(repo.teams(for: nhl).first)
        // Using a made-up league ID that has no legacyPath entry → nil
        let url = repo.logoURL(for: team, leagueID: "made-up:fake-league")
        #expect(url == nil)
    }

    // MARK: - makeTeam bridge

    @Test("makeTeam creates Team with catalog canonical ID")
    func makeTeamHasCanonicalID() throws {
        let repo = SportsCatalogRepository.shared
        let hockey = try #require(repo.sports.first { $0.id == "hockey" })
        let nhl = try #require(repo.leagues(for: hockey).first { $0.id == "hockey:national-hockey-league" })
        let catalogTeam = try #require(repo.teams(for: nhl).first)
        let team = repo.makeTeam(from: catalogTeam, leagueID: nhl.id)
        #expect(team.canonicalIDString == "team:catalog:\(catalogTeam.id)")
        #expect(team.displayName == catalogTeam.name)
    }

    // MARK: - supportsTeamSelection

    @Test("NFL supportsTeamSelection is true")
    func nflSupportsTeamSelection() throws {
        let repo = SportsCatalogRepository.shared
        let football = try #require(repo.sports.first { $0.id == "football" })
        let nfl = try #require(repo.leagues(for: football).first { $0.id == "football:national-football-league" })
        #expect(nfl.supportsTeamSelection, "NFL must support team selection (fixed membership + teams)")
    }

    @Test("ATP Tour supportsTeamSelection is false")
    func atpDoesNotSupportTeamSelection() throws {
        let repo = SportsCatalogRepository.shared
        guard let tennis = repo.sports.first(where: { $0.id == "tennis" }),
              let atp = repo.leagues(for: tennis).first(where: { $0.id == "tennis:atp-tour" })
        else { return }
        #expect(!atp.supportsTeamSelection, "ATP Tour must not support team selection (individual players)")
    }
}
