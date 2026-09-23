import Foundation
import Testing
import Darwin
@testable import NBACore

@main struct NBATestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = NBAAPIClient()
                let scoreboard = try await client.todaysScoreboard()
                guard !scoreboard.games.isEmpty else {
                    // NBA has genuine offseason days with zero games; that's a legitimate
                    // empty result, not a smoke-test failure — just report it as such.
                    print("LIVE SMOKE: today's scoreboard is empty (offseason or no games scheduled). Host reachability confirmed.")
                    exit(0)
                }
                let raw = scoreboard.games[0]
                guard let gameID = raw["gameId"].string else { throw NBAAPIError.invalidResponse }
                let box = try await client.boxScore(gameID: gameID)
                let plays = try await client.playByPlay(gameID: gameID)
                let standings = try await client.leagueStandingsV3(season: NBASeason.current(), seasonType: "Regular Season")
                print("LIVE SMOKE PASSED: gameID \(gameID), box gameID \(box.gameID ?? "nil"), \(plays.actions.count) plays, \(standings.rows.count) standings rows.")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
