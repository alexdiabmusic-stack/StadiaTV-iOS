import Foundation

nonisolated enum MLBStatusMapper {
    static func status(_ raw: MLBValue) -> BaseballGameStatus {
        let detail = raw["detailedState"].string?.lowercased() ?? ""
        if detail.contains("suspend") { return .suspended }
        if detail.contains("postpon") { return .postponed }
        if detail.contains("cancel") { return .cancelled }
        if detail.contains("delay") { return .delayed }
        if detail == "warmup" { return .warmup }
        if detail == "pre-game" || detail == "pregame" { return .pregame }
        if ["final", "game over", "completed early"].contains(detail) { return .final }
        if ["in progress", "manager challenge", "umpire review"].contains(detail) { return .live }
        if detail == "scheduled" { return .scheduled }
        switch raw["abstractGameState"].string {
        case "Final": return .final
        case "Live": return .live
        case "Preview" where detail.isEmpty: return .scheduled
        default: return .unknown
        }
    }
}
