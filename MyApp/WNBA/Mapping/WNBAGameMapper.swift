import Foundation

/// Builds `BasketballGame` from any of the three sources that share the same
/// `homeTeam`/`awayTeam`/`gameStatus` field vocabulary: the CDN scoreboard's
/// per-game entries, the CDN box score's `game` envelope, and ScheduleLeagueV2's
/// per-game entries (Step 4/8/9) — mirrors `NBAGameMapper` field-for-field, since
/// the WNBA CDN is documented to share NBA's schema exactly.
nonisolated enum WNBAGameMapper {
    static func team(_ raw: WNBAValue) -> BasketballTeam? {
        guard let id = raw["teamId"].int else { return nil }
        return BasketballTeam(id: id, city: raw["teamCity"].string ?? "", name: raw["teamName"].string ?? "",
            tricode: raw["teamTricode"].string ?? "", slug: raw["teamSlug"].string,
            wins: raw["wins"].int, losses: raw["losses"].int, score: raw["score"].int,
            timeoutsRemaining: raw["timeoutsRemaining"].int, inBonus: raw["inBonus"].bool,
            periods: quarterScores(raw["periods"]), seed: raw["seed"].int)
    }
    static func quarterScores(_ raw: WNBAValue) -> [NBAQuarterScore] {
        raw.array.compactMap { row in
            guard let period = row["period"].int, let score = row["score"].int else { return nil }
            return NBAQuarterScore(period: period, periodType: row["periodType"].string, score: score)
        }
    }
    static func officials(_ raw: WNBAValue) -> [NBAOfficial] {
        raw.array.compactMap { row in
            guard let id = row["personId"].int else { return nil }
            return NBAOfficial(id: id, name: row["name"].string ?? "\(row["firstName"].string ?? "") \(row["familyName"].string ?? "")",
                jerseyNum: row["jerseyNum"].string, assignment: row["assignment"].string)
        }
    }
    static func arena(_ raw: WNBAValue) -> NBAArena? {
        let result = NBAArena(name: raw["arenaName"].string, city: raw["arenaCity"].string, state: raw["arenaState"].string,
            country: raw["arenaCountry"].string, timezone: raw["arenaTimezone"].string)
        return result.isEmpty ? nil : result
    }
    static func gameLeader(_ raw: WNBAValue) -> NBAGameLeaderLine? {
        guard raw != .null, raw["personId"].int != nil else { return nil }
        return NBAGameLeaderLine(personID: raw["personId"].int, name: raw["name"].string, teamTricode: raw["teamTricode"].string,
            points: raw["points"].int, rebounds: raw["rebounds"].int, assists: raw["assists"].int)
    }
    static func broadcasts(_ raw: WNBAValue) -> [String] {
        let groups = ["nationalBroadcasters", "nationalOttBroadcasters", "homeTvBroadcasters", "awayTvBroadcasters"]
        let names = groups.flatMap { raw[$0].array.compactMap { $0["broadcasterDisplay"].string } }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func game(_ raw: WNBAValue) -> BasketballGame? {
        guard let idString = raw["gameId"].string, let id = BasketballGameID.validated(idString, league: .wnba),
              let home = team(raw["homeTeam"]), let away = team(raw["awayTeam"]) else { return nil }
        let start = WNBASeason.parse(raw["gameTimeUTC"].string) ?? WNBASeason.parse(raw["gameDateTimeUTC"].string) ?? WNBASeason.parse(raw["gameDateUTC"].string) ?? Date.distantFuture
        return BasketballGame(id: id, gameCode: raw["gameCode"].string, start: start, away: away, home: home,
            status: WNBAStatusMapper.status(raw), rawStatus: raw["gameStatus"].int, statusText: raw["gameStatusText"].string ?? "",
            period: raw["period"].int ?? 0, regulationPeriods: raw["regulationPeriods"].int ?? 4,
            gameClock: NBADuration.seconds(raw["gameClock"].string),
            arena: arena(raw["arena"]), attendance: raw["attendance"].int, officials: officials(raw["officials"]),
            // Playoff series context (Step 22) — mapped straight through when the
            // provider supplies it, never independently computed (Step 22 rule).
            seriesGameNumber: nonEmpty(raw["seriesGameNumber"].string), seriesText: nonEmpty(raw["seriesText"].string),
            gameLabel: nonEmpty(raw["gameLabel"].string), gameSubLabel: nonEmpty(raw["gameSubLabel"].string),
            gameSubtype: nonEmpty(raw["gameSubtype"].string),
            homeLeader: gameLeader(raw["gameLeaders"]["homeLeaders"]), awayLeader: gameLeader(raw["gameLeaders"]["awayLeaders"]),
            broadcasts: broadcasts(raw))
    }
    static func scoreboard(_ response: WNBAScoreboardResponse) -> [BasketballGame] { response.games.compactMap(game) }
    static func schedule(_ response: WNBAScheduleResponse) -> [BasketballGame] { response.games.compactMap(game) }
    static func boxScore(_ response: WNBABoxScoreResponse) -> BasketballGame? { game(response.game) }
    static func games(_ values: [WNBAValue]) -> [BasketballGame] { values.compactMap(game) }
}
