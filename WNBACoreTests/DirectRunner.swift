import Foundation
import Testing
import Darwin
@testable import WNBACore

@main struct WNBATestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = WNBALiveCDNClient()
                let scoreboard = try await client.todaysScoreboard()
                guard !scoreboard.games.isEmpty else {
                    print("LIVE SMOKE: today's scoreboard is empty (offseason or no games scheduled). Host reachability confirmed.")
                    exit(0)
                }
                let raw = scoreboard.games[0]
                guard let gameID = raw["gameId"].string else { throw WNBAAPIError.invalidResponse }
                let box = try await client.boxScore(gameID: gameID)
                let plays = try await client.playByPlay(gameID: gameID)
                print("LIVE SMOKE PASSED: gameID \(gameID), box gameID \(box.gameID ?? "nil"), \(plays.actions.count) plays.")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
