import Foundation

nonisolated enum MLBPlayMapper {
    static func plays(_ response: MLBPlayByPlayResponse, gamePk: Int, players: [Int: BaseballPlayerReference]) -> [BaseballAtBat] {
        var rows: [Int: BaseballAtBat] = [:]
        let scoring = Set(response.raw["scoringPlays"].array.compactMap(\.int))
        for raw in response.plays + [response.currentPlay] {
            guard let index = raw["about"]["atBatIndex"].int else { continue }
            let about = raw["about"], result = raw["result"], matchup = raw["matchup"]
            let batter = MLBGameMapper.player(matchup["batter"], lookup: players)
            let events = raw["playEvents"].array.enumerated().map { offset, event in
                eventModel(event, id: "\(gamePk):\(index):\(event["index"].int ?? offset)", index: event["index"].int ?? offset)
            }
            let runners = raw["runners"].array.enumerated().map { offset, runner in
                let movement = runner["movement"], details = runner["details"]
                return BaseballRunnerMovement(id: "\(gamePk):\(index):runner:\(offset)", runner: MLBGameMapper.player(details["runner"], lookup: players), start: movement["start"].string,
                    end: movement["end"].string, isOut: movement["isOut"].bool ?? false, outBase: movement["outBase"].string,
                    responsiblePitcher: MLBGameMapper.player(details["responsiblePitcher"], lookup: players), reason: details["movementReason"].string.map(MLBPlayDescriptionBuilder.humanize), earned: details["earned"].bool,
                    scored: details["isScoringEvent"].bool ?? (movement["end"].string == "score"))
            }
            let row = BaseballAtBat(gamePk: gamePk, atBatIndex: index, inning: about["inning"].int ?? 0,
                halfInning: BaseballHalfInning(rawValue: about["halfInning"].string ?? "") ?? .unknown,
                batter: batter, pitcher: MLBGameMapper.player(matchup["pitcher"], lookup: players),
                resultType: BaseballResultType(result["eventType"].string ?? ""), resultTitle: MLBPlayDescriptionBuilder.title(result), resultDescription: MLBPlayDescriptionBuilder.description(result, batter: batter),
                rbi: result["rbi"].int, awayScore: result["awayScore"].int, homeScore: result["homeScore"].int,
                isComplete: about["isComplete"].bool ?? false, isScoringPlay: about["isScoringPlay"].bool ?? scoring.contains(index),
                events: Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.index < $1.index }, runners: runners,
                finalCount: MLBGameMapper.count(raw["count"]), endTime: MLBDate.parse(about["endTime"].string))
            if let previous = rows[index], previous.isComplete && !row.isComplete { continue }
            rows[index] = row
        }
        return rows.values.sorted { $0.atBatIndex < $1.atBatIndex }
    }
    static func eventModel(_ raw: MLBValue, id: String, index: Int) -> BaseballPlayEvent {
        let details = raw["details"], pitch = raw["pitchData"], coordinates = pitch["coordinates"]
        var location: BaseballPitchCoordinates?
        if let x = coordinates["pX"].double, let z = coordinates["pZ"].double, let top = pitch["strikeZoneTop"].double, let bottom = pitch["strikeZoneBottom"].double, top > bottom, abs(x) < 10, z > -5, z < 15 {
            location = BaseballPitchCoordinates(plateX: x, plateZ: z, zoneTop: top, zoneBottom: bottom)
        }
        return BaseballPlayEvent(id: id, index: index, type: raw["type"].string ?? "unknown", resultType: BaseballResultType(details["eventType"].string ?? ""), isPitch: raw["isPitch"].bool ?? false,
            pitchNumber: raw["pitchNumber"].int, description: details["description"].string ?? MLBPlayDescriptionBuilder.title(details),
            pitchTypeCode: details["type"]["code"].string, pitchTypeDescription: details["type"]["description"].string,
            callCode: details["call"]["code"].string, callDescription: details["call"]["description"].string,
            startSpeed: pitch["startSpeed"].double, endSpeed: pitch["endSpeed"].double, zone: pitch["zone"].int,
            spinRate: pitch["breaks"]["spinRate"].double, spinDirection: pitch["breaks"]["spinDirection"].double, count: MLBGameMapper.count(raw["count"]),
            isBall: details["isBall"].bool ?? false, isStrike: details["isStrike"].bool ?? false, isInPlay: details["isInPlay"].bool ?? false, coordinates: location,
            hitDistance: raw["hitData"]["totalDistance"].double, exitVelocity: raw["hitData"]["launchSpeed"].double)
    }
}
