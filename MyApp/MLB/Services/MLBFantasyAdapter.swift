import Foundation

struct MLBFantasyAdapter {
    func currentPlayers(for sport: FantasySport) async throws -> [BannerFantasyAvailablePlayer] {
        guard sport == .mlb, let league = sport.bannerLeague else { throw SportsDataError.unsupportedCapability(.players) }
        let teams = try await SportsRepository.shared.legacyTeams(for: league)
        var players: [String: BannerFantasyAvailablePlayer] = [:]
        // Bound concurrency to avoid a 30-request burst at the MLB service.
        for team in teams {
            try Task.checkCancellation()
            let groups = try await SportsRepository.shared.legacyRoster(for: league, teamID: team.id)
            for athlete in groups.flatMap(\.athletes) {
                let slot: BannerFantasyRosterSlot
                switch athlete.position {
                case "P", "SP", "RP": slot = .pitcher
                case "C": slot = .center
                case "1B": slot = .firstBase
                case "2B": slot = .secondBase
                case "3B": slot = .thirdBase
                case "SS": slot = .shortstop
                default: slot = .outfield
                }
                players[athlete.id] = BannerFantasyAvailablePlayer(id: athlete.id, fullName: athlete.displayName,
                    teamAbbreviation: team.abbreviation, position: athlete.position,
                    eligibleSlots: slot == .pitcher ? [.pitcher] : [slot, .utility], injuryStatus: nil,
                    headshotURL: athlete.headshotURL)
            }
        }
        return players.values.sorted { $0.fullName < $1.fullName }
    }
}
