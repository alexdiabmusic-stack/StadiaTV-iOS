import Foundation

/// The golf data providers this domain can be fed by. Only `.pgaTour` is
/// wired today; the type exists so a second provider never requires
/// reshaping every Golf* model.
nonisolated enum GolfProvider: String, Sendable, Codable, Hashable {
    case pgaTour
}

/// PGA tournament ids follow the convention `{tourCode}{year}{tournamentNumber}`
/// (e.g. "R2026027"). Treated as opaque — never parse business logic out of
/// the individual characters. Tournaments are identified by this value, never
/// by matching on name/course/date.
nonisolated struct GolfTournamentID: Hashable, Codable, Sendable, CustomStringConvertible {
    let provider: GolfProvider
    let rawValue: String

    init(provider: GolfProvider = .pgaTour, rawValue: String) {
        self.provider = provider
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}
