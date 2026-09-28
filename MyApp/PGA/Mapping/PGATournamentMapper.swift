import Foundation

/// Maps the `Tournaments` GraphQL operation (uncompressed) into `GolfTournament`.
nonisolated enum PGATournamentMapper {
    static func tournaments(_ value: PGAValue) -> [GolfTournament] {
        value["tournaments"].array.map(tournament)
    }

    static func tournament(_ value: PGAValue) -> GolfTournament {
        GolfTournament(
            tournamentID: GolfTournamentID(rawValue: value["id"].string ?? ""),
            name: value["tournamentName"].string ?? "",
            logoURL: (value["tournamentLogo"].string).flatMap(URL.init(string:)),
            location: value["tournamentLocation"].string,
            city: value["city"].string,
            state: value["state"].string,
            country: value["country"].string,
            timezoneIdentifier: value["timezone"].string,
            seasonYear: value["seasonYear"].int,
            displayDate: value["displayDate"].string,
            tournamentStatusRaw: value["tournamentStatus"].string,
            roundStatusRaw: value["roundStatus"].string,
            roundStatusDisplay: value["roundStatusDisplay"].string,
            roundDisplay: value["roundDisplay"].string,
            currentRound: value["currentRound"].int,
            formatTypeRaw: value["formatType"].string,
            scoredLevel: value["scoredLevel"].string,
            courses: value["courses"].array.map(course),
            weather: weather(value["weather"]),
            headshotBaseURL: (value["headshotBaseUrl"].string).flatMap(URL.init(string:)),
            tournamentSiteURL: (value["tournamentSiteURL"].string).flatMap(URL.init(string:)),
            ticketsURL: (value["ticketsURL"].string).flatMap(URL.init(string:))
        )
    }

    private static func course(_ value: PGAValue) -> GolfCourse {
        GolfCourse(
            id: value["id"].string ?? "",
            name: value["courseName"].string ?? "",
            code: value["courseCode"].string,
            isHostCourse: value["hostCourse"].bool ?? false,
            par: nil,
            yardage: nil,
            city: nil,
            state: nil,
            country: nil,
            holes: []
        )
    }

    private static func weather(_ value: PGAValue) -> GolfWeather? {
        guard !value.isNull else { return nil }
        let reading = GolfWeatherReading(
            title: nil,
            condition: value["condition"].string,
            windDirection: value["windDirection"].string,
            windSpeedMPH: value["windSpeedMPH"].double,
            windSpeedKPH: value["windSpeedKPH"].double,
            humidity: value["humidity"].double,
            precipitation: value["precipitation"].double,
            tempF: value["tempF"].double,
            tempC: value["tempC"].double
        )
        return GolfWeather(current: reading, hourly: [], daily: [])
    }
}
