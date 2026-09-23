import Foundation

/// Builds `BasketballGame` from any of the three sources that share the same
/// `homeTeam`/`awayTeam`/`gameStatus` field vocabulary: the CDN scoreboard's
/// per-game entries, the CDN box score's `game` envelope, and ScheduleLeagueV2's
/// per-game entries. One mapper, three raw shapes, one canonical output.
nonisolated enum NBAGameMapper {
    static func team(_ raw: NBAValue) -> BasketballTeam? {
        guard let id = raw["teamId"].int else { return nil }
        return BasketballTeam(id: id, city: raw["teamCity"].string ?? "", name: raw["teamName"].string ?? "",
            tricode: raw["teamTricode"].string ?? "", slug: raw["teamSlug"].string,
            wins: raw["wins"].int, losses: raw["losses"].int, score: raw["score"].int,
            timeoutsRemaining: raw["timeoutsRemaining"].int, inBonus: raw["inBonus"].bool,
            periods: quarterScores(raw["periods"]), seed: raw["seed"].int)
    }
    static func quarterScores(_ raw: NBAValue) -> [NBAQuarterScore] {
        raw.array.compactMap { row in
            guard let period = row["period"].int, let score = row["score"].int else { return nil }
            return NBAQuarterScore(period: period, periodType: row["periodType"].string, score: score)
        }
    }
    static func officials(_ raw: NBAValue) -> [NBAOfficial] {
        raw.array.compactMap { row in
            guard let id = row["personId"].int else { return nil }
            return NBAOfficial(id: id, name: row["name"].string ?? "\(row["firstName"].string ?? "") \(row["familyName"].string ?? "")",
                jerseyNum: row["jerseyNum"].string, assignment: row["assignment"].string)
        }
    }
    static func arena(_ raw: NBAValue) -> NBAArena? {
        let result = NBAArena(name: raw["arenaName"].string, city: raw["arenaCity"].string, state: raw["arenaState"].string,
            country: raw["arenaCountry"].string, timezone: raw["arenaTimezone"].string)
        return result.isEmpty ? nil : result
    }
    static func gameLeader(_ raw: NBAValue) -> NBAGameLeaderLine? {
        guard raw != .null, raw["personId"].int != nil else { return nil }
        return NBAGameLeaderLine(personID: raw["personId"].int, name: raw["name"].string, teamTricode: raw["teamTricode"].string,
            points: raw["points"].int, rebounds: raw["rebounds"].int, assists: raw["assists"].int)
    }
    static func broadcasts(_ raw: NBAValue) -> [String] {
        let groups = ["nationalBroadcasters", "nationalOttBroadcasters", "homeTvBroadcasters", "awayTvBroadcasters"]
        let names = groups.flatMap { raw[$0].array.compactMap { $0["broadcasterDisplay"].string } }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func game(_ raw: NBAValue) -> BasketballGame? {
        guard let idString = raw["gameId"].string, let id = NBAProviderGameID(idString),
              let home = team(raw["homeTeam"]), let away = team(raw["awayTeam"]) else { return nil }
        let start = NBASeason.parse(raw["gameTimeUTC"].string) ?? NBASeason.parse(raw["gameDateTimeUTC"].string) ?? NBASeason.parse(raw["gameDateUTC"].string) ?? Date.distantFuture
        return BasketballGame(id: id, gameCode: raw["gameCode"].string, start: start, away: away, home: home,
            status: NBAStatusMapper.status(raw), rawStatus: raw["gameStatus"].int, statusText: raw["gameStatusText"].string ?? "",
            period: raw["period"].int ?? 0, regulationPeriods: raw["regulationPeriods"].int ?? 4,
            gameClock: NBADuration.seconds(raw["gameClock"].string),
            arena: arena(raw["arena"]), attendance: raw["attendance"].int, officials: officials(raw["officials"]),
            seriesGameNumber: nonEmpty(raw["seriesGameNumber"].string), seriesText: nonEmpty(raw["seriesText"].string),
            gameLabel: nonEmpty(raw["gameLabel"].string), gameSubLabel: nonEmpty(raw["gameSubLabel"].string),
            gameSubtype: nonEmpty(raw["gameSubtype"].string),
            homeLeader: gameLeader(raw["gameLeaders"]["homeLeaders"]), awayLeader: gameLeader(raw["gameLeaders"]["awayLeaders"]),
            broadcasts: broadcasts(raw))
    }
    static func scoreboard(_ response: NBAScoreboardResponse) -> [BasketballGame] { response.games.compactMap(game) }
    static func scoreboardV3(_ response: NBAScoreboardV3Response) -> [BasketballGame] { response.games.compactMap(game) }
    static func schedule(_ response: NBAScheduleResponse) -> [BasketballGame] { response.games.compactMap(game) }
    static func boxScore(_ response: NBABoxScoreResponse) -> BasketballGame? { game(response.game) }
    /// `NBAAPIClient.scoreboard(on:)` returns raw per-game values directly (no single
    /// DTO spans its three possible sources), so this is the entry point for those.
    static func games(_ values: [NBAValue]) -> [BasketballGame] { values.compactMap(game) }
}
