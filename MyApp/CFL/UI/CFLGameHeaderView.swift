import SwiftUI

struct CFLGameHeaderView: View {
    let game: CFLGameState
    let league: League

    var body: some View {
        let status = CFLGamePresentation.heroStatus(game: game)
        let teams = CFLGamePresentation.heroTeams(game: game)
        GameScoreHero(
            league: league.shortName,
            status: status,
            away: teams.away,
            home: teams.home,
            awayDestination: { AnyView(TeamRosterView(league: league, teamID: game.away.id, teamName: game.away.name)) },
            homeDestination: { AnyView(TeamRosterView(league: league, teamID: game.home.id, teamName: game.home.name)) }
        )
    }
}
