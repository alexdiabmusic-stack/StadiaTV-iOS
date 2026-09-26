import Foundation
import Testing
import Darwin
@testable import CFLCore
@main struct Runner {
    static func main() async {
        if CommandLine.arguments.contains("--live-smoke") {
            do {
                let client = CFLClient()
                let seasonID = try await CFLSeasonIdentity.shared.seasonID(for: 2026)
                let fixtures = try await client.get(.fixtures(seasonID: seasonID), as: [CFLValue].self, maxAge: 0)
                print("Native CFL: season \(seasonID), \(fixtures.count) fixtures")
                fflush(stdout); _exit(seasonID == 75 ? 0 : 1)
            } catch { print(error.localizedDescription); fflush(stdout); _exit(1) }
        }
        let result: CInt = await Testing.__swiftPMEntryPoint(); exit(result)
    }
}
