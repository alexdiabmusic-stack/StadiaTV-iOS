import Foundation
import Testing
import Darwin
@testable import MLSCore

@main struct MLSTestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = MLSStatsClient()
                let resolver = MLSSeasonResolver(client: client)
                let seasonID = try await resolver.currentSeasonID()
                let calendar = Calendar(identifier: .gregorian)
                let today = Date()
                let from = calendar.date(byAdding: .day, value: -14, to: today) ?? today
                let scheduleRaw = try await client.schedule(seasonID: seasonID, from: MLSDate.day(from), to: MLSDate.day(today),
                    competitionID: MLSSeasonResolver.regularSeasonCompetitionID, teamID: nil, pageToken: nil)
                let entries = scheduleRaw["schedule"].array
                guard let matchID = entries.first(where: { $0["match_status"].string?.lowercased() == "finalwhistle" })?["match_id"].string
                    ?? entries.first?["match_id"].string else { throw MLSAPIError.invalidResponse }
                let service = MLSGameCentreService(client: client)
                let update = try await service.fetch(matchID: matchID, tab: .overview, full: true, lineupsLoaded: false, knownPlayers: [:], commentaryCursor: nil)
                guard update.match != nil else { throw MLSAPIError.invalidResponse }
                print("LIVE SMOKE PASSED: matchId \(matchID), \(update.events?.count ?? 0) events, lineups=\(update.homeLineup != nil), stats=\(update.homeStats != nil)")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
