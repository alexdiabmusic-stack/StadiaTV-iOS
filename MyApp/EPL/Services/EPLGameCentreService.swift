import Foundation

/// Coordinates every Match Centre resource behind one call per poll tick, so
/// Overview/Timeline/Lineups/Stats/Commentary don't each independently trigger the
/// same network requests (Steps 13, 57–59). Score/clock/status always comes from
/// `/v2/matches/{id}` — events, stats, lineups, commentary only ever explain or
/// supplement that authoritative state, never replace it (Steps 63–64).
///
/// Conforms to the shared `SoccerGameCentreServing` protocol (`MyApp/Soccer/Services/
/// SoccerGameCentreUpdate.swift`) so it plugs into the same `SoccerGameCentreViewModel`
/// that every other soccer provider (MLS, ...) uses — no EPL-specific polling/reducer/
/// cache code remains in this file.
nonisolated struct EPLGameCentreService: SoccerGameCentreServing {
    let client: any EPLPulseLiveClientProtocol
    init(client: any EPLPulseLiveClientProtocol = EPLPulseLiveClient.shared) { self.client = client }

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
                if case EPLAPIError.rateLimited(let date) = error { update.retryAfter = max(update.retryAfter ?? .distantPast, date) }
                return nil
            }
        }

        var matchRaw: EPLValue?
        if let raw = accept(await result { try await client.match(matchID) }, "overview") {
            if raw["matchId"].string == matchID { matchRaw = raw } else { update.errors["overview"] = "Premier League returned a different match." }
        }
        update.match = matchRaw.flatMap { EPLMatchMapper.match($0) }
        let homeTeamID = matchRaw?["homeTeam"]["id"].string
        let awayTeamID = matchRaw?["awayTeam"]["id"].string

        if full || tab == .timeline || tab == .overview, let homeTeamID, let awayTeamID {
            if let raw = accept(await result { try await client.events(matchID) }, "events") {
                update.events = EPLEventMapper.events(raw, matchID: matchID, homeTeamID: homeTeamID, awayTeamID: awayTeamID)
            }
        }

        // Once announced, lineups rarely need re-fetching (Step 51) — only refresh on
        // a full tick or while genuinely not yet loaded, regardless of which tab is
        // active, rather than hammering this endpoint every live poll.
        if (full || !lineupsLoaded), let homeState = matchRaw.flatMap({ EPLMatchMapper.teamMatchState($0["homeTeam"]) }),
           let awayState = matchRaw.flatMap({ EPLMatchMapper.teamMatchState($0["awayTeam"]) }) {
            if let raw = accept(await result { try await client.lineups(matchID) }, "lineups") {
                update.homeLineup = .some(EPLLineupMapper.lineup(raw["home_team"], team: homeState.team))
                update.awayLineup = .some(EPLLineupMapper.lineup(raw["away_team"], team: awayState.team))
            }
        }

        if full || tab == .stats || tab == .overview, let homeTeamID, let awayTeamID {
            if let raw = accept(await result { try await client.stats(matchID) }, "stats") {
                for entry in raw.array {
                    guard let teamID = entry["teamId"].string else { continue }
                    let stats = EPLStatKeyMapper.stats(entry["stats"], teamID: teamID)
                    if teamID == homeTeamID { update.homeStats = stats } else if teamID == awayTeamID { update.awayStats = stats }
                }
            }
        }

        if full {
            if let raw = accept(await result { try await client.officials(matchID) }, "officials") { update.officials = EPLOfficialsMapper.officials(raw) }
        }

        if full || tab == .commentary {
            if let raw = accept(await result { try await client.commentary(matchID, limit: 20, next: tab == .commentary ? commentaryCursor : nil) }, "commentary") {
                update.commentary = EPLCommentaryMapper.entries(raw, matchID: matchID)
                update.commentaryNextCursor = .some(EPLPagedResponse(raw).nextCursor)
            }
        }

        // Player-name hydration: the lineups fetch already covers essentially every
        // player who could appear in this match's events (starters + subs on both
        // sides), so it's the primary source. Anything still unresolved is batch
        // -hydrated in one call rather than one request per event (Step 17).
        var directory = knownPlayers
        for lineup in [(update.homeLineup ?? nil), (update.awayLineup ?? nil)].compactMap({ $0 }) {
            for player in lineup.starters + lineup.substitutes { directory[player.reference.id] = player.reference }
        }
        let referencedIDs = Set((update.events ?? []).flatMap { [$0.playerID, $0.secondaryPlayerID].compactMap { $0 } })
        let missing = referencedIDs.subtracting(directory.keys)
        if !missing.isEmpty, let raw = accept(await result { try await client.playersByID(Array(missing)) }, "players") {
            for entry in raw.array { if let reference = EPLMatchMapper.playerBasic(entry) { directory[reference.id] = reference } }
        }
        update.playerDirectory = directory

        // Live table preview: low priority, only while the match is actually live,
        // and only on a full refresh — kept as a separate `liveStandings` slot so it
        // never gets confused with (or persisted as) the official table (Step 80).
        if full, let currentMatch = update.match, currentMatch.status.isLive {
            let season = currentMatch.season
            if let raw = accept(await result { try await client.standings(season: season, live: true) }, "standings") {
                update.liveStandings = EPLMatchMapper.standingsTable(raw, live: true)
            }
        }

        try Task.checkCancellation()
        return update
    }
}

extension SoccerGameCentreCache {
    static let epl = SoccerGameCentreCache(provider: "EPL")
}
