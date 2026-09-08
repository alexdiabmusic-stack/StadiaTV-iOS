import Foundation
import Testing
@testable import StadiaTV

// MARK: - Helpers (shared with SourceMatcherRegressionTests via file-private scope)

private let precisionPlaylistID = UUID()

private func pChannel(id: String = UUID().uuidString, name: String, group: String? = "Sports") -> Channel {
    Channel(id: id, name: name, streamURL: URL(string: "https://example.com/stream.m3u8")!,
            logoURL: nil, group: group, playlistID: precisionPlaylistID, playlistName: "PrecisionTest")
}

private func pMatch(
    id: String = "prec-\(Int.random(in: 0..<Int.max))",
    league: League,
    home: String,
    homeShort: String? = nil,
    homeAbbr: String,
    away: String,
    awayShort: String? = nil,
    awayAbbr: String,
    broadcasts: [String] = [],
    name: String = "",
    shortName: String = ""
) -> Match {
    Match(
        id: id,
        league: league,
        date: Date(),
        name: name.isEmpty ? "\(away) at \(home)" : name,
        shortName: shortName.isEmpty ? "\(awayAbbr) @ \(homeAbbr)" : shortName,
        state: .live,
        statusDetail: "In Progress",
        home: TeamSide(displayName: home, shortName: homeShort ?? home, abbreviation: homeAbbr,
                       logoURL: nil, score: "1", record: nil, isWinner: false, teamID: "1"),
        away: TeamSide(displayName: away, shortName: awayShort ?? away, abbreviation: awayAbbr,
                       logoURL: nil, score: "0", record: nil, isWinner: false, teamID: "2"),
        broadcasts: broadcasts,
        venue: nil
    )
}

private var eredivisieLeague: League { League.all.first { $0.path == "soccer/ned.1" }! }
private var mlbLeague: League { League.all.first { $0.path == "baseball/mlb" }! }
private var f1League: League { League.all.first { $0.path == "racing/f1" }! }
private var ncaafLeague: League { League.all.first { $0.path == "football/college-football" }! }
private var nhlLeague: League { League.all.first { $0.path == "hockey/nhl" }! }
private var eplLeagueP: League { League.all.first { $0.path == "soccer/eng.1" }! }

// MARK: - Precision Stream Matcher Regression Suite (v3)

@Suite("Precision stream matcher regressions (v3)")
struct PrecisionStreamMatcherTests {

    // MARK: REG-004 / REG-005: Participant boundary rule — no substring fallback

    @Test("REG-004: 'Sparta' must not match 'Spartanburg' via substring")
    func spartaDoesNotMatchSpartanburg() {
        let m = pMatch(league: eredivisieLeague,
                       home: "PSV", homeAbbr: "PSV",
                       away: "Sparta Rotterdam", awayAbbr: "SPA")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "CBS 7 Spartanburg")
        ])
        // "sparta" (6 chars) previously matched "spartanburg" via haystack.contains(token).
        // After removing the substring fallback, only whole-word token matches are allowed.
        let hasTeamMatch = ranked.first?.evidenceCategories.contains(.teamNameMatch) ?? false
        #expect(!hasTeamMatch,
                "Participant boundary: 'sparta' must not substring-match 'spartanburg'")
    }

    @Test("REG-005: 'Sparta' must not match 'Isparta' via substring")
    func spartaDoesNotMatchIsparta() {
        let m = pMatch(league: eredivisieLeague,
                       home: "PSV", homeAbbr: "PSV",
                       away: "Sparta Rotterdam", awayAbbr: "SPA")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Isparta Sports")
        ])
        let hasTeamMatch = ranked.first?.evidenceCategories.contains(.teamNameMatch) ?? false
        #expect(!hasTeamMatch,
                "Participant boundary: 'sparta' must not substring-match 'isparta'")
    }

    @Test("REG-003: Correct whole-word channel still matches Sparta Rotterdam")
    func spartaMatchesWhenWholeWord() {
        let m = pMatch(league: eredivisieLeague,
                       home: "PSV", homeAbbr: "PSV",
                       away: "Sparta Rotterdam", awayAbbr: "SPA")
        // A channel explicitly naming both teams should still confirm.
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "PSV vs Sparta Rotterdam Live")
        ])
        #expect(ranked.first?.evidenceCategories.contains(.teamNameMatch) == true,
                "Whole-word match of both team names must still fire teamNameMatch")
    }

    // MARK: REG-001: Feed family incompatibility

    @Test("REG-001: NBA-branded channel is hard-rejected for MLB event")
    func nbaChannelRejectedForMLBEvent() {
        let m = pMatch(league: mlbLeague,
                       home: "New York Yankees", homeAbbr: "NYY",
                       away: "San Diego Padres", awayAbbr: "SDP")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "NBA: San Antonio @ New York")
        ])
        // Feed family: channel = .nba, event = .mlb → incompatible → hard reject.
        #expect(ranked.isEmpty,
                "NBA-branded channel must be hard-rejected for an MLB event (wrong sport)")
    }

    @Test("Feed family: NHL channel rejected for NBA event")
    func nhlChannelRejectedForNBAEvent() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(league: nba,
                       home: "Boston Celtics", homeAbbr: "BOS",
                       away: "Miami Heat", awayAbbr: "MIA")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "NHL Network HD")
        ])
        #expect(ranked.isEmpty,
                "NHL Network channel must be hard-rejected for an NBA event")
    }

    @Test("Feed family: AHL channel rejected for NHL event")
    func ahlChannelRejectedForNHLEvent() {
        let m = pMatch(league: nhlLeague,
                       home: "Toronto Maple Leafs", homeAbbr: "TOR",
                       away: "Ottawa Senators", awayAbbr: "OTT")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "AHL TV Live")
        ])
        // AHL and NHL are in the same sport group but explicitly incompatible competition levels.
        #expect(ranked.isEmpty,
                "AHL-branded channel must be hard-rejected for an NHL event")
    }

    @Test("Feed family: generic Sports channel passes through for any sport")
    func genericSportsChannelNotRejected() {
        let m = pMatch(league: mlbLeague,
                       home: "New York Yankees", homeAbbr: "NYY",
                       away: "San Diego Padres", awayAbbr: "SDP",
                       broadcasts: ["ESPN"])
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "ESPN HD", group: "Sports")
        ])
        // Generic "ESPN HD" has unknown feed family → not rejected by incompatibility check.
        #expect(!ranked.isEmpty,
                "Generic sports broadcaster without a sport-exclusive keyword must not be feed-family rejected")
    }

    // MARK: REG-012: Racing session conflict

    @Test("REG-012: F1 Qualifying channel is hard-rejected for F1 Race event")
    func f1QualifyingChannelRejectedForRaceEvent() {
        let m = pMatch(league: f1League,
                       home: "Max Verstappen", homeAbbr: "VER",
                       away: "Charles Leclerc", awayAbbr: "LEC",
                       name: "Formula 1 Italian Grand Prix Race",
                       shortName: "F1 Italian GP Race")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "F1 Italian GP Qualifying")
        ])
        // eventSession=.race, channelSession=.qualifying → hard reject (HC-010).
        #expect(ranked.isEmpty,
                "F1 Qualifying channel must be hard-rejected for an F1 Race event")
    }

    @Test("Racing session: F1 Race channel passes for F1 Race event")
    func f1RaceChannelPassesForRaceEvent() {
        let m = pMatch(league: f1League,
                       home: "Max Verstappen", homeAbbr: "VER",
                       away: "Charles Leclerc", awayAbbr: "LEC",
                       name: "Formula 1 Italian Grand Prix Race",
                       shortName: "F1 Italian GP Race")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Sky Sports F1 Race")
        ])
        // channelSession=.race matches eventSession=.race → no session conflict.
        #expect(!ranked.isEmpty,
                "F1 Race channel must not be rejected for an F1 Race event")
    }

    @Test("Racing session: Practice channel rejected for Race event")
    func f1PracticeChannelRejectedForRaceEvent() {
        let m = pMatch(league: f1League,
                       home: "Max Verstappen", homeAbbr: "VER",
                       away: "Charles Leclerc", awayAbbr: "LEC",
                       name: "Formula 1 Italian Grand Prix Race",
                       shortName: "F1 Italian GP Race")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "F1 Italian GP FP1 Practice")
        ])
        #expect(ranked.isEmpty,
                "F1 Practice channel must be hard-rejected for an F1 Race event")
    }

    @Test("Racing session: channel with unknown session is not rejected")
    func f1ChannelWithUnknownSessionNotRejected() {
        let m = pMatch(league: f1League,
                       home: "Max Verstappen", homeAbbr: "VER",
                       away: "Charles Leclerc", awayAbbr: "LEC",
                       name: "Formula 1 Italian Grand Prix Race",
                       shortName: "F1 Italian GP Race")
        // A generic F1 channel with no session keyword should not be rejected.
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Sky Sports F1 HD")
        ])
        #expect(!ranked.isEmpty,
                "F1 channel with no session keyword must not be session-conflict rejected")
    }

    // MARK: City / United stop-word fix (soccer identity)

    @Test("Soccer: 'city' token distinguishes Manchester City from Manchester United")
    func cityTokenDistinguishesManchesterCity() {
        let m = pMatch(league: eplLeagueP,
                       home: "Manchester City", homeShort: "Man City", homeAbbr: "MCI",
                       away: "Manchester United", awayShort: "Man Utd", awayAbbr: "MUN")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Manchester City TV")
        ])
        // "city" is no longer a stop word, so distinctHome = ["city"] after removing shared "manchester".
        // "city" matches; "united" doesn't → single-side hit, NOT teamNameMatch.
        if let source = ranked.first {
            #expect(!source.evidenceCategories.contains(.teamNameMatch),
                    "'city' alone must not confirm both teams — only one side matched")
        }
    }

    @Test("Soccer: 'united' token distinguishes Manchester United from Manchester City")
    func unitedTokenDistinguishesManchesterUnited() {
        let m = pMatch(league: eplLeagueP,
                       home: "Manchester City", homeShort: "Man City", homeAbbr: "MCI",
                       away: "Manchester United", awayShort: "Man Utd", awayAbbr: "MUN")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Manchester United Live")
        ])
        if let source = ranked.first {
            #expect(!source.evidenceCategories.contains(.teamNameMatch),
                    "'united' alone must not confirm both teams — only one side matched")
        }
    }

    @Test("Soccer: channel naming both City and United confirms both teams")
    func bothDistinctTokensConfirmTeams() {
        let m = pMatch(league: eplLeagueP,
                       home: "Manchester City", homeShort: "Man City", homeAbbr: "MCI",
                       away: "Manchester United", awayShort: "Man Utd", awayAbbr: "MUN")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "Manchester City vs Manchester United Live")
        ])
        #expect(ranked.first?.evidenceCategories.contains(.teamNameMatch) == true,
                "Both city and united present → teamNameMatch must fire")
    }

    // MARK: REG-011: Numbered event slot — POSSIBLE only

    @Test("REG-011: NCAAF numbered slot is not confirmed without EPG")
    func ncaafNumberedSlotNotConfirmed() {
        let m = pMatch(league: ncaafLeague,
                       home: "Alabama Crimson Tide", homeAbbr: "ALA",
                       away: "Georgia Bulldogs", awayAbbr: "UGA")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "NCAAF 37")
        ])
        // The slot may surface as a candidate via league keywords but must not be confirmed.
        if let source = ranked.first {
            #expect(!source.isConfirmed,
                    "Numbered event slot 'NCAAF 37' must not be confirmed without EPG")
            #expect(source.matchStatus == .possible,
                    "Numbered slot without EPG must have matchStatus == .possible")
        }
    }

    @Test("NBA numbered slot not confirmed without EPG")
    func nbaNumberedSlotNotConfirmed() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(league: nba,
                       home: "Los Angeles Lakers", homeAbbr: "LAL",
                       away: "Boston Celtics", awayAbbr: "BOS")
        let ranked = SourceMatcher.rank(match: m, channels: [
            pChannel(name: "NBA 14")
        ])
        if let source = ranked.first {
            #expect(!source.isConfirmed,
                    "Numbered event slot 'NBA 14' must not be confirmed without EPG")
        }
    }

    // MARK: MatchStatus

    @Test("MatchStatus: confirmed source maps to .confirmed")
    func matchStatusConfirmedSource() {
        var source = RankedSource(channel: pChannel(name: "Test"), score: 100)
        source.evidenceCategories = [.teamNameMatch]
        #expect(source.matchStatus == .confirmed)
    }

    @Test("MatchStatus: possible source maps to .possible")
    func matchStatusPossibleSource() {
        var source = RankedSource(channel: pChannel(name: "Test"), score: 35)
        source.evidenceCategories = [.broadcastRightsMatch]
        #expect(source.matchStatus == .possible)
    }

    // MARK: MatchPlaybackContext requestGenerationID

    @Test("MatchPlaybackContext: requestGenerationID is unique per context by default")
    func requestGenerationIDIsUnique() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(id: "g-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                       away: "Celtics", awayAbbr: "BOS")
        let ch = pChannel(id: "ch-001", name: "ESPN HD")
        let ctx1 = MatchPlaybackContext(match: m, channel: ch)
        let ctx2 = MatchPlaybackContext(match: m, channel: ch)
        // Two separate context objects must have different generation IDs.
        #expect(ctx1.requestGenerationID != ctx2.requestGenerationID,
                "Each MatchPlaybackContext must get a fresh UUID so stale async results can be detected")
    }

    @Test("MatchPlaybackContext: stable id despite different requestGenerationID")
    func contextIDStableAcrossGenerations() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(id: "g-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                       away: "Celtics", awayAbbr: "BOS")
        let ch = pChannel(id: "ch-001", name: "ESPN HD")
        let ctx1 = MatchPlaybackContext(match: m, channel: ch)
        let ctx2 = MatchPlaybackContext(match: m, channel: ch)
        // `id` is used for SwiftUI identity — it must be deterministic.
        #expect(ctx1.id == ctx2.id,
                "Context id (match+channel) must be stable regardless of requestGenerationID")
    }

    // MARK: SportsOntology unit tests

    @Test("SportsOntology: NBA feed family classified from channel name")
    func feedFamilyNBAFromChannelName() {
        #expect(SportsOntology.classifyFeedFamily(from: "NBA: San Antonio @ New York") == .nba)
    }

    @Test("SportsOntology: WNBA not misclassified as NBA")
    func feedFamilyWNBANotNBA() {
        #expect(SportsOntology.classifyFeedFamily(from: "WNBA Game of the Week") == .wnba)
    }

    @Test("SportsOntology: AHL classified from channel name")
    func feedFamilyAHLFromChannelName() {
        #expect(SportsOntology.classifyFeedFamily(from: "AHL Hockey Live") == .ahl)
    }

    @Test("SportsOntology: generic ESPN unknown feed family")
    func feedFamilyESPNIsUnknown() {
        #expect(SportsOntology.classifyFeedFamily(from: "ESPN HD") == .unknown)
    }

    @Test("SportsOntology: NBA incompatible with MLB")
    func nbaIncompatibleWithMLB() {
        #expect(SportsOntology.isIncompatible(candidate: .nba, with: .mlb))
    }

    @Test("SportsOntology: AHL incompatible with NHL")
    func ahlIncompatibleWithNHL() {
        #expect(SportsOntology.isIncompatible(candidate: .ahl, with: .nhl))
    }

    @Test("SportsOntology: same family not incompatible")
    func sameFamilyNotIncompatible() {
        #expect(!SportsOntology.isIncompatible(candidate: .nhl, with: .nhl))
    }

    @Test("SportsOntology: unknown candidate never incompatible")
    func unknownCandidateNeverIncompatible() {
        #expect(!SportsOntology.isIncompatible(candidate: .unknown, with: .nba))
    }

    @Test("SportsOntology: numbered slot detected — NCAAF 37")
    func numberedSlotNCAAF37() {
        #expect(SportsOntology.isNumberedEventSlot("NCAAF 37"))
    }

    @Test("SportsOntology: numbered slot detected — NHL GAME 07")
    func numberedSlotNHLGame07() {
        #expect(SportsOntology.isNumberedEventSlot("NHL GAME 07"))
    }

    @Test("SportsOntology: named channel not flagged as numbered slot")
    func namedChannelNotNumberedSlot() {
        #expect(!SportsOntology.isNumberedEventSlot("Sky Sports Premier League"))
    }
}
