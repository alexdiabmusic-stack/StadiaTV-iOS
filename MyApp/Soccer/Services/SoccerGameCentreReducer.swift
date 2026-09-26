import Foundation

/// Merges one poll's `SoccerGameCentreUpdate` into the running `SoccerGameCentreSnapshot`.
/// This is where every anti-stale/anti-regression guarantee lives, for every soccer
/// provider: out-of-order responses are rejected outright (a game-switch race), the
/// authoritative score/clock only ever comes from the match endpoint, events merge by
/// identity rather than replace wholesale, and a lineup or stats line that has already
/// loaded can never be wiped by a later, emptier response.
nonisolated enum SoccerGameCentreReducer {
    /// Commentary is bounded in memory — this is generous enough that a full session
    /// of paging "load older" rarely hits it, while still capping worst case.
    private static let maxStoredCommentary = 500

    static func apply(_ update: SoccerGameCentreUpdate, to old: SoccerGameCentreSnapshot) -> SoccerGameCentreSnapshot {
        guard update.matchID == old.matchID, update.requestedAt >= old.fetchedAt else { return old }

        var result = old
        result.fetchedAt = update.requestedAt

        // Score/clock/status: always trust the match endpoint directly once it has
        // passed the ordering gate above — never reconstructed from events, which
        // sidesteps own-goal/VAR/penalty-correction bugs by design.
        if let match = update.match { result.match = match }

        if let events = update.events {
            var byID = Dictionary(uniqueKeysWithValues: old.events.map { ($0.id, $0) })
            for event in events { byID[event.id] = event }
            result.events = byID.values.sorted { a, b in
                if let ta = a.timestamp, let tb = b.timestamp, ta != tb { return ta < tb }
                if (a.minute ?? -1) != (b.minute ?? -1) { return (a.minute ?? -1) < (b.minute ?? -1) }
                return a.ordinal < b.ordinal
            }
            result.eventsLoaded = true
            result.lastEventsUpdate = update.requestedAt
        }

        // A lineup that has already loaded is never overwritten by a later "not
        // announced" (nil) response — that would only happen from a flaky/regressed
        // poll, not a real state change (lineups don't get un-announced).
        if let incomingHome = update.homeLineup, incomingHome != nil || old.homeLineup == nil { result.homeLineup = incomingHome }
        if let incomingAway = update.awayLineup, incomingAway != nil || old.awayLineup == nil { result.awayLineup = incomingAway }
        if update.homeLineup != nil || update.awayLineup != nil { result.lineupsLoaded = true; result.lastLineupsUpdate = update.requestedAt }

        if let homeStats = update.homeStats { result.homeStats = homeStats }
        if let awayStats = update.awayStats { result.awayStats = awayStats }
        if update.homeStats != nil || update.awayStats != nil { result.statsLoaded = true; result.lastStatsUpdate = update.requestedAt }

        if let officials = update.officials, !officials.isEmpty { result.officials = officials; result.officialsLoaded = true }

        if let incoming = update.commentary {
            var byID = Dictionary(uniqueKeysWithValues: old.commentary.map { ($0.id, $0) })
            for entry in incoming { byID[entry.id] = entry }
            let merged = byID.values.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            result.commentary = Array(merged.prefix(Self.maxStoredCommentary))
            result.lastCommentaryUpdate = update.requestedAt
        }
        if let cursor = update.commentaryNextCursor { result.commentaryNextCursor = cursor }

        if !update.playerDirectory.isEmpty { result.playerDirectory.merge(update.playerDirectory) { _, new in new } }
        if let liveStandings = update.liveStandings { result.liveStandings = liveStandings }
        if let conferenceStandings = update.conferenceStandings { result.conferenceStandings = conferenceStandings }
        if let playerMatchStats = update.playerMatchStats { result.playerMatchStats = playerMatchStats }
        if let penaltyShootout = update.penaltyShootout { result.penaltyShootout = penaltyShootout }

        if let shots = update.shots {
            var byID = Dictionary(uniqueKeysWithValues: old.shots.map { ($0.id, $0) })
            for shot in shots { byID[shot.id] = shot }
            result.shots = byID.values.sorted { ($0.minute ?? 0) < ($1.minute ?? 0) }
        }
        if let momentum = update.momentum { result.momentum = momentum }
        if let providerMatchIDs = update.providerMatchIDs { result.providerMatchIDs = providerMatchIDs }

        return result
    }
}
