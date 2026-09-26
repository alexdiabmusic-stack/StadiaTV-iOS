import Foundation

/// Conforms to the shared `BasketballGameCenterServing` protocol — `NBAGameCenterService`
/// is the other conformer. Deliberately simpler than NBA's: no stats.wnba.com
/// fallback for scoreboard/box/plays (Step 21/26 — live score/PBP must never
/// depend on Stats availability), so a CDN failure here is just an error the
/// shared reducer/view already know how to degrade around, never a silent
/// switch to a more fragile secondary host.
nonisolated struct WNBAGameCenterService: BasketballGameCenterServing {
    let client: any WNBALiveCDNClientProtocol
    init(client: any WNBALiveCDNClientProtocol = WNBALiveCDNClient.shared) { self.client = client }

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
                if let apiError = error as? WNBAAPIError {
                    switch apiError {
                    case .rateLimited(let date): update.retryAfter = max(update.retryAfter ?? .distantPast, date)
                    case .blocked: update.retryAfter = max(update.retryAfter ?? .distantPast, Date().addingTimeInterval(60))
                    case .invalidURL, .invalidResponse, .http, .decoding: break
                    }
                }
                return nil
            }
        }

        if full || tab == .boxscore || tab == .shots {
            if let box = accept(await result { try await client.boxScore(gameID: gameID.providerID) }, "overview") {
                if box.gameID == gameID.providerID, let game = WNBAGameMapper.boxScore(box) {
                    update.boxGame = game
                    let homeBox = WNBABoxScoreMapper.players(box.homeTeam)
                    let awayBox = WNBABoxScoreMapper.players(box.awayTeam)
                    update.homeBox = homeBox
                    update.awayBox = awayBox
                    update.homeTeamStats = WNBABoxScoreMapper.teamStats(box.homeTeam)
                    update.awayTeamStats = WNBABoxScoreMapper.teamStats(box.awayTeam)
                    update.homeLeaders = WNBABoxScoreMapper.leaders(homeBox, teamID: game.home.id)
                    update.awayLeaders = WNBABoxScoreMapper.leaders(awayBox, teamID: game.away.id)
                    update.onCourtHome = WNBABoxScoreMapper.onCourt(box.homeTeam)
                    update.onCourtAway = WNBABoxScoreMapper.onCourt(box.awayTeam)
                } else {
                    update.errors["overview"] = "WNBA returned a different game."
                }
            }
        } else if let scoreboard = accept(await result { try await client.todaysScoreboard() }, "overview") {
            if let raw = scoreboard.games.first(where: { $0["gameId"].string == gameID.providerID }), let game = WNBAGameMapper.game(raw) {
                update.scoreboardGame = game
            } else {
                update.errors["overview"] = "WNBA returned a different game."
            }
        }

        if tab == .plays || tab == .overview || tab == .shots || full {
            if let plays = accept(await result { try await client.playByPlay(gameID: gameID.providerID) }, "plays") {
                if plays.gameID == gameID.providerID {
                    update.plays = WNBAPlayMapper.events(plays, gameID: gameID)
                    update.playsSource = "cdn"
                } else {
                    update.errors["plays"] = "WNBA returned a different game."
                }
            }
            // No stats.wnba.com fallback here by design (Step 21/26) — if the CDN
            // play stream is unavailable, the Plays tab shows "temporarily
            // unavailable" via the shared error surface rather than reaching for a
            // more fragile secondary host for a live-data concern.
        }
        try Task.checkCancellation()
        return update
    }
}
