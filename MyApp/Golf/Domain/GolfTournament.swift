import Foundation

/// Provider truth for scoring/leaderboard behavior — never assume every
/// event is a standard four-round individual stroke-play event (STEP 8).
nonisolated enum GolfTournamentFormat: Sendable, Hashable {
    case strokePlay
    case team
    case matchPlay
    case modified
    case unknown(String)

    init(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .unknown(""); return }
        switch raw.uppercased() {
        case "STROKE_PLAY", "STROKEPLAY", "INDIVIDUAL_STROKE_PLAY": self = .strokePlay
        case "TEAM": self = .team
        case "MATCH_PLAY", "MATCHPLAY": self = .matchPlay
        case "MODIFIED", "MODIFIED_STABLEFORD", "STABLEFORD": self = .modified
        default: self = .unknown(raw)
        }
    }

    /// Whether the standard stroke-play cut/leaderboard assumptions this app
    /// implements are valid for this format (STEP 8/95). Non-stroke-play
    /// formats still render the basic leaderboard/status; cut UI and
    /// stroke-play-only affordances are suppressed for them.
    var supportsStandardStrokePlayAssumptions: Bool {
        if case .strokePlay = self { return true }
        return false
    }
}

/// Normalized from `tournamentStatus`/`roundStatus`/`roundStatusDisplay`
/// (STEP 9). Golf delays for weather/darkness are common — never assume a
/// round ends on the scheduled calendar date.
nonisolated enum GolfTournamentStatus: Sendable, Hashable {
    case scheduled
    case roundNotStarted
    case roundInProgress
    case roundSuspended
    case roundComplete
    case tournamentComplete
    case cancelled
    case unknown(String)

    init(tournamentStatusRaw: String?, roundStatusRaw: String?) {
        let tournamentUpper = tournamentStatusRaw?.uppercased() ?? ""
        let roundUpper = roundStatusRaw?.uppercased() ?? ""
        let combined = roundUpper.isEmpty ? tournamentUpper : roundUpper

        if combined.contains("CANCEL") { self = .cancelled; return }
        if combined.contains("SUSPEND") || combined.contains("DELAY") { self = .roundSuspended; return }
        if tournamentUpper.contains("COMPLETE") || tournamentUpper.contains("OFFICIAL") || tournamentUpper == "FINAL" {
            self = .tournamentComplete
            return
        }
        if combined.contains("COMPLETE") || combined == "OFFICIAL" || combined == "FINAL" { self = .roundComplete; return }
        if combined.contains("PROGRESS") || combined.contains("LIVE") || combined.contains("ACTIVE") { self = .roundInProgress; return }
        if combined.contains("NOT_STARTED") || combined.contains("NOTSTARTED") || combined.contains("SCHEDULED") || combined.contains("UPCOMING") {
            self = .roundNotStarted
            return
        }
        if combined.isEmpty { self = .unknown(""); return }
        self = .unknown(combined)
    }

    var isLive: Bool {
        switch self {
        case .roundInProgress, .roundSuspended: return true
        default: return false
        }
    }

    var displayLabel: String {
        switch self {
        case .scheduled, .roundNotStarted: return "Upcoming"
        case .roundInProgress: return "Live"
        case .roundSuspended: return "Suspended"
        case .roundComplete: return "Round Complete"
        case .tournamentComplete: return "Final"
        case .cancelled: return "Cancelled"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }
}

/// Aggregate tournament metadata (STEP 6) — the root object a
/// `PGATournamentCentreService` assembles its Overview/Leaderboard/Course/Tee
/// Times tabs around.
nonisolated struct GolfTournament: Identifiable, Sendable, Hashable {
    var id: String { tournamentID.rawValue }

    let tournamentID: GolfTournamentID
    let name: String
    let logoURL: URL?
    let location: String?
    let city: String?
    let state: String?
    let country: String?
    let timezoneIdentifier: String?
    let seasonYear: Int?
    let displayDate: String?
    let tournamentStatusRaw: String?
    let roundStatusRaw: String?
    let roundStatusDisplay: String?
    let roundDisplay: String?
    let currentRound: Int?
    let formatTypeRaw: String?
    let scoredLevel: String?
    let courses: [GolfCourse]
    let weather: GolfWeather?
    let headshotBaseURL: URL?
    let tournamentSiteURL: URL?
    let ticketsURL: URL?

    var status: GolfTournamentStatus {
        GolfTournamentStatus(tournamentStatusRaw: tournamentStatusRaw, roundStatusRaw: roundStatusRaw)
    }
    var format: GolfTournamentFormat { GolfTournamentFormat(raw: formatTypeRaw) }
    var timeZone: TimeZone? { timezoneIdentifier.flatMap(TimeZone.init(identifier:)) }
    var hostCourse: GolfCourse? { courses.first(where: \.isHostCourse) ?? courses.first }
    /// True when this event rotates among more than one course (STEP 7).
    var isMultiCourse: Bool { courses.count > 1 }
}
