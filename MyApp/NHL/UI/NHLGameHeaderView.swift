import SwiftUI

struct NHLGameHeaderView: View {
    let game: HockeyGame
    let league: League

    var body: some View {
        let status = NHLGamePresentation.heroStatus(game: game)
        let teams = NHLGamePresentation.heroTeams(game: game)
        GameScoreHero(
            league: league.shortName,
            status: status,
            away: teams.away,
            home: teams.home,
            awayDestination: { AnyView(TeamRosterView(league: league, teamID: String(game.away.id), teamName: game.away.name)) },
            homeDestination: { AnyView(TeamRosterView(league: league, teamID: String(game.home.id), teamName: game.home.name)) }
        )
    }
}
