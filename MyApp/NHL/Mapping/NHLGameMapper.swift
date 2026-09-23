import Foundation

nonisolated enum NHLGameMapper {
    static func game(_ dto: NHLGameDTO) -> HockeyGame? {
        guard let id = dto.id, let start = NHLDate.parse(dto.startTimeUTC),
              let home = team(dto.homeTeam), let away = team(dto.awayTeam) else { return nil }
        let state: BannerGameStatus
        switch dto.gameScheduleState {
        case "PPD": state = .postponed
        case "CNCL": state = .cancelled
        default:
            switch dto.gameState {
            case "LIVE", "CRIT": state = .live
            case "OFF", "FINAL": state = .final
            case "FUT": state = .scheduled
            case "PRE": state = .pregame
            case "SUSP": state = .suspended
            default: state = .unknown
            }
        }
        return HockeyGame(id: id, start: start, status: state, period: dto.period,
                          clock: dto.clock.timeRemaining, secondsRemaining: dto.clock.secondsRemaining,
                          clockRunning: dto.clock.running, intermission: dto.clock.inIntermission,
                          home: home, away: away,
                          broadcasts: dto.raw["tvBroadcasts"].array.compactMap { $0["network"].string },
                          venue: dto.raw["venue"].localized,
                          gameCenterURL: webURL(dto.raw["gameCenterLink"].string, allowNHLPath: true))
    }
    static func team(_ dto: NHLTeamDTO) -> HockeyTeam? {
        guard let id = dto.id else { return nil }
        // The app bundles NHL logo assets; native AsyncImage cannot decode NHL's SVGs.
        let logo = URL(string: "banner-asset:/NHLLogo_\(dto.abbreviation)")
        return HockeyTeam(id: id, abbreviation: dto.abbreviation, name: dto.name,
                          logo: logo ?? webURL(dto.raw["logo"].string), score: dto.score, shots: dto.shots)
    }
    static func webURL(_ string: String?, allowNHLPath: Bool = false) -> URL? {
        guard var string, !string.isEmpty else { return nil }
        if allowNHLPath, string.hasPrefix("/") { string = "https://www.nhl.com" + string }
        guard let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    static func players(_ box: NHLBoxscoreResponse, roster: [Int: HockeyPlayerReference]) -> [HockeyPlayerGameStats] {
        var output: [HockeyPlayerGameStats] = []
        for (side, team) in [("awayTeam", box.game.awayTeam), ("homeTeam", box.game.homeTeam)] {
            guard let teamID = team.id else { continue }
            for (key, label) in [("forwards", "Forwards"), ("defense", "Defensemen"), ("goalies", "Goalies")] {
                for row in box.players[side][key].array {
                    guard let id = row["playerId"].int else { continue }
                    let player = roster[id] ?? HockeyPlayerReference(id: id, name: row["name"].localized ?? "Unknown player", teamID: teamID, jersey: row["sweaterNumber"].int, position: row["position"].string, headshot: nil)
                    let fields = [("goals","G"),("assists","A"),("points","PTS"),("plusMinus","+/−"),("pim","PIM"),("sog","SOG"),("hits","Hits"),("blockedShots","Blocks"),("powerPlayGoals","PPG"),("faceoffWinningPctg","FO%"),("toi","TOI"),("shifts","Shifts"),("giveaways","Giveaways"),("takeaways","Takeaways"),("saves","Saves"),("shotsAgainst","SA"),("goalsAgainst","GA"),("savePctg","SV%"),("saveShotsAgainst","SV/SA"),("evenStrengthShotsAgainst","EV SA"),("powerPlayShotsAgainst","PP SA"),("shorthandedShotsAgainst","SH SA")]
                    let stats = fields.compactMap { key, label -> HockeyStat? in
                        guard let value = row[key].string else { return nil }
                        return HockeyStat(id: key, label: label, value: value)
                    }
                    output.append(HockeyPlayerGameStats(id: id, teamID: teamID, group: label, player: player, stats: stats))
                }
            }
        }
        return output
    }
    static func teamStats(game: HockeyGame?, landing: NHLGameDTO?, players: [HockeyPlayerGameStats], rightRail: NHLValue? = nil) -> [HockeyTeamComparison] {
        let rows = rightRail?["teamGameStats"].array ?? landing?.raw["summary"]["teamGameStats"].array ?? []
        var output = rows.compactMap { row -> HockeyTeamComparison? in
            guard let key = row["category"].string, let away = row["awayValue"].string, let home = row["homeValue"].string else { return nil }
            let names = ["sog":"Shots on goal", "faceoffWinningPctg":"Faceoff %", "faceoffWins":"Faceoffs won", "powerPlay":"Power plays", "powerPlayPctg":"Power-play %", "pim":"Penalty minutes", "blockedShots":"Blocked shots"]
            let isPercentage = key.hasSuffix("Pctg")
            let a = isPercentage ? row["awayValue"].double.map { String(format: "%.1f%%", $0 * 100) } ?? away : away
            let h = isPercentage ? row["homeValue"].double.map { String(format: "%.1f%%", $0 * 100) } ?? home : home
            return HockeyTeamComparison(id: key, label: names[key] ?? HockeyPlayDescriptionBuilder.humanize(key), away: a, home: h)
        }
        guard let game else { return output }
        if let a = game.away.shots, let h = game.home.shots {
            output.removeAll { $0.id == "sog" }
            output.insert(HockeyTeamComparison(id: "sog", label: "Shots on goal", away: String(a), home: String(h)), at: 0)
        }
        for (key, label) in [("hits","Hits"),("blockedShots","Blocked shots"),("pim","Penalty minutes"),("giveaways","Giveaways"),("takeaways","Takeaways")] where !output.contains(where: { $0.id == key }) {
            func sum(_ id: Int) -> String? {
                let values = players.filter { $0.teamID == id }.compactMap { $0.stats.first { $0.id == key }?.value }.compactMap(Int.init)
                return values.isEmpty ? nil : String(values.reduce(0,+))
            }
            if let a = sum(game.away.id), let h = sum(game.home.id) { output.append(HockeyTeamComparison(id: key, label: label, away: a, home: h)) }
        }
        return output
    }
}
