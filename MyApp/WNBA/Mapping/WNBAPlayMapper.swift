import Foundation

/// Maps the WNBA live CDN play stream into `NBAPlayEvent` (Step 12) — mirrors
/// `NBAPlayMapper` field-for-field, since the WNBA CDN is documented to share the
/// same action vocabulary (Step 13 keeps this a separate DTO-consuming mapper,
/// even though the canonical output and the classification logic it calls into
/// are fully shared, in case the schemas diverge later). Actions are merged into
/// a dictionary keyed by stable identity (`actionNumber`/`orderNumber`/`actionId`,
/// never the description text — Step 14), so re-fetching the same window is
/// idempotent and a correction *replaces* rather than duplicates.
nonisolated enum WNBAPlayMapper {
    static func events(_ response: WNBAPlayByPlayResponse, gameID: BasketballGameID) -> [NBAPlayEvent] {
        merge(response.actions, gameID: gameID)
    }
    private static func merge(_ actions: [WNBAValue], gameID: BasketballGameID) -> [NBAPlayEvent] {
        var mapped: [String: NBAPlayEvent] = [:]
        for (index, raw) in actions.enumerated() {
            guard let event = build(raw, gameID: gameID, fallbackIndex: index) else { continue }
            mapped[event.id] = event
        }
        // `NBAPlayEvent.sorted` — the same shared comparator `NBAPlayMapper` and
        // `BasketballGameCenterReducer` use (lives on the canonical domain type
        // itself, not in either league's DTO-consuming mapper, so no cross-league
        // dependency is needed to reuse it).
        return NBAPlayEvent.sorted(Array(mapped.values))
    }
    private static func build(_ raw: WNBAValue, gameID: BasketballGameID, fallbackIndex: Int) -> NBAPlayEvent? {
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
        // free-text shot description and must not be consulted first.
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
