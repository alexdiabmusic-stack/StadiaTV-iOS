import Foundation

/// Hole-level scoring stats for the *current* tournament (from `CourseStats`)
/// — distinct from static hole geometry, since averages/rank only exist once
/// a round has been played.
nonisolated struct GolfHole: Identifiable, Codable, Sendable, Hashable {
    var id: Int { number }
    let number: Int
    let par: Int?
    let yardage: Int?
    let scoringAverage: Double?
    let scoringAverageToParDisplay: String?
    let rank: Int?
    let eagles: Int?
    let birdies: Int?
    let pars: Int?
    let bogeys: Int?
    let doubleBogeyOrWorse: Int?

    var scoringAverageToPar: GolfScore { GolfScore(raw: scoringAverageToParDisplay) }
}

nonisolated struct GolfCourse: Identifiable, Codable, Sendable, Hashable {
    var id: String
    let name: String
    let code: String?
    let isHostCourse: Bool
    let par: Int?
    let yardage: Int?
    let city: String?
    let state: String?
    let country: String?
    let holes: [GolfHole]
}

/// Deep single-hole detail (`HoleDetails`) — includes the "about this hole"
/// blurb and players currently on the hole, unavailable from `CourseStats`.
nonisolated struct GolfHoleDetail: Identifiable, Codable, Sendable, Hashable {
    var id: String { "\(courseID)-\(holeNumber)" }
    let courseID: String
    let holeNumber: Int
    let par: Int?
    let yardage: Int?
    let rankDisplay: String?
    let aboutThisHole: String?
    let eagles: Int?
    let eaglesPercent: Double?
    let birdies: Int?
    let birdiesPercent: Double?
    let pars: Int?
    let parsPercent: Double?
    let bogeys: Int?
    let bogeysPercent: Double?
    let doubleBogeysOrWorse: Int?
    let doubleBogeysOrWorsePercent: Double?
    let tourcastURL: URL?
}
