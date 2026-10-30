import Foundation
nonisolated extension BannerPlayer {
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

nonisolated extension BannerStandingGroup {
    func toLegacyStandingsGroup() -> StandingsGroup {
        StandingsGroup(id: id.rawValue, name: name, rows: standings.map { $0.toLegacyStandingRow() })
    }
}

nonisolated extension BannerStanding {
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

nonisolated extension BannerLeader {
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

nonisolated extension BannerInjury {
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

nonisolated extension BannerNewsArticle {
    func toLegacyArticle(league: League) -> ESPNArticle {
        // Prefer author byline; fall back to publisher name for attribution.
        let displayByline = authorByline ?? publisher ?? sourceName
        // Preserve article-level league metadata instead of relabelling every
        // result with the feed requested by the caller.
        let classification = BannerNewsDeduplicator.classify(headline: headline, description: description)
        let ambiguous = BannerNewsDeduplicator.hasAmbiguousLeagueEvidence(headline: headline, description: description)
        let feedOnlyProviders: Set<SportsDataProviderID> = [.cbsRSS, .nbcSports, .foxRSS, .bbcSport, .skySports]
        let requiresContentEvidence = provenance.map { feedOnlyProviders.contains($0.provider) } ?? false
        let resolvedID = ambiguous ? nil : classification.leagueID ?? (requiresContentEvidence ? nil : leagueID)
        let resolvedLeague = resolvedID.flatMap { id in
            League.all.first { SportsIdentityResolver.canonicalLeagueID(for: $0) == id }
        }
        // Explicit content from another sport must never retain the feed's label.
        let conflicts = classification.sport.map { $0 != resolvedLeague?.group } ?? false
        let articleLeague = classification.leagueID.flatMap { id in
            League.all.first { SportsIdentityResolver.canonicalLeagueID(for: $0) == id }
        } ?? resolvedLeague ?? league
        let category = conflicts
            ? classification.sport.map { String(localized: String.LocalizationValue($0.rawValue)) }
            : resolvedLeague?.shortName ?? (classification.sport ?? (ambiguous ? nil : primarySport)).map { String(localized: String.LocalizationValue($0.rawValue)) }
        let validatedDate = published.flatMap { $0 <= Date().addingTimeInterval(300) ? $0 : nil }
        return ESPNArticle(
            id: id.rawValue,
            headline: headline,
            description: description,
            published: validatedDate,
            url: url,
            imageURL: imageURL,
            league: articleLeague,
            byline: displayByline,
            type: articleType,
            isPremium: false,
            categories: [],
            publisher: publisher ?? sourceName,
            validatedCategory: category ?? String(localized: "Sports"),
            relevantTeamIDs: teamIDs.map(\.rawValue)
        )
    }
}

