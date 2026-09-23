import Foundation

nonisolated enum MLBGameMapper {
    static func player(_ raw: MLBValue, lookup: [Int: BaseballPlayerReference] = [:]) -> BaseballPlayerReference? {
        guard let id = raw["id"].int else { return nil }
        return BaseballPlayerReference(id: id, name: raw["fullName"].string ?? lookup[id]?.name ?? "Unknown player",
                                       position: raw["primaryPosition"]["abbreviation"].string ?? lookup[id]?.position,
                                       jersey: raw["primaryNumber"].string ?? lookup[id]?.jersey)
    }
    static func players(_ raw: MLBValue) -> [Int: BaseballPlayerReference] {
        Dictionary(raw.object.values.compactMap { player($0) }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }
    static func team(_ raw: MLBValue, runs: Int? = nil, record: MLBValue = .null) -> BaseballTeam? {
        guard let id = raw["id"].int else { return nil }
        let record = record == .null ? raw["record"]["leagueRecord"] : record
        return BaseballTeam(id: id, name: raw["name"].string ?? "Team", abbreviation: raw["abbreviation"].string ?? raw["teamName"].string ?? raw["name"].string ?? "MLB", runs: runs,
                            record: record["wins"].string.flatMap { wins in record["losses"].string.map { "\(wins)-\($0)" } })
    }
    static func schedule(_ raw: MLBValue) -> BaseballGame? {
        guard let id = raw["gamePk"].int, let start = MLBDate.parse(raw["gameDate"].string),
              let away = team(raw["teams"]["away"]["team"], runs: raw["teams"]["away"]["score"].int, record: raw["teams"]["away"]["leagueRecord"]),
              let home = team(raw["teams"]["home"]["team"], runs: raw["teams"]["home"]["score"].int, record: raw["teams"]["home"]["leagueRecord"]) else { return nil }
        return BaseballGame(id: id, start: start, away: away, home: home, status: MLBStatusMapper.status(raw["status"]), detailedStatus: raw["status"]["detailedState"].string ?? "Status unavailable",
            venue: raw["venue"]["name"].string, season: raw["season"].int, gameType: raw["gameType"].string, gameGuid: raw["gameGuid"].string, officialDate: raw["officialDate"].string,
            doubleHeader: raw["doubleHeader"].string, gameNumber: raw["gameNumber"].int, seriesGameNumber: raw["seriesGameNumber"].int, seriesDescription: raw["seriesDescription"].string,
            scheduledInnings: raw["scheduledInnings"].int, probableAway: player(raw["teams"]["away"]["probablePitcher"]), probableHome: player(raw["teams"]["home"]["probablePitcher"]),
            broadcasts: raw["broadcasts"].array.compactMap { $0["name"].string })
    }
    static func feed(_ response: MLBGameFeedResponse) -> BaseballGame? {
        let raw = response.data, line = response.live["linescore"]
        guard let id = response.gamePk, let start = MLBDate.parse(raw["datetime"]["dateTime"].string),
              let away = team(raw["teams"]["away"], runs: line["teams"]["away"]["runs"].int),
              let home = team(raw["teams"]["home"], runs: line["teams"]["home"]["runs"].int) else { return nil }
        return BaseballGame(id: id, start: start, away: away, home: home, status: MLBStatusMapper.status(raw["status"]), detailedStatus: raw["status"]["detailedState"].string ?? "Status unavailable",
            venue: raw["venue"]["name"].string, weather: [raw["weather"]["condition"].string, raw["weather"]["temp"].string.map { "\($0)°F" }, raw["weather"]["wind"].string].compactMap { $0 }.joined(separator: " · "),
            season: raw["game"]["season"].int, gameType: raw["game"]["type"].string, gameGuid: raw["game"]["gameGuid"].string, officialDate: raw["datetime"]["officialDate"].string,
            doubleHeader: raw["game"]["doubleHeader"].string, gameNumber: raw["game"]["gameNumber"].int, scheduledInnings: line["scheduledInnings"].int,
            probableAway: player(raw["probablePitchers"]["away"]), probableHome: player(raw["probablePitchers"]["home"]))
    }
    static func count(_ raw: MLBValue, live: Bool = false) -> BaseballCount {
        func valid(_ key: String, _ max: Int) -> Int? { raw[key].int.flatMap { (0...max).contains($0) ? $0 : nil } }
        return BaseballCount(balls: valid("balls", live ? 3 : 4), strikes: valid("strikes", live ? 2 : 3), outs: valid("outs", 3))
    }
    static func line(_ raw: MLBValue, players: [Int: BaseballPlayerReference]) -> BaseballLineScore? {
        guard raw != .null, !raw.object.isEmpty else { return nil }
        let count = count(raw, live: true)
        let state = raw["inningState"].string
        let clear = count.outs == 3 || ["middle", "end"].contains(state?.lowercased() ?? "")
        let offense = raw["offense"]
        let bases = clear ? BaseballBaseState() : BaseballBaseState(first: player(offense["first"], lookup: players), second: player(offense["second"], lookup: players), third: player(offense["third"], lookup: players))
        return BaseballLineScore(currentInning: raw["currentInning"].int, inningState: state, scheduledInnings: raw["scheduledInnings"].int, count: count, bases: bases,
            batter: player(offense["batter"], lookup: players), pitcher: player(raw["defense"]["pitcher"], lookup: players),
            awayRuns: raw["teams"]["away"]["runs"].int, homeRuns: raw["teams"]["home"]["runs"].int,
            awayHits: raw["teams"]["away"]["hits"].int, homeHits: raw["teams"]["home"]["hits"].int,
            awayErrors: raw["teams"]["away"]["errors"].int, homeErrors: raw["teams"]["home"]["errors"].int,
            innings: raw["innings"].array.compactMap { inning in
                guard let num = inning["num"].int else { return nil }
                return BaseballInningLine(id: num, awayRuns: inning["away"]["runs"].int, homeRuns: inning["home"]["runs"].int)
            })
    }
}
