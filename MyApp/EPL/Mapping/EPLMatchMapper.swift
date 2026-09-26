import Foundation

/// Maps raw PulseLive/SDP JSON into the canonical Soccer domain. Defensive throughout —
/// an undocumented, unversioned API can add/rename/drop fields without notice (see
/// EPL-INTEGRATION.md), so every accessor tolerates absence and nothing force-unwraps.
nonisolated enum EPLMatchMapper {

    /// A team as it appears embedded in a match's `homeTeam`/`awayTeam` object.
    static func teamMatchState(_ raw: EPLValue) -> SoccerTeamMatchState? {
        guard let id = raw["id"].string else { return nil }
        let team = SoccerTeam(id: id, name: raw["name"].string ?? "Team", shortName: raw["shortName"].string ?? raw["name"].string ?? "Team", abbreviation: raw["abbr"].string ?? "")
        return SoccerTeamMatchState(team: team, score: raw["score"].int, halfTimeScore: raw["halfTimeScore"].int, redCards: raw["redCards"].int ?? 0)
    }

    /// A team as it appears in a teams-list/season-teams response.
    static func team(_ raw: EPLValue) -> SoccerTeam? {
        guard let id = raw["id"].string else { return nil }
        return SoccerTeam(id: id, name: raw["name"].string ?? "Team", shortName: raw["shortName"].string ?? raw["name"].string ?? "Team", abbreviation: raw["abbr"].string ?? "")
    }

    /// A single match, from either a `/v2/matches` list row or the `/v2/matches/{id}` detail
    /// object — both share the same field names, but only the detail form nests
    /// `seasonInfo`; the list form has a flat `season` string instead.
    static func match(_ raw: EPLValue) -> SoccerMatch? {
        guard let id = raw["matchId"].string,
              let kickoff = EPLDate.parseKickoff(raw["kickoff"].string),
              let home = teamMatchState(raw["homeTeam"]),
              let away = teamMatchState(raw["awayTeam"]) else { return nil }
        let season = raw["season"].string ?? raw["seasonId"].string ?? raw["seasonInfo"]["id"].string ?? EPLSeasonResolver.seasonParameter(for: kickoff)
        let status = EPLStatusMapper.status(period: raw["period"].string)
        return SoccerMatch(id: id, competitionID: raw["competitionId"].string ?? EPLSeasonResolver.competitionID, season: season,
            matchWeek: raw["matchWeek"].int, phase: raw["phase"].string, kickoff: kickoff, status: status,
            clock: EPLClockMapper.clock(status: status, rawClock: raw["clock"].string), home: home, away: away,
            ground: raw["ground"].string, attendance: raw["attendance"].int, resultType: raw["resultType"].string)
    }

    // MARK: Standings

    static func standingsSplit(_ raw: EPLValue) -> SoccerStandingsSplit {
        SoccerStandingsSplit(position: raw["position"].int, played: raw["played"].int, won: raw["won"].int, drawn: raw["drawn"].int, lost: raw["lost"].int,
            goalsFor: raw["goalsFor"].int, goalsAgainst: raw["goalsAgainst"].int, points: raw["points"].int, startingPosition: raw["startingPosition"].int)
    }

    static func standingsEntry(_ raw: EPLValue) -> SoccerStandingsEntry? {
        guard let team = team(raw["team"]) else { return nil }
        let home = raw["home"], away = raw["away"]
        return SoccerStandingsEntry(team: team, overall: standingsSplit(raw["overall"]),
            home: home == .null ? nil : standingsSplit(home), away: away == .null ? nil : standingsSplit(away))
    }

    static func standingsTable(_ raw: EPLValue, live: Bool) -> SoccerStandingsTable {
        let entries = raw["tables"].array.flatMap { $0["entries"].array }.compactMap { standingsEntry($0) }
        var deductions: [String: Int] = [:]
        for entry in raw["deductions"].array {
            if let teamID = entry["team"]["id"].string ?? entry["teamId"].string, let points = entry["points"].int { deductions[teamID] = points }
        }
        return SoccerStandingsTable(matchWeek: raw["matchweek"].int, entries: entries, isLive: live, deductions: deductions)
    }

    // MARK: Players

    /// Squad-list player row: `{name:{first,last,display}, id, shirtNum, position, ...}`.
    static func rosterPlayer(_ raw: EPLValue) -> SoccerRosterPlayer? {
        guard let id = raw["id"].string else { return nil }
        let name = raw["name"]
        let reference = SoccerPlayerReference(id: id, firstName: name["first"].string, lastName: name["last"].string)
        let birth = raw["dates"]["birth"].string.flatMap { value -> Date? in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: value)
        }
        return SoccerRosterPlayer(reference: reference, position: raw["position"].string, shirtNumber: raw["shirtNum"].string, nationality: raw["country"]["country"].string, dateOfBirth: birth)
    }

    /// `/v1/players/{id}/basic`: `{firstName, lastName, id, position, currentTeam, ...}`.
    static func playerBasic(_ raw: EPLValue) -> SoccerPlayerReference? {
        guard let id = raw["id"].string else { return nil }
        return SoccerPlayerReference(id: id, firstName: raw["firstName"].string, lastName: raw["lastName"].string)
    }
}
