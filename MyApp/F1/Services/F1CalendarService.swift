import Foundation

nonisolated struct F1Meeting: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let season: Int
    let round: Int
    let name: String
    let circuit: String
    let country: String
    let sessions: [F1ScheduledSession]
}
nonisolated struct F1ScheduledSession: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let meeting: String
    let circuit: String
    let name: String
    let start: Date
    let season: Int
    let round: Int
    var type: F1SessionType { F1SessionType(name) }
}
actor F1CalendarService {
    static let shared = F1CalendarService()
    private let client: F1HTTPClient
    private var cache: [Int: (Date, [F1Meeting])] = [:]
    init(client: F1HTTPClient = .shared) { self.client = client }
    func meetings(season: Int) async throws -> [F1Meeting] {
        if let (date, cached) = cache[season], Date().timeIntervalSince(date) < 21600 { return cached }
        let raw = try await resource("\(season)/races/")
        let values = raw["MRData"]["RaceTable"]["Races"].array.compactMap(Self.meeting)
        cache[season] = (Date(), values); return values
    }
    func resource(_ path: String) async throws -> F1Value {
        guard !path.contains(".."), var components = URLComponents(string: "https://api.jolpi.ca/ergast/f1/" + path) else { throw F1LiveTimingError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "limit", value: "100")]
        guard let url = components.url else { throw F1LiveTimingError.invalidResponse }
        return try await client.json(url)
    }
    nonisolated static func meeting(_ raw: F1Value) -> F1Meeting? {
        guard let season = raw["season"].int, let round = raw["round"].int, let name = raw["raceName"].string else { return nil }
        let circuit = raw["Circuit"]["circuitName"].string ?? "Circuit"
        let definitions = [("FirstPractice", "Practice 1"), ("SecondPractice", "Practice 2"), ("ThirdPractice", "Practice 3"), ("SprintQualifying", "Sprint Qualifying"), ("SprintShootout", "Sprint Qualifying"), ("Qualifying", "Qualifying"), ("Sprint", "Sprint"), ("Race", "Race")]
        let sessions = definitions.compactMap { key, label -> F1ScheduledSession? in
            if key == "SprintShootout" && raw["SprintQualifying"]["date"].string != nil { return nil }
            let value = key == "Race" ? raw : raw[key]
            guard let day = value["date"].string, let time = value["time"].string, let date = F1Date.parse(day + "T" + time) else { return nil }
            return F1ScheduledSession(id: "\(season).\(round).\(key)", meeting: name, circuit: circuit, name: label, start: date, season: season, round: round)
        }.sorted { $0.start < $1.start }
        return F1Meeting(id: "\(season).\(round)", season: season, round: round, name: name, circuit: circuit, country: raw["Circuit"]["Location"]["country"].string ?? "", sessions: sessions)
    }
    func session(id: String) async throws -> F1ScheduledSession? {
        guard let season = id.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        return try await meetings(season: season).flatMap(\.sessions).first { $0.id == id }
    }
}
