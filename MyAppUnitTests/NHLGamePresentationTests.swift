import Foundation
import Testing
@testable import BannerTV

@Suite("NHLGamePresentation")
struct NHLGamePresentationTests {

    private func period(_ number: Int, kind: String, regulation: Int = 3) -> HockeyPeriod {
        HockeyPeriod(raw: .object(["number": .number(Double(number)), "periodType": .string(kind), "maxRegulationPeriods": .number(Double(regulation))]))
    }

    private let away = HockeyTeam(id: 1, abbreviation: "SJS", name: "San Jose Sharks", logo: nil, score: 1, shots: 24)
    private let home = HockeyTeam(id: 2, abbreviation: "LAK", name: "Los Angeles Kings", logo: nil, score: 2, shots: 36)

    private func game() -> HockeyGame {
        HockeyGame(id: 1, start: Date(), status: .live, period: period(2, kind: "REG"), clock: "10:00",
                   secondsRemaining: 600, clockRunning: true, intermission: false, home: home, away: away,
                   broadcasts: [], venue: "SAP Center", gameCenterURL: nil)
    }

    private func player(_ id: Int, name: String, teamID: Int) -> HockeyPlayerReference {
        HockeyPlayerReference(id: id, name: name, teamID: teamID, jersey: nil, position: nil, headshot: nil)
    }

    // MARK: - Timeline

    @Test("Goals are ordered chronologically with the score and team attached")
    func timelineOrdersGoalsChronologically() {
        let first = HockeyPlayEvent(id: "1", nhlEventID: nil, sortOrder: 1, period: period(1, kind: "REG"), timeInPeriod: "15:50",
                                     timeRemaining: nil, eventType: .goal, teamID: 2, title: "Kempe scores", subtitle: nil,
                                     xCoordinate: nil, yCoordinate: nil, homeTeamDefendingSide: nil, homeScore: 1, awayScore: 0,
                                     homeShots: nil, awayShots: nil, primaryPlayer: player(100, name: "Adrian Kempe", teamID: 2),
                                     secondaryPlayer: nil, tertiaryPlayer: nil, assists: [], shotType: "slap", strength: nil,
                                     videoURL: nil, rawSituationCode: nil, shootoutRound: nil)
        let second = HockeyPlayEvent(id: "2", nhlEventID: nil, sortOrder: 2, period: period(1, kind: "REG"), timeInPeriod: "08:21",
                                      timeRemaining: nil, eventType: .goal, teamID: 1, title: "Celebrini scores", subtitle: nil,
                                      xCoordinate: nil, yCoordinate: nil, homeTeamDefendingSide: nil, homeScore: 1, awayScore: 1,
                                      homeShots: nil, awayShots: nil, primaryPlayer: player(200, name: "Macklin Celebrini", teamID: 1),
                                      secondaryPlayer: nil, tertiaryPlayer: nil, assists: [], shotType: "wrist", strength: nil,
                                      videoURL: nil, rawSituationCode: nil, shootoutRound: nil)
        let events = NHLGamePresentation.timeline(events: [first, second], game: game())
        #expect(events.map(\.id) == ["1", "2"])
        #expect(events[0].teamAbbreviation == "LAK")
        #expect(events[0].scoreAfter == "0–1")
        #expect(events[1].teamAbbreviation == "SJS")
        #expect(events[1].scoreAfter == "1–1")
    }

    @Test("Power-play and empty-net strength map to badges")
    func timelineMapsStrengthBadges() {
        let pp = HockeyPlayEvent(id: "1", nhlEventID: nil, sortOrder: 1, period: period(1, kind: "REG"), timeInPeriod: "10:00",
                                  timeRemaining: nil, eventType: .goal, teamID: 2, title: "", subtitle: nil, xCoordinate: nil, yCoordinate: nil,
                                  homeTeamDefendingSide: nil, homeScore: 1, awayScore: 0, homeShots: nil, awayShots: nil,
                                  primaryPlayer: nil, secondaryPlayer: nil, tertiaryPlayer: nil, assists: [], shotType: nil,
                                  strength: "Power-play goal", videoURL: nil, rawSituationCode: nil, shootoutRound: nil)
        let en = HockeyPlayEvent(id: "2", nhlEventID: nil, sortOrder: 2, period: period(3, kind: "REG"), timeInPeriod: "01:00",
                                  timeRemaining: nil, eventType: .goal, teamID: 1, title: "", subtitle: nil, xCoordinate: nil, yCoordinate: nil,
                                  homeTeamDefendingSide: nil, homeScore: 1, awayScore: 1, homeShots: nil, awayShots: nil,
                                  primaryPlayer: nil, secondaryPlayer: nil, tertiaryPlayer: nil, assists: [], shotType: nil,
                                  strength: "Empty-net goal", videoURL: nil, rawSituationCode: nil, shootoutRound: nil)
        let events = NHLGamePresentation.timeline(events: [pp, en], game: game())
        #expect(events[0].badges == [.powerPlay])
        #expect(events[1].badges == [.emptyNet])
    }

    @Test("Non-goal events are excluded from the scoring timeline")
    func timelineExcludesNonGoals() {
        let hit = HockeyPlayEvent(id: "1", nhlEventID: nil, sortOrder: 1, period: period(1, kind: "REG"), timeInPeriod: "10:00",
                                   timeRemaining: nil, eventType: .hit, teamID: 2, title: "", subtitle: nil, xCoordinate: nil, yCoordinate: nil,
                                   homeTeamDefendingSide: nil, homeScore: nil, awayScore: nil, homeShots: nil, awayShots: nil,
                                   primaryPlayer: nil, secondaryPlayer: nil, tertiaryPlayer: nil, assists: [], shotType: nil, strength: nil,
                                   videoURL: nil, rawSituationCode: nil, shootoutRound: nil)
        #expect(NHLGamePresentation.timeline(events: [hit], game: game()).isEmpty)
    }

    // MARK: - Leaders

    @Test("Skaters with zero points are excluded from leaders")
    func leadersExcludeZeroPointSkaters() {
        let zero = HockeyPlayerGameStats(id: 1, teamID: 2, group: "Forwards", player: player(1, name: "Zero Point", teamID: 2),
                                          stats: [HockeyStat(id: "points", label: "PTS", value: "0"), HockeyStat(id: "goals", label: "G", value: "0"), HockeyStat(id: "assists", label: "A", value: "0")])
        let leaders = NHLGamePresentation.leaders(players: [zero], game: game())
        #expect(leaders.isEmpty)
    }

    @Test("The top skater by points is selected for each team")
    func leadersSelectTopSkaterByPoints() {
        let low = HockeyPlayerGameStats(id: 1, teamID: 2, group: "Forwards", player: player(1, name: "Low Point", teamID: 2),
                                         stats: [HockeyStat(id: "points", label: "PTS", value: "1"), HockeyStat(id: "goals", label: "G", value: "1"), HockeyStat(id: "assists", label: "A", value: "0")])
        let high = HockeyPlayerGameStats(id: 2, teamID: 2, group: "Forwards", player: player(2, name: "High Point", teamID: 2),
                                          stats: [HockeyStat(id: "points", label: "PTS", value: "3"), HockeyStat(id: "goals", label: "G", value: "2"), HockeyStat(id: "assists", label: "A", value: "1")])
        let leaders = NHLGamePresentation.leaders(players: [low, high], game: game())
        #expect(leaders.first?.name == "High Point")
        #expect(leaders.first?.statLine == "2 G · 1 A")
    }

    // MARK: - Key stats

    @Test("Key stats follow the curated order and skip missing categories")
    func keyStatsFollowCuratedOrderAndSkipMissing() {
        let stats = [
            HockeyTeamComparison(id: "takeaways", label: "Takeaways", away: "5", home: "6"),
            HockeyTeamComparison(id: "sog", label: "Shots on goal", away: "24", home: "36"),
            HockeyTeamComparison(id: "hits", label: "Hits", away: "19", home: "24")
        ]
        let keyStats = NHLGamePresentation.keyStats(teamStats: stats, game: game())
        #expect(keyStats.map(\.id) == ["sog", "hits", "takeaways"], "Order follows the curated list, not the input order, and skips ids with no data (faceoff/powerPlay/blockedShots/giveaways here)")
    }

    @Test("Power play percentage is attached as secondary text")
    func powerPlaySecondaryText() {
        let stats = [
            HockeyTeamComparison(id: "powerPlay", label: "Power plays", away: "2/3", home: "1/2"),
            HockeyTeamComparison(id: "powerPlayPctg", label: "Power-play %", away: "66.7%", home: "50.0%")
        ]
        let keyStats = NHLGamePresentation.keyStats(teamStats: stats, game: game())
        let pp = keyStats.first { $0.id == "powerPlay" }
        #expect(pp?.awaySecondary == "66.7%")
        #expect(pp?.homeSecondary == "50.0%")
    }
}
