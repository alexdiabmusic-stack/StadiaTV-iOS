import Foundation

struct FantasyPlayerResolver: Sendable {
    private let persistence: FantasyPersistenceStore

    nonisolated init(persistence: FantasyPersistenceStore = .shared) {
        self.persistence = persistence
    }

    func resolve(
        players: [FantasyPlayer],
        knownStadiaPlayers: [StadiaPlayerIdentity] = []
    ) async -> [String: FantasyPlayerResolution] {
        var persisted = await persistence.loadMappings()
        var output: [String: FantasyPlayerResolution] = [:]
        let knownByESPNID = Dictionary(grouping: knownStadiaPlayers.compactMap { identity in
            identity.espnAthleteID.map { ($0, identity) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        let knownByNameTeam = Dictionary(grouping: knownStadiaPlayers, by: {
            Self.nameTeamKey(name: $0.displayName, team: $0.teamAbbreviation)
        })
        let knownBySurnameTeamPosition = Dictionary(grouping: knownStadiaPlayers, by: {
            Self.surnameTeamPositionKey(name: $0.displayName, team: $0.teamAbbreviation, position: $0.position)
        })

        for player in players {
            if let cached = persisted[player.id], cachedStillMatches(cached, player: player) {
                output[player.id] = .resolved(cached)
                continue
            }

            if let espnID = player.externalIDs.espnID, !espnID.isEmpty {
                let candidates = knownByESPNID[espnID] ?? []
                if candidates.count == 1 {
                    output[player.id] = .resolved(candidates[0])
                    persisted[player.id] = candidates[0]
                    continue
                } else if candidates.count > 1 {
                    output[player.id] = .ambiguous(candidates)
                    continue
                } else {
                    let identity = StadiaPlayerIdentity(
                        id: "espn:\(espnID)",
                        leaguePath: player.sport.stadiaLeague?.path ?? "",
                        displayName: player.fullName,
                        teamAbbreviation: player.teamAbbreviation,
                        position: player.position,
                        espnAthleteID: espnID,
                        source: "\(player.provider.rawValue).external.espn"
                    )
                    output[player.id] = .resolved(identity)
                    persisted[player.id] = identity
                    continue
                }
            }

            let exactCandidates = knownByNameTeam[Self.nameTeamKey(name: player.fullName, team: player.teamAbbreviation)] ?? []
            if exactCandidates.count == 1 {
                output[player.id] = .resolved(exactCandidates[0])
                persisted[player.id] = exactCandidates[0]
                continue
            } else if exactCandidates.count > 1 {
                output[player.id] = .ambiguous(exactCandidates)
                continue
            }

            let surnameCandidates = knownBySurnameTeamPosition[Self.surnameTeamPositionKey(name: player.fullName, team: player.teamAbbreviation, position: player.position)] ?? []
            if surnameCandidates.count == 1 {
                output[player.id] = .resolved(surnameCandidates[0])
                persisted[player.id] = surnameCandidates[0]
                continue
            } else if surnameCandidates.count > 1 {
                output[player.id] = .ambiguous(surnameCandidates)
                continue
            }

            let fuzzyCandidates = carefullyFuzzyMatch(player, in: knownStadiaPlayers)
            if fuzzyCandidates.count == 1 {
                output[player.id] = .resolved(fuzzyCandidates[0])
                persisted[player.id] = fuzzyCandidates[0]
            } else if fuzzyCandidates.count > 1 {
                output[player.id] = .ambiguous(fuzzyCandidates)
            } else {
                output[player.id] = .unresolved("No reliable Stadia player identity match")
            }
        }

        await persistence.saveMappings(persisted)
        return output
    }

    func invalidateMapping(for sleeperPlayerID: String) async {
        var mappings = await persistence.loadMappings()
        mappings.removeValue(forKey: sleeperPlayerID)
        await persistence.saveMappings(mappings)
    }

    private func cachedStillMatches(_ cached: StadiaPlayerIdentity, player: FantasyPlayer) -> Bool {
        if let cachedTeam = cached.teamAbbreviation, let currentTeam = player.teamAbbreviation, cachedTeam != currentTeam {
            return false
        }
        if let cachedPosition = cached.position, let currentPosition = player.position, cachedPosition != currentPosition {
            return false
        }
        return true
    }

    private func carefullyFuzzyMatch(_ player: FantasyPlayer, in identities: [StadiaPlayerIdentity]) -> [StadiaPlayerIdentity] {
        guard let team = player.teamAbbreviation, !team.isEmpty else { return [] }
        let target = FantasyStringNormalizer.normalize(player.fullName)
        let candidates = identities.filter { identity in
            identity.teamAbbreviation == team && (identity.position == nil || player.position == nil || identity.position == player.position)
        }
        let strong = candidates.filter { candidate in
            let name = FantasyStringNormalizer.normalize(candidate.displayName)
            return levenshteinDistance(target, name) <= 1
        }
        return strong.count == 1 ? strong : []
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func nameTeamKey(name: String, team: String?) -> String {
        "\(FantasyStringNormalizer.normalize(name))|\(team ?? "")"
    }

    private static func surnameTeamPositionKey(name: String, team: String?, position: String?) -> String {
        let surname = FantasyStringNormalizer.normalize(name).split(separator: " ").last.map(String.init) ?? ""
        return "\(surname)|\(team ?? "")|\(position ?? "")"
    }
}
