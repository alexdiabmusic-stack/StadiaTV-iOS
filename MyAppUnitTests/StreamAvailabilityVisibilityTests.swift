import Foundation
import Testing
@testable import BannerTV

/// Prompt 7 step 3 of MatchLinker/PROMPTS.md: "a playlist export without MLS listings collapses
/// MLS while one with them does not." `StreamAvailabilityStore.isLeagueOnPlaylist` is the data
/// layer behind that collapsing — MatchesView hides a league's matches into "Not on your
/// playlist" when this returns false.
@MainActor
@Suite("StreamAvailabilityStore per-league visibility")
struct StreamAvailabilityVisibilityTests {

    private var mls: League { League.all.first { $0.path == "soccer/usa.1" }! }
    private var nhl: League { League.all.first { $0.path == "hockey/nhl" }! }

    private func match(id: String, league: League) -> Match {
        Match(
            id: id, league: league, date: Date(), name: "Test", shortName: "Test",
            state: .pre, statusDetail: "",
            home: TeamSide(displayName: "Home", shortName: "Home", abbreviation: "HOM", logoURL: nil, score: nil, record: nil, isWinner: false),
            away: TeamSide(displayName: "Away", shortName: "Away", abbreviation: "AWY", logoURL: nil, score: nil, record: nil, isWinner: false),
            broadcasts: [], venue: nil
        )
    }

    /// Clears the store's persisted key before and after so this test never reads stale state
    /// left behind by a previous run or pollutes a later one.
    private func withFreshStore(_ body: (StreamAvailabilityStore) -> Void) {
        let key = "streamAvailability.leagueVisibilityLog.v1"
        UserDefaults.standard.removeObject(forKey: key)
        let store = StreamAvailabilityStore()
        body(store)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("A league with 10+ matches and zero confident stays hidden")
    func leagueWithNoConfidentMatchesIsNotOnPlaylist() {
        withFreshStore { store in
            let matches = (0..<10).map { match(id: "mls-\($0)", league: mls) }
            store.recordLeagueVisibility(matches: matches, confirmedCounts: [:])
            #expect(!store.isLeagueOnPlaylist(mls))
        }
    }

    @Test("A league with at least one confident match stays visible")
    func leagueWithAConfidentMatchIsOnPlaylist() {
        withFreshStore { store in
            let matches = (0..<10).map { match(id: "mls-\($0)", league: mls) }
            store.recordLeagueVisibility(matches: matches, confirmedCounts: ["mls-0": 1])
            #expect(store.isLeagueOnPlaylist(mls))
        }
    }

    @Test("Fewer than 10 matches always stays visible, confident or not")
    func leagueWithFewMatchesStaysVisible() {
        withFreshStore { store in
            let matches = (0..<3).map { match(id: "nhl-\($0)", league: nhl) }
            store.recordLeagueVisibility(matches: matches, confirmedCounts: [:])
            #expect(store.isLeagueOnPlaylist(nhl))
        }
    }
}
