import Foundation
import Testing
import Darwin
@testable import LaLigaCore

/// Minimal `LaLigaOfficialMatchSource` for the live-smoke path only — the real
/// `LaLigaProvider` (with its season-match cache) lives in the app target, so this
/// wraps the same client + mapper calls directly rather than re-implementing it.
private struct DirectOfficialMatchSource: LaLigaOfficialMatchSource {
    let client: any LaLigaClientProtocol
    let subscriptionSlug: String
    let season: String
    func officialMatch(id: String) async throws -> SoccerMatch? {
        for page in 0..<4 {
            let raw = try await client.matches(subscriptionSlug: subscriptionSlug, competition: "primera-division", limit: 100, offset: page * 100)
            let rows = raw["matches"].array
            if let row = rows.first(where: { $0["id"].string == id }) { return LaLigaMatchMapper.match(row, season: season) }
            if rows.count < 100 { break }
        }
        return nil
    }
}

@main struct LaLigaTestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = LaLigaClient()
                let resolver = LaLigaSeasonResolver(client: client)
                let slug = try await resolver.currentSubscriptionSlug()
                let year = LaLigaSeasonResolver.startingYear()

                var finishedRow: LaLigaValue?
                var offset = 0
                while offset < 400 {
                    let raw = try await client.matches(subscriptionSlug: slug, limit: 100, offset: offset)
                    let rows = raw["matches"].array
                    if let row = rows.first(where: { $0["status"].string == "FullTime" }) { finishedRow = row; break }
                    if rows.count < 100 { break }
                    offset += 100
                }
                guard let finishedRow, let matchID = finishedRow["id"].string else { throw LaLigaAPIError.invalidResponse }

                let source = DirectOfficialMatchSource(client: client, subscriptionSlug: slug, season: String(year))
                let service = LaLigaGameCentreService(officialSource: source)
                let update = try await service.fetch(matchID: matchID, tab: .overview, full: true, lineupsLoaded: false, knownPlayers: [:], commentaryCursor: nil)
                guard update.match != nil else { throw LaLigaAPIError.invalidResponse }
                print("LIVE SMOKE PASSED: matchId \(matchID), fotmob=\(update.providerMatchIDs?.fotmob ?? "unresolved"), events=\(update.events?.count ?? 0), lineups=\(update.homeLineup != nil), stats=\(update.homeStats != nil)")
                exit(0)
            } catch { print("LIVE SMOKE FAILED: \(error)"); exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
