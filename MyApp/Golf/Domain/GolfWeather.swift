import Foundation

nonisolated struct GolfWeatherReading: Codable, Sendable, Hashable {
    let title: String?
    let condition: String?
    let windDirection: String?
    let windSpeedMPH: Double?
    let windSpeedKPH: Double?
    let humidity: Double?
    let precipitation: Double?
    let tempF: Double?
    let tempC: Double?
}

nonisolated struct GolfWeather: Codable, Sendable, Hashable {
    /// From the tournament-header summary (`Tournaments.weather`) — always
    /// available when weather is supported at all.
    let current: GolfWeatherReading?
    /// From the dedicated `Weather` operation — optional richer forecast.
    let hourly: [GolfWeatherReading]
    let daily: [GolfWeatherReading]
}
