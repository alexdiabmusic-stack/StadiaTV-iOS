import Foundation
import Testing
import Darwin
@testable import MLBCore

@main struct MLBTestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = MLBAPIClient()
                let date = try #require(MLBDate.parse("2024-07-04T12:00:00Z"))
                let schedule = try await client.schedule(date: date)
                let discovered = try #require(schedule.games.first { $0["gamePk"].int == 744834 })
                let game = try #require(MLBGameMapper.schedule(discovered))
                let update = try await MLBGameCenterService(client: client).fetch(gamePk: game.id, tab: .overview, full: true, includeContent: true)
                let snapshot = MLBGameCenterReducer.apply(update, to: BaseballGameSnapshot(gamePk: game.id, game: game))
                guard update.errors.isEmpty, snapshot.atBats.count > 50, !snapshot.box.isEmpty, snapshot.game?.home.runs == 1 else { throw MLBAPIError.invalidResponse }
                let light = try await MLBGameCenterService(client: client).fetch(gamePk: game.id, tab: .plays, full: false, includeContent: false)
                guard light.errors.isEmpty, light.plays != nil, light.line != nil else { throw MLBAPIError.invalidResponse }
                let teams = try await client.teams()
                let standings = try await client.standings(season: 2024)
                let roster = try await client.roster(teamID: 141)
                let player = try await client.player(playerID: 596019)
                let probability = try await client.winProbability(gamePk: game.id)
                let context = try await client.contextMetrics(gamePk: game.id)
                guard !teams.raw["teams"].array.isEmpty, !standings.raw["records"].array.isEmpty, !roster.raw["roster"].array.isEmpty, !player.raw["people"].array.isEmpty, !probability.raw.array.isEmpty, context.raw["homeWinProbability"].double != nil else { throw MLBAPIError.invalidResponse }
                print("LIVE SMOKE PASSED: schedule gamePk \(game.id), \(snapshot.atBats.count) at-bats, \(snapshot.box.count) box players, \(snapshot.highlights.count) highlights, \(probability.raw.array.count) probability points; light refresh, teams, standings, roster, player and context succeeded.")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
