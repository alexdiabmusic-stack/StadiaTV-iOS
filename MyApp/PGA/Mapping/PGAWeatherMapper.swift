import Foundation

/// Maps the dedicated `Weather` operation (hourly/daily forecast). The
/// tournament-header "current" snapshot instead comes from
/// `PGATournamentMapper` (`Tournaments.weather`) — this only ever
/// supplements it, and this app hides weather UI entirely if either call
/// fails rather than blocking the rest of the Tournament Centre (STEP 98).
nonisolated enum PGAWeatherMapper {
    static func forecast(_ value: PGAValue, current: GolfWeatherReading?) -> GolfWeather {
        GolfWeather(
            current: current,
            hourly: value["hourly"].array.map(reading),
            daily: value["daily"].array.map(reading)
        )
    }

    private static func reading(_ value: PGAValue) -> GolfWeatherReading {
        let temperature = value["temperature"]
        return GolfWeatherReading(
            title: value["title"].string,
            condition: value["condition"].string,
            windDirection: value["windDirection"].string,
            windSpeedMPH: value["windSpeedMPH"].double,
            windSpeedKPH: value["windSpeedKPH"].double,
            humidity: value["humidity"].double,
            precipitation: value["precipitation"].double,
            tempF: temperature["tempF"].double ?? temperature["maxTempF"].double,
            tempC: temperature["tempC"].double ?? temperature["maxTempC"].double
        )
    }
}
