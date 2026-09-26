import Foundation

/// Maps a match overview's top-level `referees[]` into `[SoccerOfficial]`. Unlike
/// EPL, officials arrive bundled in the match overview response itself — no
/// separate endpoint call is needed. Roles confirmed live: `referee`,
/// `firstAssistant`, `secondAssistant`, `fourthOfficial`, `videoReferee`,
/// `videoRefereeAssistant` — preserved verbatim rather than forced into a fixed enum.
nonisolated enum MLSOfficialsMapper {
    static func officials(_ raw: MLSValue) -> [SoccerOfficial] {
        raw["referees"].array.compactMap { entry -> SoccerOfficial? in
            let name = [entry["first_name"].string, entry["last_name"].string].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return SoccerOfficial(name: name, role: entry["role"].string ?? "Official")
        }
    }
}
