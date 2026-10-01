import Testing
@testable import BannerTV

/// Guards against a repeat of the Liga MX "dead league" bug (MatchLinker/PROMPTS.md, Prompt 7):
/// `League.all` listed a league (`soccer/mex.1`) with no matching entry in
/// `SportsRepository`'s provider list, so selecting it always threw `noProviderAvailable`.
@Suite("Sports catalog provider coverage")
struct SportsCatalogProviderCoverageTests {

    @Test("Every League.all entry has a registered SportsRepository provider")
    func everyLeagueHasAProvider() {
        let repository = SportsRepository.shared
        for league in League.all {
            #expect(repository.hasProvider(for: league), "\(league.name) (\(league.path)) has no SportsRepository provider")
        }
    }
}
