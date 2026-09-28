import Foundation

/// Maps the decompressed `TeeTimesCompressedV2` payload.
nonisolated enum PGATeeTimesMapper {
    static func teeTimes(_ value: PGAValue, tournamentID: String) -> GolfTeeTimes {
        let rounds = value["rounds"].array.map(round)
        return GolfTeeTimes(tournamentID: tournamentID, timezoneIdentifier: value["timezone"].string, rounds: rounds)
    }

    private static func round(_ value: PGAValue) -> GolfTeeTimesRound {
        let roundNumber = value["roundInt"].int ?? 0
        let groups = value["groups"].array.map { group(roundNumber: roundNumber, value: $0) }
        return GolfTeeTimesRound(
            roundNumber: roundNumber,
            roundDisplay: value["roundDisplay"].string,
            roundStatusRaw: value["roundStatus"].string,
            groups: groups
        )
    }

    private static func group(roundNumber: Int, value: PGAValue) -> GolfTeeGroup {
        let players = value["players"].array.map { player -> GolfTeeGroupPlayer in
            GolfTeeGroupPlayer(
                id: player["id"].string ?? UUID().uuidString,
                firstName: player["firstName"].string,
                lastName: player["lastName"].string,
                displayName: player["displayName"].string,
                country: player["country"].string
            )
        }
        return GolfTeeGroup(
            roundNumber: roundNumber,
            groupNumber: value["groupNumber"].int ?? 0,
            teeTime: PGAMappingSupport.epochMillis(value["teeTime"]),
            startingTee: value["startTee"].int,
            backNine: value["backNine"].bool ?? false,
            players: players
        )
    }
}
