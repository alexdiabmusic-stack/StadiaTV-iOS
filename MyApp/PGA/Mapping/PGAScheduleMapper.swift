import Foundation

/// Maps `GET schedule/{tour}/{year}` (REST, uncompressed JSON).
nonisolated enum PGAScheduleMapper {
    static func season(_ value: PGAValue, tour: String, year: Int) -> GolfSeasonSchedule {
        let tournaments = value["tournaments"].array.map(entry)
        return GolfSeasonSchedule(tour: tour, year: year, tournaments: tournaments)
    }

    private static func entry(_ value: PGAValue) -> GolfScheduleEntry {
        let courseData = value["courseData"]
        let champion = value["champions"].array.first
        return GolfScheduleEntry(
            tournamentID: GolfTournamentID(rawValue: value["tournamentId"].string ?? ""),
            name: value["name"].string ?? "",
            year: Int(value["year"].string ?? "") ?? value["year"].int,
            month: value["month"].string,
            displayDate: value["displayDate"].string,
            statusRaw: value["status"].string,
            purseDisplay: value["purse"].string,
            fedExCupPointsDisplay: value["standings"]["value"].string,
            championDisplayName: champion?["displayName"].string,
            championEarningsDisplay: value["championEarnings"].string,
            courseName: courseData["name"].string,
            city: courseData["city"].string,
            state: courseData["stateCode"].string,
            country: courseData["country"].string,
            tournamentSiteURL: (value["tournamentSiteUrl"].string).flatMap(URL.init(string:))
        )
    }
}
