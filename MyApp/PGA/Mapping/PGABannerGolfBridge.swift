import Foundation

/// Bridges the rich native `Golf*` domain into the app's pre-existing
/// generic `BannerGolfTournament` shape. This exists purely so
/// `SportsRepository.golfTournament(for:gameID:)` — the app's
/// capability-routed, sport-agnostic entry point already wired through
/// `GameCentreContainerView`/`GolfGameCentre` — has a real implementation
/// instead of an always-throwing stub. The primary PGA experience is the
/// bespoke `PGATournamentCentreView` (STEP 59-60), which consumes the native
/// `Golf*` domain directly and never goes through this bridge.
nonisolated enum PGABannerGolfBridge {
    static func tournament(_ tournament: GolfTournament, leaderboard: [GolfLeaderboardEntry], league: League) -> BannerGolfTournament {
        let leagueID = SportsIdentityResolver.canonicalLeagueID(for: league)
        let gameID = BannerEntityID(rawValue: tournament.id)
        let provenance = DataProvenance(provider: .pga, fetchedAt: Date(), providerEntityID: tournament.id, confidence: 1)

        return BannerGolfTournament(
            id: gameID,
            leagueID: leagueID,
            gameID: gameID,
            tournamentName: tournament.name,
            tourName: "PGA TOUR",
            status: bannerStatus(tournament.status),
            statusDetail: tournament.roundStatusDisplay ?? tournament.roundDisplay,
            currentRound: tournament.currentRound,
            totalRounds: tournament.format.supportsStandardStrokePlayAssumptions ? 4 : nil,
            course: tournament.hostCourse.map(course),
            cutLine: nil,
            leaderboard: leaderboard.map { entry(tournamentID: tournament.id, entry: $0, provider: provenance) },
            broadcasts: [],
            stats: [],
            provenance: provenance
        )
    }

    private static func bannerStatus(_ status: GolfTournamentStatus) -> BannerTournamentStatus {
        switch status {
        case .scheduled, .roundNotStarted: return .upcoming
        case .roundInProgress: return .live
        case .roundSuspended: return .suspended
        case .roundComplete, .tournamentComplete: return .complete
        case .cancelled, .unknown: return .unknown
        }
    }

    private static func course(_ course: GolfCourse) -> BannerGolfCourse {
        BannerGolfCourse(
            id: BannerEntityID(rawValue: course.id),
            name: course.name,
            location: [course.city, course.state].compactMap { $0 }.joined(separator: ", ").nilIfEmpty,
            par: course.par,
            yardage: course.yardage,
            holes: course.holes.map {
                BannerGolfCourseHole(number: $0.number, par: $0.par, yardage: $0.yardage, handicap: nil)
            }
        )
    }

    private static func entry(tournamentID: String, entry: GolfLeaderboardEntry, provider: DataProvenance) -> BannerGolfLeaderboardEntry {
        BannerGolfLeaderboardEntry(
            id: BannerEntityID(rawValue: "\(tournamentID)-\(entry.player.id)"),
            playerID: BannerEntityID(rawValue: entry.player.id),
            playerName: entry.player.displayName,
            position: entry.positionDisplay,
            isTied: entry.isTied,
            totalScore: entry.totalDisplay,
            todayScore: entry.currentRoundScoreDisplay,
            thru: entry.thruDisplay,
            status: entry.playerState.shortLabel,
            rounds: entry.roundScores.map {
                BannerGolfRound(number: $0.roundNumber, displayName: "R\($0.roundNumber)", score: $0.displayValue, strokes: $0.strokes, scoreToPar: nil, holes: [])
            },
            stats: [],
            aliases: [ProviderEntityAlias(provider: .pga, id: entry.player.id)],
            provenance: provider
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
