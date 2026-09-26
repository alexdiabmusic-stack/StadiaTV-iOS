import Foundation

/// Maps both the CDN live play-by-play and the PlayByPlayV3 secondary/rich fallback
/// into the same `NBAPlayEvent`. Actions are merged into a dictionary keyed by a
/// stable identity (never the description text) so re-fetching the same window is
/// idempotent and a replay-review correction *replaces* rather than duplicates
/// (Step 12, Step 72).
nonisolated enum NBAPlayMapper {
    static func events(_ response: NBAPlayByPlayResponse, gameID: BasketballGameID) -> [NBAPlayEvent] {
        merge(response.actions, gameID: gameID)
    }
    static func eventsV3(_ response: NBAPlayByPlayV3Response, gameID: BasketballGameID) -> [NBAPlayEvent] {
        merge(response.actions.map { NBAValue.object($0) }, gameID: gameID)
    }
    private static func merge(_ actions: [NBAValue], gameID: BasketballGameID) -> [NBAPlayEvent] {
        var mapped: [String: NBAPlayEvent] = [:]
        for (index, raw) in actions.enumerated() {
            guard let event = build(raw, gameID: gameID, fallbackIndex: index) else { continue }
            mapped[event.id] = event
        }
        // `NBAPlayEvent.sorted` (not a copy local to this mapper) — the same
        // comparator `BasketballGameCenterReducer` and `WNBAPlayMapper` use, so a
        // merged play list is ordered identically everywhere.
        return NBAPlayEvent.sorted(Array(mapped.values))
    }
    private static func build(_ raw: NBAValue, gameID: BasketballGameID, fallbackIndex: Int) -> NBAPlayEvent? {
        let actionNumber = raw["actionNumber"].int
        let orderNumber = raw["orderNumber"].int ?? actionNumber
        guard actionNumber != nil || orderNumber != nil else { return nil }
        let actionID = raw["actionId"].int
        let period = raw["period"].int ?? 0
        let clockRaw = raw["clock"].string
        let clockText = NBADuration.clockText(clockRaw)
        let actionType = raw["actionType"].string ?? ""
        let subType = raw["subType"].string
        let shotResult = raw["shotResult"].string
        let type = NBAPlayType(actionType: actionType, subType: subType, shotResult: shotResult)
        let teamID = raw["teamId"].int
        let teamTricode = raw["teamTricode"].string
        let personID = raw["personId"].int
        let playerName = raw["playerName"].string ?? raw["playerNameI"].string
        let isFieldGoal = (raw["isFieldGoal"].bool ?? (raw["isFieldGoal"].int == 1))
        let shotDistance = raw["shotDistance"].double
        let xLegacy = raw["xLegacy"].double ?? raw["x"].double
        let yLegacy = raw["yLegacy"].double ?? raw["y"].double
        // The discriminator lives in `actionType` ("2pt"/"3pt"); `subType` is a
        // free-text shot description ("Pullup", "Step Back Jump shot") and must
        // not be consulted first, or a described three gets scored as a two.
        let shotValue = actionType.hasPrefix("3") ? 3 : (subType?.contains("3") == true ? 3 : 2)
        let shot = type.isShot
            ? BasketballCourtCoordinateTransformer.normalize(xLegacy: xLegacy, yLegacy: yLegacy, distanceFeet: shotDistance, made: type == .madeShot, value: shotValue)
            : nil
        let scoreHome = raw["scoreHome"].int
        let scoreAway = raw["scoreAway"].int
        let assistPlayerName = raw["assistPlayerNameInitial"].string ?? raw["assistPlayerName"].string
        let blockPlayerName = raw["blockPlayerName"].string
        let stealPlayerName = raw["stealPlayerName"].string
        let isPeriodBoundary = type == .periodStart || type == .periodEnd
        let (title, subtitle) = BasketballPlayDescriptionBuilder.describe(
            type: type, description: raw["description"].string, playerName: playerName, assistPlayerName: assistPlayerName,
            blockPlayerName: blockPlayerName, stealPlayerName: stealPlayerName, teamTricode: teamTricode,
            shotDistance: shotDistance, period: period, scoreHome: scoreHome, scoreAway: scoreAway)
        let id = "\(gameID.providerID):\(actionID.map(String.init) ?? actionNumber.map(String.init) ?? "i\(fallbackIndex)")"
        return NBAPlayEvent(id: id, gameID: gameID, actionNumber: actionNumber, orderNumber: orderNumber ?? fallbackIndex,
            period: period, clockText: clockText, type: type, teamID: teamID, teamTricode: teamTricode, personID: personID,
            playerName: playerName, title: title, subtitle: subtitle, scoreHome: scoreHome, scoreAway: scoreAway,
            isFieldGoal: isFieldGoal, shot: shot, isPeriodBoundary: isPeriodBoundary,
            priority: BasketballPlayDescriptionBuilder.priority(for: type, subType: subType), assistPlayerName: assistPlayerName,
            videoAvailable: raw["videoAvailable"].bool == true)
    }
}
