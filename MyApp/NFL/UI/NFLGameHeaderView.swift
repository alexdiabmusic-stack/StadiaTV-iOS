import SwiftUI

struct NFLGameHeaderView: View {
    let game: NFLGameState
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
            if [.live, .halftime, .delayed].contains(game.status), let possession = game.possession {
                HStack { Label("\(possession.abbreviation) BALL", systemImage: "american.football.fill")
                    if let down = game.downDistance { Text(down).bold() }
                    if let field = game.field { Text(field.text) }
                }.font(.subheadline)
                if game.isRedZone == true { Text("RED ZONE").font(.caption.bold()) }
            }
        }.padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var status: String {
        if game.status == .halftime { return "HALFTIME" }
        if game.status == .live {
            let period = game.quarter.flatMap { value -> String? in
                if let number = Int(value) { return number > 4 ? "OT \(number - 4)" : "Q\(number)" }
                return ["FIRST": "Q1", "SECOND": "Q2", "THIRD": "Q3", "FOURTH": "Q4", "OVERTIME": "OT"][value] ?? value.replacingOccurrences(of: "_", with: " ")
            }
            return [period, game.clock].compactMap { $0 }.joined(separator: " • ")
        }
        return game.statusText.uppercased()
    }
    private func team(_ team: FootballTeamState) -> some View {
        NavigationLink {
            TeamRosterView(league: League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football), teamID: team.id, teamName: team.name)
        } label: {
            VStack(spacing: 5) {
                TeamLogo(url: team.logo, size: 44).accessibilityHidden(true)
                Text(team.abbreviation).font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(team.name). Team roster")
    }
}
