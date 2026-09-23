import Foundation

nonisolated struct NHLGameCenterUpdate: Sendable {
    let gameID: Int
    let landing: NHLGameDTO?
    let boxscore: NHLBoxscoreResponse?
    let playByPlay: NHLPlayByPlayResponse?
    let errors: [String: String]
    let retryAfter: Date?
    var rightRail: NHLValue? = nil
}
nonisolated protocol NHLGameCenterServing: Sendable {
    func fetch(gameID: Int) async throws -> NHLGameCenterUpdate
}
nonisolated struct NHLGameCenterService: NHLGameCenterServing {
    let client: any NHLAPIClientProtocol
    init(client: any NHLAPIClientProtocol = NHLAPIClient.shared) { self.client = client }
    private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    func fetch(gameID: Int) async throws -> NHLGameCenterUpdate {
        async let landing = result { try await client.landing(gameID: gameID) }
        async let box = result { try await client.boxscore(gameID: gameID) }
        async let plays = result { try await client.playByPlay(gameID: gameID) }
        async let rail = result { try await client.rightRail(gameID: gameID) }
        let (l, b, p, r) = await (landing, box, plays, rail)
        try Task.checkCancellation()
        var errors: [String: String] = [:]
        var retryAfter: Date?
        func value<T>(_ result: Result<T, Error>, key: String) -> T? {
            switch result {
            case .success(let value): return value
            case .failure(let error):
                errors[key] = error.localizedDescription
                if case NHLAPIError.rateLimited(let date) = error { retryAfter = max(retryAfter ?? .distantPast, date) }
                return nil
            }
        }
        var lv = value(l, key: "landing"), bv = value(b, key: "boxscore"), pv = value(p, key: "plays")
        let railValue = value(r, key: "stats")
        if let response = lv, response.id != gameID { lv = nil; errors["landing"] = "NHL returned a different game." }
        if let response = bv, response.game.id != gameID { bv = nil; errors["boxscore"] = "NHL returned a different game." }
        if let response = pv, response.game.id != gameID { pv = nil; errors["plays"] = "NHL returned a different game." }
        if let response = lv, NHLGameMapper.game(response) == nil {
            lv = nil; errors["landing"] = "NHL overview is missing required game information."
        }
        if let response = bv, NHLGameMapper.game(response.game) == nil {
            bv = nil; errors["boxscore"] = "NHL box score is missing required game information."
        }
        if let response = pv, NHLGameMapper.game(response.game) == nil {
            pv = nil; errors["plays"] = "NHL play-by-play is missing required game information."
        }
        return NHLGameCenterUpdate(gameID: gameID, landing: lv, boxscore: bv, playByPlay: pv, errors: errors, retryAfter: retryAfter, rightRail: railValue)
    }
}
actor NHLGameCenterCache {
    static let shared = NHLGameCenterCache()
    private var memory: [Int: HockeyGameCenterSnapshot] = [:]
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/NHL/v1", isDirectory: true)
    }
    func load(_ id: Int) -> HockeyGameCenterSnapshot? {
        if let cached = memory[id] { return cached }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")),
              let value = try? JSONDecoder().decode(HockeyGameCenterSnapshot.self, from: data), value.gameID == id else { return nil }
        // Cached live data is explicitly labeled stale by the view until refreshed.
        memory[id] = value
        return value
    }
    func save(_ value: HockeyGameCenterSnapshot) {
        memory[value.gameID] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent("\(value.gameID).json"), options: .atomic)
        } catch {
            #if DEBUG
            print("NHL cache write failed: \(error)")
            #endif
        }
    }
}
nonisolated enum NHLGameCenterReducer {
    static func accepts(_ candidate: HockeyGame, over current: HockeyGame?) -> Bool {
        guard let current else { return true }
        guard candidate.id == current.id else { return false }
        if current.status == .final && candidate.status != .final { return false }
        if current.status == .live && [.scheduled, .pregame].contains(candidate.status) { return false }
        if candidate.period.number < current.period.number { return false }
        if candidate.period.number == current.period.number, candidate.status == .live, current.status == .live,
           let old = current.secondsRemaining, let new = candidate.secondsRemaining, new > old { return false }
        return true
    }
    static func apply(_ update: NHLGameCenterUpdate, to old: HockeyGameCenterSnapshot) -> HockeyGameCenterSnapshot {
        guard update.gameID == old.gameID else { return old }
        var result = old
        var acceptedData = false
        let candidates = [update.landing, update.boxscore?.game, update.playByPlay?.game].compactMap { $0 }.compactMap(NHLGameMapper.game)
        for game in candidates where accepts(game, over: result.game) {
            result.game = game
            acceptedData = true
        }
        let landingFresh = update.landing.flatMap(NHLGameMapper.game).map { accepts($0, over: old.game) } ?? false
        if landingFresh, let landing = update.landing {
            result.landingLoaded = true
            result.scoringSummary = NHLPlayMapper.scoringSummary(landing)
            result.recapURL = NHLGameMapper.webURL(landing.raw["summary"]["gameRecap"]["url"].string)
        }
        if let plays = update.playByPlay, let game = NHLGameMapper.game(plays.game), accepts(game, over: old.game) {
            let previousEvents = Dictionary(old.events.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            let mapped = NHLPlayMapper.events(plays, landing: landingFresh ? update.landing : nil).map { event in
                var merged = event
                if !landingFresh, let previous = previousEvents[event.id] {
                    merged.videoURL = merged.videoURL ?? previous.videoURL
                    merged.strength = merged.strength ?? previous.strength
                    merged.scorerSeasonGoals = merged.scorerSeasonGoals ?? previous.scorerSeasonGoals
                    if merged.assistSeasonTotals.isEmpty { merged.assistSeasonTotals = previous.assistSeasonTotals }
                }
                return merged
            }
            // A full NHL stream replaces prior revisions; do not append duplicates or
            // retain goals removed by a review. Reject truncated/older feed snapshots.
            if (mapped.last?.sortOrder ?? 0) >= (old.events.last?.sortOrder ?? 0) {
                result.events = mapped; result.playsLoaded = true
            }
        }
        if let box = update.boxscore, let game = NHLGameMapper.game(box.game), accepts(game, over: old.game) {
            let roster = NHLPlayMapper.roster(update.playByPlay?.rosterSpots ?? [])
            result.players = NHLGameMapper.players(box, roster: roster); result.boxscoreLoaded = true
        }
        if acceptedData {
            // Never replace cached stats with aggregates from an entirely stale update.
            result.teamStats = NHLGameMapper.teamStats(game: result.game, landing: landingFresh ? update.landing : nil, players: result.players, rightRail: update.rightRail)
            result.fetchedAt = Date()
        }
        return result
    }
}
