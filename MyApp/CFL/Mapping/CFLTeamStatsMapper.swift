import Foundation

/// `/api/stats/teamrecords` (verified live: ~150-field schema matching `cfl-sdk`'s
/// `types.py`) has no per-fixture scoping — only season-to-date cumulative totals are
/// available from this endpoint (confirmed by inspecting the real response shape), so
/// this mapper is explicitly a season-stats view, never mislabeled as this game's stats.
/// Ordered per the CFL stats-tab priority: First Downs/Total Offence/Passing/Rushing/
/// Turnovers/2nd-Down/3rd-Down/Red Zone/Penalties/Time of Possession/Sacks first;
/// returns/special-teams/rouge counts live under "More Stats".
nonisolated enum CFLTeamStatsMapper {
    nonisolated struct Row: Identifiable, Sendable { let id = UUID(); let title: String; let home: String; let away: String }

    static func rows(home: CFLValue, away: CFLValue) -> (primary: [Row], more: [Row]) {
        func text(_ raw: CFLValue, _ key: String) -> String { raw[key].string ?? "–" }
        func ratio(_ raw: CFLValue, _ made: String, _ attempted: String) -> String { "\(text(raw, made))/\(text(raw, attempted))" }
        func penalties(_ raw: CFLValue) -> String {
            let offense = raw["penaltiesChargedOffense"].int ?? 0
            let defense = raw["penaltiesChargedDefense"].int ?? 0
            return String(offense + defense)
        }
        func timeOfPossession(_ raw: CFLValue) -> String {
            guard let seconds = raw["timeOfPossessionSeconds"].int else { return "–" }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        let primary: [Row] = [
            Row(title: "First Downs", home: text(home, "firstDowns"), away: text(away, "firstDowns")),
            Row(title: "Total Offence", home: text(home, "offenseYards"), away: text(away, "offenseYards")),
            Row(title: "Passing Yards", home: text(home, "passesSucceededYards"), away: text(away, "passesSucceededYards")),
            Row(title: "Rushing Yards", home: text(home, "rushingYards"), away: text(away, "rushingYards")),
            Row(title: "Turnovers", home: text(home, "turnovers"), away: text(away, "turnovers")),
            Row(title: "2nd Down Conversions", home: ratio(home, "secondDownsConversions", "secondDownsAttempted"), away: ratio(away, "secondDownsConversions", "secondDownsAttempted")),
            Row(title: "3rd Down Conversions", home: ratio(home, "thirdDownsConversions", "thirdDownsAttempted"), away: ratio(away, "thirdDownsConversions", "thirdDownsAttempted")),
            Row(title: "Red Zone", home: ratio(home, "driveInsideTwentySucceeded", "driveInsideTwentyAttempted"), away: ratio(away, "driveInsideTwentySucceeded", "driveInsideTwentyAttempted")),
            Row(title: "Penalties", home: penalties(home), away: penalties(away)),
            Row(title: "Time of Possession", home: timeOfPossession(home), away: timeOfPossession(away)),
            Row(title: "Sacks", home: text(home, "sacks"), away: text(away, "sacks")),
        ]
        let more: [Row] = [
            Row(title: "Field Goals", home: ratio(home, "fieldGoalsSucceeded", "fieldGoalsAttempted"), away: ratio(away, "fieldGoalsSucceeded", "fieldGoalsAttempted")),
            Row(title: "Punt Return Yards", home: text(home, "puntingReturnsYards"), away: text(away, "puntingReturnsYards")),
            Row(title: "Kickoff Return Yards", home: text(home, "kickoffsReturnsYards"), away: text(away, "kickoffsReturnsYards")),
            Row(title: "Singles (Rouge)", home: text(home, "singles"), away: text(away, "singles")),
        ]
        return (primary, more)
    }
}
