import Foundation

/// Maps `/api/v1/teams/{slug}/squad` rows into `[SoccerRosterPlayer]`. Verified live
/// 2026-09-24 (Real Madrid squad): the row nests player identity under `person`
/// (distinct from the squad-row's own `id`), and the row's own `opta_id` (`p60772`)
/// is the stable cross-endpoint join key (Step 6) — that becomes
/// `SoccerPlayerReference.id`, never `person.id` or the squad-row id. `role.slug ==
/// "jugador"` distinguishes players from any non-player entry the endpoint might
/// return; `current == false` rows (out on loan / historical) are excluded by default.
nonisolated enum LaLigaSquadMapper {
    static func roster(_ raw: LaLigaValue, activeOnly: Bool = true) -> [SoccerRosterPlayer] {
        raw["squads"].array.compactMap { row -> SoccerRosterPlayer? in
            guard row["role"]["slug"].string == "jugador" || row["role"].object.isEmpty else { return nil }
            if activeOnly, row["current"].bool == false { return nil }
            return player(row)
        }
    }

    static func player(_ row: LaLigaValue) -> SoccerRosterPlayer? {
        let person = row["person"]
        guard let id = row["opta_id"].string ?? person["id"].string else { return nil }
        let reference = SoccerPlayerReference(id: id, firstName: person["firstname"].string, lastName: person["lastname"].string)
        return SoccerRosterPlayer(reference: reference, position: positionLabel(row["position"]["id"].int, raw: row["position"]["name"].string),
            shirtNumber: row["shirt_number"].string, nationality: person["country"]["id"].string, dateOfBirth: LaLigaDate.parse(person["date_of_birth"].string))
    }

    /// La Liga's `position.id` is stable and documented (1 GK / 2 DF / 3 MF / 4 FW —
    /// verified live 2026-09-24); translated to an English label to match EPL/MLS's
    /// display convention instead of the API's Spanish `position.name` (Step 39 —
    /// canonical logic depends only on the stable `id`, never the localized string).
    private static func positionLabel(_ id: Int?, raw: String?) -> String? {
        switch id {
        case 1: return "Goalkeeper"
        case 2: return "Defender"
        case 3: return "Midfielder"
        case 4: return "Forward"
        default: return raw
        }
    }
}
