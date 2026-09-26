import SwiftUI

struct CFLBoxScoreView: View {
    let game: CFLGameState
    let players: [CFLPlayerGameLine]
    @State private var home = false
    private var filtered: [CFLPlayerGameLine] { players.filter { $0.teamID == (home ? game.home.id : game.away.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FootballQuarterScoreView(home: game.home, away: game.away, overtimeActive: game.isOvertime)
            Picker("Team", selection: $home) { Text(game.away.abbreviation).tag(false); Text(game.home.abbreviation).tag(true) }.pickerStyle(.segmented)
            section("Passing", filtered.filter { ($0.stats["passesAttempted"] ?? 0) > 0 }) {
                "\(Int($0.stats["passesSucceeded"] ?? 0))/\(Int($0.stats["passesAttempted"] ?? 0)) • \(Int($0.stats["passesSucceededYards"] ?? 0)) YDS • \(Int($0.stats["touchdownsPasses"] ?? 0)) TD • \(Int($0.stats["passesIntercepted"] ?? 0)) INT"
            }
            section("Rushing", filtered.filter { ($0.stats["rushes"] ?? 0) > 0 }) {
                "\(Int($0.stats["rushes"] ?? 0)) CAR • \(Int($0.stats["rushingYards"] ?? 0)) YDS • \(Int($0.stats["touchdownsRushing"] ?? 0)) TD"
            }
            section("Receiving", filtered.filter { ($0.stats["receptions"] ?? 0) > 0 }) {
                "\(Int($0.stats["receptions"] ?? 0)) REC • \(Int($0.stats["receptionsYards"] ?? 0)) YDS • \(Int($0.stats["touchdownsReceptions"] ?? 0)) TD"
            }
            section("Defence", filtered.filter { ($0.stats["tackles"] ?? 0) + ($0.stats["sacks"] ?? 0) + ($0.stats["interceptions"] ?? 0) > 0 }) {
                "\(Int($0.stats["tackles"] ?? 0)) TKL • \(($0.stats["sacks"] ?? 0).formatted()) SACK • \(Int($0.stats["interceptions"] ?? 0)) INT"
            }
            section("Kicking", filtered.filter { ($0.stats["fieldGoalsAttempted"] ?? 0) > 0 || ($0.stats["singles"] ?? 0) > 0 }) {
                "\(Int($0.stats["fieldGoalsSucceeded"] ?? 0))/\(Int($0.stats["fieldGoalsAttempted"] ?? 0)) FG • \(Int($0.stats["singles"] ?? 0)) SINGLE"
            }
            if filtered.isEmpty { ContentUnavailableView("No player statistics yet", systemImage: "list.bullet.rectangle") }
        }.padding()
    }
    private func section(_ title: String, _ rows: [CFLPlayerGameLine], line: @escaping (CFLPlayerGameLine) -> String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !rows.isEmpty {
                Text(title).font(.title3.bold())
                ForEach(rows) { player in
                    VStack(alignment: .leading, spacing: 4) { Text(player.name).font(.headline); Text(line(player)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
struct CFLStatsView: View {
    let home: CFLValue
    let away: CFLValue
    let homeAbbreviation: String
    let awayAbbreviation: String
    @State private var showMore = false
    var body: some View {
        let rows = CFLTeamStatsMapper.rows(home: home, away: away)
        VStack(spacing: 20) {
            ForEach(rows.primary) { row(homeAbbreviation, awayAbbreviation, $0) }
            if !rows.more.isEmpty {
                Button(showMore ? "Hide more stats" : "More stats") { showMore.toggle() }.buttonStyle(.bordered)
                if showMore { ForEach(rows.more) { row(homeAbbreviation, awayAbbreviation, $0) } }
            }
        }.padding()
    }
    private func row(_ home: String, _ away: String, _ stat: CFLTeamStatsMapper.Row) -> some View {
        VStack(spacing: 8) { Text(stat.title).font(.headline); HStack {
            Text("\(away)  \(stat.away)")
            Spacer()
            Text("\(home)  \(stat.home)")
        }.monospacedDigit() }.accessibilityElement(children: .combine)
    }
}
