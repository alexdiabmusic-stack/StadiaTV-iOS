import Foundation

/// Maps `/api/v1/matches` and `/api/v1/subscriptions/{slug}/standing` team/match
/// objects into the canonical Soccer domain. Verified live 2026-09-24 against both a
/// pre-match and a full-time fixture, plus a standings row — see LALIGA-INTEGRATION.md
/// for the exact probed field set. Score fields (`home_score`/`away_score`) are
/// entirely absent pre-match, never `0` — mapped straight through as optional ints,
/// never defaulted.
nonisolated enum LaLigaMatchMapper {
    static func team(_ raw: LaLigaValue) -> SoccerTeam? {
        guard let id = raw["id"].string else { return nil }
        let name = raw["name"].string ?? raw["nickname"].string ?? "Team"
        let shortName = raw["nickname"].string ?? name
        let abbreviation = raw["shortname"].string ?? String(shortName.prefix(3)).uppercased()
        LaLigaAssetResolver.shared.record(teamID: id, shieldURLString: raw["shield"]["url"].string)
        return SoccerTeam(id: id, name: name, shortName: shortName, abbreviation: abbreviation)
    }

    static func teamIdentity(_ raw: LaLigaValue) -> LaLigaTeamIdentity? {
        guard let numericID = raw["id"].string else { return nil }
        return LaLigaTeamIdentity(numericID: numericID, optaID: raw["opta_id"].string, slug: raw["slug"].string)
    }

    static func teamMatchState(_ teamRaw: LaLigaValue, score: LaLigaValue) -> SoccerTeamMatchState? {
        guard let team = team(teamRaw) else { return nil }
        return SoccerTeamMatchState(team: team, score: score.int, halfTimeScore: nil, redCards: 0)
    }

    /// A single `/api/v1/matches` row. The list endpoint returns matches in
    /// descending-date order (verified live 2026-09-24, offset 0 = the season's last
    /// gameweek) — callers that need chronological order must sort explicitly rather
    /// than trust feed order.
    static func match(_ raw: LaLigaValue, season: String) -> SoccerMatch? {
        guard let id = raw["id"].string,
              let kickoff = LaLigaDate.parse(raw["date"].string),
              let home = teamMatchState(raw["home_team"], score: raw["home_score"]),
              let away = teamMatchState(raw["away_team"], score: raw["away_score"]) else { return nil }
        let status = LaLigaStatusMapper.status(raw["status"].string)
        return SoccerMatch(id: id, competitionID: String(LaLigaProviderConfiguration.competitionID), season: season,
            matchWeek: raw["gameweek"]["week"].int, phase: nil, kickoff: kickoff, status: status, clock: nil,
            home: home, away: away, ground: raw["venue"]["name"].string, attendance: nil, resultType: nil)
    }

    // MARK: Standings

    static func standingsSplit(_ raw: LaLigaValue) -> SoccerStandingsSplit {
        SoccerStandingsSplit(position: raw["position"].int, played: raw["played"].int, won: raw["won"].int, drawn: raw["drawn"].int,
            lost: raw["lost"].int, goalsFor: raw["goals_for"].int, goalsAgainst: raw["goals_against"].int, points: raw["points"].int, startingPosition: nil)
    }

    static func standingsEntry(_ raw: LaLigaValue) -> SoccerStandingsEntry? {
        guard let team = team(raw["team"]) else { return nil }
        return SoccerStandingsEntry(team: team, overall: standingsSplit(raw), home: nil, away: nil)
    }

    /// Official pre-match table only — the standing endpoint has no documented
    /// `live=true` equivalent (Step 30), so this always maps `isLive: false`; the
    /// Overview UI must label it "LEAGUE TABLE", never "LIVE TABLE".
    static func standingsTable(_ raw: LaLigaValue) -> SoccerStandingsTable {
        SoccerStandingsTable(matchWeek: nil, entries: raw["standings"].array.compactMap(standingsEntry), isLive: false, deductions: [:])
    }
}
