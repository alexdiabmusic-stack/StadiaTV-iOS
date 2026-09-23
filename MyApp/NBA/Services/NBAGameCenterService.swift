import Foundation

nonisolated enum NBAGameTab: String, Codable, CaseIterable, Identifiable {
    case overview = "Overview", plays = "Play-by-Play", boxscore = "Box Score", shots = "Shot Chart"
    var id: String { rawValue }
}

nonisolated struct NBAGameCenterUpdate: Sendable {
    let gameID: NBAProviderGameID
    let requestedAt: Date
    /// Lightweight game state pulled out of the shared scoreboard — used on ticks
    /// that don't need fresh box stats, so the per-game box score endpoint isn't
    /// re-fetched every poll.
    var scoreboardGame: BasketballGame?
    /// From the combined CDN box score response, which carries both game state and
    /// player/team stats together — there's no separate lightweight box endpoint.
    var boxGame: BasketballGame?
    var box: NBABoxScoreResponse?
    var plays: [NBAPlayEvent]?
    var playsSource: String?
    var errors: [String: String] = [:]
    var retryAfter: Date?
}

nonisolated protocol NBAGameCenterServing: Sendable {
    func fetch(gameID: NBAProviderGameID, tab: NBAGameTab, full: Bool) async throws -> NBAGameCenterUpdate
}

nonisolated struct NBAGameCenterService: NBAGameCenterServing {
    let client: any NBAAPIClientProtocol
    init(client: any NBAAPIClientProtocol = NBAAPIClient.shared) { self.client = client }

    private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    func fetch(gameID: NBAProviderGameID, tab: NBAGameTab, full: Bool) async throws -> NBAGameCenterUpdate {
        var update = NBAGameCenterUpdate(gameID: gameID, requestedAt: Date())
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
            if let box = accept(await result { try await client.boxScore(gameID: gameID.rawValue) }, "overview") {
                if box.gameID == gameID.rawValue, let game = NBAGameMapper.boxScore(box) {
                    update.boxGame = game
                    update.box = box
                } else {
                    update.errors["overview"] = "NBA returned a different game."
                }
            }
        } else if let scoreboard = accept(await result { try await client.todaysScoreboard() }, "overview") {
            if let raw = scoreboard.games.first(where: { $0["gameId"].string == gameID.rawValue }), let game = NBAGameMapper.game(raw) {
                update.scoreboardGame = game
            } else {
                update.errors["overview"] = "NBA returned a different game."
            }
        }

        if tab == .plays || tab == .overview || tab == .shots || full {
            if let plays = accept(await result { try await client.playByPlay(gameID: gameID.rawValue) }, "plays") {
                if plays.gameID == gameID.rawValue {
                    update.plays = NBAPlayMapper.events(plays, gameID: gameID)
                    update.playsSource = "cdn"
                } else {
                    update.errors["plays"] = "NBA returned a different game."
                }
            } else if let v3 = accept(await result { try await client.playByPlayV3(gameID: gameID.rawValue) }, "plays") {
                // Recovered on the stats.nba.com fallback — clear the CDN failure so a
                // successful (if secondary-sourced) surface isn't reported as an error.
                let returnedIDs = v3.actions.compactMap { $0["gameId"]?.string }
                if returnedIDs.allSatisfy({ $0 == gameID.rawValue }) {
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
