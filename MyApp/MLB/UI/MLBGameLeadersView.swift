import SwiftUI

struct MLBGameLeadersView: View {
    let players: [BaseballBoxPlayer]
    let league: League
    private var hitters: [BaseballBoxPlayer] {
        Array(players.filter { (Int($0.batting["hits"] ?? "") ?? 0) > 0 }.sorted {
            (Int($0.batting["rbi"] ?? "") ?? 0, Int($0.batting["hits"] ?? "") ?? 0) > (Int($1.batting["rbi"] ?? "") ?? 0, Int($1.batting["hits"] ?? "") ?? 0)
        }.prefix(3))
    }
    var body: some View {
        if !hitters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Batting leaders").font(.title3.bold())
                ForEach(hitters) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        MLBPlayerLink(player: row.player, league: league)
                        Text([row.batting["hits"].map { "\($0) H" }, row.batting["rbi"].map { "\($0) RBI" }, row.batting["homeRuns"].map { "\($0) HR" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
