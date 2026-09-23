import Foundation
import Testing
import Darwin
@testable import NFLCore
@main struct Runner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = NFLShieldClient()
                let week = NFLWeek(season: 2025, seasonType: .regular, week: 1)
                let response = try await client.weeklyGameDetails(week)
                let games = response.games.compactMap { NFLGameMapper.game($0) }
                print("Native Shield: \(games.count) games, \(games.reduce(0) { $0 + $1.drives.count }) drives, \(games.reduce(0) { $0 + $1.plays.count }) plays")
                async let weeks = client.weeks(season: 2025, type: .regular)
                async let summary = client.liveGameSummaries(week)
                async let standings = client.standings(week)
                async let rosters = client.rosters(season: 2025)
                async let injuries = client.injuries(week)
                let counts = try await (weeks, summary, standings, rosters, injuries)
                print("Resources: \(counts.0["weeks"].array.count) weeks, \(counts.1["data"].array.count) summaries, \(counts.2["weeks"].array.count) standings weeks, \(counts.3["rosters"].array.count) rosters, \(counts.4["injuries"].array.count) injury records")
                if let teamID = games.first?.home.id {
                    let team = try await client.team(id: teamID)
                    print("Team detail has native identity: \(team["id"].string == teamID)")
                }
                fflush(stdout); _exit(games.count == 16 ? 0 : 1)
            } catch { print(error.localizedDescription); fflush(stdout); _exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint(); exit(result)
    }
}
