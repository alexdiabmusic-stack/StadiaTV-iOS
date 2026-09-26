import Foundation
import Testing
import Darwin
@testable import EPLCore

@main struct EPLTestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = EPLPulseLiveClient()
                let season = EPLSeasonResolver.seasonParameter()
                let matchesRaw = try await client.matches(season: season, matchweek: nil, team: nil, period: "FullTime", limit: 5, next: nil, sort: "kickoff:desc", kickoffAfter: nil, kickoffBefore: nil)
                let matches = EPLPagedResponse(matchesRaw).data
                guard let first = matches.first, let matchID = first["matchId"].string else { throw EPLAPIError.invalidResponse }
                let service = EPLGameCentreService(client: client)
                let update = try await service.fetch(matchID: matchID, tab: .overview, full: true, lineupsLoaded: false, knownPlayers: [:], commentaryCursor: nil)
                guard update.errors.isEmpty, update.match != nil, (update.events?.isEmpty == false) else { throw EPLAPIError.invalidResponse }
                let standings = try await client.standings(season: season, live: false)
                guard !EPLMatchMapper.standingsTable(standings, live: false).entries.isEmpty else { throw EPLAPIError.invalidResponse }
                print("LIVE SMOKE PASSED: matchId \(matchID), \(update.events?.count ?? 0) events, lineups=\(update.homeLineup != nil), stats=\(update.homeStats != nil)")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
