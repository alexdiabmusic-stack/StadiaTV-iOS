import Foundation

/// Maps `TourCupSplit` (FedExCup / tour-equivalent points race). Only rows
/// typed `TourCupCombinedPlayer` are real standings — `TourCupCombinedInfo`
/// rows are supplementary text/info rows the provider mixes into the same
/// list and must be filtered out rather than mis-mapped into a standing.
nonisolated enum PGAFedExMapper {
    static func standings(_ value: PGAValue) -> [GolfCupStanding] {
        var players = value["projectedPlayers"].array.filter { $0["__typename"].string == "TourCupCombinedPlayer" }
        if players.isEmpty {
            players = value["officialPlayers"].array.filter { $0["__typename"].string == "TourCupCombinedPlayer" }
        }
        return players.map(standing)
    }

    private static func standing(_ value: PGAValue) -> GolfCupStanding {
        let ranking = value["rankingData"]
        let points = value["pointData"]
        return GolfCupStanding(
            playerID: value["id"].string ?? UUID().uuidString,
            displayName: value["displayName"].string ?? [value["firstName"].string, value["lastName"].string].compactMap { $0 }.joined(separator: " "),
            country: value["country"].string,
            officialRankDisplay: ranking["official"].string,
            projectedRankDisplay: ranking["projected"].string,
            officialPointsDisplay: points["official"].string,
            projectedPointsDisplay: points["projected"].string,
            movementRaw: ranking["movement"].string,
            movementAmountDisplay: ranking["movementAmount"].string
        )
    }
}
