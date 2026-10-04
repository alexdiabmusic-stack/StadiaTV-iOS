import SwiftUI

struct BasketballGameHeaderView: View {
    let game: BasketballGame
    let league: League

    var body: some View {
        let status = BasketballGamePresentation.heroStatus(game: game)
        let teams = BasketballGamePresentation.heroTeams(game: game)
        VStack(spacing: 0) {
            GameScoreHero(
                league: league.shortName,
                status: status,
                away: teams.away,
                home: teams.home,
                awayDestination: { AnyView(TeamRosterView(league: league, teamID: String(game.away.id), teamName: game.away.displayName)) },
                homeDestination: { AnyView(TeamRosterView(league: league, teamID: String(game.home.id), teamName: game.home.displayName)) }
            )
            if game.status == .live {
                HStack(spacing: 20) {
                    timeouts(game.away, label: "\(game.away.tricode) TO")
                    if let broadcast = game.broadcasts.first { Text(broadcast).font(.caption).foregroundStyle(Theme.textSecondary) }
                    timeouts(game.home, label: "\(game.home.tricode) TO")
                }
                .padding(.bottom, Theme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
            }
        }
    }

    private func timeouts(_ team: BasketballTeam, label: String) -> some View {
        Group {
            if let remaining = team.timeoutsRemaining {
                HStack(spacing: 3) {
                    Text(label).font(.caption2.bold())
                    ForEach(0..<remaining, id: \.self) { _ in Image(systemName: "circle.fill").font(.caption2) }
                    if team.inBonus == true { Text("BONUS").font(.caption2.bold()).foregroundStyle(Theme.accessibleAccent) }
                }
            }
        }.accessibilityElement(children: .combine)
    }
}
