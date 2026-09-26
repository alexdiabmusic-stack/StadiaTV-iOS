import SwiftUI

struct BasketballGameLeadersView: View {
    let snapshot: BasketballGameSnapshot
    let league: League
    let config: BasketballLeagueConfiguration
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if let game = snapshot.game {
                column(title: game.away.tricode, leaders: snapshot.awayLeaders, fallback: game.awayLeader)
                column(title: game.home.tricode, leaders: snapshot.homeLeaders, fallback: game.homeLeader)
            }
        }
    }
    @ViewBuilder private func column(title: String, leaders: NBATeamGameLeaders?, fallback: NBAGameLeaderLine?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) leaders").font(.title3.bold())
            if let leaders {
                if let points = leaders.points { row(points, label: "PTS") }
                if let rebounds = leaders.rebounds { row(rebounds, label: "REB") }
                if let assists = leaders.assists { row(assists, label: "AST") }
            } else if let fallback {
                VStack(alignment: .leading, spacing: 2) {
                    BasketballPlayerLink(personID: fallback.personID ?? 0, name: fallback.name ?? "Unknown player", league: league, config: config)
                    Text([fallback.points.map { "\($0) PTS" }, fallback.rebounds.map { "\($0) REB" }, fallback.assists.map { "\($0) AST" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ leader: NBAStatLeader, label: String) -> some View {
        HStack {
            BasketballPlayerLink(personID: leader.personID, name: leader.name, league: league, config: config)
            Spacer()
            Text("\(leader.value) \(label)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
