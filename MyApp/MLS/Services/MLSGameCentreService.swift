import Foundation

/// Coordinates every Match Centre resource behind one call per poll tick, same
/// contract as `EPLGameCentreService` (Score/clock/status always comes from
/// `/matches/{id}` — events, stats, lineups, commentary only ever explain or
/// supplement that authoritative state, never replace it). MLS's overview response
/// conveniently bundles lineups, formation, managers, and officials in one call —
/// unlike EPL, none of those need a separate request.
nonisolated struct MLSGameCentreService: SoccerGameCentreServing {
    let client: any MLSStatsClientProtocol
    init(client: any MLSStatsClientProtocol = MLSStatsClient.shared) { self.client = client }

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
                if case MLSAPIError.rateLimited(let date) = error { update.retryAfter = max(update.retryAfter ?? .distantPast, date) }
                return nil
            }
        }

        var overviewRaw: MLSValue?
        if let raw = accept(await result { try await client.match(matchID) }, "overview") {
            if raw["match_information"]["match_id"].string == matchID { overviewRaw = raw } else { update.errors["overview"] = "MLS returned a different match." }
        }
        update.match = overviewRaw.flatMap { MLSMatchMapper.overviewMatch($0) }
        let homeTeamID = overviewRaw?["home"]["team_id"].string
        let awayTeamID = overviewRaw?["away"]["team_id"].string
        let seasonID = overviewRaw?["match_information"]["season_id"].string
        let competitionID = overviewRaw?["match_information"]["competition_id"].string

        var directory = knownPlayers
        if let overviewRaw, let homeTeamID, let awayTeamID {
            // Lineups, officials, and managers all arrive bundled in the overview —
            // no separate request. Once announced, this only re-parses (never
            // re-fetches) on every poll, which is cheap; the reducer's lineup
            // regression guard is what actually prevents "not announced" flicker.
            if full || !lineupsLoaded {
                let homeTeam = SoccerTeam(id: homeTeamID, name: overviewRaw["home"]["team_name"].string ?? homeTeamID,
                    shortName: overviewRaw["home"]["team_short_name"].string ?? homeTeamID, abbreviation: overviewRaw["home"]["team_three_letter_code"].string ?? homeTeamID)
                let awayTeam = SoccerTeam(id: awayTeamID, name: overviewRaw["away"]["team_name"].string ?? awayTeamID,
                    shortName: overviewRaw["away"]["team_short_name"].string ?? awayTeamID, abbreviation: overviewRaw["away"]["team_three_letter_code"].string ?? awayTeamID)
                update.homeLineup = .some(MLSLineupMapper.lineup(overviewRaw["home"], team: homeTeam))
                update.awayLineup = .some(MLSLineupMapper.lineup(overviewRaw["away"], team: awayTeam))
                for lineup in [update.homeLineup ?? nil, update.awayLineup ?? nil].compactMap({ $0 }) {
                    for player in lineup.starters + lineup.substitutes { directory[player.reference.id] = player.reference }
                }
            }
            if full { update.officials = MLSOfficialsMapper.officials(overviewRaw) }

            if full || tab == .timeline || tab == .overview {
                let playerTeamMap = MLSMatchMapper.playerTeamMap(fromOverview: overviewRaw)
                if let raw = accept(await result { try await client.keyEvents(matchID, event: nil, perPage: nil) }, "events") {
                    update.events = MLSEventMapper.events(raw, matchID: matchID, playerTeamMap: playerTeamMap)
                    directory.merge(MLSEventMapper.playerDirectory(fromKeyEvents: raw)) { _, new in new }
                }
            }

            if full || tab == .stats || tab == .overview {
                if let raw = accept(await result { try await client.teamMatchStats(matchID) }, "stats") {
                    for entry in raw["match_statistics_list"].array {
                        let stats = entry["match_statistics"]
                        for teamEntry in stats["team_statistics"].array {
                            guard let teamID = teamEntry["team_id"].string else { continue }
                            let mapped = MLSStatKeyMapper.stats(teamEntry, teamID: teamID)
                            if teamID == homeTeamID { update.homeStats = mapped } else if teamID == awayTeamID { update.awayStats = mapped }
                        }
                    }
                }
            }

            // Player match stats are heavier (one row per player on the pitch) and
            // only useful on the Stats tab or a full refresh — never polled every
            // live tick regardless of which tab is showing.
            if full || tab == .stats {
                if let raw = accept(await result { try await client.playerMatchStats(matchID) }, "playerStats") {
                    update.playerMatchStats = MLSPlayerStatsMapper.stats(raw, matchID: matchID)
                }
            }

            if full, let currentMatch = update.match, currentMatch.status == .penalties {
                if let raw = accept(await result { try await client.keyEvents(matchID, event: "penalties", perPage: nil) }, "shootout") {
                    update.penaltyShootout = MLSShootoutMapper.shootout(raw, matchID: matchID, homeTeamID: homeTeamID, awayTeamID: awayTeamID)
                }
            }

            // Conference live table preview: low priority, only while the match is
            // actually live, and only on a full refresh — a separate `conferenceStandings`
            // slot so it never gets confused with (or persisted as) the official table.
            if full, let currentMatch = update.match, currentMatch.status.isLive, let seasonID, let competitionID {
                if let raw = accept(await result { try await client.standings(competitionID: competitionID, seasonID: seasonID, category: "conference", isLive: true) }, "standings") {
                    update.conferenceStandings = MLSStandingsMapper.tables(raw, isLive: true)
                    update.liveStandings = update.conferenceStandings?.first { $0.entries.contains { $0.team.id == homeTeamID || $0.team.id == awayTeamID } }
                }
            }
        }

        if full || tab == .commentary {
            if let raw = accept(await result { try await client.commentary(matchID, pageToken: tab == .commentary ? commentaryCursor : nil) }, "commentary") {
                update.commentary = MLSCommentaryMapper.entries(raw, matchID: matchID)
                update.commentaryNextCursor = .some(raw["next_page_token"].string)
            }
        }

        update.playerDirectory = directory
        try Task.checkCancellation()
        return update
    }
}

extension SoccerGameCentreCache {
    static let mls = SoccerGameCentreCache(provider: "MLS")
}
