import SwiftUI

struct SoccerGameHeaderView: View {
    let match: SoccerMatch
    let league: League
    let homeLogo: URL?
    let awayLogo: URL?

    var body: some View {
        let status = SoccerGamePresentation.heroStatus(match: match)
        let teams = SoccerGamePresentation.heroTeams(match: match, homeLogo: homeLogo, awayLogo: awayLogo)
        GameScoreHero(
            league: league.shortName,
            status: status,
            away: teams.away,
            home: teams.home,
            awayDestination: { AnyView(TeamRosterView(league: league, teamID: match.away.team.id, teamName: match.away.team.name)) },
            homeDestination: { AnyView(TeamRosterView(league: league, teamID: match.home.team.id, teamName: match.home.team.name)) }
        )
    }
}
