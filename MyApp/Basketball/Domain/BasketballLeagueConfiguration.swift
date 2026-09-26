import Foundation

/// Every native basketball league sharing this Game Center. Centralized rather
/// than scattering league IDs ("00" NBA, "10" WNBA) through call sites.
nonisolated enum BasketballLeague: String, Codable, Sendable, CaseIterable {
    case nba, wnba
}

/// League-specific wiring the shared Basketball Game Center is parameterized by —
/// which CDN/stats host to talk to, the league's own numeric ID, and its app-level
/// league path. NBA and WNBA both feed the same canonical domain/services/UI; only
/// this configuration (plus each league's own API/DTO/Mapping stack) differs.
nonisolated struct BasketballLeagueConfiguration: Sendable {
    let league: BasketballLeague
    let leagueID: String
    let liveCDNHost: String
    let statsHost: String
    let leaguePath: String
    let displayName: String

    static let nba = BasketballLeagueConfiguration(league: .nba, leagueID: "00", liveCDNHost: "cdn.nba.com", statsHost: "stats.nba.com", leaguePath: "basketball/nba", displayName: "NBA")
    static let wnba = BasketballLeagueConfiguration(league: .wnba, leagueID: "10", liveCDNHost: "cdn.wnba.com", statsHost: "stats.wnba.com", leaguePath: "basketball/wnba", displayName: "WNBA")
}

/// A provider-native game identifier, tagged with which league issued it. NBA and
/// WNBA both use 10-digit numeric strings with load-bearing leading zeros (never
/// stored as an `Int`) — the `league` tag is what keeps a WNBA and an NBA game ID
/// that happen to share the same digits from ever being treated as the same game
/// (cache keys, snapshot identity, reducer stale-update checks all compare the
/// whole `BasketballGameID`, not just `providerID`).
nonisolated struct BasketballGameID: Hashable, Codable, Sendable, CustomStringConvertible {
    let league: BasketballLeague
    let providerID: String
    var description: String { providerID }

    /// Both NBA and WNBA gameIds are exactly 10 numeric characters. Returns `nil`
    /// for anything else rather than truncating/coercing untrusted network input.
    static func validated(_ raw: String, league: BasketballLeague) -> BasketballGameID? {
        guard raw.count == 10, raw.allSatisfy(\.isNumber) else { return nil }
        return BasketballGameID(league: league, providerID: raw)
    }
}
