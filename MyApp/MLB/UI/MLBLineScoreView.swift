import SwiftUI

struct MLBLineScoreView: View {
    let line: BaseballLineScore
    let game: BaseballGame
    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Team")
                    ForEach(line.innings) { inning in Text("\(inning.id)") }
                    Text("R").bold(); Text("H"); Text("E")
                }.foregroundStyle(.secondary)
                row(game.away, home: false)
                row(game.home, home: true)
            }.font(.subheadline.monospacedDigit()).padding()
        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func row(_ team: BaseballTeam, home: Bool) -> some View {
        GridRow {
            Text(team.abbreviation).bold()
            ForEach(line.innings) { inning in
                Text((home ? inning.homeRuns : inning.awayRuns).map(String.init) ?? "–")
                    .accessibilityLabel("\(team.name), inning \(inning.id), \((home ? inning.homeRuns : inning.awayRuns).map(String.init) ?? "not played")")
            }
            Text((home ? line.homeRuns : line.awayRuns).map(String.init) ?? "–").bold()
            Text((home ? line.homeHits : line.awayHits).map(String.init) ?? "–")
            Text((home ? line.homeErrors : line.awayErrors).map(String.init) ?? "–")
        }
    }
}
struct MLBCurrentMatchupView: View {
    let snapshot: BaseballGameSnapshot
    let league: League
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let line = snapshot.line, snapshot.game?.status == .live, !line.betweenInnings {
                player(line.batter, label: "Batter", pitching: false)
                player(line.pitcher, label: "Pitcher", pitching: true)
            } else if let game = snapshot.game, [.scheduled, .pregame, .warmup].contains(game.status) {
                player(game.probableAway, label: "Probable pitcher · \(game.away.abbreviation)", pitching: true)
                player(game.probableHome, label: "Probable pitcher · \(game.home.abbreviation)", pitching: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
    @ViewBuilder private func player(_ player: BaseballPlayerReference?, label: String, pitching: Bool) -> some View {
        if let player {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                MLBPlayerLink(player: player, league: league)
                if let row = snapshot.box.first(where: { $0.player.id == player.id }) {
                    let stats = pitching ? row.pitching : row.batting
                    let keys = pitching ? ["inningsPitched", "hits", "earnedRuns", "strikeOuts", "numberOfPitches"] : ["hits", "atBats", "homeRuns", "rbi"]
                    let labels = pitching ? ["IP", "H", "ER", "K", "pitches"] : ["H", "AB", "HR", "RBI"]
                    Text(zip(keys, labels).compactMap { key, label in stats[key].map { "\($0) \(label)" } }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
struct MLBPlayerLink: View {
    let player: BaseballPlayerReference
    let league: League
    var body: some View {
        NavigationLink {
            PlayerDetailView(league: league, athlete: MLBLegacyMapper.athlete(player))
        } label: { Text(player.name).font(.headline).frame(minHeight: 44, alignment: .leading) }
        .buttonStyle(.plain)
    }
}
