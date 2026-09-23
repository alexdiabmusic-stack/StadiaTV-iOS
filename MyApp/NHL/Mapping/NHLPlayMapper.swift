import Foundation
import OSLog

nonisolated enum NHLPlayMapper {
    static func roster(_ spots: [NHLRosterSpot]) -> [Int: HockeyPlayerReference] {
        // Duplicate roster records must not trap Dictionary(uniqueKeysWithValues:).
        Dictionary(spots.map { spot in
            let name = [spot.firstName.value, spot.lastName.value].filter { !$0.isEmpty }.joined(separator: " ")
            return (spot.playerID, HockeyPlayerReference(id: spot.playerID, name: name.isEmpty ? "Unknown player" : name, teamID: spot.teamID, jersey: spot.sweaterNumber, position: spot.positionCode, headshot: NHLGameMapper.webURL(spot.headshot)))
        }, uniquingKeysWith: { _, newest in newest })
    }
    static func scoringSummary(_ landing: NHLGameDTO) -> [HockeyPlayEvent] {
        guard let gameID = landing.id else { return [] }
        var output: [HockeyPlayEvent] = []
        for group in landing.raw["summary"]["scoring"].array {
            let period = HockeyPeriod(raw: group["periodDescriptor"])
            for goal in group["goals"].array {
                func player(_ value: NHLValue) -> HockeyPlayerReference? {
                    guard let id = value["playerId"].int else { return nil }
                    let name = [value["firstName"].localized, value["lastName"].localized].compactMap { $0 }.joined(separator: " ")
                    return HockeyPlayerReference(id: id, name: name.isEmpty ? value["name"].localized ?? "Unknown player" : name,
                        teamID: nil, jersey: value["sweaterNumber"].int, position: nil,
                        headshot: NHLGameMapper.webURL(value["headshot"].string))
                }
                let scorer = player(goal)
                let assists = goal["assists"].array.compactMap(player)
                let team = [landing.awayTeam, landing.homeTeam].first { $0.abbreviation == goal["teamAbbrev"].localized }
                let strength = ["pp":"Power-play goal", "sh":"Short-handed goal", "ev":"Even-strength goal"][goal["strength"].string ?? ""]
                let text = HockeyPlayDescriptionBuilder.describe(type: .goal, primary: scorer?.name ?? "Unknown player",
                    secondary: nil, tertiary: nil, assists: assists.map(\.name), details: goal, period: period, strength: strength)
                let eventID = goal["eventId"].int
                output.append(HockeyPlayEvent(id: "\(gameID):summary:\(eventID.map(String.init) ?? String(output.count))",
                    nhlEventID: eventID, sortOrder: output.count, period: period, timeInPeriod: goal["timeInPeriod"].string,
                    timeRemaining: nil, eventType: .goal, teamID: team?.id, title: text.0, subtitle: text.1,
                    xCoordinate: nil, yCoordinate: nil, homeTeamDefendingSide: goal["homeTeamDefendingSide"].string,
                    homeScore: goal["homeScore"].int, awayScore: goal["awayScore"].int, homeShots: nil, awayShots: nil,
                    primaryPlayer: scorer, secondaryPlayer: assists.first, tertiaryPlayer: assists.dropFirst().first,
                    assists: assists, shotType: goal["shotType"].string.map(HockeyPlayDescriptionBuilder.humanize),
                    strength: strength, videoURL: NHLGameMapper.webURL(goal["highlightClipSharingUrl"].string),
                    rawSituationCode: goal["situationCode"].string, shootoutRound: nil, scorerSeasonGoals: goal["goalsToDate"].int))
            }
        }
        return output
    }
    static func events(_ response: NHLPlayByPlayResponse, landing: NHLGameDTO?) -> [HockeyPlayEvent] {
        let roster = roster(response.rosterSpots)
        let goals = landing?.raw["summary"]["scoring"].array.flatMap { $0["goals"].array } ?? []
        let goalsByID = Dictionary(goals.compactMap { goal in goal["eventId"].int.map { ($0, goal) } }, uniquingKeysWith: { _, latest in latest })
        func resolve(_ id: Int?) -> HockeyPlayerReference? {
            guard let id else { return nil }
            if let player = roster[id] { return player }
            #if DEBUG
            Logger(subsystem: "BannerTV", category: "NHL").debug("Unresolved NHL player \(id)")
            #endif
            return HockeyPlayerReference(id: id, name: "Unknown player", teamID: nil, jersey: nil, position: nil, headshot: nil)
        }
        func richPlayer(_ raw: NHLValue) -> HockeyPlayerReference? {
            guard let id = raw["playerId"].int else { return nil }
            let existing = roster[id]
            let fullName = [raw["firstName"].localized, raw["lastName"].localized].compactMap { $0 }.joined(separator: " ")
            return HockeyPlayerReference(id: id, name: fullName.isEmpty ? existing?.name ?? raw["name"].localized ?? "Unknown player" : fullName,
                                         teamID: existing?.teamID, jersey: existing?.jersey ?? raw["sweaterNumber"].int,
                                         position: existing?.position, headshot: NHLGameMapper.webURL(raw["headshot"].string) ?? existing?.headshot)
        }
        var attempts: [Int: Int] = [:]
        var mapped: [String: HockeyPlayEvent] = [:]
        var seen: Set<String> = []
        let ordered = response.plays.enumerated().filter { index, play in
            seen.insert("\(play.eventID.map(String.init) ?? "missing"):\(play.sortOrder ?? index)").inserted
        }.sorted {
            ($0.element.sortOrder ?? $0.offset) < ($1.element.sortOrder ?? $1.offset)
        }
        for (offset, play) in ordered {
            let raw = play.raw, details = play.details
            let type = HockeyEventType(key: play.typeDescKey, code: play.typeCode)
            let period = HockeyPeriod(raw: raw["periodDescriptor"])
            let goal = play.eventID.flatMap { goalsByID[$0] } ?? .null
            let primaryKey: String
            let secondaryKey: String?
            let tertiaryKey: String?
            switch type {
            case .goal: primaryKey = "scoringPlayerId"; secondaryKey = "assist1PlayerId"; tertiaryKey = "assist2PlayerId"
            case .shot, .missedShot, .failedShot: primaryKey = "shootingPlayerId"; secondaryKey = "goalieInNetId"; tertiaryKey = nil
            case .blockedShot: primaryKey = "shootingPlayerId"; secondaryKey = "blockingPlayerId"; tertiaryKey = nil
            case .hit: primaryKey = "hittingPlayerId"; secondaryKey = "hitteePlayerId"; tertiaryKey = nil
            case .faceoff: primaryKey = "winningPlayerId"; secondaryKey = "losingPlayerId"; tertiaryKey = nil
            case .penalty: primaryKey = "committedByPlayerId"; secondaryKey = "drawnByPlayerId"; tertiaryKey = "servedByPlayerId"
            default: primaryKey = "playerId"; secondaryKey = nil; tertiaryKey = nil
            }
            let primary = type == .goal ? richPlayer(goal) ?? resolve(details[primaryKey].int) : resolve(details[primaryKey].int)
            let secondary = secondaryKey.flatMap { resolve(details[$0].int) }
            let tertiary = tertiaryKey.flatMap { resolve(details[$0].int) }
            let assists = type == .goal ? (goal["assists"] == .null ? [secondary, tertiary].compactMap { $0 } : goal["assists"].array.compactMap(richPlayer)) : []
            let situationCode = raw["situationCode"].string
            var strength: String?
            if type == .goal {
                switch goal["strength"].string {
                case "pp": strength = "Power-play goal"
                case "sh": strength = "Short-handed goal"
                case "ev": strength = "Even-strength goal"
                default: strength = nil
                }
                if ["empty-net", "en"].contains(goal["goalModifier"].string ?? "") { strength = "Empty-net goal" }
                else if let situation = NHLSituationParser(situationCode), let team = details["eventOwnerTeamId"].int {
                    let isHome = team == response.game.homeTeam.id
                    if !(isHome ? situation.awayGoalie : situation.homeGoalie) { strength = "Empty-net goal" }
                    else if strength == nil { strength = situation.label(scoringHome: isHome) }
                }
            }
            let text = HockeyPlayDescriptionBuilder.describe(type: type, primary: primary?.name ?? "Unknown player",
                                                              secondary: secondary?.name, tertiary: tertiary?.name,
                                                              assists: assists.map(\.name), details: details, period: period, strength: strength)
            let teamID = details["eventOwnerTeamId"].int
            var round: Int?
            if period.kind == .shootout, type == .goal || type.isShot, let teamID {
                attempts[teamID, default: 0] += 1
                round = attempts[teamID]
            }
            let order = play.sortOrder ?? offset
            let id = "\(response.game.id ?? 0):\(play.eventID.map(String.init) ?? "missing"):\(order)"
            let totalPairs: [(Int, Int)] = goal["assists"].array.compactMap { assist in
                guard let playerID = assist["playerId"].int, let count = assist["assistsToDate"].int else { return nil }
                return (playerID, count)
            }
            let assistTotals = Dictionary(totalPairs, uniquingKeysWith: { _, latest in latest })
            mapped[id] = HockeyPlayEvent(id: id, nhlEventID: play.eventID, sortOrder: order, period: period,
                                        timeInPeriod: raw["timeInPeriod"].string, timeRemaining: raw["timeRemaining"].string,
                                        eventType: type, teamID: teamID, title: text.0, subtitle: text.1,
                                        xCoordinate: details["xCoord"].double, yCoordinate: details["yCoord"].double,
                                        homeTeamDefendingSide: raw["homeTeamDefendingSide"].string,
                                        homeScore: details["homeScore"].int, awayScore: details["awayScore"].int,
                                        homeShots: details["homeSOG"].int, awayShots: details["awaySOG"].int,
                                        primaryPlayer: primary, secondaryPlayer: secondary, tertiaryPlayer: tertiary, assists: assists,
                                        shotType: details["shotType"].string.map(HockeyPlayDescriptionBuilder.humanize),
                                        strength: strength, videoURL: NHLGameMapper.webURL(goal["highlightClipSharingUrl"].string),
                                        rawSituationCode: situationCode, shootoutRound: round,
                                        scorerSeasonGoals: goal["goalsToDate"].int ?? details["scoringPlayerTotal"].int,
                                        assistSeasonTotals: assistTotals)
        }
        return mapped.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
    }
}
