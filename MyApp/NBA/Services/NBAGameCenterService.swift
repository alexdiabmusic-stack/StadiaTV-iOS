import Foundation

nonisolated struct NBAGameCenterService: BasketballGameCenterServing {
    let client: any NBAAPIClientProtocol
    init(client: any NBAAPIClientProtocol = NBAAPIClient.shared) { self.client = client }

    private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    func fetch(gameID: BasketballGameID, tab: BasketballGameTab, full: Bool) async throws -> BasketballGameCenterUpdate {
        var update = BasketballGameCenterUpdate(gameID: gameID, requestedAt: Date())
        func accept<T>(_ result: Result<T, Error>, _ key: String) -> T? {
            switch result {
            case .success(let value): return value
            case .failure(let error):
                update.errors[key] = error.localizedDescription
                if let apiError = error as? NBAAPIError {
                    switch apiError {
                    case .rateLimited(let date): update.retryAfter = max(update.retryAfter ?? .distantPast, date)
                    // A blocked host won't clear on its own timeline; give the view model
                    // a floor to back off to even if the client's own breaker is shorter.
                    case .blocked: update.retryAfter = max(update.retryAfter ?? .distantPast, Date().addingTimeInterval(60))
                    case .invalidURL, .invalidResponse, .http, .decoding: break
                    }
                }
                return nil
            }
        }

        if full || tab == .boxscore || tab == .shots {
            if let box = accept(await result { try await client.boxScore(gameID: gameID.providerID) }, "overview") {
                if box.gameID == gameID.providerID, let game = NBAGameMapper.boxScore(box) {
                    update.boxGame = game
                    // The box response carries both game state and player/team stats
                    // together (`box.homeTeam`/`awayTeam` are the very same nodes
                    // `NBAGameMapper.boxScore` just read `game.home`/`.away` from, so
                    // there's no separate container to fall out of sync with); map it
                    // here — rather than in the shared reducer, which only ever sees
                    // canonical types — into every field the reducer's anti-regression
                    // checks and the snapshot itself need.
                    let homeBox = NBABoxScoreMapper.players(box.homeTeam)
                    let awayBox = NBABoxScoreMapper.players(box.awayTeam)
                    update.homeBox = homeBox
                    update.awayBox = awayBox
                    update.homeTeamStats = NBABoxScoreMapper.teamStats(box.homeTeam)
                    update.awayTeamStats = NBABoxScoreMapper.teamStats(box.awayTeam)
                    update.homeLeaders = NBABoxScoreMapper.leaders(homeBox, teamID: game.home.id)
                    update.awayLeaders = NBABoxScoreMapper.leaders(awayBox, teamID: game.away.id)
                    update.onCourtHome = NBABoxScoreMapper.onCourt(box.homeTeam)
                    update.onCourtAway = NBABoxScoreMapper.onCourt(box.awayTeam)
                } else {
                    update.errors["overview"] = "NBA returned a different game."
                }
            }
        } else if let scoreboard = accept(await result { try await client.todaysScoreboard() }, "overview") {
            if let raw = scoreboard.games.first(where: { $0["gameId"].string == gameID.providerID }), let game = NBAGameMapper.game(raw) {
                update.scoreboardGame = game
            } else {
                update.errors["overview"] = "NBA returned a different game."
            }
        }

        if tab == .plays || tab == .overview || tab == .shots || full {
            if let plays = accept(await result { try await client.playByPlay(gameID: gameID.providerID) }, "plays") {
                if plays.gameID == gameID.providerID {
                    update.plays = NBAPlayMapper.events(plays, gameID: gameID)
                    update.playsSource = "cdn"
                } else {
                    update.errors["plays"] = "NBA returned a different game."
                }
            } else if let v3 = accept(await result { try await client.playByPlayV3(gameID: gameID.providerID) }, "plays") {
                // Recovered on the stats.nba.com fallback — clear the CDN failure so a
                // successful (if secondary-sourced) surface isn't reported as an error.
                let returnedIDs = v3.actions.compactMap { $0["gameId"]?.string }
                if returnedIDs.allSatisfy({ $0 == gameID.providerID }) {
                    update.plays = NBAPlayMapper.eventsV3(v3, gameID: gameID)
                    update.playsSource = "stats"
                    update.errors["plays"] = nil
                } else {
                    update.errors["plays"] = "NBA returned a different game."
                }
            }
        }
        try Task.checkCancellation()
        return update
    }
}
