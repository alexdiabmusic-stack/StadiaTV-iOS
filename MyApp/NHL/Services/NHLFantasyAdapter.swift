import Foundation

struct NHLFantasyAdapter {
    func currentPlayers(for sport: FantasySport) async throws -> [BannerFantasyAvailablePlayer] {
        guard sport == .nhl, let league = sport.bannerLeague else { throw SportsDataError.unsupportedCapability(.players) }
        let teams = try await SportsRepository.shared.legacyTeams(for: league)
        var players: [String: BannerFantasyAvailablePlayer] = [:]
        // Bound concurrency to avoid a 32-request burst at the NHL service.
        for team in teams {
            try Task.checkCancellation()
            let groups = try await SportsRepository.shared.legacyRoster(for: league, teamID: team.id)
            for athlete in groups.flatMap(\.athletes) {
                let slot: BannerFantasyRosterSlot
                switch athlete.position {
                case "C": slot = .center
                case "L", "LW": slot = .leftWing
                case "R", "RW": slot = .rightWing
                case "D": slot = .defense
                case "G": slot = .goalie
                default: slot = .forward
                }
                players[athlete.id] = BannerFantasyAvailablePlayer(id: athlete.id, fullName: athlete.displayName,
                    teamAbbreviation: team.abbreviation, position: athlete.position,
                    eligibleSlots: slot == .goalie ? [.goalie] : [slot, .utility], injuryStatus: nil,
                    headshotURL: athlete.headshotURL)
            }
        }
        return players.values.sorted { $0.fullName < $1.fullName }
    }
}
