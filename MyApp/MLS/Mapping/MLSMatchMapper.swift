import Foundation

/// Maps MLS's schedule and match-overview payloads into the canonical Soccer
/// domain. Two distinct shapes feed `SoccerMatch`: `/matches/seasons/{id}` returns
/// flat schedule entries (score/status/team identity inline), while `/matches/{id}`
/// nests the same information under `match_information`/`home`/`away`/`environment`.
/// Score always comes from `home_team_goals`/`away_team_goals` (real integers on
/// both shapes) rather than parsing the `"2:2"` display string.
nonisolated enum MLSMatchMapper {
    static func scheduleMatch(_ raw: MLSValue) -> SoccerMatch? {
        guard let matchID = raw["match_id"].string,
              let homeID = raw["home_team_id"].string, let awayID = raw["away_team_id"].string,
              let seasonID = raw["season_id"].string, let competitionID = raw["competition_id"].string,
              let kickoff = MLSDate.parseISO8601(raw["planned_kickoff_time"].string) else { return nil }
        let statusRaw = raw["match_status"].string
        let status = MLSStatusMapper.status(matchStatus: statusRaw)
        func side(teamID: String, nameKey: String, shortKey: String, abbrKey: String, goalsKey: String) -> SoccerTeamMatchState {
            SoccerTeamMatchState(team: SoccerTeam(id: teamID, name: raw[nameKey].string ?? teamID, shortName: raw[shortKey].string ?? teamID, abbreviation: raw[abbrKey].string ?? teamID),
                score: raw[goalsKey].int, halfTimeScore: nil, redCards: 0)
        }
        var match = SoccerMatch(id: matchID, competitionID: competitionID, season: raw["season"].int.map(String.init) ?? seasonID,
            matchWeek: raw["match_day"].int, phase: raw["match_type"].string, kickoff: kickoff, status: status,
            clock: MLSClockMapper.clock(status: status, minuteOfPlay: raw["minute_of_play"].string),
            home: side(teamID: homeID, nameKey: "home_team_name", shortKey: "home_team_short_name", abbrKey: "home_team_three_letter_code", goalsKey: "home_team_goals"),
            away: side(teamID: awayID, nameKey: "away_team_name", shortKey: "away_team_short_name", abbrKey: "away_team_three_letter_code", goalsKey: "away_team_goals"),
            ground: raw["stadium_name"].string, attendance: nil, resultType: nil)
        match.conference = raw["sub_league"].string
        match.competitionName = raw["competition_name"].string
        match.dataStatus = raw["match_date_time_status"].string
        return match
    }

    static func overviewMatch(_ raw: MLSValue) -> SoccerMatch? {
        let info = raw["match_information"]
        guard let matchID = info["match_id"].string, let seasonID = info["season_id"].string,
              let competitionID = info["competition_id"].string,
              let kickoff = MLSDate.parseISO8601(info["kickoff_time"].string) ?? MLSDate.parseISO8601(info["planned_kickoff_time"].string) else { return nil }
        let home = raw["home"], away = raw["away"]
        guard let homeID = home["team_id"].string, let awayID = away["team_id"].string else { return nil }
        let statusRaw = info["match_status"].string
        let status = MLSStatusMapper.status(matchStatus: statusRaw)
        // Match overview's player entries carry no card/dismissal field (that only
        // appears in `/statistics/players/matches/{id}`) — `redCards` defaults to 0
        // here, same as EPL when the count isn't otherwise available; the Timeline
        // tab still shows every red card individually via `key_events`.
        func side(_ block: MLSValue, teamID: String, goalsKey: String) -> SoccerTeamMatchState {
            SoccerTeamMatchState(team: team(from: block, teamID: teamID), score: info[goalsKey].int, halfTimeScore: nil, redCards: 0)
        }
        var match = SoccerMatch(id: matchID, competitionID: competitionID, season: info["season"].int.map(String.init) ?? seasonID,
            matchWeek: info["match_day"].int, phase: info["match_type"].string, kickoff: kickoff, status: status,
            clock: MLSClockMapper.clock(status: status, minuteOfPlay: info["minute_of_play"].string),
            home: side(home, teamID: homeID, goalsKey: "home_team_goals"), away: side(away, teamID: awayID, goalsKey: "away_team_goals"),
            ground: raw["environment"]["stadium_name"].string, attendance: nil, resultType: nil)
        match.conference = info["sub_league"].string
        match.competitionName = info["competition_name"].string
        match.dataStatus = info["data_status"].string
        return match
    }

    /// `team_id`/`team_name`/`team_short_name`/`team_three_letter_code` appear on
    /// match overview's `home`/`away` blocks; the standalone club list and standings
    /// use the `club_`/`team_` variants respectively — this reads whichever is present.
    private static func team(from block: MLSValue, teamID: String) -> SoccerTeam {
        let name = block["team_name"].string ?? block["club_name"].string ?? teamID
        let short = block["team_short_name"].string ?? block["club_short_name"].string ?? name
        let abbr = block["team_three_letter_code"].string ?? block["club_three_letter_code"].string ?? block["three_letter_code"].string ?? short
        return SoccerTeam(id: teamID, name: name, shortName: short, abbreviation: abbr)
    }

    static func club(_ raw: MLSValue) -> SoccerTeam? {
        guard let id = raw["club_id"].string else { return nil }
        return SoccerTeam(id: id, name: raw["club_name"].string ?? id, shortName: raw["club_short_name"].string ?? raw["short_name"].string ?? id,
            abbreviation: raw["club_three_letter_code"].string ?? raw["three_letter_code"].string ?? id)
    }

    /// Builds a `person_id -> team_id` map from a match overview's `home`/`away`
    /// player lists — needed because `key_events`' `shot_at_goals` bucket carries no
    /// `team_id` of its own (a genuine MLS API gap, confirmed live), unlike every
    /// other event type.
    static func playerTeamMap(fromOverview raw: MLSValue) -> [String: String] {
        var map: [String: String] = [:]
        for side in ["home", "away"] {
            guard let teamID = raw[side]["team_id"].string else { continue }
            for player in raw[side]["players"].array {
                if let personID = player["person_id"].string { map[personID] = teamID }
            }
        }
        return map
    }

    static func playerReference(_ raw: MLSValue, idKey: String = "person_id", firstKey: String = "first_name", lastKey: String = "last_name") -> SoccerPlayerReference? {
        guard let id = raw[idKey].string else { return nil }
        return SoccerPlayerReference(id: id, firstName: raw[firstKey].string, lastName: raw[lastKey].string)
    }
}
