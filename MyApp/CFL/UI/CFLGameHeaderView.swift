import SwiftUI

struct CFLGameHeaderView: View {
    let game: CFLGameState
    var body: some View {
        VStack(spacing: 10) {
            Text(status).font(.subheadline.weight(.semibold))
            HStack(alignment: .center, spacing: 20) {
                team(game.away)
                if ![.scheduled, .pregame].contains(game.status), game.home.score != nil || game.away.score != nil {
                    Text("\(game.away.score.map(String.init) ?? "–") — \(game.home.score.map(String.init) ?? "–")")
                        .font(.largeTitle.bold()).monospacedDigit().minimumScaleFactor(0.6)
                        .accessibilityLabel("\(game.away.name) \(game.away.score.map(String.init) ?? "unknown"), \(game.home.name) \(game.home.score.map(String.init) ?? "unknown")")
                } else { Text(game.start, style: .time).font(.title2.bold()) }
                team(game.home)
            }
            if game.isOvertime, game.status == .live || game.status == .final { Text("OVERTIME").font(.caption.bold()) }
        }.padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var status: String {
        if game.status == .halftime { return "HALFTIME" }
        if game.status == .live { return [game.statusText, game.clock].compactMap { $0 }.joined(separator: " • ").uppercased() }
        return game.statusText.uppercased()
    }
    private func team(_ team: FootballTeamState) -> some View {
        NavigationLink {
            TeamRosterView(league: League(name: "CFL", shortName: "CFL", path: "football/cfl", group: .football), teamID: team.id, teamName: team.name)
        } label: {
            VStack(spacing: 5) {
                TeamLogo(url: team.logo, size: 44).accessibilityHidden(true)
                Text(team.abbreviation).font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(team.name). Team roster")
    }
}
