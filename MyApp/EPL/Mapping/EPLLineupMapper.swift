import Foundation

/// Maps `/v3/matches/{id}/lineups`. Verified live 2026-09-23: `formation.lineup` is a
/// nested array of player-ID rows (goalkeeper-first, then each tactical line) that
/// already matches the formation string exactly — the pitch view renders straight
/// from that structured grouping and never needs to parse "4-2-3-1" itself.
/// An unannounced lineup returns HTTP 200 with an empty `players` array (not a 404)
/// — the mapper turns that into `nil`, which the UI reads as "not announced yet"
/// rather than an error.
nonisolated enum EPLLineupMapper {
    static func lineup(_ raw: EPLValue, team: SoccerTeam) -> SoccerLineup? {
        let playersRaw = raw["players"].array
        guard !playersRaw.isEmpty else { return nil }
        var byID: [String: EPLValue] = [:]
        for player in playersRaw { if let id = player["id"].string { byID[id] = player } }

        func slot(_ id: String, isStarter: Bool) -> SoccerLineupPlayer? {
            guard let raw = byID[id] else { return nil }
            let reference = SoccerPlayerReference(id: id, firstName: raw["firstName"].string, lastName: raw["lastName"].string)
            return SoccerLineupPlayer(reference: reference, shirtNumber: raw["shirtNum"].string, position: raw["position"].string, isCaptain: raw["isCaptain"].bool ?? false, isStarter: isStarter)
        }

        let formationRaw = raw["formation"]["formation"].string
        let rows = raw["formation"]["lineup"].array.map { $0.array.compactMap { $0.string } }
        let subIDs = raw["formation"]["subs"].array.compactMap { $0.string }
        let starters: [SoccerLineupPlayer]
        let substitutes: [SoccerLineupPlayer]
        if rows.isEmpty {
            // No formation grouping supplied — `players` still lists everyone, but
            // there's no signal distinguishing starter from substitute membership.
            // Falling back to "everyone" as a structured list (rather than dropping
            // the roster entirely) satisfies Step 27: a starting-XI list, not a
            // fabricated pitch, and never silently empty when real data exists.
            starters = playersRaw.compactMap { $0["id"].string }.compactMap { slot($0, isStarter: true) }
            substitutes = []
        } else {
            starters = rows.flatMap { $0 }.compactMap { slot($0, isStarter: true) }
            substitutes = subIDs.compactMap { slot($0, isStarter: false) }
        }
        let formation = (formationRaw.flatMap { $0.isEmpty ? nil : $0 }).map { SoccerFormation(raw: $0, rows: rows) }

        let manager = raw["managers"].array.first
        let managerName = manager.flatMap { m -> String? in
            let full = [m["firstName"].string, m["lastName"].string].compactMap { $0 }.joined(separator: " ")
            return full.isEmpty ? nil : full
        }

        return SoccerLineup(team: team, formation: formation, starters: starters, substitutes: substitutes, managerName: managerName)
    }
}
