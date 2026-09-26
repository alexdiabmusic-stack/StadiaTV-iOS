import Foundation

/// Maps a match overview's `home`/`away` block into `SoccerLineup`. MLS supplies
/// only a formation *label* (`latest_line_up`: `"4-3-3"`) with no per-player pitch
/// coordinates or tactical-row grouping — unlike PulseLive, there is no `rows` data
/// to derive at all, structured or otherwise. Per the integration brief, this never
/// invents positions: `SoccerFormation(rows:)` is left empty so `SoccerFormationPitchView`
/// has nothing to (mis)render, while the label itself still displays via `raw`.
/// Starters/substitutes fall back to a flat list grouped by `playing_position` when
/// supplied, or one undivided group when it isn't.
nonisolated enum MLSLineupMapper {
    static func lineup(_ block: MLSValue, team: SoccerTeam) -> SoccerLineup? {
        let players = block["players"].array
        guard !players.isEmpty else { return nil }  // not yet announced
        let slots = players.compactMap { player -> SoccerLineupPlayer? in
            guard let reference = MLSMatchMapper.playerReference(player) else { return nil }
            return SoccerLineupPlayer(reference: reference, shirtNumber: player["shirt_number"].int.map(String.init),
                position: nonEmpty(player["playing_position"].string), isCaptain: player["team_leader"].bool ?? false,
                isStarter: player["starting"].bool ?? false)
        }
        let starters = slots.filter(\.isStarter)
        let substitutes = slots.filter { !$0.isStarter }
        let formationLabel = nonEmpty(block["latest_line_up"].string) ?? nonEmpty(block["initial_line_up"].string)
        let manager = block["trainer_staff"].array.first { $0["role"].string == "headcoach" }
        let managerName = manager.map { [$0["first_name"].string, $0["last_name"].string].compactMap { $0 }.joined(separator: " ") }
        return SoccerLineup(team: team, formation: formationLabel.map { SoccerFormation(raw: $0, rows: []) },
            starters: starters, substitutes: substitutes, managerName: managerName)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
