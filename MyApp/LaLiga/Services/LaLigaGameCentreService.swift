import Foundation

/// The official-match baseline lookup `LaLigaGameCentreService` depends on —
/// factored out as a protocol (rather than depending on `LaLigaProvider`
/// concretely) purely for testability: `LaLigaProvider` conforms to this but also
/// implements `NativeSportsProvider`, which returns app-only legacy types
/// (`Match`/`Team`/`StandingsGroup`) that don't exist in the standalone
/// `LaLigaCoreTests` package. This protocol's one method only ever returns the
/// canonical `SoccerMatch`, so it — and everything depending on it — stays testable
/// outside the full app target.
nonisolated protocol LaLigaOfficialMatchSource: Sendable {
    func officialMatch(id: String) async throws -> SoccerMatch?
}

/// Coordinates every Match Centre resource behind one call per poll tick, exactly
/// like EPL/MLS — but La Liga is the first *two-source* provider: the official
/// LaLiga API supplies the season/schedule baseline (Step 19 — it owns
/// competition/rounds/fixtures/standings/squads), while FotMob supplies every
/// live-match enrichment surface the official API doesn't document (events,
/// lineups, stats, shot map, ticker — Step 10).
///
/// Authority rule (Step 19, 37): once `LaLigaFotMobMatchResolver` resolves a
/// FotMob match, FotMob becomes authoritative for score/clock/status from kickoff
/// through FullTime; the official fixture remains authoritative before kickoff and
/// once FullTime is confirmed. This is a pure function of the *official* match's
/// own status, not a per-poll coin flip, so it never alternates every refresh.
/// Either source failing degrades gracefully rather than killing the other
/// (Step 34/35): an official-API outage still leaves whatever FotMob last
/// supplied in place tab-by-tab, and a FotMob outage still leaves the official
/// score/status/venue/matchweek visible.
nonisolated struct LaLigaGameCentreService: SoccerGameCentreServing {
    let officialSource: any LaLigaOfficialMatchSource
    let fotmobClient: any FotMobClientProtocol
    let matchResolver: LaLigaFotMobMatchResolver

    // No default for `officialSource` (unlike `fotmobClient`/`matchResolver`) —
    // its only real implementation, `LaLigaProvider`, lives in the app target and
    // depends on legacy types (`Match`/`Team`/`NativeSportsProvider`) that don't
    // exist in the standalone `LaLigaCoreTests` package. Defaulting to it here
    // would pull `LaLigaProvider.swift` into every symlinked build of this file.
    // The app wiring (`MatchDetailView`/`TVMatchDetailView`) always passes
    // `LaLigaProvider.shared` explicitly.
    init(officialSource: any LaLigaOfficialMatchSource, fotmobClient: any FotMobClientProtocol = FotMobClient.shared, matchResolver: LaLigaFotMobMatchResolver = .shared) {
        self.officialSource = officialSource
        self.fotmobClient = fotmobClient
        self.matchResolver = matchResolver
    }

    private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    func fetch(matchID: String, tab: SoccerGameTab, full: Bool, lineupsLoaded: Bool, knownPlayers: [String: SoccerPlayerReference], commentaryCursor: String?) async throws -> SoccerGameCentreUpdate {
        var update = SoccerGameCentreUpdate(matchID: matchID, requestedAt: Date())
        func accept<T>(_ outcome: Result<T, Error>, _ key: String) -> T? {
            switch outcome {
            case .success(let value): return value
            case .failure(let error):
                update.errors[key] = error.localizedDescription
                if case LaLigaAPIError.rateLimited(let date) = error { update.retryAfter = max(update.retryAfter ?? .distantPast, date) }
                if case FotMobAPIError.rateLimited(let date) = error { update.retryAfter = max(update.retryAfter ?? .distantPast, date) }
                return nil
            }
        }

        // Official baseline (Step 19). Cheap after the first poll — reuses
        // `LaLigaProvider`'s own 5-minute season-match cache rather than
        // re-paginating ~380 fixtures every tick.
        guard let officialMatchOutcome = accept(await result { try await self.officialSource.officialMatch(id: matchID) }, "overview"),
              let officialMatch = officialMatchOutcome else {
            return update
        }

        // Reconciliation (Step 16/36) — skipped outright for matches long over,
        // since a finished match from days ago never needs live FotMob data.
        let matchIsStale = officialMatch.status == .fullTime && officialMatch.kickoff.timeIntervalSinceNow < -86400
        let resolvedFotMobID: String? = matchIsStale ? nil : await matchResolver.resolve(
            officialMatchID: matchID, homeTeamID: officialMatch.home.team.id, awayTeamID: officialMatch.away.team.id,
            homeTeamName: officialMatch.home.team.name, awayTeamName: officialMatch.away.team.name, kickoff: officialMatch.kickoff
        )
        update.providerMatchIDs = SoccerProviderMatchIDs(laligaOfficial: matchID, fotmob: resolvedFotMobID)

        var matchDetailsRaw: FotMobValue?
        if let resolvedFotMobID {
            matchDetailsRaw = accept(await result { try await fotmobClient.matchDetails(matchId: resolvedFotMobID) }, "fotmob")
        }

        // Authority rule: FotMob leads score/clock/status once resolved and the
        // official fixture is no longer pre-match; official remains authoritative
        // before kickoff (FotMob's status for a not-yet-started match is no more
        // useful than the official schedule) and this never re-checks FotMob's
        // own status to decide — only the official match's.
        var currentMatch = officialMatch
        if let matchDetailsRaw, officialMatch.status != .scheduled, officialMatch.status != .pregame {
            currentMatch = FotMobMatchMapper.apply(matchDetailsRaw, to: officialMatch)
        }
        update.match = currentMatch

        // Everything below only ever comes from FotMob — the official API has no
        // documented events/lineups/stats/shots/commentary surface for a single
        // match (Step 10). An official-API-only match (unresolved FotMob id)
        // simply shows score/status/venue/matchweek with the rest degraded
        // (Step 35's "Detailed live match data is temporarily unavailable").
        if let matchDetailsRaw {
            let fotmobHomeID = FotMobMatchMapper.homeTeamID(matchDetailsRaw)

            if full || tab == .timeline || tab == .overview {
                update.events = FotMobEventMapper.events(matchDetailsRaw, matchID: matchID, homeTeamID: currentMatch.home.team.id, awayTeamID: currentMatch.away.team.id)
            }

            if full || !lineupsLoaded {
                update.homeLineup = .some(FotMobLineupMapper.lineup(matchDetailsRaw["content"]["lineup"]["homeTeam"], team: currentMatch.home.team))
                update.awayLineup = .some(FotMobLineupMapper.lineup(matchDetailsRaw["content"]["lineup"]["awayTeam"], team: currentMatch.away.team))
            }

            if full || tab == .stats || tab == .overview {
                let sides = FotMobStatsMapper.stats(matchDetailsRaw, homeTeamID: currentMatch.home.team.id, awayTeamID: currentMatch.away.team.id)
                update.homeStats = sides.home
                update.awayStats = sides.away
            }

            if full || tab == .shots {
                update.shots = FotMobShotMapper.shots(matchDetailsRaw, matchID: matchID, fotmobHomeTeamID: fotmobHomeID,
                    homeTeamID: currentMatch.home.team.id, awayTeamID: currentMatch.away.team.id)
            }

            if full {
                update.momentum = FotMobMomentumMapper.samples(matchDetailsRaw)
            }

            // Live ticker is supplemental only (Step 26) — a missing/blocked
            // ticker file is expected (Step 14) and never treated as a hard
            // failure of the whole poll; Timeline keeps working from `update.events`.
            if (full || tab == .commentary), let resolvedFotMobID,
               let ltcURL = FotMobCommentaryMapper.ltcURL(fotmobMatchID: resolvedFotMobID, matchDetails: matchDetailsRaw),
               let raw = try? await fotmobClient.liveTickerRaw(ltcUrl: ltcURL), let entries = FotMobCommentaryMapper.entries(raw) {
                update.commentary = entries
            }

            var directory = knownPlayers
            for lineup in [(update.homeLineup ?? nil), (update.awayLineup ?? nil)].compactMap({ $0 }) {
                for player in lineup.starters + lineup.substitutes { directory[player.reference.id] = player.reference }
            }
            update.playerDirectory = directory
        }

        try Task.checkCancellation()
        return update
    }
}

extension SoccerGameCentreCache {
    static let laliga = SoccerGameCentreCache(provider: "LaLiga")
}
