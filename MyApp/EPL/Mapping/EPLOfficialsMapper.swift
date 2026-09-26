import Foundation

/// Maps `/v1/matches/{id}/officials`: `{matchOfficials:[{official:{name},type}]}`.
nonisolated enum EPLOfficialsMapper {
    static func officials(_ raw: EPLValue) -> [SoccerOfficial] {
        raw["matchOfficials"].array.compactMap { entry in
            guard let name = entry["official"]["name"].string else { return nil }
            return SoccerOfficial(name: name, role: entry["type"].string ?? "Official")
        }
    }
}
