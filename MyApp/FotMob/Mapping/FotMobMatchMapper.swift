import Foundation

/// Overlays FotMob's live score/status/clock onto an already-known `SoccerMatch`
/// (the official LaLiga fixture) rather than building one from scratch — FotMob's
/// team/competition/season identity is never trusted over the official source
/// (Step 19); only score/clock/status are ever taken from here, and only while
/// `LaLigaGameCentreService` has decided FotMob is the authoritative live source
/// for this match.
nonisolated enum FotMobMatchMapper {
    static func apply(_ raw: FotMobValue, to base: SoccerMatch) -> SoccerMatch {
        var result = base
        let teams = raw["header"]["teams"].array
        if teams.count > 0 { result.home.score = teams[0]["score"].int }
        if teams.count > 1 { result.away.score = teams[1]["score"].int }
        let status = FotMobStatusMapper.status(raw["header"]["status"])
        result.status = status
        result.clock = FotMobClockMapper.clock(status: status, raw: raw["header"]["status"])
        return result
    }

    /// `general.matchId` — FotMob's own match identifier, distinct from La Liga's
    /// official id (Step 16). Never compared to or substituted for it.
    static func matchID(_ raw: FotMobValue) -> String? { raw["general"]["matchId"].string }
    static func homeTeamID(_ raw: FotMobValue) -> String? { raw["general"]["homeTeam"]["id"].string }
    static func awayTeamID(_ raw: FotMobValue) -> String? { raw["general"]["awayTeam"]["id"].string }
    static func homeTeamName(_ raw: FotMobValue) -> String? { raw["general"]["homeTeam"]["name"].string }
    static func awayTeamName(_ raw: FotMobValue) -> String? { raw["general"]["awayTeam"]["name"].string }
    static func kickoff(_ raw: FotMobValue) -> Date? { FotMobDate.parse(raw["header"]["status"]["utcTime"].string) }
}

nonisolated enum FotMobDate {
    /// FotMob's `utcTime` is millisecond ISO 8601 (`"2026-08-15T17:30:00.000Z"`),
    /// verified live 2026-09-24.
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value)
    }
    // `ISO8601DateFormatter` predates Sendable but is never mutated after creation
    // here — read-only use is safe across concurrent callers.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
