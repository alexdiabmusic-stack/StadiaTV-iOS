import Foundation

nonisolated struct NFLPlayerStatistics: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let teamID: String
    var passingAttempts = 0, completions = 0, passingTouchdowns = 0, interceptions = 0
    var passingYards: Int? = 0
    var carries = 0, rushingTouchdowns = 0
    var rushingYards: Int? = 0
    var receptions = 0, receivingTouchdowns = 0
    var receivingYards: Int? = 0
    var tackles = 0, assists = 0, defensiveInterceptions = 0
    var sacks = 0.0
    var fieldGoals = 0, fieldGoalAttempts = 0, extraPoints = 0, extraPointAttempts = 0
    var punts = 0
    var puntYards: Int? = 0
}
nonisolated enum NFLStatisticsMapper {
    /// GSIS stat IDs carried in current Shield play.stats. Core totals are regression-tested
    /// against the NFL-supplied 2025 DAL/PHI gamebook, not inferred from descriptions.
    static func players(_ plays: [NFLPlay]) -> [NFLPlayerStatistics] {
        var values: [String: NFLPlayerStatistics] = [:]
        for stat in plays.flatMap(\.participants) {
            guard let id = stat.id, let team = stat.teamID, let code = stat.rawStatType else { continue }
            var value = values[id] ?? NFLPlayerStatistics(id: id, name: stat.name, teamID: team)
            func sum(_ previous: Int?) -> Int? {
                guard let previous, let yards = stat.yards else { return nil }
                return previous + yards
            }
            switch code {
            case 10, 11: value.carries += 1; value.rushingYards = sum(value.rushingYards); if code == 11 { value.rushingTouchdowns += 1 }
            case 12, 13: value.rushingYards = sum(value.rushingYards); if code == 13 { value.rushingTouchdowns += 1 }
            case 14, 19: value.passingAttempts += 1; if code == 19 { value.interceptions += 1 }
            case 15, 16: value.passingAttempts += 1; value.completions += 1; value.passingYards = sum(value.passingYards); if code == 16 { value.passingTouchdowns += 1 }
            case 21, 22: value.receptions += 1; value.receivingYards = sum(value.receivingYards); if code == 22 { value.receivingTouchdowns += 1 }
            case 23, 24: value.receivingYards = sum(value.receivingYards); if code == 24 { value.receivingTouchdowns += 1 }
            case 25, 26: value.defensiveInterceptions += 1
            case 29, 31, 32: value.punts += 1; value.puntYards = sum(value.puntYards)
            case 69, 70, 71: value.fieldGoalAttempts += 1; if code == 70 { value.fieldGoals += 1 }
            case 72, 73, 74: value.extraPointAttempts += 1; if code == 72 { value.extraPoints += 1 }
            case 79, 80: value.tackles += 1
            case 82: value.assists += 1
            case 83: value.sacks += 1
            case 84: value.sacks += 0.5
            default: continue
            }
            values[id] = value
        }
        return values.values.sorted { $0.name < $1.name }
    }
}
