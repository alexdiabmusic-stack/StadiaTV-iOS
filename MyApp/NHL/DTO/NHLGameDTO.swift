import Foundation

nonisolated struct NHLGameDTO: Decodable, Sendable {
    let raw: NHLValue
    init(from decoder: Decoder) throws { raw = try NHLValue(from: decoder) }
    init(raw: NHLValue) { self.raw = raw }
    var id: Int? { raw["id"].int }
    var season: Int? { raw["season"].int }
    var gameType: Int? { raw["gameType"].int }
    var gameDate: String? { raw["gameDate"].string }
    var startTimeUTC: String? { raw["startTimeUTC"].string }
    var gameState: String? { raw["gameState"].string }
    var gameScheduleState: String? { raw["gameScheduleState"].string }
    var homeTeam: NHLTeamDTO { NHLTeamDTO(raw: raw["homeTeam"]) }
    var awayTeam: NHLTeamDTO { NHLTeamDTO(raw: raw["awayTeam"]) }
    var period: HockeyPeriod { HockeyPeriod(raw: raw["periodDescriptor"]) }
    var clock: NHLClockDTO { NHLClockDTO(raw: raw["clock"]) }
}
nonisolated struct NHLTeamDTO: Sendable {
    let raw: NHLValue
    var id: Int? { raw["id"].int }
    var abbreviation: String { raw["abbrev"].string ?? "" }
    var name: String { raw["name"].localized ?? [raw["placeName"].localized, raw["commonName"].localized].compactMap { $0 }.joined(separator: " ") }
    var score: Int? { raw["score"].int }
    var shots: Int? { raw["sog"].int }
}
nonisolated struct NHLClockDTO: Sendable {
    let raw: NHLValue
    var timeRemaining: String? { raw["timeRemaining"].string }
    var secondsRemaining: Int? { raw["secondsRemaining"].int }
    var running: Bool { raw["running"].bool ?? false }
    var inIntermission: Bool { raw["inIntermission"].bool ?? false }
}
nonisolated struct NHLScoreResponse: Decodable, Sendable {
    let games: [NHLGameDTO]
    init(from decoder: Decoder) throws {
        let raw = try NHLValue(from: decoder)
        games = raw["games"].array.map(NHLGameDTO.init)
    }
}
nonisolated struct NHLScheduleResponse: Decodable, Sendable {
    let games: [NHLGameDTO]
    init(from decoder: Decoder) throws {
        let raw = try NHLValue(from: decoder)
        games = raw["gameWeek"].array.flatMap { $0["games"].array }.map(NHLGameDTO.init)
    }
}
nonisolated struct NHLPlayDTO: Sendable {
    let raw: NHLValue
    var eventID: Int? { raw["eventId"].int }
    var sortOrder: Int? { raw["sortOrder"].int }
    var typeDescKey: String? { raw["typeDescKey"].string }
    var typeCode: Int? { raw["typeCode"].int }
    var details: NHLValue { raw["details"] }
}
nonisolated struct NHLPlayByPlayResponse: Decodable, Sendable {
    let game: NHLGameDTO
    let plays: [NHLPlayDTO]
    let rosterSpots: [NHLRosterSpot]
    init(from decoder: Decoder) throws {
        let raw = try NHLValue(from: decoder)
        game = NHLGameDTO(raw: raw)
        plays = raw["plays"].array.map { NHLPlayDTO(raw: $0) }
        rosterSpots = raw["rosterSpots"].array.compactMap(NHLRosterSpot.init)
    }
}
nonisolated struct NHLRosterSpot: Sendable {
    let playerID: Int
    let teamID: Int?
    let firstName: NHLLocalizedName
    let lastName: NHLLocalizedName
    let sweaterNumber: Int?
    let positionCode: String?
    let headshot: String?
    init?(raw: NHLValue) {
        guard let id = raw["playerId"].int ?? raw["id"].int else { return nil }
        playerID = id; teamID = raw["teamId"].int
        firstName = NHLLocalizedName(raw["firstName"]); lastName = NHLLocalizedName(raw["lastName"])
        sweaterNumber = raw["sweaterNumber"].int; positionCode = raw["positionCode"].string
        headshot = raw["headshot"].string
    }
}
nonisolated struct NHLBoxscoreResponse: Decodable, Sendable {
    let game: NHLGameDTO
    let players: NHLValue
    init(from decoder: Decoder) throws {
        let raw = try NHLValue(from: decoder)
        game = NHLGameDTO(raw: raw); players = raw["playerByGameStats"]
    }
}
nonisolated struct NHLStandingsResponse: Decodable, Sendable {
    let rows: [NHLValue]
    init(from decoder: Decoder) throws { rows = try NHLValue(from: decoder)["standings"].array }
}
nonisolated struct NHLRosterResponse: Decodable, Sendable {
    let players: [NHLRosterSpot]
    init(from decoder: Decoder) throws {
        let raw = try NHLValue(from: decoder)
        players = ["forwards", "defensemen", "goalies"].flatMap { raw[$0].array }.compactMap(NHLRosterSpot.init)
    }
}
nonisolated struct NHLPlayerResponse: Decodable, Sendable {
    let raw: NHLValue
    init(from decoder: Decoder) throws { raw = try NHLValue(from: decoder) }
}
