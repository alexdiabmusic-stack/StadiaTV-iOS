import Foundation

nonisolated enum NFLGameMapper {
    static func status(_ raw: String?, quarter: String? = nil) -> NFLGameStatus {
        if ["HALFTIME", "HALF_TIME", "END_OF_HALF"].contains(quarter?.uppercased() ?? ""), !["FINAL", "END_OF_GAME"].contains(raw?.uppercased() ?? "") { return .halftime }
        return switch raw?.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
        case "SCHEDULED": .scheduled
        case "PREGAME", "PRE_GAME": .pregame
        case "IN_PROGRESS", "INGAME", "IN_GAME", "LIVE", "GAME": .live
        case "HALFTIME", "HALF_TIME": .halftime
        case "DELAYED", "SUSPENDED_TEMPORARY": .delayed
        case "SUSPENDED": .suspended
        case "POSTPONED": .postponed
        case "CANCELLED", "CANCELED": .cancelled
        case "FINAL", "FINAL_OVERTIME", "FINAL_OT", "END_OF_GAME": .final
        default: .unknown
        }
    }
    static func image(_ value: String?) -> URL? {
        guard let value else { return nil }
        let path = value.contains("/image/upload/") ? value.replacingOccurrences(of: "{formatInstructions}", with: "f_png,w_192") : value.replacingOccurrences(of: "{formatInstructions}", with: "image/upload/f_png,w_192")
        guard let url = URL(string: path), url.scheme == "https" else { return nil }
        return url
    }
    static func team(_ raw: NFLValue, summary: NFLValue = .null, metadata: NFLValue = .null) -> NFLTeamState? {
        guard let id = raw["id"].string ?? summary["teamId"].string else { return nil }
        let abbreviation = metadata["abbreviation"].string ?? raw["abbreviation"].string ?? raw["currentLogo"].string?.split(separator: "/").last.map(String.init) ?? "NFL"
        return NFLTeamState(id: id, name: raw["fullName"].string ?? metadata["fullName"].string ?? abbreviation, abbreviation: abbreviation,
            logo: image(raw["currentLogo"].string ?? metadata["currentLogo"].string), score: summary["score"]["total"].int,
            quarters: summary["score"].object.compactMapValues(\.int).filter { $0.key != "total" }, possession: summary["hasPossession"].bool == true)
    }
    static func field(_ text: String?, possession: NFLTeamState?, home: NFLTeamState, away: NFLTeamState) -> NFLFieldPosition? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: " ")
        let yard = parts.last.flatMap { Int($0) }.flatMap { (0...50).contains($0) ? $0 : nil }
        let side = parts.count > 1 ? String(parts[0]) : nil
        var toGoal: Int?
        if let yard, let possession {
            if side == possession.abbreviation { toGoal = 100 - yard }
            else if side == home.abbreviation || side == away.abbreviation { toGoal = yard }
            else if side == nil && yard == 50 { toGoal = 50 }
        }
        return NFLFieldPosition(text: text, sideAbbreviation: side, yard: yard, yardsToGoal: toGoal)
    }
    static func game(_ raw: NFLValue, metadata: [String: NFLValue] = [:], players: [String: String] = [:], now: Date = Date()) -> NFLGameState? {
        guard let id = raw["id"].string, let season = raw["season"].int, let week = raw["week"].int,
              let type = raw["seasonType"].string.flatMap(NFLSeasonType.init),
              let start = date(raw["time"].string),
              let home = team(raw["homeTeam"], summary: raw["summary"]["homeTeam"], metadata: metadata[raw["homeTeam"]["id"].string ?? ""] ?? .null),
              let away = team(raw["awayTeam"], summary: raw["summary"]["awayTeam"], metadata: metadata[raw["awayTeam"]["id"].string ?? ""] ?? .null) else { return nil }
        let summary = raw["summary"]
        guard summary["gameId"].string == nil || summary["gameId"].string == id,
              raw["driveChart"]["gameId"].string == nil || raw["driveChart"]["gameId"].string == id else { return nil }
        let phase = summary["phase"].string ?? raw["status"].string ?? "Unknown"
        let drives = NFLPlayMapper.drives(raw["driveChart"]["drives"], gameID: id)
        let plays = NFLPlayMapper.plays(raw["driveChart"]["plays"], gameID: id, drives: drives, players: players)
        return NFLGameState(id: id, week: NFLWeek(season: season, seasonType: type, week: week), start: start,
            home: home, away: away, status: status(phase, quarter: summary["quarter"].string), statusText: phase.replacingOccurrences(of: "_", with: " ").capitalized,
            quarter: summary["quarter"].string, clock: summary["clock"].string, down: summary["down"].int,
            distance: summary["distance"].int, goalToGo: summary["isGoalToGo"].bool, redZone: summary["isRedZone"].bool,
            field: field(summary["yardLine"].string, possession: home.possession ? home : away.possession ? away : nil, home: home, away: away),
            offset: summary["offset"].int, venue: raw["venue"]["name"].string, weather: summary["weather"].string,
            broadcasts: raw["broadcastInfo"]["homeNetworkChannels"].array.compactMap(\.string), drives: drives, plays: plays,
            summaryUpdated: now, detailsUpdated: now)
    }
    static func applySummary(_ raw: NFLValue, to previous: NFLGameState, now: Date = Date()) -> NFLGameState {
        guard raw["gameId"].string == previous.id,
              (raw["offset"].int ?? previous.offset ?? 0) >= (previous.offset ?? 0) else { return previous }
        var game = previous
        for home in [true, false] {
            let value = raw[home ? "homeTeam" : "awayTeam"]
            var side = home ? game.home : game.away
            guard value["teamId"].string == side.id else { continue }
            if let score = value["score"]["total"].int { side.score = score }
            if let possession = value["hasPossession"].bool { side.possession = possession }
            if !value["score"].object.isEmpty { side.quarters = value["score"].object.compactMapValues(\.int).filter { $0.key != "total" } }
            if home { game.home = side } else { game.away = side }
        }
        if let phase = raw["phase"].string { game.status = status(phase, quarter: raw["quarter"].string); game.statusText = phase.replacingOccurrences(of: "_", with: " ").capitalized }
        game.quarter = raw["quarter"].string; game.clock = raw["clock"].string
        game.down = raw["down"].int; game.distance = raw["distance"].int
        game.goalToGo = raw["isGoalToGo"].bool; game.redZone = raw["isRedZone"].bool
        game.field = field(raw["yardLine"].string, possession: game.possession, home: game.home, away: game.away)
        game.offset = raw["offset"].int ?? game.offset; game.summaryUpdated = now
        return game
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: value) { return date }
        f.formatOptions.insert(.withFractionalSeconds); return f.date(from: value)
    }
}
