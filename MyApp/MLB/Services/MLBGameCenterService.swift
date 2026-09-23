import Foundation

nonisolated enum MLBGameTab: String, Codable, CaseIterable, Identifiable {
    case overview = "Overview", plays = "Play-by-Play", boxscore = "Box Score", stats = "Stats"
    var id: String { rawValue }
}
nonisolated struct MLBGameCenterUpdate: Sendable {
    let gamePk: Int
    let requestedAt: Date
    var feed: MLBGameFeedResponse?
    var status: MLBGameFeedResponse?
    var line: MLBLineScoreResponse?
    var plays: MLBPlayByPlayResponse?
    var box: MLBBoxscoreResponse?
    var content: MLBContentResponse?
    var probability: MLBWinProbabilityResponse?
    var errors: [String: String] = [:]
    var retryAfter: Date?
}
nonisolated protocol MLBGameCenterServing: Sendable {
    func fetch(gamePk: Int, tab: MLBGameTab, full: Bool, includeContent: Bool) async throws -> MLBGameCenterUpdate
}
nonisolated struct MLBGameCenterService: MLBGameCenterServing {
    let client: any MLBAPIClientProtocol
    init(client: any MLBAPIClientProtocol = MLBAPIClient.shared) { self.client = client }
    private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    func fetch(gamePk: Int, tab: MLBGameTab, full: Bool, includeContent: Bool) async throws -> MLBGameCenterUpdate {
        var update = MLBGameCenterUpdate(gamePk: gamePk, requestedAt: Date())
        func accept<T>(_ result: Result<T, Error>, _ key: String) -> T? {
            switch result {
            case .success(let value): return value
            case .failure(let error):
                update.errors[key] = error.localizedDescription
                if case MLBAPIError.rateLimited(let date) = error { update.retryAfter = max(update.retryAfter ?? .distantPast, date) }
                return nil
            }
        }
        if full {
            update.feed = accept(await result { try await client.liveFeed(gamePk: gamePk) }, "overview")
            if let feed = update.feed, feed.gamePk != gamePk || MLBGameMapper.feed(feed) == nil {
                update.feed = nil; update.errors["overview"] = "MLB returned inconsistent game information."
            }
        }
        // Recover independent surfaces even when the combined feed is unavailable.
        if update.feed == nil {
            async let status = result { try await client.status(gamePk: gamePk) }
            async let line = result { try await client.linescore(gamePk: gamePk) }
            let (s, l) = await (status, line)
            update.status = accept(s, "overview"); update.line = accept(l, "linescore")
            if let status = update.status, status.gamePk != gamePk { update.status = nil; update.errors["overview"] = "MLB returned a different game." }
            if tab == .plays || tab == .overview || full {
                update.plays = accept(await result { try await client.playByPlay(gamePk: gamePk) }, "plays")
            }
            if tab == .boxscore || full {
                update.box = accept(await result { try await client.boxscore(gamePk: gamePk) }, "boxscore")
            }
        }
        if tab == .stats {
            update.probability = accept(await result { try await client.winProbability(gamePk: gamePk) }, "stats")
        }
        if includeContent {
            update.content = accept(await result { try await client.content(gamePk: gamePk) }, "content")
        }
        try Task.checkCancellation()
        return update
    }
}
