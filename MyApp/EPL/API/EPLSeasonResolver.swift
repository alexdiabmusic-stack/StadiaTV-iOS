import Foundation

/// Maps calendar dates to Premier League SDP season identifiers. SDP's `season`
/// query parameter is the *starting year* of the August-to-May season (2025 =
/// 2025/26, 2026 = 2026/27) — never derive it from a bare calendar year without
/// accounting for the season boundary, or July fixtures would resolve to the
/// wrong (already-finished) season.
nonisolated enum EPLSeasonResolver {
    /// The competition ID for the Premier League within the SDP API. Centralized here
    /// (rather than scattered through endpoint call sites) since every SDP route needs it.
    static let competitionID = "8"

    /// The season a given date falls within. The Premier League season starts in
    /// August; July is treated as pre-season (still the prior season's ID) since no
    /// fixtures exist yet for the upcoming one.
    static func season(for date: Date = Date(), calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return month >= 7 ? year : year - 1
    }

    /// Season identifier formatted the way SDP expects it in query strings.
    static func seasonParameter(for date: Date = Date()) -> String { String(season(for: date)) }
}
