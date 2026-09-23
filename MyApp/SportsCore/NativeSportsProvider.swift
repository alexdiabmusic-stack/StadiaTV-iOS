import Foundation

/// The provider boundary speaks app models. Future league APIs register their own
/// implementation; there is no implicit cross-provider or ESPN fallback.
nonisolated protocol NativeSportsProvider: Sendable {
    var leaguePath: String { get }
    func scores(on date: Date?) async throws -> [Match]
    func schedule(start: Date, days: Int) async throws -> [Match]
    func teams() async throws -> [Team]
    func standings() async throws -> [StandingsGroup]
    func roster(teamID: String) async throws -> [RosterGroup]
    func playerOverview(id: String) async throws -> AthleteOverview
}
