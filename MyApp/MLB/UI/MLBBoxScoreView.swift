import SwiftUI

struct MLBBoxScoreView: View {
    let snapshot: BaseballGameSnapshot
    let league: League
    @State private var home = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let game = snapshot.game {
                if let line = snapshot.line { MLBLineScoreView(line: line, game: game) }
                Picker("Team", selection: $home) {
                    Text(game.away.abbreviation).tag(false); Text(game.home.abbreviation).tag(true)
                }.pickerStyle(.segmented)
                let rows = snapshot.box.filter { $0.teamID == (home ? game.home.id : game.away.id) }
                table(rows.filter { !$0.batting.isEmpty }, pitching: false)
                table(rows.filter { !$0.pitching.isEmpty }, pitching: true)
                if rows.isEmpty { Text("Player statistics will appear when available.").foregroundStyle(.secondary) }
            }
        }.padding()
    }
    private func table(_ rows: [BaseballBoxPlayer], pitching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pitching ? "Pitching" : "Batting").font(.title3.bold())
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    MLBPlayerLink(player: row.player, league: league)
                    let stats = pitching ? row.pitching : row.batting
                    let keys = pitching ? ["inningsPitched", "hits", "runs", "earnedRuns", "baseOnBalls", "strikeOuts", "homeRuns", "numberOfPitches", "strikes"] : ["atBats", "runs", "hits", "rbi", "baseOnBalls", "strikeOuts", "homeRuns"]
                    let labels = pitching ? ["IP", "H", "R", "ER", "BB", "SO", "HR", "P", "S"] : ["AB", "R", "H", "RBI", "BB", "SO", "HR"]
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 10) {
                        ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                            VStack(spacing: 3) {
                                Text(labels[index]).font(.caption).foregroundStyle(.secondary)
                                Text(stats[key] ?? "–").font(.subheadline.monospacedDigit())
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}
