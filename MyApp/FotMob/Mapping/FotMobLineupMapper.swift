import Foundation

/// Maps `content.lineup.homeTeam`/`awayTeam` into `SoccerLineup`. Unlike EPL/MLS's
/// providers, FotMob does not hand back pre-grouped formation rows — each starter
/// instead carries `verticalLayout.y`/`horizontalLayout` pitch-fraction coordinates
/// (verified live 2026-09-24). This derives row grouping from those coordinates
/// plus the formation string's own line sizes (e.g. "3-5-2" -> [3,5,2] outfield
/// players after the keeper) rather than parsing the formation string alone — a
/// heuristic, not verbatim provider structure, disclosed here and in
/// LALIGA-INTEGRATION.md. The goalkeeper is identified as the starter with the
/// smallest `verticalLayout.y` (closest to their own goal), which held for the one
/// real lineup sampled but is not a documented FotMob contract.
nonisolated enum FotMobLineupMapper {
    static func lineup(_ raw: FotMobValue, team: SoccerTeam) -> SoccerLineup? {
        let starters = raw["starters"].array
        guard !starters.isEmpty else { return nil }
        let subs = raw["subs"].array
        let formationRaw = raw["formation"].string

        let starterSlots = starters.map { slot($0, isStarter: true) }
        let subSlots = subs.map { slot($0, isStarter: false) }
        let rows = formationRows(starters: starters, formation: formationRaw)
        let formation = formationRaw.flatMap { $0.isEmpty ? nil : $0 }.map { SoccerFormation(raw: $0, rows: rows) }
        let managerName = raw["coach"]["name"].string

        return SoccerLineup(team: team, formation: formation, starters: starterSlots, substitutes: subSlots, managerName: managerName)
    }

    private static func slot(_ raw: FotMobValue, isStarter: Bool) -> SoccerLineupPlayer {
        let reference = SoccerPlayerReference(id: raw["id"].string ?? "", firstName: raw["firstName"].string, lastName: raw["lastName"].string)
        return SoccerLineupPlayer(reference: reference, shirtNumber: raw["shirtNumber"].string, position: nil,
            isCaptain: false, isStarter: isStarter, rating: raw["performance"]["rating"].double)
    }

    private static func formationRows(starters: [FotMobValue], formation: String?) -> [[String]] {
        guard starters.count == 11, let formation else { return [] }
        let lineSizes = formation.split(separator: "-").compactMap { Int($0) }
        guard lineSizes.reduce(0, +) == 10 else { return [] } // outfield players only; keeper is separate
        let sorted = starters.sorted { ($0["verticalLayout"]["y"].double ?? 0) < ($1["verticalLayout"]["y"].double ?? 0) }
        guard let goalkeeper = sorted.first?["id"].string else { return [] }
        var rows: [[String]] = [[goalkeeper]]
        var cursor = 1
        for size in lineSizes {
            let line = sorted[cursor..<min(cursor + size, sorted.count)].compactMap { $0["id"].string }
            rows.append(line)
            cursor += size
        }
        return rows
    }
}
