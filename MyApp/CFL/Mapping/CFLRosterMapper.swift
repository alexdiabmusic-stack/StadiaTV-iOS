import Foundation

/// `/api/teams/{id}/roster` (verified live) has no explicit nationality/eligibility field
/// in the current schema — `state`/`roster_counter` are surfaced verbatim rather than
/// interpreted into a National/International designation that isn't actually in the data.
nonisolated enum CFLRosterMapper {
    static func groups(_ raw: CFLValue) -> [RosterGroup] {
        let players = raw["rosterplayers"].array
        let grouped = Dictionary(grouping: players) { $0["position"].string ?? "Players" }
        return grouped.keys.sorted().map { key in
            RosterGroup(id: key, title: key, athletes: (grouped[key] ?? []).compactMap { person -> RosterAthlete? in
                guard let id = person["player_id"].string else { return nil }
                let name = [person["firstname"].string, person["lastname"].string].compactMap { $0 }.joined(separator: " ")
                var player = RosterAthlete(id: id, displayName: name.isEmpty ? "Unknown player" : name, jersey: person["jersey_no"].string,
                    position: person["position"].string, positionName: person["position"].string, headshotURL: nil,
                    age: nil, displayHeight: heightText(person), displayWeight: person["weight_lbs"].string.map { "\($0) lb" },
                    college: person["college"].string, experienceYears: nil,
                    birthPlace: nil, isInjured: person["state"].string == "injured_list")
                player.canonicalID = "player:league.football-cfl:cfl:\(id)"
                return player
            })
        }
    }
    private static func heightText(_ person: CFLValue) -> String? {
        guard let ft = person["height_ft"].int else { return nil }
        let inches = person["height_in"].int ?? 0
        return "\(ft)′ \(inches)″"
    }
}
