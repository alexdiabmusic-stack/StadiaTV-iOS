import Foundation

/// Pure merge function, shared by every basketball league — operates only on
/// `BasketballGameCenterUpdate`/`BasketballGameSnapshot`, never on a league's raw
/// DTOs. Box-score rows arrive already mapped into `NBAPlayerGameLine`/etc by the
/// per-league `*GameCenterService` (which alone knows how to read its own raw
/// response), so this reducer's anti-regression checks work off the canonical
/// shapes only.
nonisolated enum BasketballGameCenterReducer {
    static func apply(_ update: BasketballGameCenterUpdate, to old: BasketballGameSnapshot) -> BasketballGameSnapshot {
        guard update.gameID == old.gameID, update.requestedAt >= old.fetchedAt else { return old }
        if let scoreboardGame = update.scoreboardGame, scoreboardGame.id != old.gameID { return old }
        if let boxGame = update.boxGame, boxGame.id != old.gameID { return old }
        for play in update.plays ?? [] where play.gameID != old.gameID { return old }

        let incomingGame = update.boxGame ?? update.scoreboardGame
        if let incomingGame {
            let oldPeriod = old.game?.period ?? 0
            if incomingGame.period < oldPeriod { return old }
            if incomingGame.period == 0, oldPeriod > 0 { return old }
            if old.game?.status.stopsPolling == true, !incomingGame.status.stopsPolling { return old }
            if incomingGame.period == oldPeriod {
                let scoreAdvanced = (incomingGame.home.score ?? 0) > (old.game?.home.score ?? 0)
                    || (incomingGame.away.score ?? 0) > (old.game?.away.score ?? 0)
                let playCountGrew = (update.plays?.count ?? 0) > old.plays.count
                // The clock counts down; a rollback with corroborating progress (score moved,
                // more plays arrived) is a legitimate replay-review correction, but a bare
                // rollback with no such evidence is treated as stale data.
                if let newClock = incomingGame.gameClock, let oldClock = old.game?.gameClock,
                   newClock > oldClock + 2.0, !scoreAdvanced, !playCountGrew {
                    return old
                }
                let scoreRegressed = (incomingGame.home.score ?? 0) < (old.game?.home.score ?? 0)
                    || (incomingGame.away.score ?? 0) < (old.game?.away.score ?? 0)
                // An official scoring correction is legitimate, but only when it arrives
                // alongside a fresh box score — a bare decrease from the lightweight
                // scoreboard surface is treated as stale rather than authoritative.
                if scoreRegressed, update.homeBox == nil { return old }
            }
        }

        var result = old
        if let incomingGame {
            var merged = incomingGame
            if merged.broadcasts.isEmpty { merged.broadcasts = old.game?.broadcasts ?? [] }
            result.game = merged
            result.lastScoreUpdate = Date()
        }

        // Plays merge by id — this is what makes a replay-review correction *replace*
        // rather than duplicate, per `NBAPlayMapper`'s own header comment. Never shrinks
        // unless the incoming payload contributes nothing new and looks behind.
        if let incoming = update.plays {
            var byID = Dictionary(uniqueKeysWithValues: old.plays.map { ($0.id, $0) })
            let hasNewID = incoming.contains { byID[$0.id] == nil }
            for play in incoming { byID[play.id] = play }
            let candidate = NBAPlayEvent.sorted(Array(byID.values))
            let regressed: Bool
            if let oldNewest = old.plays.last, let newNewest = candidate.last {
                regressed = (newNewest.period, newNewest.sortKey) < (oldNewest.period, oldNewest.sortKey)
            } else {
                regressed = false
            }
            if !regressed || hasNewID {
                result.plays = candidate
                result.playsLoaded = true
                result.lastPlayUpdate = Date()
            }
        }
        // Pure projection — shots never drift independently of the play list they come from.
        result.shots = result.plays.compactMap(\.shot)

        if let homeBox = update.homeBox, let awayBox = update.awayBox, let game = incomingGame ?? old.game {
            let validTeamIDs: Set<Int> = [game.home.id, game.away.id]
            let hasForeignTeam = (homeBox + awayBox).contains { !validTeamIDs.contains($0.teamID) }
            let isShrinking = !game.status.stopsPolling
                && ((!old.homeBox.isEmpty && homeBox.count < old.homeBox.count) || (!old.awayBox.isEmpty && awayBox.count < old.awayBox.count))
            if !hasForeignTeam, !isShrinking {
                result.homeBox = homeBox
                result.awayBox = awayBox
                result.homeTeamStats = update.homeTeamStats
                result.awayTeamStats = update.awayTeamStats
                result.homeLeaders = update.homeLeaders
                result.awayLeaders = update.awayLeaders
                if let onCourtHome = update.onCourtHome, (0...5).contains(onCourtHome.count) { result.onCourtHome = onCourtHome }
                if let onCourtAway = update.onCourtAway, (0...5).contains(onCourtAway.count) { result.onCourtAway = onCourtAway }
                result.boxLoaded = true
                result.lastBoxUpdate = Date()
            }
        }

        let accepted = incomingGame != nil || update.plays != nil || update.homeBox != nil
        if accepted {
            result.fetchedAt = update.requestedAt
            result.timestamp = ISO8601DateFormatter().string(from: update.requestedAt)
            // Best-effort provenance label — the score/box surfaces are fetched behind
            // each league's own opaque CDN→stats fallback, so plays (fetched directly
            // against each host in the service) is the one surface whose source is known.
            if let playsSource = update.playsSource { result.source = playsSource }
        }
        return result
    }
}
