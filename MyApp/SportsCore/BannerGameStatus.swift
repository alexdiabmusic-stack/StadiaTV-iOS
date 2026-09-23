import Foundation

nonisolated enum BannerGameStatus: String, Codable, Hashable, Sendable {
    case scheduled
    case pregame
    case live
    case delayed
    case postponed
    case suspended
    case final
    case cancelled
    case unknown

}
