import Foundation

nonisolated enum MLBGameCenterReducer {
    static func apply(_ update: MLBGameCenterUpdate, to old: BaseballGameSnapshot) -> BaseballGameSnapshot {
        guard update.gamePk == old.gamePk, update.requestedAt >= old.fetchedAt else { return old }
        if let feed = update.feed, feed.gamePk != old.gamePk { return old }
        if let status = update.status, status.gamePk != old.gamePk { return old }
        let timestamp = (update.feed ?? update.status)?.raw["metaData"]["timeStamp"].string
        if let timestamp, let previous = old.timestamp, timestamp < previous { return old }
        var result = old
        let feed = update.feed
        if let feed { result.players.merge(MLBGameMapper.players(feed.data["players"]), uniquingKeysWith: { _, new in new }) }
        let playsRaw = update.plays ?? feed.map { MLBPlayByPlayResponse(raw: $0.live["plays"]) }
        if let playsRaw {
            let plays = MLBPlayMapper.plays(playsRaw, gamePk: old.gamePk, players: result.players)
            if let previous = old.atBats.last, let newest = plays.last {
                if newest.atBatIndex < previous.atBatIndex { return old }
                if newest.atBatIndex == previous.atBatIndex {
                    if previous.isComplete && !newest.isComplete { return old }
                    if newest.events.count < previous.events.count { return old }
                    if let oldTime = previous.endTime, let newTime = newest.endTime, newTime < oldTime { return old }
                }
            } else if !old.atBats.isEmpty, plays.isEmpty { return old }
            result.atBats = plays; result.playsLoaded = true
        }
        if let game = feed.flatMap(MLBGameMapper.feed) {
            if old.game?.status == .final && game.status != .final { return old }
            var merged = game
            merged.broadcasts = game.broadcasts.isEmpty ? old.game?.broadcasts ?? [] : game.broadcasts
            merged.seriesDescription = game.seriesDescription ?? old.game?.seriesDescription
            result.game = merged
        } else if let status = update.status, var game = result.game {
            let mapped = MLBStatusMapper.status(status.data["status"])
            if game.status == .final && mapped != .final { return old }
            game.status = mapped; game.detailedStatus = status.data["status"]["detailedState"].string ?? game.detailedStatus
            result.game = game
        }
        if let raw = update.line?.raw ?? feed?.live["linescore"], let line = MLBGameMapper.line(raw, players: result.players) {
            if let oldInning = old.line?.currentInning, let inning = line.currentInning, inning < oldInning { return old }
            if line.currentInning == old.line?.currentInning, old.line?.inningState?.lowercased() == "bottom", line.inningState?.lowercased() == "top" { return old }
            result.line = line
            if let runs = line.awayRuns { result.game?.away.runs = runs }
            if let runs = line.homeRuns { result.game?.home.runs = runs }
        }
        if let raw = update.box?.raw ?? feed?.live["boxscore"] {
            let mapped = MLBBoxscoreMapper.players(raw)
            if let game = result.game, mapped.contains(where: { $0.teamID != game.away.id && $0.teamID != game.home.id }) { return old }
            result.box = mapped; result.boxLoaded = true
        }
        if let content = update.content {
            result.highlights = content.raw["highlights"]["highlights"]["items"].array.compactMap { item in
                guard let id = item["id"].string ?? item["guid"].string,
                      let value = item["playbacks"].array.first(where: { $0["url"].string?.contains(".mp4") == true })?["url"].string,
                      let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
                return BaseballHighlight(id: id, title: item["headline"].string ?? item["title"].string ?? "Watch highlight", url: url)
            }
        }
        if let probability = update.probability {
            result.probabilities = probability.raw.array.compactMap { row in
                guard let index = row["about"]["atBatIndex"].int, let percent = row["homeTeamWinProbability"].double, (0...100).contains(percent) else { return nil }
                return BaseballWinProbability(atBatIndex: index, homePercent: percent)
            }
        }
        let accepted = update.feed != nil || update.status != nil || update.line != nil || update.plays != nil || update.box != nil
        if accepted { result.fetchedAt = update.requestedAt; result.timestamp = timestamp ?? old.timestamp }
        return result
    }
}
