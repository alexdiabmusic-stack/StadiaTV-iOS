import Foundation

struct NBAFantasyAdapter {
    func currentPlayers(for sport: FantasySport) async throws -> [BannerFantasyAvailablePlayer] {
        guard sport == .nba, let league = sport.bannerLeague else { throw SportsDataError.unsupportedCapability(.players) }
        let teams = try await SportsRepository.shared.legacyTeams(for: league)
        var players: [String: BannerFantasyAvailablePlayer] = [:]
        // Bound concurrency to avoid a burst of roster requests at stats.nba.com,
        // which is already the more fragile of the two NBA hosts.
        for team in teams {
            try Task.checkCancellation()
            let groups = try await SportsRepository.shared.legacyRoster(for: league, teamID: team.id)
            for athlete in groups.flatMap(\.athletes) {
                let slot: BannerFantasyRosterSlot
                switch athlete.position {
                case "PG": slot = .pointGuard
                case "SG": slot = .shootingGuard
                case "SF": slot = .smallForward
                case "PF": slot = .powerForward
                case "C": slot = .center
                default: slot = .utility
                }
                players[athlete.id] = BannerFantasyAvailablePlayer(id: athlete.id, fullName: athlete.displayName,
                    teamAbbreviation: team.abbreviation, position: athlete.position,
                    eligibleSlots: [slot, .utility], injuryStatus: nil, headshotURL: athlete.headshotURL)
            }
        }
        return players.values.sorted { $0.fullName < $1.fullName }
    }
}
