import Foundation
extension BannerPlayer {
    func toLegacyRosterAthlete() -> RosterAthlete {
        var athlete = RosterAthlete(
            id: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id ?? id.rawValue,
            displayName: displayName,
            jersey: jerseyNumber,
            position: position,
            positionName: position,
            headshotURL: headshotURL,
            age: nil,
            displayHeight: nil,
            displayWeight: nil,
            college: nil,
            experienceYears: nil,
            birthPlace: nil,
            isInjured: false
        )
        athlete.canonicalID = id.rawValue
        return athlete
    }
}

extension BannerStandingGroup {
    func toLegacyStandingsGroup() -> StandingsGroup {
        StandingsGroup(id: id.rawValue, name: name, rows: standings.map { $0.toLegacyStandingRow() })
    }
}

extension BannerStanding {
    func toLegacyStandingRow() -> StandingRow {
        StandingRow(
            teamID: SportsIdentityResolver.providerID(from: teamID, provider: .espn)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .appleSports)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .nhl)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .mlb)
                ?? teamID.rawValue,
            displayName: teamDisplayName ?? teamID.rawValue,
            abbreviation: teamAbbreviation ?? "",
            logoURL: teamLogoURL,
            record: displayRecord,
            wins: wins,
            losses: losses,
            ties: ties,
            winPercent: nil,
            gamesBack: nil,
            streak: nil,
            pointsFor: nil,
            pointsAgainst: nil,
            leaguePoints: points,
            gamesPlayed: gamesPlayed,
            goalDiff: nil
        )
    }
}

extension BannerLeader {
    func toLegacyLeaderBoard() -> LeaderBoard {
        LeaderBoard(
            id: id.rawValue,
            statName: statKey,
            displayName: displayName,
            rows: players.enumerated().map { index, row in
                let value = row.stats.first { $0.key == statKey }?.value ?? row.stats.first?.value ?? "--"
                return LeaderRow(
                    rank: index + 1,
                    athleteID: SportsIdentityResolver.providerID(from: row.playerID, provider: .espn)
                        ?? SportsIdentityResolver.providerID(from: row.playerID, provider: .appleSports)
                        ?? SportsIdentityResolver.providerID(from: row.playerID, provider: .mlb)
                        ?? row.playerID.rawValue,
                    displayName: row.playerDisplayName ?? row.playerID.rawValue,
                    teamAbbreviation: row.teamAbbreviation,
                    headshotURL: row.headshotURL,
                    value: value
                )
            }
        )
    }
}

extension BannerInjury {
    func toLegacyLeagueInjury() -> LeagueInjury {
        LeagueInjury(
            id: id.rawValue,
            athleteName: playerName,
            teamAbbreviation: nil,
            position: nil,
            status: status,
            detail: detail,
            headshotURL: nil
        )
    }
}

extension BannerNewsArticle {
    func toLegacyArticle(league: League) -> ESPNArticle {
        // Prefer author byline; fall back to publisher name for attribution.
        let displayByline = authorByline ?? publisher ?? sourceName
        return ESPNArticle(
            id: id.rawValue,
            headline: headline,
            description: description,
            published: published,
            url: url,
            imageURL: imageURL,
            league: league,
            byline: displayByline,
            type: articleType,
            isPremium: false,
            categories: []
        )
    }
}

