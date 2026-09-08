import Foundation

/// Loads banner_sports_catalog.json once at startup, caches it, and exposes
/// helpers used by the onboarding flow and the rest of the app.
@MainActor
final class SportsCatalogRepository {
    static let shared = SportsCatalogRepository()

    private(set) var catalog: SportsCatalog?
    private(set) var loadError: String?

    private init() { load() }

    private func load() {
        guard let url = Bundle.main.url(forResource: "banner_sports_catalog", withExtension: "json") else {
            loadError = "[Catalog] banner_sports_catalog.json not found in bundle."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            catalog = try JSONDecoder().decode(SportsCatalog.self, from: data)
        } catch {
            loadError = "[Catalog] Decode failed: \(error)"
        }
    }

    // MARK: - Ordered accessors

    var sports: [CatalogSport] {
        (catalog?.sports ?? []).sorted { $0.uiSortOrder < $1.uiSortOrder }
    }

    func leagues(for sport: CatalogSport) -> [CatalogLeague] {
        sport.leagues.filter(\.enabled).sorted { $0.sortOrder < $1.sortOrder }
    }

    func teams(for league: CatalogLeague) -> [CatalogTeam] {
        league.teams.sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Lookup

    func sport(id: String) -> CatalogSport? {
        catalog?.sports.first { $0.id == id }
    }

    func league(id: String) -> CatalogLeague? {
        catalog?.sports.flatMap(\.leagues).first { $0.id == id }
    }

    func team(id: String) -> CatalogTeam? {
        catalog?.sports.flatMap(\.leagues).flatMap(\.teams).first { $0.id == id }
    }

    // MARK: - SportGroup bridge

    func sportGroup(for catalogSportID: String) -> SportGroup? {
        switch catalogSportID {
        case "football":   return .football
        case "basketball": return .basketball
        case "baseball":   return .baseball
        case "hockey":     return .hockey
        case "soccer":     return .soccer
        case "tennis":     return .tennis
        case "golf":       return .golf
        case "racing":     return .racing
        default:           return nil
        }
    }

    // MARK: - Legacy League bridge

    /// Returns the existing `League` struct for a catalog league ID, if one exists.
    func legacyLeague(for catalogLeagueID: String) -> League? {
        guard let path = Self.legacyPath[catalogLeagueID] else { return nil }
        return League.all.first { $0.path == path }
    }

    func legacyLeaguePath(for catalogLeagueID: String) -> String? {
        Self.legacyPath[catalogLeagueID]
    }

    // MARK: - Logo resolution

    /// Returns a local bundle asset URL for a catalog team using TeamLogoAssetResolver.
    func logoURL(for team: CatalogTeam, leagueID: String) -> URL? {
        guard let path = Self.legacyPath[leagueID] else { return nil }
        return TeamLogoAssetResolver.assetURL(
            leaguePath: path,
            abbreviation: team.abbreviation,
            displayName: team.name
        )
    }

    // MARK: - Catalog team → legacy Team struct

    func makeTeam(from catalogTeam: CatalogTeam, leagueID: String) -> Team {
        Team(
            id: catalogTeam.id,
            displayName: catalogTeam.name,
            shortDisplayName: catalogTeam.abbreviation ?? catalogTeam.name,
            abbreviation: catalogTeam.abbreviation ?? "",
            logoURL: logoURL(for: catalogTeam, leagueID: leagueID),
            canonicalIDString: "team:catalog:\(catalogTeam.id)"
        )
    }

    // MARK: - Team ID → parent league ID

    static func leagueID(fromTeamID teamID: String) -> String? {
        let parts = teamID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return "\(parts[0]):\(parts[1])"
    }

    // MARK: - Catalog → Legacy path mapping

    nonisolated static let legacyPath: [String: String] = [
        // Football
        "football:national-football-league":                 "football/nfl",
        "football:canadian-football-league":                 "football/cfl",
        "football:ncaa-football":                            "football/college-football",
        "football:united-football-league":                   "football/ufl",
        // Basketball
        "basketball:nba":                                    "basketball/nba",
        "basketball:wnba":                                   "basketball/wnba",
        "basketball:nba-g-league":                           "basketball/nba-development",
        "basketball:ncaa-men-s-basketball":                  "basketball/mens-college-basketball",
        "basketball:ncaa-women-s-basketball":                "basketball/womens-college-basketball",
        "basketball:australian-national-basketball-league":  "basketball/nbl",
        // Baseball
        "baseball:major-league-baseball":                    "baseball/mlb",
        "baseball:ncaa-division-i-baseball":                 "baseball/college-baseball",
        "baseball:world-baseball-classic":                   "baseball/world-baseball-classic",
        // Hockey
        "hockey:national-hockey-league":                     "hockey/nhl",
        "hockey:ncaa-men-s-ice-hockey":                      "hockey/mens-college-hockey",
        "hockey:ncaa-women-s-ice-hockey":                    "hockey/womens-college-hockey",
        // Soccer
        "soccer:premier-league":                             "soccer/eng.1",
        "soccer:efl-championship":                           "soccer/eng.2",
        "soccer:major-league-soccer":                        "soccer/usa.1",
        "soccer:national-women-s-soccer-league":             "soccer/usa.nwsl",
        "soccer:la-liga":                                    "soccer/esp.1",
        "soccer:serie-a":                                    "soccer/ita.1",
        "soccer:bundesliga":                                 "soccer/ger.1",
        "soccer:ligue-1":                                    "soccer/fra.1",
        "soccer:liga-mx":                                    "soccer/mex.1",
        "soccer:eredivisie":                                 "soccer/ned.1",
        "soccer:primeira-liga":                              "soccer/por.1",
        "soccer:saudi-pro-league":                           "soccer/ksa.1",
        "soccer:uefa-champions-league":                      "soccer/uefa.champions",
        "soccer:uefa-europa-league":                         "soccer/uefa.europa",
        "soccer:fifa-world-cup":                             "soccer/fifa.world",
        // Tennis
        "tennis:atp-tour":                                   "tennis/atp",
        "tennis:wta-tour":                                   "tennis/wta",
        // Golf
        "golf:pga-tour":                                     "golf/pga",
        "golf:lpga-tour":                                    "golf/lpga",
        "golf:dp-world-tour":                                "golf/eur",
        "golf:pga-tour-champions":                           "golf/champions-tour",
        // Racing
        "racing:formula-1":                                  "racing/f1",
        "racing:nascar-cup-series":                          "racing/nascar-premier",
        "racing:nascar-craftsman-truck-series":              "racing/nascar-truck",
        "racing:indycar-series":                             "racing/irl",
        "racing:nhra":                                       "racing/nhra",
    ]
}
