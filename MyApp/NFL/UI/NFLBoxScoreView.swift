import SwiftUI

struct NFLBoxScoreView: View {
    let game: NFLGameState
    @State private var home = false
    private var players: [NFLPlayerStatistics] { NFLStatisticsMapper.players(game.plays).filter { $0.teamID == (home ? game.home.id : game.away.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FootballQuarterScoreView(home: game.home, away: game.away, overtimeActive: game.quarter?.contains("OVERTIME") == true)
            Picker("Team", selection: $home) { Text(game.away.abbreviation).tag(false); Text(game.home.abbreviation).tag(true) }.pickerStyle(.segmented)
            section("Passing", players.filter { $0.passingAttempts > 0 }) { "\($0.completions)/\($0.passingAttempts) • \($0.passingYards.map(String.init) ?? "–") YDS • \($0.passingTouchdowns) TD • \($0.interceptions) INT" }
            section("Rushing", players.filter { $0.carries > 0 || $0.rushingYards != 0 }) { "\($0.carries) CAR • \($0.rushingYards.map(String.init) ?? "–") YDS • \($0.rushingTouchdowns) TD" }
            section("Receiving", players.filter { $0.receptions > 0 || $0.receivingYards != 0 }) { "\($0.receptions) REC • \($0.receivingYards.map(String.init) ?? "–") YDS • \($0.receivingTouchdowns) TD" }
            section("Defense", players.filter { $0.tackles + $0.assists + $0.defensiveInterceptions > 0 || $0.sacks > 0 }) { "\($0.tackles) TKL • \($0.assists) AST • \($0.sacks.formatted()) SACK • \($0.defensiveInterceptions) INT" }
            section("Kicking", players.filter { $0.fieldGoalAttempts + $0.extraPointAttempts > 0 }) { "\($0.fieldGoals)/\($0.fieldGoalAttempts) FG • \($0.extraPoints)/\($0.extraPointAttempts) XP" }
            section("Punting", players.filter { $0.punts > 0 }) { "\($0.punts) PUNTS • \($0.puntYards.map(String.init) ?? "–") YDS" }
            if players.isEmpty { ContentUnavailableView("No player statistics yet", systemImage: "list.bullet.rectangle") }
        }.padding()
    }
    private func section(_ title: String, _ players: [NFLPlayerStatistics], line: @escaping (NFLPlayerStatistics) -> String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !players.isEmpty {
                Text(title).font(.title3.bold())
                ForEach(players) { player in
                    VStack(alignment: .leading, spacing: 4) { Text(player.name).font(.headline); Text(line(player)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
struct NFLStatsView: View {
    let game: NFLGameState
    private func total(_ team: String, codes: Set<Int>, yards: Bool = false) -> String {
        let records = game.plays.flatMap(\.participants).filter { $0.teamID == team && codes.contains($0.rawStatType ?? -1) }
        if !yards { return String(records.count) }
        guard records.allSatisfy({ $0.yards != nil }) else { return "–" }
        return String(records.compactMap(\.yards).reduce(0, +))
    }
    var body: some View {
        VStack(spacing: 20) {
            if game.plays.flatMap(\.participants).isEmpty {
                ContentUnavailableView("No team statistics yet", systemImage: "chart.bar", description: Text("Statistics will appear when the game begins."))
            } else {
            row("First downs", codes: [3, 4, 5])
            row("Rushing yards", codes: [10, 11, 12, 13], yards: true)
            row("Net passing yards", codes: [15, 16, 20], yards: true)
            row("Total yards", codes: [10, 11, 12, 13, 15, 16, 20], yards: true)
            row("Penalties", codes: [93])
            row("Penalty yards", codes: [93], yards: true)
            }
        }.padding()
    }
    private func row(_ title: String, codes: Set<Int>, yards: Bool = false) -> some View {
        VStack(spacing: 8) { Text(title).font(.headline); HStack {
            Text("\(game.away.abbreviation)  \(total(game.away.id, codes: codes, yards: yards))")
            Spacer()
            Text("\(game.home.abbreviation)  \(total(game.home.id, codes: codes, yards: yards))")
        }.monospacedDigit() }.accessibilityElement(children: .combine)
    }
}
